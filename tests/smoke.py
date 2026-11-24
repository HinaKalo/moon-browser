"""Exercise the packaged Windows host and real WebKit processes over loopback."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from threading import Event, Thread
from time import monotonic, sleep
from urllib.parse import unquote, urlsplit
from zipfile import ZipFile


PAYLOAD = b"Moon Browser download fixture\n"
CHECKS = (
    "dpi_reflow=ok",
    "first_page_paint_ms=",
    "lua_userscripts=ok",
    "navigation_ok=1",
    "tab_stress open=50",
    "warm_switch_p95_us=",
    "session_roundtrip=1",
    "history_navigation=ok",
    "plugin_case_0=ok",
    "plugin_case_1=ok",
    "plugin_case_2=ok",
    "plugin_case_3=ok",
    "plugin_case_4=ok",
    "download=ok",
    "process_terminated tab=",
    "crash_recovery=ok",
    "\nPASS\n",
)


class Fixture(BaseHTTPRequestHandler):
    seen_unicode = Event()
    seen_lua_demo = Event()

    def do_GET(self):
        path = unquote(urlsplit(self.path).path)
        if path == "/download":
            data, content_type = PAYLOAD, "application/octet-stream"
        elif path == "/lua-demo-verified":
            self.seen_lua_demo.set()
            data, content_type = b"ok", "text/plain"
        elif path.startswith("/page/"):
            name = path.removeprefix("/page/")
            if name == "中文":
                self.seen_unicode.set()
            demo = ""
            if name == "initial":
                example = Path(__file__).resolve().parent.parent / "docs-site" / "public" / "lua-demo.html"
                markup = example.read_text(encoding="utf-8").split("<main>", 1)[1].split("</main>", 1)[0]
                demo = (
                    markup +
                    '<script>new MutationObserver((_, observer) => {'
                    'const status = document.getElementById("lua-status");'
                    'const completed = document.querySelectorAll(\'#ticket-list [data-state="done"][hidden]\');'
                    'const urgent = document.querySelector(\'#ticket-list [data-priority="urgent"]\');'
                    'if (status.textContent === "已隐藏完成工单，紧急工单已突出显示"'
                    ' && status.classList.contains("success") && completed.length === 2'
                    ' && urgent.classList.contains("important") && !urgent.hidden'
                    ' && document.getElementById("demo-banner").hidden) {'
                    'observer.disconnect(); fetch("/lua-demo-verified"); }'
                    '}).observe(document.body, {childList:true,subtree:true,attributes:true});</script>'
                )
            data = (
                "<!doctype html><meta charset=utf-8>"
                f"<title>Moon fixture {name}</title>"
                '<main style="font:32px Segoe UI;background:#375aaf;color:white;padding:45px">'
                "Moon Browser · 本地渲染验证</main><input id=entry placeholder='输入'>" + demo
            ).encode()
            content_type = "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        if path == "/download":
            self.send_header("Content-Disposition", 'attachment; filename="moon.txt"')
        self.end_headers()
        try:
            self.wfile.write(data)
        except (ConnectionResetError, BrokenPipeError):
            pass

    def log_message(self, *_):
        pass


def preview_env(root):
    return {
        **os.environ,
        "MOON_BROWSER_PROFILE_DIR": str(root / "profile"),
    }


def answer_contract_prompts(proc):
    """Respond only to this test browser's Lua approval dialogs."""
    import ctypes
    from ctypes import wintypes as wt

    user = ctypes.WinDLL("user32", use_last_error=True)
    user.FindWindowExW.argtypes = [wt.HWND, wt.HWND, wt.LPCWSTR, wt.LPCWSTR]
    user.FindWindowExW.restype = wt.HWND
    user.GetWindowThreadProcessId.argtypes = [wt.HWND, ctypes.POINTER(wt.DWORD)]
    user.IsWindowVisible.argtypes = [wt.HWND]
    user.PostMessageW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM]
    for answer in (7, 6):  # IDNO, then IDYES
        while proc.poll() is None:
            dialog = None
            while dialog := user.FindWindowExW(None, dialog, "#32770", "启用 Lua 用户脚本"):
                owner = wt.DWORD()
                user.GetWindowThreadProcessId(dialog, ctypes.byref(owner))
                if owner.value == proc.pid and user.IsWindowVisible(dialog):
                    break
            if dialog is not None:
                user.PostMessageW(dialog, 0x0111, answer, 0)  # WM_COMMAND
                while proc.poll() is None and user.IsWindowVisible(dialog):
                    sleep(0.02)
                break
            sleep(0.05)


