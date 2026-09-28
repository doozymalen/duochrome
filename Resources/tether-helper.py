# Duochrome 테더링 도우미: 공개 라이브러리 libgphoto2(python-gphoto2)로 USB에 연결한 카메라를 다룬다.
# Duochrome과는 표준 입출력으로 JSON 한 줄씩 주고받는다. 유선(USB) 전용.
#  받는 명령: {"cmd":"connect"} {"cmd":"set","name":"iso","value":"400"} {"cmd":"capture"}
#            {"cmd":"live","on":true} {"cmd":"af"} {"cmd":"focus","step":"Near 1"} {"cmd":"zoom","value":"5"}
#            {"cmd":"folder","path":"..."} {"cmd":"quit"}
#  보내는 소식: connected / config / frame(JPEG base64) / file / status / error / disconnected
import sys, os, json, time, base64, threading, queue, subprocess

try:
    import gphoto2 as gp
except Exception as e:  # 설치 전
    print(json.dumps({"ev": "error", "msg": "gphoto2 없음: %s" % e}), flush=True)
    sys.exit(2)

WANTED = ["aperture", "shutterspeed", "iso", "whitebalance", "colortemperature", "exposurecompensation",
          "imageformat", "drivemode", "focusmode", "capturetarget", "manualfocusdrive", "eoszoom", "batterylevel"]

out_lock = threading.Lock()


def emit(ev, **kw):
    kw["ev"] = ev
    with out_lock:
        sys.stdout.write(json.dumps(kw, ensure_ascii=False) + "\n")
        sys.stdout.flush()


cmds = queue.Queue()


def reader():
    for line in sys.stdin:
        line = line.strip()
        if line:
            try:
                cmds.put(json.loads(line))
            except Exception:
                emit("error", msg="명령을 읽지 못함: " + line[:80])
    cmds.put({"cmd": "quit"})


