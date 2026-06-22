"""macOS backend: composes Quartz input + osascript (menu/AX) + wisptermctl
(text), and owns the isolated WispTerm.app instance lifecycle.
"""
import os
import signal
import subprocess
import tempfile
import time

from . import keycodes, osascript, quartz_input, wait
from .base import ItemState
from .ctl import Ctl
from .panes import primary_pane_id

_CONFIG = (
    "agent-control-enabled = true\n"
    "auto-update-check = false\n"
    "font-size = 14\n"
)


class MacDriver:
    def __init__(self, app_bundle: str, ctl_binary: str):
        # app_bundle: .../zig-out/bin/WispTerm.app ; ctl_binary: .../zig-out/bin/wisptermctl
        self.exe = os.path.join(app_bundle, "Contents", "MacOS", "WispTerm")
        self.ctl_binary = ctl_binary
        self.home = tempfile.mkdtemp(prefix="wispterm-e2e-")
        self.proc = None
        self.ctl = Ctl(home=self.home, binary=self.ctl_binary)

    # ---- lifecycle ----
    def _config_dir(self) -> str:
        return os.path.join(self.home, "Library", "Application Support", "wispterm")

    def launch(self, *, cols: int = 80, rows: int = 24) -> None:
        cfg_dir = self._config_dir()
        os.makedirs(cfg_dir, exist_ok=True)
        with open(os.path.join(cfg_dir, "config"), "w") as f:
            f.write(_CONFIG)

        env = dict(os.environ)
        env["HOME"] = self.home
        self.proc = subprocess.Popen([self.exe], env=env)

        # wait for the control server to publish its discovery file, then for a
        # live terminal surface to exist.
        disc = os.path.join(cfg_dir, "agent-control.json")
        wait.wait_until(lambda: os.path.exists(disc), timeout=15, interval=0.2)
        wait.wait_until(self._has_terminal_surface, timeout=15, interval=0.2)
        self.focus()

    def _has_terminal_surface(self) -> bool:
        try:
            primary_pane_id(self.ctl.panes())
            return True
        except Exception:
            return False

    def quit(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        import shutil
        shutil.rmtree(self.home, ignore_errors=True)

    def focus(self) -> None:
        osascript.run(osascript.activate_script(self.proc.pid))
        time.sleep(0.3)  # let activation settle before posting events

    # ---- discovery ----
    def primary_pane(self) -> str:
        return primary_pane_id(self.ctl.panes())

    # ---- real input ----
    def key(self, key_name: str, *mods: str) -> None:
        for m in mods:
            if m not in keycodes.MODIFIERS:
                raise ValueError(f"unknown modifier: {m}")
        quartz_input.key(keycodes.keycode(key_name), quartz_input.mods_to_flags(list(mods)))

    def text(self, s: str) -> None:
        for ch in s:
            if ch in ("\n", "\r"):
                self.key("return")
            else:
                quartz_input.type_char(ch)

    def click(self, x: int, y: int, *, count: int = 1) -> None:
        quartz_input.click(x, y, count=count)

    # ---- menu / window ----
    def menu_click(self, *path: str) -> None:
        osascript.run(osascript.menu_click_script(self.proc.pid, list(path)))

    def menu_item_state(self, *path: str) -> ItemState:
        out = osascript.run(osascript.menu_item_enabled_script(self.proc.pid, list(path)))
        return ItemState(enabled=(out.strip().lower() == "true"))

    def window_attr(self, name: str) -> str:
        return osascript.run(osascript.window_attr_script(self.proc.pid, name))

    # ---- terminal text ----
    def get_text(self, pane: str, recent=None) -> str:
        return self.ctl.get_text(pane, recent)

    def wait_for(self, pane: str, pattern: str, timeout: float = 5.0) -> None:
        self.ctl.wait_for(pane, pattern, timeout=timeout)

    def read_clipboard(self) -> str:
        return osascript.run(osascript.clipboard_script())