def run_browser(exe, base, root, force_pressure, fallback, quick):
    env = preview_env(root)
    profile = Path(env["MOON_BROWSER_PROFILE_DIR"])
    profile.mkdir()
    def userscript(name, host_and_path, body, *, extra="", enabled=True):
        return {
            "enabled": enabled,
            "source": (
                f"-- ==MoonUserScript==\n-- @name {name}\n-- @api 1\n"
                f"-- @match {host_and_path}\n{extra}-- ==/MoonUserScript==\n{body}\n"
            ),
        }

    initial = f"{base}/page/initial"
    second = f"{base}/page/second"
    change_second = 'moon.dom.setText("title", "This script should have been blocked")'
    scripts = [
        userscript("Moon Lua smoke budget", initial, "while true do end"),
        userscript("Moon Lua smoke allowed", initial,
                   'assert(io == nil and os == nil and package == nil and debug == nil and pcall == nil)\n'
                   'assert(moon.apiVersion == 1 and moon.page.url == "' + initial + '")\n'
                   'moon.dom.setText("title", "Moon fixture initial Lua ✓")'),
        userscript("Moon Lua smoke excluded", second, change_second, extra=f"-- @exclude {second}\n"),
        userscript("Moon Lua smoke disabled", second, change_second, enabled=False),
        userscript("Moon Lua smoke wrong origin", second.replace("127.0.0.1", "localhost"), change_second),
    ]
    bundled_demo = Path(__file__).resolve().parent.parent / "examples" / "welcome.user.lua"
    demo_source = bundled_demo.read_text(encoding="utf-8").replace(
        "https://docs.browser.moonl.cloud/lua-demo.html", initial, 1
    )
    scripts.append({"enabled": True, "source": demo_source})
    Fixture.seen_lua_demo.clear()
    (profile / "lua-userscripts.json").write_text(json.dumps(scripts), encoding="utf-8")
    contract_client = exe.parent / "tests" / "MoonPluginContractClient.exe"
    if contract_client.exists():
        target = profile / "plugins" / "api-contract"
        target.mkdir(parents=True)
        shutil.copyfile(contract_client, target / contract_client.name)
        manifest = {
            "id": "moon.api-contract", "name": "Plugin API contract",
            "version": "1.0.0", "apiVersion": 2, "runtime": "native",
            "entry": contract_client.name,
            "contributes": {"commands": [{"id": "deny", "label": "Test denied API"},
                                         {"id": "exercise", "label": "Test granted API"}]},
            "permissions": ["tabs.read", "lua.scripts.manage"],
            "events": ["tabs.changed"],
        }
        (target / "plugin.json").write_text(json.dumps(manifest), encoding="utf-8")
    if force_pressure:
        (profile / "memory.json").write_text(
            json.dumps({"pressure_mib": 128, "target_mib": 96}), encoding="utf-8"
        )
    report = root / "report.txt"
    args = [str(exe), "--smoke", base, str(report)]
    if fallback:
        args += ["--gdi"]
    if quick:
        args += ["--smoke-quick"]
    browser = subprocess.Popen(args, env=env)
    if contract_client.exists():
        Thread(target=answer_contract_prompts, args=(browser,), daemon=True).start()
    try:
        status = browser.wait(timeout=320)
    except subprocess.TimeoutExpired:
        browser.kill()
        browser.wait()
        raise
    finally:
        log = report.read_text(encoding="utf-8") if report.exists() else ""
        print(log, end="", flush=True)
    skipped = ("tab_stress", "warm_switch") if quick else ()
    missing = [check for check in CHECKS if check not in log and not check.startswith(skipped)]
    if contract_client.exists() and "plugin_api_v2=ok" not in log:
        missing.append("plugin_api_v2=ok")
    if status or missing:
        contract_error = profile / "plugins" / "api-contract" / "contract-error.txt"
        if contract_error.exists():
            print("Plugin contract client:", contract_error.read_text(encoding="utf-8"))
        raise RuntimeError(f"Browser exit {status}; missing checks: {missing}")
    if not Fixture.seen_lua_demo.is_set():
        raise RuntimeError("The downloadable Lua demo did not filter and highlight the expected items")
    print("lua_public_demo=ok", flush=True)
    if force_pressure and "pressure=1" not in log:
        raise RuntimeError("Configured pressure path did not run")
    if not quick:
        baseline = int(re.search(r"baseline_commit=(\d+)", log).group(1))
        peak = int(re.search(r"tab_stress .* peak=(\d+)", log).group(1))
        if peak > max(2 * 1024**3, baseline + 768 * 1024**2):
            raise RuntimeError(f"50-tab private commit grew unexpectedly: baseline={baseline}, peak={peak}")
    if (profile / "smoke-download.txt").read_bytes() != PAYLOAD:
        raise RuntimeError("Downloaded content was corrupted")


