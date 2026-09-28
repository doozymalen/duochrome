# Duochrome 원격 엔진: 코랩 가상 머신의 커널 안에서만 돈다.
# 웹 화면·원격 접속 없이, Duochrome이 공식 코랩 명령줄 도구로 파일을 올리고 이 함수들을 부른 뒤 결과를 받아 간다.
# 엔진(ComfyUI)은 가상 머신 안 127.0.0.1에서만 듣는다 (바깥에 열지 않음).
import os, sys, json, time, shutil, subprocess, urllib.request, urllib.error

ST_ROOT = "/content/ComfyUI"
ST_JOBS = "/content/duochrome_jobs"
ST_PORT = 8188
os.makedirs("/root/.cache/huggingface", exist_ok=True)
os.makedirs(ST_JOBS, exist_ok=True)


def _say(s):
    print(s, flush=True)


def _alive():
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{ST_PORT}/system_stats", timeout=2)
        return True
    except Exception:
        return False


def duochrome_ready():
    print("DUOCHROME_READY" if _alive() and os.path.exists("/content/duochrome_ready") else "DUOCHROME_NOT_READY", flush=True)


def duochrome_gpu():
    out = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader"], capture_output=True, text=True).stdout.strip()
    print("DUOCHROME_GPU " + out, flush=True)


def duochrome_setup():
    t0 = time.time()
    if not os.path.isdir(ST_ROOT):
        _say("@@단계 1/4 엔진 내려받기")
        subprocess.run(["git", "clone", "--depth", "1", "-q", "https://github.com/comfyanonymous/ComfyUI", ST_ROOT], check=True)
    _say("@@단계 2/4 엔진 부품 설치")
    subprocess.run([sys.executable, "-m", "pip", "install", "-q", "-r", f"{ST_ROOT}/requirements.txt", "hf_transfer", "spandrel"], check=True)
    os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
    from huggingface_hub import hf_hub_download
    m = f"{ST_ROOT}/models"
    _say("@@단계 3/4 모델 받기 (약 30GB)")
    for repo, fn, sub in [
        ("black-forest-labs/FLUX.1-Fill-dev", "flux1-fill-dev.safetensors", "diffusion_models"),
        ("black-forest-labs/FLUX.1-Fill-dev", "ae.safetensors", "vae"),
        ("comfyanonymous/flux_text_encoders", "clip_l.safetensors", "text_encoders"),
        ("comfyanonymous/flux_text_encoders", "t5xxl_fp8_e4m3fn.safetensors", "text_encoders"),
    ]:
        if not os.path.exists(f"{m}/{sub}/{fn}"):
            t1 = time.time()
            hf_hub_download(repo, fn, local_dir=f"{m}/{sub}")
            _say(f"@@받음 {fn} {time.time() - t1:.0f}초")
    for url in ["https://github.com/cszn/KAIR/releases/download/v1.0/scunet_color_real_psnr.pth",
                "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth"]:
        dst = f"{m}/upscale_models/{url.rsplit('/', 1)[1]}"
        if not os.path.exists(dst):
            urllib.request.urlretrieve(url, dst)
    # 반사 제거 (DSIT): Duochrome 전용 부품이 /content/xreflection, /content/reflection 을 쓴다.
    # 배포 서버가 파이썬 이름의 요청을 거절해(403) curl로 받는다. 실패해도 다른 기능은 쓸 수 있게 넘어간다
    try:
        if not os.path.isdir("/content/xreflection"):
            subprocess.run(["git", "clone", "--depth", "1", "-q", "https://github.com/hainuo-wang/XReflection", "/content/xreflection"], check=False)
        os.makedirs("/content/reflection", exist_ok=True)
        ck = "/content/reflection/dsit-26.6959.ckpt"
        if not os.path.exists(ck) or os.path.getsize(ck) < 2_000_000_000:
            subprocess.run(["curl", "-L", "--fail", "-s", "-C", "-", "-o", ck, "https://checkpoints.mingjia.li/dsit-26.6959.ckpt"], check=True)
        subprocess.run([sys.executable, "-m", "pip", "install", "-q", "timm"], check=False)
    except Exception as e:
        _say(f"@@경고 반사 제거 모델을 받지 못함: {e}")
    # Duochrome 전용 부품 (맥에서 올린 것). 바뀌었으면 엔진을 다시 켠다
    changed = False
    if os.path.exists("/content/duochrome_nodes.py"):
        dst = f"{ST_ROOT}/custom_nodes/duochrome_nodes/__init__.py"
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        new = open("/content/duochrome_nodes.py").read()
        if not os.path.exists(dst) or open(dst).read() != new:
            open(dst, "w").write(new)
            changed = True
    _say("@@단계 4/4 엔진 켜기")
    global _st_proc
    if changed and _alive():
        subprocess.run(["pkill", "-f", "main.py --listen 127.0.0.1 --port " + str(ST_PORT)], check=False)
        for _ in range(30):
            if not _alive():
                break
            time.sleep(1)
    if not _alive():
        log = open("/content/duochrome_engine.log", "a")
        subprocess.Popen([sys.executable, "main.py", "--listen", "127.0.0.1", "--port", str(ST_PORT),
                          "--disable-auto-launch", "--preview-method", "none"], cwd=ST_ROOT, stdout=log, stderr=log)
        for _ in range(300):
            if _alive():
                break
            time.sleep(1)
        else:
            raise RuntimeError("엔진이 켜지지 않음: " + open("/content/duochrome_engine.log").read()[-800:])
    open("/content/duochrome_ready", "w").write("ok")
    _say(f"@@끝 {time.time() - t0:.0f}")


