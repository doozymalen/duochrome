# Duochrome tether helper: controls a USB-connected camera through libgphoto2 (python-gphoto2).
# Talks to Duochrome over stdin/stdout, one JSON object per line. Wired (USB) only.
#  Commands in: {"cmd":"connect"} {"cmd":"set","name":"iso","value":"400"} {"cmd":"capture"}
#            {"cmd":"live","on":true} {"cmd":"af"} {"cmd":"focus","step":-1} {"cmd":"zoom","value":"5"}
#            {"cmd":"folder","path":"..."} {"cmd":"quit"}
#  Events out: connected / config(+caps) / frame(JPEG base64) / file / status / error / disconnected
#  Focus/zoom config names differ by vendor; find the available ones on connect and report them in caps.
#  focus step: negative is nearer, positive is farther (1 = small, 3 = large).
import sys, os, json, time, base64, threading, queue, subprocess

try:
    import gphoto2 as gp
except Exception as e:  # before install
    print(json.dumps({"ev": "error", "msg": "gphoto2 없음: %s" % e}), flush=True)
    sys.exit(2)

WANTED = ["aperture", "shutterspeed", "iso", "whitebalance", "colortemperature", "exposurecompensation",
          "imageformat", "drivemode", "focusmode", "capturetarget", "batterylevel"]

# Vendor-specific config names (first match wins)
AF_NAMES = ["autofocusdrive", "autofocus"]                        # Canon/Nikon / Sony
FOCUS_NAMES = ["manualfocusdrive", "manualfocus"]                 # Canon (Near/Far steps), Nikon (range) / Sony (range)
ZOOM_NAMES = ["eoszoom", "liveviewzoomratio", "liveviewzoom"]     # Canon / Nikon etc. (only when it is a choice)
CHOICE_TYPES = (gp.GP_WIDGET_RADIO, gp.GP_WIDGET_MENU)

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

    # If macOS's photo import daemon (ptpcamerad) grabs the camera first, USB can't be opened → stop it briefly, then open
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

    @staticmethod
    def _find(cfg, names):
        for n in names:
            try:
                w = cfg.get_child_by_name(n)
            except gp.GPhoto2Error:
                continue
            if not w.get_readonly():
                return w
        return None

    @staticmethod
    def _choices(w):
        return [str(w.get_choice(i)) for i in range(w.count_choices())]

    def caps(self, cfg):
        """이 카메라에서 되는 것: 자동 초점, 수동 초점, 라이브 뷰 확대 값"""
        focus = False
        fw = self._find(cfg, FOCUS_NAMES)
        if fw is not None:
            if fw.get_type() in CHOICE_TYPES:
                ch = self._choices(fw)
                focus = any(c.startswith("Near") for c in ch) and any(c.startswith("Far") for c in ch)
            elif fw.get_type() == gp.GP_WIDGET_RANGE:
                focus = True
        zw = self._find(cfg, ZOOM_NAMES)
        zoom = self._choices(zw) if zw is not None and zw.get_type() in CHOICE_TYPES else []
        return {"af": self._find(cfg, AF_NAMES) is not None, "focus": focus, "zoom": zoom}

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
        emit("config", items=items, caps=self.caps(cfg))

    def _press(self, w, cfg, on, off):
        w.set_value(on)
        self.camera.set_config(cfg)
        try:
            w.set_value(off)
            self.camera.set_config(cfg)
        except gp.GPhoto2Error:
            pass

    def autofocus(self):
        cfg = self.camera.get_config()
        w = self._find(cfg, AF_NAMES)
        if w is None:
            raise ValueError("이 카메라는 원격 자동 초점을 지원하지 않습니다")
        self._press(w, cfg, 1, 0)

    def focus(self, step):
        cfg = self.camera.get_config()
        w = self._find(cfg, FOCUS_NAMES)
        if w is None or step == 0:
            raise ValueError("이 카메라는 원격 수동 초점을 지원하지 않습니다")
        n = min(abs(step), 3)
        if w.get_type() in CHOICE_TYPES:
            # Canon: "Near 1"–"Near 3", "Far 1"–"Far 3", stop is "None"
            ch = self._choices(w)
            word = "Near" if step < 0 else "Far"
            opts = sorted(c for c in ch if c.startswith(word))
            want = "%s %d" % (word, n)
            pick = want if want in opts else (opts[-1] if n > 1 else opts[0])
            self._press(w, cfg, pick, "None" if "None" in ch else pick)
        else:
            lo, hi, _ = w.get_range()
            if hi <= 10:
                v = n                           # Sony: 1–7 is the size of one move
            else:
                v = 30 if n == 1 else 300       # Nikon: motor steps
            v = max(lo, min(hi, -v if step < 0 else v))
            self._press(w, cfg, float(v), 0.0 if lo <= 0 <= hi else float(v))

    def zoom(self, value):
        cfg = self.camera.get_config()
        w = self._find(cfg, ZOOM_NAMES)
        if w is None:
            raise ValueError("이 카메라는 라이브 뷰 확대를 지원하지 않습니다")
        w.set_value(str(value))
        self.camera.set_config(cfg)

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
            # Companion files (RAW+JPEG etc.) arrive as follow-up events
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
        # Also receive shots taken with the camera's own shutter
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
            self.auto = True   # From now on, plugging in the camera reconnects automatically
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
                self.autofocus()
            elif cmd == "focus":
                self.focus(int(c["step"]))
            elif cmd == "zoom":
                self.zoom(c["value"])
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
                if now - self.last_frame >= 1 / 20:   # at most 20 fps
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
        emit("config", items=items, caps={"af": True, "focus": True, "zoom": ["1", "5", "10"]})

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
        # Send the preview JPEG embedded in the file as a live view
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