def run_win32(exe, base, root):
    import ctypes
    from ctypes import wintypes as wt

    user = ctypes.WinDLL("user32", use_last_error=True)
    user.FindWindowW.argtypes = [wt.LPCWSTR, wt.LPCWSTR]
    user.FindWindowW.restype = wt.HWND
    user.FindWindowExW.argtypes = [wt.HWND, wt.HWND, wt.LPCWSTR, wt.LPCWSTR]
    user.FindWindowExW.restype = wt.HWND
    user.SendMessageW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM]
    user.SendMessageW.restype = ctypes.c_ssize_t
    user.PostMessageW.argtypes = user.SendMessageW.argtypes
    user.GetWindowThreadProcessId.argtypes = [wt.HWND, ctypes.POINTER(wt.DWORD)]
    user.GetDpiForWindow.argtypes = [wt.HWND]
    user.GetDpiForWindow.restype = wt.UINT
    user.GetWindowLongPtrW.argtypes = [wt.HWND, ctypes.c_int]
    user.GetWindowLongPtrW.restype = ctypes.c_ssize_t
    user.GetWindowRect.argtypes = [wt.HWND, ctypes.POINTER(wt.RECT)]
    user.ClientToScreen.argtypes = [wt.HWND, ctypes.POINTER(wt.POINT)]
    user.GetClientRect.argtypes = [wt.HWND, ctypes.POINTER(wt.RECT)]
    user.GetDlgItem.argtypes = [wt.HWND, ctypes.c_int]
    user.GetDlgItem.restype = wt.HWND
    user.IsWindowVisible.argtypes = [wt.HWND]
    user.SetWindowPos.argtypes = [wt.HWND, wt.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wt.UINT]
    user.SetThreadDpiAwarenessContext.argtypes = [wt.HANDLE]
    user.SetThreadDpiAwarenessContext(wt.HANDLE(-4))
    proc = subprocess.Popen([str(exe), "--gdi"], env=preview_env(root))
    frame = None
    try:
        deadline = monotonic() + 20
        while monotonic() < deadline:
            candidate = None
            while candidate := user.FindWindowExW(None, candidate, "MoonBrowserWindow", None):
                owner = wt.DWORD()
                user.GetWindowThreadProcessId(candidate, ctypes.byref(owner))
                if owner.value == proc.pid:
                    frame = candidate
                    break
            if frame:
                break
            if proc.poll() is not None:
                raise RuntimeError(f"Win32 smoke startup exited with {proc.returncode}")
            sleep(0.1)
        if not frame:
            raise RuntimeError("Win32 shell not found")
        style = user.GetWindowLongPtrW(frame, -16)  # GWL_STYLE
        if style & 0x00C00000 == 0x00C00000:  # WS_CAPTION
            raise RuntimeError(f'Duplicate Windows title bar style is present: {style:#x}')
        outer, origin = wt.RECT(), wt.POINT()
        if (not user.GetWindowRect(frame, ctypes.byref(outer))
                or not user.ClientToScreen(frame, ctypes.byref(origin))
                or origin.y != outer.top):
            raise RuntimeError('Native non-client area added a second row above the toolbar')
        print('single_titlebar=ok', flush=True)
        edit = user.GetDlgItem(frame, 1001)
        home = user.GetDlgItem(frame, 1002)
        content = user.FindWindowExW(frame, None, "MoonContent", None)
        if not edit or not home or not content:
            raise RuntimeError("Missing native Win32 children")
        dpi = user.GetDpiForWindow(frame)
        user.SetWindowPos(frame, None, 0, 0, 840, 590, 0x0016)
        sleep(0.15)
        client, pane = wt.RECT(), wt.RECT()
        user.GetClientRect(frame, ctypes.byref(client))
        user.GetClientRect(content, ctypes.byref(pane))
        def px(value):
            return (value * dpi + 48) // 96

        side = px(281) + px(9)
        expected_chrome = px(49) + px(9)
        if client.right - pane.right != side or client.bottom - pane.bottom != expected_chrome:
            raise RuntimeError(f"Incorrect DPI layout at {dpi} DPI")

        def click(x, y):
            user.PostMessageW(frame, 0x0202, 0, y << 16 | x)  # WM_LBUTTONUP

        def popup_bounds():
            deadline = monotonic() + 4
            while monotonic() < deadline:
                candidate = None
                while candidate := user.FindWindowExW(None, candidate, "#32768", None):
                    owner = wt.DWORD()
                    user.GetWindowThreadProcessId(candidate, ctypes.byref(owner))
                    if owner.value == proc.pid and user.IsWindowVisible(candidate):
                        rect = wt.RECT()
                        user.GetWindowRect(candidate, ctypes.byref(rect))
                        user.PostMessageW(frame, 0x001F, 0, 0)  # WM_CANCELMODE
                        sleep(0.1)
                        return rect
                sleep(0.05)
            raise RuntimeError("Native menu did not open")

        click(px(104), client.bottom - px(26))
        footer_menu = popup_bounds()
        if (abs(footer_menu.left - (origin.x + px(88))) > px(16)
                or abs(footer_menu.bottom - (origin.y + client.bottom - px(41))) > px(16)):
            raise RuntimeError(f"Sidebar menu is not anchored to its button: {footer_menu.left}, {footer_menu.bottom}")
        click(client.right - px(159), px(24))
        toolbar_menu = popup_bounds()
        if (abs(toolbar_menu.right - (origin.x + client.right - px(143))) > px(16)
                or abs(toolbar_menu.top - (origin.y + px(40))) > px(16)):
            raise RuntimeError(f"Toolbar menu is not anchored to its button: {toolbar_menu.right}, {toolbar_menu.top}")
        print("native_menu_anchors=ok", flush=True)

        def find_palette():
            deadline = monotonic() + 4
            while monotonic() < deadline:
                candidate = None
                while candidate := user.FindWindowExW(None, candidate, "MoonPalette", None):
                    owner = wt.DWORD()
                    user.GetWindowThreadProcessId(candidate, ctypes.byref(owner))
                    if owner.value == proc.pid:
                        return candidate
                sleep(0.05)
            raise RuntimeError("Native command palette did not open")

        if not user.IsWindowVisible(home) or user.IsWindowVisible(content):
            raise RuntimeError("The native new-tab view did not open")
        click(px(70), px(65))
        palette = find_palette()
        actions = user.GetDlgItem(palette, 1004)
        rows = user.SendMessageW(actions, 0x018B, 0, 0)  # LB_GETCOUNT
        if rows < 7:
            raise RuntimeError("Missing built-in command or tab entries")
        user.PostMessageW(user.GetDlgItem(palette, 1003), 0x0100, 0x0D, 1)
        sleep(0.2)
        click(px(70), px(65))
        palette = find_palette()
        if user.SendMessageW(user.GetDlgItem(palette, 1004), 0x018B, 0, 0) != rows + 1:
            raise RuntimeError("The command palette did not create a tab")
        user.PostMessageW(user.GetDlgItem(palette, 1003), 0x0100, 0x1B, 1)
        sleep(0.2)
        click(client.right - px(197), px(25))
        sleep(0.2)
        user.GetClientRect(content, ctypes.byref(pane))
        if client.right - pane.right != 2 * px(9):
            raise RuntimeError("The native sidebar did not collapse")
        click(client.right - px(197), px(25))
        sleep(0.2)
        print("native_home=ok command_palette=ok sidebar_focus_mode=ok")

        address = ctypes.create_unicode_buffer(base + "/page/中文")
        user.SendMessageW(home, 0x000C, 0, ctypes.addressof(address))  # WM_SETTEXT
        user.PostMessageW(home, 0x0100, 0x0D, 1)  # WM_KEYDOWN / Enter
        if not Fixture.seen_unicode.wait(15):
            raise RuntimeError("Unicode address did not reach the loopback fixture")
        if not user.IsWindowVisible(content) or user.IsWindowVisible(home):
            raise RuntimeError("The WebKit view did not replace the native new-tab view")
        print(f"win32_unicode_address=ok resized_dpi={dpi} chrome_px={expected_chrome} fallback=GDI+")
    finally:
        if frame:
            user.PostMessageW(frame, 0x0010, 0, 0)
        try:
            proc.wait(8)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("exe", type=Path)
    parser.add_argument("--pressure", action="store_true")
    parser.add_argument("--gdi", action="store_true")
    parser.add_argument("--ui", action="store_true", help="Also test actual Win32 resizing and Unicode navigation")
    parser.add_argument("--quick", action="store_true", help="Skip the 50-tab stress and run the engine/plugin/download checks")
    parser.add_argument("--report", type=Path, help="Copy browser metrics to this path")
    args = parser.parse_args()
    source = args.exe.resolve(strict=True)
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server, tempfile.TemporaryDirectory(prefix="moon-smoke-") as directory:
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        root = Path(directory)
        if source.suffix.lower() == ".zip":
            preview = root / "preview"
            with ZipFile(source) as bundle:
                bundle.extractall(preview)
            exe = preview / "MoonBrowser.exe"
        else:
            exe = source
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            try:
                run_browser(exe, base, root, args.pressure, args.gdi, args.quick)
            finally:
                report = root / "report.txt"
                if args.report and report.exists():
                    args.report.write_bytes(report.read_bytes())
            if args.ui:
                run_win32(exe, base, root / "ui")
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    main()