def duochrome_job(name, jpeg=False):
    """ST_JOBS/<name>.json 작업 흐름을 돌려 결과를 ST_JOBS/<name>-out.png 로 (큰 결과는 jpeg=True로 줄여 받는다)"""
    t0 = time.time()
    wf = json.load(open(f"{ST_JOBS}/{name}.json"))
    req = urllib.request.Request(f"http://127.0.0.1:{ST_PORT}/prompt", json.dumps({"prompt": wf}).encode(),
                                 {"Content-Type": "application/json"})
    try:
        pid = json.load(urllib.request.urlopen(req))["prompt_id"]
    except urllib.error.HTTPError as e:
        raise RuntimeError("작업을 받지 않음: " + e.read().decode()[:600])
    while True:
        time.sleep(0.3)
        h = json.load(urllib.request.urlopen(f"http://127.0.0.1:{ST_PORT}/history/{pid}"))
        if pid in h:
            break
        if time.time() - t0 > 1800:
            raise RuntimeError("30분 안에 끝나지 않음")
    e = h[pid]
    if e.get("status", {}).get("status_str") == "error":
        msgs = [m[1].get("exception_message", "") for m in e["status"].get("messages", []) if m[0] == "execution_error"]
        raise RuntimeError("작업 실패: " + (msgs[0] if msgs else "알 수 없음"))
    for o in e.get("outputs", {}).values():
        for im in o.get("images", []):
            dst = f"{ST_JOBS}/{name}-out.png"
            src = os.path.join(ST_ROOT, "output", im.get("subfolder", ""), im["filename"])
            if jpeg:
                from PIL import Image
                Image.open(src).convert("RGB").save(dst, "JPEG", quality=97, subsampling=0)
                os.remove(src)
            else:
                shutil.move(src, dst)
            for f in os.listdir(f"{ST_ROOT}/input"):
                if f.startswith(name):
                    os.remove(f"{ST_ROOT}/input/{f}")
            _say(f"@@결과 {dst} {time.time() - t0:.1f}")
            return
    raise RuntimeError("결과 그림이 없음")


_say("DUOCHROME_LOADED")


# 오래 걸리는 일은 커널 안 뒤 스레드에서 돌리고, Duochrome은 짧은 명령으로 상태만 묻는다
# (코랩 연결로 명령 하나를 30분씩 붙잡으면 응답을 잃고 멈출 때가 있었다)
import threading as _th
_st_tasks = {}


def _st_start(name, fn):
    _st_tasks[name] = {"state": "running", "step": "", "out": ""}
    def run():
        try:
            fn()
            _st_tasks[name]["state"] = "done"
        except Exception as e:
            _st_tasks[name]["state"] = "error: " + str(e)[:800]
    _th.Thread(target=run, daemon=True).start()
    print("DUOCHROME_STARTED", flush=True)


def duochrome_setup_start():
    global _say
    base_say = print
    def say(s):
        if "setup" in _st_tasks:
            _st_tasks["setup"]["step"] = s
        base_say(s, flush=True)
    _say = say
    _st_start("setup", duochrome_setup)


def duochrome_job_start(name, jpeg=False):
    _st_start(name, lambda: duochrome_job(name, jpeg))


def duochrome_status(name):
    t = _st_tasks.get(name, {"state": "unknown", "step": ""})
    print("DUOCHROME_STATE " + t["state"], flush=True)
    if t.get("step"):
        print("DUOCHROME_STEP " + t["step"], flush=True)