class Tether:
    def __init__(self):
        self.camera = None
        self.live = False
        self.folder = os.path.expanduser("~/Pictures")
        self.last_frame = 0.0
        self.auto = False
        self.last_try = 0.0

    # macOS의 사진 가져오기 데몬(ptpcamerad)이 카메라를 먼저 잡으면 USB를 열 수 없다 → 잠시 끄고 연다
    def _free_usb(self):
        subprocess.run(["killall", "-9", "ptpcamerad"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def connect(self, quiet=False):
        self.close()
        cl = gp.Camera.autodetect()
        if cl.count() == 0:
            if not quiet:
                emit("status", msg="카메라를 찾지 못했습니다. USB로 연결하고 카메라를 켜 주세요.", connected=False)
            return False
        last = None
        for _ in range(5):
            self._free_usb()
            time.sleep(0.3)
            try:
                cam = gp.Camera()
                cam.init()
                self.camera = cam
                break
            except gp.GPhoto2Error as e:
                last = e
                time.sleep(0.7)
        if not self.camera:
            emit("error", msg="카메라를 열지 못함: %s (다른 프로그램이 쓰는 중일 수 있음)" % last)
            return False
        summary = cl.get_name(0)
        emit("connected", model=summary)
        self.send_config()
        return True

    def close(self):
        if self.camera:
            try:
                if self.live:
                    self._set("viewfinder", 0)
                self.camera.exit()
            except Exception:
                pass
        self.camera = None
        self.live = False

    def send_config(self):
        cfg = self.camera.get_config()
        items = {}
        for name in WANTED:
            try:
                w = cfg.get_child_by_name(name)
            except gp.GPhoto2Error:
                continue
            item = {"label": w.get_label(), "value": str(w.get_value()), "readonly": bool(w.get_readonly())}
            t = w.get_type()
            if t in (gp.GP_WIDGET_RADIO, gp.GP_WIDGET_MENU):
                item["choices"] = [str(w.get_choice(i)) for i in range(w.count_choices())]
            items[name] = item
        emit("config", items=items)

    def _set(self, name, value):
        cfg = self.camera.get_config()
        w = cfg.get_child_by_name(name)
        t = w.get_type()
        if t in (gp.GP_WIDGET_TOGGLE,):
            value = int(value)
        elif t == gp.GP_WIDGET_RANGE:
            value = float(value)
        w.set_value(value)
        self.camera.set_config(cfg)

    def set(self, name, value):
        try:
            self._set(name, value)
        except gp.GPhoto2Error as e:
            emit("error", msg="%s 바꾸기 실패: %s" % (name, e))
        self.send_config()

    def download(self, path):
        os.makedirs(self.folder, exist_ok=True)
        dst = os.path.join(self.folder, path.name)
        n = 1
        base, ext = os.path.splitext(dst)
        while os.path.exists(dst):
            dst = "%s-%d%s" % (base, n, ext)
            n += 1
        f = self.camera.file_get(path.folder, path.name, gp.GP_FILE_TYPE_NORMAL)
        f.save(dst)
        emit("file", path=dst)

    def capture(self):
        was_live = self.live
        try:
            emit("status", msg="촬영 중…")
            path = self.camera.capture(gp.GP_CAPTURE_IMAGE)
            self.download(path)
            # RAW+JPEG 등 함께 생긴 파일은 소식으로 뒤따라 온다
            t0 = time.time()
            while time.time() - t0 < 1.5:
                ev, data = self.camera.wait_for_event(200)
                if ev == gp.GP_EVENT_FILE_ADDED:
                    self.download(data)
                    t0 = time.time()
                elif ev == gp.GP_EVENT_TIMEOUT:
                    break
        except gp.GPhoto2Error as e:
            emit("error", msg="촬영 실패: %s" % e)
        self.live = was_live

    def frame(self):
        try:
            f = self.camera.capture_preview()
            data = memoryview(f.get_data_and_size()).tobytes()
            emit("frame", jpeg=base64.b64encode(data).decode())
        except gp.GPhoto2Error as e:
            emit("error", msg="라이브 뷰 실패: %s" % e)
            self.live = False
            emit("live", on=False)

    def poll_events(self):
        # 카메라 셔터로 직접 찍은 사진도 받는다
        try:
            ev, data = self.camera.wait_for_event(150)
        except gp.GPhoto2Error:
            emit("disconnected")
            try:
                self.camera.exit()
            except Exception:
                pass
            self.camera = None
            return
        if ev == gp.GP_EVENT_FILE_ADDED:
            self.download(data)

    def handle(self, c):
        cmd = c.get("cmd")
        if cmd == "folder":
            self.folder = c.get("path", self.folder)
            return True
        if cmd == "connect":
            self.auto = True   # 이후로는 카메라를 꽂으면 알아서 붙는다
            self.connect()
            return True
        if cmd == "quit":
            self.close()
            return False
        if not self.camera:
            emit("error", msg="카메라가 연결되지 않았습니다.")
            return True
        try:
            if cmd == "set":
                self.set(c["name"], c["value"])
            elif cmd == "capture":
                self.capture()
            elif cmd == "live":
                self.live = bool(c.get("on"))
                if not self.live:
                    try:
                        self._set("viewfinder", 0)
                    except gp.GPhoto2Error:
                        pass
                emit("live", on=self.live)
            elif cmd == "af":
                self._set("autofocusdrive", 1)
                try:
                    self._set("autofocusdrive", 0)
                except gp.GPhoto2Error:
                    pass
            elif cmd == "focus":
                self._set("manualfocusdrive", c["step"])
                try:
                    self._set("manualfocusdrive", "None")
                except gp.GPhoto2Error:
                    pass
            elif cmd == "zoom":
                self._set("eoszoom", c["value"])
            elif cmd == "refresh":
                self.send_config()
        except (gp.GPhoto2Error, KeyError, ValueError) as e:
            emit("error", msg="%s 실패: %s" % (cmd, e))
        return True

    def run(self):
        threading.Thread(target=reader, daemon=True).start()
        running = True
        while running:
            try:
                c = cmds.get(timeout=0.01 if self.live else 0.05)
                running = self.handle(c)
                continue
            except queue.Empty:
                pass
            if not self.camera:
                if self.auto and time.time() - self.last_try > 2:
                    self.last_try = time.time()
                    self.connect(quiet=True)
                else:
                    time.sleep(0.2)
                continue
            if self.live:
                now = time.time()
                if now - self.last_frame >= 1 / 20:   # 초당 최대 20장
                    self.last_frame = now
                    self.frame()
            else:
                self.poll_events()


class FakeTether(Tether):
    """시험용 가짜 카메라 (DUOCHROME_TETHER_FAKE=원본 RAW 경로): 화면·받기 흐름을 카메라 없이 확인한다"""
    def __init__(self, sample):
        super().__init__()
        self.sample = sample
        self.values = {"aperture": "8", "shutterspeed": "1/125", "iso": "400", "whitebalance": "Auto",
                       "imageformat": "RAW", "exposurecompensation": "0"}
        self.choices = {"aperture": ["2.8", "4", "5.6", "8", "11", "16"], "shutterspeed": ["1/30", "1/60", "1/125", "1/250"],
                        "iso": ["100", "200", "400", "800", "1600"], "whitebalance": ["Auto", "Daylight", "Tungsten"],
                        "imageformat": ["RAW", "RAW + Large Fine JPEG"], "exposurecompensation": ["-1", "0", "1"]}
        self.n = 0

    def connect(self, quiet=False):
        self.camera = True
        emit("connected", model="가짜 카메라 (시험)")
        self.send_config()
        return True

    def close(self):
        self.camera = None
        self.live = False

    def send_config(self):
        items = {k: {"label": k, "value": v, "readonly": False, "choices": self.choices[k]} for k, v in self.values.items()}
        items["batterylevel"] = {"label": "battery", "value": "80%", "readonly": True}
        emit("config", items=items)

    def _set(self, name, value):
        if name in self.values:
            self.values[name] = str(value)

    def set(self, name, value):
        self._set(name, value)
        self.send_config()

    def capture(self):
        import shutil
        self.n += 1
        os.makedirs(self.folder, exist_ok=True)
        ext = os.path.splitext(self.sample)[1]
        dst = os.path.join(self.folder, "IMG_%04d%s" % (9000 + self.n, ext))
        shutil.copyfile(self.sample, dst)
        emit("file", path=dst)

    def frame(self):
        # 원본에 들어 있는 미리보기 JPEG를 라이브 뷰처럼 보낸다
        if not hasattr(self, "jpeg"):
            data = open(self.sample, "rb").read()
            i = data.find(b"\xff\xd8\xff", 1000)
            j = data.find(b"\xff\xd9", i)
            self.jpeg = data[i:j + 2] if i > 0 and j > 0 else b""
        if self.jpeg:
            emit("frame", jpeg=base64.b64encode(self.jpeg).decode())

    def poll_events(self):
        time.sleep(0.1)

    def handle(self, c):
        if c.get("cmd") in ("af", "focus", "zoom"):
            emit("status", msg="(가짜) %s" % c.get("cmd"))
            return True
        return super().handle(c)


if __name__ == "__main__":
    emit("ready", version=gp.gp_library_version(gp.GP_VERSION_SHORT)[0])
    fake = os.environ.get("DUOCHROME_TETHER_FAKE")
    (FakeTether(fake) if fake else Tether()).run()
