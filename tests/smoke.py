"""Exercise the packaged Windows host and real WebKit processes over loopback."""
import argparse
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from threading import Event, Thread
from time import monotonic, sleep
from urllib.parse import parse_qs, quote, unquote, urlsplit
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
    seen_editor_reload = Event()
    seen_editor_ready = Event()
    seen_extension_network = Event()
    seen_blocked_request = Event()
    seen_filter_proof = Event()
    seen_allowed_request = Event()
    filter_probe = False
    slow_download_release = Event()
    change_site_data_source = Event()
    change_site_data_entry = Event()
    site_data_entry_changed = Event()
    site_data_catalog_ready = Event()
    change_page_source = Event()
    navigate_from_site_menu = Event()
    navigate_from_link_menu = Event()
    page_source_requests = 0
    popup_attempts = set()
    popup_destinations = set()
    reading_layout = {}
    closed_loaded = {}
    privacy_reports = {}
    private_window_reports = {}
    privacy_asset_requests = 0
    chrome_layout = None
    chrome_sequence = 0

    def do_GET(self):
        path = unquote(urlsplit(self.path).path)
        if path == "/slow-download":
            chunk = b"x" * (64 * 1024)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="slow-test.bin"')
            self.send_header("Content-Length", str(len(chunk) * 8))
            self.end_headers()
            try:
                self.wfile.write(chunk)
                self.wfile.flush()
                if self.slow_download_release.wait(25):
                    self.wfile.write(chunk * 7)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass
            return
        if path == "/download":
            data, content_type = PAYLOAD, "application/octet-stream"
        elif path == "/lua-demo-verified":
            self.seen_lua_demo.set()
            data, content_type = b"ok", "text/plain"
        elif path.startswith("/private-window-report/"):
            token = path.rsplit("/",1)[-1]
            report = {key: values[0] for key,values in parse_qs(urlsplit(self.path).query).items()}
            cookies = self.headers.get("Cookie","")
            report["http"] = next((c.split("=",1)[1] for c in cookies.split("; ") if c.startswith("moon-window-http=")),"")
            self.private_window_reports[token] = report
            data, content_type = b"ok", "text/plain"
        elif path.startswith("/private-window-probe/"):
            token = path.rsplit("/",1)[-1]
            initial = {"regular-seed": "regular", "private-seed": "private"}.get(token)
            if initial:
                cookie = f"moon-window-http={initial}; Path=/; HttpOnly; Max-Age=3600"
            script = (
                '<!doctype html><meta charset=utf-8><title>Private window probe</title><script>'
                'addEventListener("load",async()=>{const fields={};'
                f'const token={json.dumps(token)};try{{const initial={json.dumps(initial)};'
                'if(initial){localStorage.setItem("moon-window",initial);'
                'const cache=await caches.open("moon-window");'
                'await cache.put("/moon-window-state",new Response(initial));'
                'await new Promise((resolve,reject)=>{const r=indexedDB.open("moon-window-"+initial,1);'
                'r.onupgradeneeded=()=>r.result.createObjectStore("probe");'
                'r.onsuccess=()=>{r.result.close();resolve()};r.onerror=()=>reject(r.error)});}'
                'fields.local=localStorage.getItem("moon-window")??"";'
                'fields.idb=(await indexedDB.databases()).map(d=>d.name).filter(n=>n.startsWith("moon-window-")).sort().join(",");'
                'const cached=await caches.match("/moon-window-state",{cacheName:"moon-window"});'
                'fields.cache=cached?await cached.text():"";'
                '}catch(error){fields.error=String(error);}'
                'await fetch("/private-window-report/"+token+"?"+new URLSearchParams(fields),{cache:"no-store"});'
                '});</script>'
            )
            data,content_type = script.encode(),"text/html; charset=utf-8"
        elif path == "/editor-verified":
            self.seen_editor_reload.set()
            data, content_type = b"ok", "text/plain"
        elif path == "/editor-ready":
            self.seen_editor_ready.set()
            data, content_type = b"ok", "text/plain"
        elif path == "/extension-network":
            self.seen_extension_network.set()
            data, content_type = b"unexpected", "text/plain"
        elif path.startswith("/moon-filter-probe/blocked"):
            (self.seen_allowed_request if "?allow=1" in self.path else self.seen_blocked_request).set()
            data, content_type = b"", "application/javascript"
        elif path == "/moon-filter-probe/passed":
            self.seen_filter_proof.set()
            data, content_type = b"ok", "text/plain"
        elif path == "/site-data-navigation":
            action = b"change" if self.change_site_data_source.is_set() else b"overwrite" if self.change_site_data_entry.is_set() else b"keep"
            data, content_type = action, "text/plain"
        elif path == "/site-data-entry-changed":
            self.site_data_entry_changed.set()
            data, content_type = b"ok", "text/plain"
        elif path == "/site-data-catalog-ready":
            self.site_data_catalog_ready.set()
            data, content_type = b"ok", "text/plain"
        elif path == "/page-source-navigation":
            data, content_type = (b"change" if self.change_page_source.is_set() else b"wait"), "text/plain"
        elif path == "/site-menu-navigation":
            data, content_type = (b"change" if self.navigate_from_site_menu.is_set() else b"wait"), "text/plain"
        elif path == "/link-menu-navigation":
            data, content_type = (b"change" if self.navigate_from_link_menu.is_set() else b"wait"), "text/plain"
        elif path.startswith("/popup-attempt/"):
            self.popup_attempts.add(path.removeprefix("/popup-attempt/"))
            data, content_type = b"ok", "text/plain"
        elif path.startswith("/popup-target/"):
            self.popup_destinations.add(path.removeprefix("/popup-target/"))
            data, content_type = b"<title>Popup destination</title>Opened", "text/html"
        elif path.startswith("/reading-layout/"):
            _, _, page, width, scroll = path.split("/")
            self.reading_layout[page] = (int(width), int(scroll))
            data, content_type = b"ok", "text/plain"
        elif path.startswith("/closed-ready/"):
            page = path.removeprefix("/closed-ready/")
            self.closed_loaded[page] = self.closed_loaded.get(page, 0) + 1
            data, content_type = b"ok", "text/plain"
        elif path == "/privacy-cacheable":
            type(self).privacy_asset_requests += 1
            data, content_type = b"cache fixture", "text/plain"
        elif path == "/privacy-worker.js":
            data, content_type = b"self.addEventListener('fetch',()=>{});", "application/javascript"
        elif path.startswith("/chrome-layout/"):
            sequence, *layout = map(int,path.removeprefix("/chrome-layout/").split("/"))
            if sequence >= self.chrome_sequence:
                type(self).chrome_sequence = sequence
                type(self).chrome_layout = tuple(layout)
            data, content_type = b"ok", "text/plain"
        elif path.startswith("/privacy-report/"):
            stage = path.removeprefix("/privacy-report/")
            report = {key: values[0] for key, values in parse_qs(urlsplit(self.path).query).items()}
            report["cookies"] = self.headers.get("Cookie", "")
            self.privacy_reports[stage] = report
            data, content_type = b"ok", "text/plain"
        elif path.startswith("/page/"):
            name = path.removeprefix("/page/")
            if name == "中文":
                self.seen_unicode.set()
            demo = ""
            if name in ("link-menu-contract","link-menu-stale"):
                suffix = "target" if name == "link-menu-contract" else "stale-target"
                demo = (f'<a style="position:absolute;top:10px;left:10px" href="/page/link-menu-{suffix}">本地链接验收</a>'
                        '<a style="position:absolute;top:46px;left:10px" href="mailto:fixture@example.invalid">邮件链接</a>')
                if name == "link-menu-stale":
                    demo += ('<script>const poll=setInterval(async()=>{'
                             'const r=await fetch("/link-menu-navigation",{cache:"no-store"});'
                             'if(await r.text()==="change"){clearInterval(poll);location.replace("/page/link-menu-after");}'
                             '},120);</script>')
            if name == "site-menu-contract":
                demo = ('<script>const poll=setInterval(async()=>{'
                        'const response=await fetch("/site-menu-navigation",{cache:"no-store"});'
                        'if(await response.text()==="change"){clearInterval(poll);location.replace("/page/site-menu-after");}'
                        '},120);</script>')
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
                if self.filter_probe:
                    demo += (
                        '<div id="moon-blocker-warning">Ad blocker detected.</div>'
                        '<script>const ad=document.createElement("script");'
                        'const scriptBlocked=new Promise(resolve=>{ad.onload=()=>resolve(false);'
                        'ad.onerror=()=>resolve(true);ad.src="/moon-filter-probe/blocked.js";'
                        'document.head.append(ad);});'
                        'const fetchBlocked=fetch("/moon-filter-probe/blocked-fetch").then(()=>false,()=>true);'
                        'Promise.all([scriptBlocked,fetchBlocked]).then(results=>{'
                        'if(results.every(Boolean)&&getComputedStyle(document.getElementById("moon-blocker-warning")).display==="none")'
                        'fetch("/moon-filter-probe/passed");'
                        '});</script>'
                    )
            if name == "editor":
                demo = (
                    '<p id="editor-proof">Original</p><script>'
                    'new MutationObserver(() => { '
                    'const text = document.querySelector("#editor-proof").textContent;'
                    'if (text === "Lua editor reloaded") fetch("/editor-verified");'
                    'else if (text === "Old Lua source") fetch("/editor-ready");'
                    '}).observe(document.querySelector("#editor-proof"), {childList:true});</script>'
                )
            if name == "filter-allowed":
                demo = '<script>fetch("/moon-filter-probe/blocked-fetch?allow=1");</script>'
            if name == "site-data-contract":
                demo = (
                    '<script>localStorage.setItem("moon-local","local-value");'
                    'sessionStorage.setItem("moon-session","session-value");'
                    '(async()=>{await Promise.all(['
                    'new Promise((ok,fail)=>{const request=indexedDB.open("moon-inventory",3);'
                    'request.onupgradeneeded=()=>request.result.createObjectStore("records");'
                    'request.onsuccess=()=>{request.result.close();ok()};request.onerror=fail}),'
                    '(async()=>{await caches.open("moon-request-cache");await caches.open("月".repeat(150));'
                    'await Promise.all(Array.from({length:32},(_,i)=>caches.open("cache-"+i)))})()]);'
                    'IDBFactory.prototype.databases=async()=>[{name:"forged",version:88}];'
                    'CacheStorage.prototype.keys=async()=>["forged"];'
                    'fetch("/site-data-catalog-ready");})().catch(()=>{});'
                    'Object.defineProperty(document,"cookie",{get:()=>"forged=other"});'
                    'Storage.prototype.getItem=()=>"forged";'
                    'let changed=false;setInterval(async()=>{const r=await fetch("/site-data-navigation",{cache:"no-store"});'
                    'const action=await r.text();if(action==="change")location.replace("/page/site-data-changed");'
                    'if(action==="overwrite"&&!changed){changed=true;localStorage.setItem("moon-local","page-change");'
                    'fetch("/site-data-entry-changed",{cache:"no-store"});}},400);</script>'
                )
            if name in ("popup-default", "popup-allow", "popup-private"):
                stage = name.removeprefix("popup-")
                demo = (
                    '<script>addEventListener("load",()=>setTimeout(()=>{'
                    f'window.open("/popup-target/{stage}","_blank");fetch("/popup-attempt/{stage}");'
                    '},250));</script>'
                )
            if name in ("popup-click", "popup-click-blocked", "popup-click-reset"):
                stage = name.removeprefix("popup-")
                demo = (
                    f'<a href="/popup-target/{stage}" target="_blank" onclick="fetch(\'/popup-attempt/{stage}\')" '
                    'style="position:fixed;top:0;left:0;padding:12px;background:white">Open in new tab</a>'
                )
            if name == "source-contract":
                Fixture.page_source_requests += 1
                demo = (
                    '<!-- 源码雪月🌙 -->\n<p id="wire">before mutation</p>'
                    '<script>document.querySelector("#wire").textContent="after"+" mutation";'
                    'setInterval(async()=>{const reply=await fetch("/page-source-navigation");'
                    'if(await reply.text()==="change")location.replace("/page/source-changed");},300);</script>\n'
                    '<!--' + '月🌙' * 77_000 + 'END-OF-WIRE-->'
                )
            if name in ("reading-contract", "reading-other-origin", "reading-restart"):
                demo = (
                    '<p style="margin-top:1100px">月亮查找词</p>'
                    '<p style="margin-top:1200px;margin-bottom:1000px">月亮查找词</p>'
                    '<script>let previous;const report=()=>{'
                    'const value=innerWidth+"/"+Math.round(scrollY);'
                    f'if(previous!==value){{previous=value;fetch("/reading-layout/{name}/"+value);}}'
                    '};addEventListener("scroll",report);addEventListener("resize",report);'
                    'addEventListener("load",report);</script>'
                )
            if name in ("closed-first", "closed-second", "closed-item", "closed-protected", "task-eligible", "task-protected",
                        "pinned-first", "pinned-second", "session-first", "session-second", "session-pinned", "session-private",
                        "session-external", "order-last"):
                demo = f'<script>addEventListener("pageshow",()=>fetch("/closed-ready/{name}"));</script>'
            if name == "chrome-window":
                demo = (
                    '<style>body{min-height:300vh;background:#64bfa8}main{position:sticky;top:0}'
                    'aside{position:fixed;right:0;top:0;width:42px;height:100%;background:#ed795b;transform:translateZ(0)}</style>'
                    '<aside></aside><script>let timer,sequence=0;const report=()=>{clearTimeout(timer);'
                    'timer=setTimeout(()=>fetch("/chrome-layout/"+'
                    '[++sequence,Math.round(performance.timeOrigin),innerWidth,innerHeight,Math.round(scrollY)].join("/"),'
                    '{cache:"no-store"}),90);};'
                    'addEventListener("load",()=>{scrollTo(0,280);report();});'
                    'addEventListener("resize",report);addEventListener("scroll",report);</script>'
                )
            if name == "closed-post":
                demo = ('<form action="/closed-submit" method="post"><input name="fixture" value="test"></form>'
                        '<script>document.forms[0].submit();</script>')
            if name.startswith("privacy-"):
                seed = "true" if name == "privacy-seed" else "false"
                demo = (
                    '<script>addEventListener("load",async()=>{let phase="local";try{'
                    f'if({seed}){{'
                    'localStorage.setItem("moon-privacy","present");'
                    'phase="indexeddb";'
                    'await new Promise((resolve,reject)=>{const r=indexedDB.open("moon-privacy",1);'
                    'r.onupgradeneeded=()=>r.result.createObjectStore("proof");'
                    'r.onsuccess=()=>{r.result.close();resolve();};r.onerror=reject;});'
                    'phase="cache open";const saved=await caches.open("moon-privacy");'
                    'phase="cache put";await saved.put("/privacy-cache-proof",new Response("present"));'
                    'phase="service worker";if(navigator.serviceWorker)await navigator.serviceWorker.register("/privacy-worker.js",{scope:"/privacy-worker-only/"});'
                    '}'
                    'phase="resource fetch";'
                    'const r=await fetch("/privacy-cacheable",{cache:"force-cache"});await r.text();'
                    'phase="storage read";const fields={local:localStorage.getItem("moon-privacy")==="present",'
                    'idb:(await indexedDB.databases()).some(v=>v.name==="moon-privacy"),'
                    'domCache:(await caches.keys()).includes("moon-privacy"),'
                    'worker:navigator.serviceWorker&&(await navigator.serviceWorker.getRegistrations()).some(v=>v.scope.endsWith("/privacy-worker-only/"))};'
                    f'await fetch("/privacy-report/{name}?"+new URLSearchParams(fields),{{cache:"no-store"}});'
                    f'}}catch(error){{fetch("/privacy-report/{name}?error="+encodeURIComponent(phase+": "+error),{{cache:"no-store"}});}}'
                    '});</script>'
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
        if path == "/page/site-data-contract":
            self.send_header("Set-Cookie", "moon-visible=cookie-value; Path=/")
            self.send_header("Set-Cookie", "moon-http-only=private-value; HttpOnly; Path=/")
        if path == "/page/privacy-seed":
            self.send_header("Set-Cookie", "moon-privacy-visible=present; Path=/")
            self.send_header("Set-Cookie", "moon-privacy-http=present; HttpOnly; Path=/")
        if path == "/privacy-cacheable":
            self.send_header("Cache-Control", "public, max-age=3600")
        if path.startswith("/private-window-probe/"):
            self.send_header("Cache-Control","no-store")
            if initial:
                self.send_header("Set-Cookie",cookie)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (ConnectionResetError, BrokenPipeError):
            pass

    def log_message(self, *_):
        pass

    def do_POST(self):
        if self.path != "/closed-submit":
            self.send_error(404)
            return
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        data = b"<!doctype html><title>Posted fixture</title><p>Submitted</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


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
    request_filter = exe.with_name("MoonRequestFilter.dll").exists()
    if request_filter:
        Fixture.filter_probe = True
        filter_fixture = profile / "plugins" / "filter-contract"
        filter_fixture.mkdir(parents=True)
        (filter_fixture / "plugin.json").write_text(json.dumps({
            "id": "moon.filter-fixture", "name": "Filter fixture", "version": "1.0.0",
            "apiVersion": 2, "runtime": "native", "entry": "Unused.exe", "networkRules": "test.rules",
            "permissions": ["network.filter"],
            "contributes": {"commands": [{"id": "open", "label": "Filter fixture"}]},
        }), encoding="utf-8")
        (filter_fixture / "test.rules").write_text(
            "@127.0.0.1\t/moon-filter-probe/blocked\n+127.0.0.1\t#moon-blocker-warning\n", encoding="utf-8")
        (profile / "plugin-state.json").write_text(json.dumps([
            {"id": "moon.filter-fixture", "enabled": True, "tabs_read": False, "network_filter": True},
        ]), encoding="utf-8")
    if fallback:
        args += ["--gdi"]
    if quick:
        args += ["--smoke-quick"]
    browser = subprocess.Popen(args, env=env)
    if contract_client.exists():
        Thread(target=answer_contract_prompts, args=(browser,), daemon=True).start()
    try:
        deadline = monotonic() + 320
        while True:
            remaining = deadline-monotonic()
            if remaining<=0:
                raise subprocess.TimeoutExpired(args,320)
            try:
                status = browser.wait(timeout=min(remaining,1 if quick else 320))
                break
            except subprocess.TimeoutExpired:
                if quick:
                    try:
                        progress = report.read_text(encoding="utf-8")
                    except OSError:
                        progress = ""
                    if "process_terminated tab=1\n" in progress.partition("fixture_crash_requested=1\n")[0]:
                        browser.kill()
                        browser.wait()
                        print("WebKit terminated before the intentional crash test.",flush=True)
                        raise SystemExit(75)
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
        if quick and "process_terminated tab=1\n" in log.partition("fixture_crash_requested=1\n")[0]:
            print("WebKit terminated before the intentional crash test.",flush=True)
            raise SystemExit(75)
        contract_error = profile / "plugins" / "api-contract" / "contract-error.txt"
        if contract_error.exists():
            print("Plugin contract client:", contract_error.read_text(encoding="utf-8"))
        raise RuntimeError(f"Browser exit {status}; missing checks: {missing}")
    if not Fixture.seen_lua_demo.is_set():
        raise RuntimeError("The downloadable Lua demo did not filter and highlight the expected items")
    print("lua_public_demo=ok", flush=True)
    if request_filter:
        if Fixture.seen_blocked_request.is_set() or not Fixture.seen_filter_proof.is_set():
            raise RuntimeError(f"Request filtering or document-start cosmetic rule failed "
                               f"(request reached server: {Fixture.seen_blocked_request.is_set()})")
        print("native_request_filter=ok document_start_cosmetic_rule=ok",flush=True)
    if force_pressure and "pressure=1" not in log:
        raise RuntimeError("Configured pressure path did not run")
    if not quick:
        baseline = int(re.search(r"baseline_commit=(\d+)", log).group(1))
        peak = int(re.search(r"tab_stress .* peak=(\d+)", log).group(1))
        if peak > max(2 * 1024**3, baseline + 768 * 1024**2):
            raise RuntimeError(f"50-tab private commit grew unexpectedly: baseline={baseline}, peak={peak}")
    if (profile / "smoke-download.txt").read_bytes() != PAYLOAD:
        raise RuntimeError("Downloaded content was corrupted")
    if (exe.parent / "plugins" / "downloads" / "MoonDownloads.exe").is_file():
        with closing(sqlite3.connect(profile / "downloads.sqlite3")) as db:
            row = db.execute("SELECT state,received,path FROM downloads ORDER BY id DESC LIMIT 1").fetchone()
        if not row or row[0] != 2 or row[1] != len(PAYLOAD) or Path(row[2]).name != "smoke-download.txt":
            raise RuntimeError(f"The download manager did not persist the completed WebKit download: {row}")
        print("download_completion_record=ok", flush=True)


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
    user.GetClassLongPtrW.argtypes = [wt.HWND, ctypes.c_int]
    user.GetClassLongPtrW.restype = ctypes.c_size_t
    user.GetWindowRect.argtypes = [wt.HWND, ctypes.POINTER(wt.RECT)]
    user.ClientToScreen.argtypes = [wt.HWND, ctypes.POINTER(wt.POINT)]
    user.GetClientRect.argtypes = [wt.HWND, ctypes.POINTER(wt.RECT)]
    user.ShowWindow.argtypes = [wt.HWND, ctypes.c_int]
    user.IsIconic.argtypes = [wt.HWND]
    user.IsZoomed.argtypes = [wt.HWND]
    user.MonitorFromWindow.argtypes = [wt.HWND, wt.DWORD]
    user.MonitorFromWindow.restype = wt.HANDLE
    user.GetMonitorInfoW.argtypes = [wt.HANDLE, ctypes.c_void_p]
    user.RegisterHotKey.argtypes = [wt.HWND,ctypes.c_int,wt.UINT,wt.UINT]
    user.UnregisterHotKey.argtypes = [wt.HWND,ctypes.c_int]
    user.GetMenuItemCount.argtypes = [wt.HMENU]
    user.GetMenuState.argtypes = [wt.HMENU,wt.UINT,wt.UINT]
    user.GetMenuState.restype = wt.UINT
    user.GetMenuStringW.argtypes = [wt.HMENU,wt.UINT,wt.LPWSTR,ctypes.c_int,wt.UINT]
    user.GetSubMenu.argtypes = [wt.HMENU,ctypes.c_int]
    user.GetSubMenu.restype = wt.HMENU
    user.GetDlgItem.argtypes = [wt.HWND, ctypes.c_int]
    user.GetDlgItem.restype = wt.HWND
    user.IsWindowVisible.argtypes = [wt.HWND]
    user.SetWindowPos.argtypes = [wt.HWND, wt.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wt.UINT]
    user.SetThreadDpiAwarenessContext.argtypes = [wt.HANDLE]
    user.SetThreadDpiAwarenessContext(wt.HANDLE(-4))
    user.GetWindow.argtypes = [wt.HWND, wt.UINT]
    user.GetWindow.restype = wt.HWND
    user.IsWindow.argtypes = [wt.HWND]
    profile = Path(preview_env(root)["MOON_BROWSER_PROFILE_DIR"])
    manager = exe.parent / "plugins" / "lua-manager" / "MoonLuaManager.exe"
    devtools = exe.parent / "plugins" / "devtools" / "MoonDevTools.exe"
    docked_devtools = devtools.exists() and any(command["id"] == "window" for command in
        json.loads(devtools.with_name("plugin.json").read_text(encoding="utf-8"))["contributes"]["commands"])
    history = exe.parent / "plugins" / "history" / "MoonHistory.exe"
    blocker = exe.parent / "plugins" / "blocker" / "MoonBlocker.exe"
    bookmarks = exe.parent / "plugins" / "bookmarks" / "MoonBookmarks.exe"
    bookmark_transfer = bookmarks.exists() and '"bookmarks.transfer"' in bookmarks.with_name("plugin.json").read_text(encoding="utf-8")
    downloads = exe.parent / "plugins" / "downloads" / "MoonDownloads.exe"
    has_bulk_clear = downloads.exists() and "clear-completed" in (downloads.parent / "downloads.html").read_text(encoding="utf-8")
    site_data = exe.parent / "plugins" / "site-data" / "MoonSiteData.exe"
    has_site_menu = site_data.exists() and json.loads(site_data.with_name("plugin.json").read_text(encoding="utf-8"))["contributes"]["commands"][0].get("siteMenu")
    page_source = exe.parent / "plugins" / "page-source" / "MoonPageSource.exe"
    popups = exe.parent / "plugins" / "popups" / "MoonPopups.exe"
    reading = exe.parent / "plugins" / "reading" / "MoonReading.exe"
    recent = exe.parent / "plugins" / "recent-tabs" / "MoonRecentTabs.exe"
    privacy = exe.parent / "plugins" / "privacy" / "MoonPrivacy.exe"
    task_manager = exe.parent / "plugins" / "task-manager" / "MoonTaskManager.exe"
    commands = exe.parent / "plugins" / "ui-commands" / "MoonCommandExample.exe"
    search_plugin = exe.parent / "plugins" / "search" / "MoonSearch.exe"
    session_plugin = exe.parent / "plugins" / "session" / "MoonSession.exe"
    tab_tools = exe.parent / "plugins" / "tab-tools" / "MoonTabTools.exe"
    has_web_link_menu = tab_tools.exists() and '"linkMenu"' in tab_tools.with_name("plugin.json").read_text(encoding="utf-8")
    private_window = exe.parent / "plugins" / "private-window" / "MoonPrivateWindow.exe"
    if task_manager.exists():
        profile.mkdir(parents=True,exist_ok=True)
        (profile / "memory.json").write_text(
            json.dumps({"warm_tabs": 20, "idle_seconds": 3600, "pressure_mib": 32768, "target_mib": 32000}), encoding="utf-8")
    if manager.exists():
        fixture = profile / "plugins" / "settings"
        fixture.mkdir(parents=True)
        if page_source.exists():
            (profile / "plugin-shortcuts.json").write_text(json.dumps([
                {"plugin": "moon.source", "command": "open", "shortcut": "Ctrl+Shift+7"},
                {"plugin": "moon.devtools", "command": "console", "shortcut": "Ctrl+Shift+7"},
                {"plugin": "moon.bookmarks", "command": "open", "shortcut": "Ctrl+Shift+L"},
            ]), encoding="utf-8")
        (profile / "plugin-state.json").write_text(json.dumps([
            {"id": "moon.lua-manager", "enabled": True, "tabs_read": False, "lua_scripts_manage": True},
            {"id": "moon.reading", "enabled": True, "tabs_read": False, "page_reading": True},
            {"id": "moon.settings-fixture", "enabled": True, "tabs_read": False},
            {"id": "moon.devtools", "enabled": True, "tabs_read": False, "page_inspect": True},
            {"id": "moon.history-fixture", "enabled": True, "tabs_read": False, "history_manage": True, "popups_manage": popups.exists()},
            {"id": "moon.filter-settings-fixture", "enabled": True, "tabs_read": False, "network_filter": True},
            {"id": "moon.bookmark-fixture", "enabled": True, "tabs_read": False, "bookmarks_manage": True, "bookmarks_transfer": bookmark_transfer},
            {"id": "moon.download-fixture", "enabled": True, "tabs_read": False, "downloads_manage": True},
            {"id": "moon.site-data-fixture", "enabled": True, "tabs_read": False, "site_data_read": True, "site_data_write": True},
            {"id": "moon.source-fixture", "enabled": True, "tabs_read": False, "page_source": True},
            {"id": "moon.closed-fixture", "enabled": True, "tabs_read": False, "tabs_closed_manage": True},
            {"id": "moon.privacy-cache-fixture", "enabled": True, "tabs_read": False, "privacy_clear": True},
            {"id": "moon.privacy-data-fixture", "enabled": True, "tabs_read": False, "privacy_clear": True},
            {"id": "moon.task-fixture", "enabled": True, "tabs_read": False, "task_manager_manage": True},
            {"id": "moon.command-fixture", "enabled": True, "tabs_read": False, "ui_commands": True},
            {"id": "moon.search-fixture", "enabled": True, "tabs_read": False, "search_manage": True},
            {"id": "moon.tab-tools", "enabled": True, "tabs_read": False, "tabs_organize": True},
        ]), encoding="utf-8")
        (fixture / "plugin.json").write_text(json.dumps({
            "id": "moon.settings-fixture", "name": "Settings fixture", "version": "1.0.0",
            "apiVersion": 2, "runtime": "native", "entry": "Unused.exe", "settingsPage": "settings.html",
            "contributes": {"commands": [{"id": "open", "label": "Fixture"}]},
        }), encoding="utf-8")
        (fixture / "settings.html").write_text(
            '<title>Extension fixture</title><script>(async()=>{'
            'if(window.webkit.messageHandlers.moonPlugins)return;'
            'const api=window.webkit.messageHandlers.moonSettings;'
            'const call=async op=>JSON.parse(await api.postMessage(JSON.stringify(op)));'
            'const forged=await call({op:"write",value:{bad:true},pluginId:"moon.lua-manager"});'
            'if(forged.ok)return;'
            + ('const denied=await window.webkit.messageHandlers.moonHost.postMessage('
               'JSON.stringify({jsonrpc:"2.0",id:"1",method:"history.list",params:{}}));'
               'if(JSON.parse(denied).error?.code!==-32001)return;' if history.exists() else '') +
            ('const siteDenied=await window.webkit.messageHandlers.moonHost.postMessage('
             'JSON.stringify({jsonrpc:"2.0",id:"2",method:"siteData.status",params:{}}));'
             'if(JSON.parse(siteDenied).error?.code!==-32001)return;' if site_data.exists() else '') +
            ('const readingDenied=await window.webkit.messageHandlers.moonHost.postMessage('
             'JSON.stringify({jsonrpc:"2.0",id:"3",method:"reading.find",params:{}}));'
             'if(JSON.parse(readingDenied).error?.code!==-32601)return;' if reading.exists() else '') +
            ('const closedDenied=await window.webkit.messageHandlers.moonHost.postMessage('
             'JSON.stringify({jsonrpc:"2.0",id:"4",method:"tabs.closed.list",params:{}}));'
             'if(JSON.parse(closedDenied).error?.code!==-32001)return;' if recent.exists() else '') +
            ('const privacyDenied=await window.webkit.messageHandlers.moonHost.postMessage('
             'JSON.stringify({jsonrpc:"2.0",id:"5",method:"privacy.clear",params:{siteData:true}}));'
             'if(JSON.parse(privacyDenied).error?.code!==-32001)return;' if privacy.exists() else '') +
            ('const tasksDenied=await window.webkit.messageHandlers.moonHost.postMessage('
             'JSON.stringify({jsonrpc:"2.0",id:"6",method:"taskManager.snapshot",params:{view:"tabs"}}));'
             'if(JSON.parse(tasksDenied).error?.code!==-32001)return;' if task_manager.exists() else '') +
            ('const menuDenied=await window.webkit.messageHandlers.moonHost.postMessage('
             'JSON.stringify({jsonrpc:"2.0",id:"7",method:"ui.menu.add",params:{id:"open"}}));'
             'if(JSON.parse(menuDenied).error?.code!==-32001)return;' if commands.exists() else '') +
            ('const sourceDenied=await window.webkit.messageHandlers.moonHost.postMessage('
             'JSON.stringify({jsonrpc:"2.0",id:"8",method:"pageSource.status",params:{}}));'
             'if(JSON.parse(sourceDenied).error?.code!==-32001)return;' if page_source.exists() else '') +
            ('const popupDenied=await window.webkit.messageHandlers.moonHost.postMessage('
             'JSON.stringify({jsonrpc:"2.0",id:"9",method:"popups.status",params:{}}));'
             'if(JSON.parse(popupDenied).error?.code!==-32001)return;' if popups.exists() else '') +
            ('const downloadsDenied=await window.webkit.messageHandlers.moonHost.postMessage('
             'JSON.stringify({jsonrpc:"2.0",id:"10",method:"downloads.clearCompleted",params:{}}));'
             'if(JSON.parse(downloadsDenied).error?.code!==-32001)return;'
             if has_bulk_clear else '') +
            f'let blocked=false; try{{await fetch("{base}/extension-network");}}catch{{blocked=true;}}'
            'if(!blocked)return;'
            'const write=await call({op:"write",value:{roundTrip:7}});'
            'const read=await call({op:"read"});'
            'if(write.ok&&read.ok&&read.value.roundTrip===7)await call({op:"write",value:{passed:true}});'
            '})();</script>', encoding="utf-8")
        lua_source = (
            "-- ==MoonUserScript==\n-- @name Editor fixture\n-- @api 1\n"
            f"-- @match {base}/page/editor\n-- ==/MoonUserScript==\n"
            'moon.dom.setText("#editor-proof", "Old Lua source")\n'
        )
        (profile / "lua-userscripts.json").write_text(
            json.dumps([{"source": lua_source, "enabled": True}]), encoding="utf-8")
    if history.exists():
        fixture = profile / "plugins" / "history-contract"
        fixture.mkdir(parents=True)
        (fixture / "plugin.json").write_text(json.dumps({
            "id": "moon.history-fixture", "name": "History API fixture", "version": "1.0.0",
            "apiVersion": 2, "runtime": "native", "entry": "Unused.exe", "settingsPage": "history.html",
            "permissions": ["history.manage"] + (["popups.manage"] if popups.exists() else []),
            "contributes": {"commands": [{"id": "open", "label": "History fixture"}]},
        }), encoding="utf-8")
        bundled_page = (history.parent / "history.html").read_text(encoding="utf-8")
        contract = (
            '<script>(async()=>{'
            'const api=window.webkit.messageHandlers;let id=0;'
            'const call=async(method,params={})=>JSON.parse(await api.moonHost.postMessage('
            'JSON.stringify({jsonrpc:"2.0",id:String(++id),method,params})));'
            'const waitFor=async predicate=>{for(let i=0;i<60;i++){const el=predicate();'
            'if(el)return el;await new Promise(resolve=>setTimeout(resolve,50));}throw new Error("UI timeout");};'
            'try{'
            'const options=JSON.parse(await api.moonSettings.postMessage(JSON.stringify({op:"read"}))).value;'
            'if(options?.popupMode){const reply=await call("popups.setRule",{origin:options.popupOrigin,mode:options.popupMode});'
            'const popupResult=reply.result===true?"saved":reply.error?.data?.reason||"unexpected";'
            'await api.moonSettings.postMessage(JSON.stringify({op:"write",value:{popupResult}}));return;}'
            'const first=await call("history.list",{query:"HISTORY-contract"});'
            'const row=first.result?.visits?.[0];'
            'if(!row?.url.endsWith("/page/history-contract") || !row.title.includes("history-contract"))throw new Error("list");'
            'const excluded=await call("history.list",{query:"history-contract",before:row.id});'
            'if(excluded.result?.visits?.length!==0)throw new Error("cursor");'
            'if((await call("tabs.getActive")).error?.code!==-32601)throw new Error("scope");'
            'const search=document.getElementById("query");'
            'search.value="HISTORY-contract";search.dispatchEvent(new Event("input"));'
            'const link=await waitFor(()=>document.querySelector("#results li a[href$=\'/page/history-contract\']"));'
            'await waitFor(()=>document.querySelectorAll("#results li").length===1);'
            'link.closest("li").querySelector("button").click();'
            'await waitFor(()=>document.getElementById("status").textContent==="没有匹配的浏览记录。");'
            'if((await call("history.remove",{id:row.id})).error?.code!==-32004)throw new Error("remove");'
            'const clear=document.getElementById("clear");clear.click();'
            'const dialog=document.getElementById("confirm-clear");'
            'if(!dialog.open)throw new Error("confirm dialog");document.getElementById("cancel").click();'
            'if(dialog.open||!(await call("history.list")).result?.visits?.length)throw new Error("clear cancel");'
            'clear.click();document.getElementById("confirm").click();'
            'await waitFor(()=>!dialog.open);'
            'if((await call("history.list")).result?.visits?.length!==0)throw new Error("clear");'
            'await api.moonSettings.postMessage(JSON.stringify({op:"write",value:{passed:true}}));'
            '}catch(error){await api.moonSettings.postMessage(JSON.stringify({op:"write",value:{error:String(error)}}));}'
            '})();</script>'
        )
        (fixture / "history.html").write_text(bundled_page.replace("</html>", contract + "</html>"), encoding="utf-8")
    if blocker.exists():
        fixture = profile / "plugins" / "blocker-settings"
        fixture.mkdir(parents=True)
        shutil.copy2(blocker,fixture / blocker.name)
        manifest = json.loads((blocker.parent / "plugin.json").read_text(encoding="utf-8"))
        manifest["id"] = "moon.filter-settings-fixture"
        (fixture / "plugin.json").write_text(json.dumps(manifest), encoding="utf-8")
        (fixture / "strict.rules").write_text("@127.0.0.1\t/moon-filter-probe/blocked\n", encoding="utf-8")
        html = (blocker.parent / "filter.html").read_text(encoding="utf-8")
        contract = (
            '<script>(async()=>{const siteInput=document.getElementById("site");'
            'for(let i=0;siteInput.disabled&&i<50;i++)await new Promise(r=>setTimeout(r,50));'
            'if(siteInput.disabled)return;'
            'siteInput.value="127.0.0.1";document.getElementById("pause").click();'
            '})();</script>'
        )
        (fixture / "filter.html").write_text(html.replace("</html>",contract + "</html>"), encoding="utf-8")
    if bookmarks.exists():
        fixture = profile / "plugins" / "bookmark-contract"
        fixture.mkdir(parents=True)
        manifest = json.loads((bookmarks.parent / "plugin.json").read_text(encoding="utf-8"))
        manifest["id"] = "moon.bookmark-fixture"
        for command in manifest["contributes"]["commands"]:
            if command["id"] in ("import","export"):
                command["label"] = "Bookmark transfer fixture " + command["id"]
                command.pop("menu",None)
            if command.get("linkMenu"):
                command["label"] = "未授权的书签链接命令"
        (fixture / "plugin.json").write_text(json.dumps(manifest), encoding="utf-8")
        page = (bookmarks.parent / "bookmarks.html").read_text(encoding="utf-8")
        contract = (
            '<script>(async()=>{const api=window.webkit.messageHandlers.moonSettings;'
            'const emit=value=>api.postMessage(JSON.stringify({op:"write",value}));'
            'const wait=async(fn)=>{for(let i=0;i<70;i++){if(fn())return;await new Promise(r=>setTimeout(r,50));}'
            'throw Error("bookmarks UI timeout");};'
            'try{await wait(()=>document.querySelector("#results li"));'
            'document.querySelector("#results li button").click();'
            'document.getElementById("title").value="编辑后的书签";document.getElementById("folder").value="测试文件夹";'
            'document.getElementById("save").click();'
            'await wait(()=>!document.getElementById("editor").open);'
            'const input=document.getElementById("search");input.value="测试文件夹";input.dispatchEvent(new Event("input"));'
            'await wait(()=>document.querySelector("#results").textContent.includes("编辑后的书签"));'
            'if(document.getElementById("export")){document.getElementById("export").click();'
            'await wait(()=>document.getElementById("transfer-status").textContent.includes("已导出 1 个"));}'
            'await emit({passed:true});}catch(error){await emit({error:String(error)});}})();</script>'
        )
        (fixture / "bookmarks.html").write_text(page.replace("</html>", contract + "</html>"), encoding="utf-8")
    if downloads.exists():
        fixture = profile / "plugins" / "download-contract"
        fixture.mkdir(parents=True)
        manifest = json.loads((downloads.parent / "plugin.json").read_text(encoding="utf-8"))
        manifest["id"] = "moon.download-fixture"
        (fixture / "plugin.json").write_text(json.dumps(manifest), encoding="utf-8")
        page = (downloads.parent / "downloads.html").read_text(encoding="utf-8")
        contract = (
            '<script>(async()=>{const api=window.webkit.messageHandlers.moonSettings;'
            'const emit=value=>api.postMessage(JSON.stringify({op:"write",value}));'
            'const wait=async(fn)=>{for(let i=0;i<90;i++){const v=fn();if(v)return v;'
            'await new Promise(r=>setTimeout(r,50));}throw Error("downloads UI timeout");};'
            'try{await wait(()=>document.querySelector("progress")?.value>0);'
            'const clear=document.getElementById("clear-completed");'
            'if(clear){const dialog=document.getElementById("clear-dialog");'
            'clear.click();if(!dialog.open)throw Error("missing clear confirmation");'
            'document.getElementById("cancel-clear").click();await wait(()=>!dialog.open);'
            'if(!(await host("downloads.list",{})).downloads.some(item=>item.state==="complete"))throw Error("clear cancel");'
            'const input=document.getElementById("search");input.value="slow-test";input.dispatchEvent(new Event("input"));'
            'await wait(()=>!document.querySelector("#results").textContent.includes("completed-proof.txt"));'
            'clear.click();document.getElementById("confirm-clear").click();'
            'await wait(()=>document.getElementById("feedback").textContent.includes("已清除 1 条"));'
            'const remaining=(await host("downloads.list",{})).downloads.map(item=>item.state).sort();'
            'if(remaining.join(",")!=="failed,transferring")throw Error("unexpected download states: "+remaining);}'
            'const cancel=await wait(()=>document.querySelector(\'button[data-control$=":cancel"]\'));cancel.click();'
            'await wait(()=>document.querySelector("#results").textContent.includes("已取消"));'
            'await emit({passed:true});}catch(error){await emit({error:String(error)});}})();</script>'
        )
        (fixture / "downloads.html").write_text(page.replace("</html>", contract + "</html>"), encoding="utf-8")
    if page_source.exists():
        fixture = profile / "plugins" / "page-source-contract"
        fixture.mkdir(parents=True)
        shutil.copy2(page_source,fixture / page_source.name)
        manifest = json.loads((page_source.parent / "plugin.json").read_text(encoding="utf-8"))
        manifest["id"] = "moon.source-fixture"
        action = manifest["contributes"]["commands"][0]
        action["label"] = "运行网页源代码验收"
        del action["shortcut"]
        (fixture / "plugin.json").write_text(json.dumps(manifest),encoding="utf-8")
        page = (page_source.parent / "source.html").read_text(encoding="utf-8")
        contract = """
<script>(async()=>{
    const api=window.webkit.messageHandlers.moonSettings;
    const emit=value=>api.postMessage(JSON.stringify({op:"write",value}));
    const wait=async(fn,label)=>{for(let n=0;n<240;n++){const result=await fn();if(result)return result;
        await new Promise(resolve=>setTimeout(resolve,50));}throw Error(label);};
    try {
        const initial=await host("pageSource.status");
        if(initial.state==="idle"){
            const isolated=await host("pageSource.read",{generation:1,offset:0}).then(()=>false,()=>true);
            await emit({isolated});
        }
        const result=await wait(async()=>{const current=await host("pageSource.status");
            return current.state==="ready"&&current;},"no source snapshot");
        await wait(()=>!viewer.hidden&&source.textContent,"source was not rendered");
        const value=source.textContent;
        if(!result.truncated||result.bytes>512*1024||result.bytes<512*1024-3||
            !value.includes("<!-- 源码雪月🌙 -->")||!value.includes('<p id="wire">before mutation</p>')||
            value.includes("END-OF-WIRE")||value.includes("�")||source.childElementCount)
            throw Error("unexpected source contents");
        wrap.click();
        if(wrap.getAttribute("aria-pressed")!=="true"||!viewer.classList.contains("wrap"))
            throw Error("line wrap not applied");
        await emit({ready:true});
        await wait(async()=>(await host("pageSource.status")).state==="stale","source was not invalidated");
        try {await host("pageSource.read",{generation:result.generation,offset:0});}
        catch {await wait(()=>viewer.hidden&&!source.textContent,"stale source remained visible");
            await emit({passed:true});return;}
        throw Error("stale source could be read");
    } catch(error){await emit({error:String(error)});}
})();</script>"""
        (fixture / "source.html").write_text(page.replace("</html>",contract+"</html>"),encoding="utf-8")
    if site_data.exists():
        fixture = profile / "plugins" / "site-data-contract"
        fixture.mkdir(parents=True)
        shutil.copy2(site_data,fixture / site_data.name)
        manifest = json.loads((site_data.parent / "plugin.json").read_text(encoding="utf-8"))
        manifest["id"] = "moon.site-data-fixture"
        manifest["contributes"]["commands"][0]["label"] = "运行站点数据验收"
        (fixture / "plugin.json").write_text(json.dumps(manifest), encoding="utf-8")
        page = (site_data.parent / "site-data.html").read_text(encoding="utf-8")
        contract = (
            '<script>(async()=>{const api=window.webkit.messageHandlers.moonSettings;'
            'const emit=value=>api.postMessage(JSON.stringify({op:"write",value}));'
            'const wait=async(fn,label)=>{for(let i=0;i<180;i++){const v=await fn();if(v)return v;'
            'await new Promise(r=>setTimeout(r,50));}throw Error(label);};'
            'try{const result=await wait(async()=>{const data=await host("siteData.status");'
            'if(data.state==="unavailable"||data.state==="stale")throw Error("snapshot "+data.state+": "+data.failure);'
            'return data.state==="ready"&&data;},"snapshot ready");'
            f'if(result.origin!=="{base}")throw Error("origin");'
            'for(const [section,key,secret] of [["cookies","moon-visible","cookie-value"],'
            '["local","moon-local","local-value"],["session","moon-session","session-value"]]){'
            'document.querySelector("[data-group="+section+"]").click();'
            'const row=await wait(()=>[...document.querySelectorAll("#results li")].find(r=>r.querySelector("code").textContent===key),key);'
            'if(row.querySelector("pre").textContent)throw Error("value visible by default");'
            'row.querySelector("button").click();'
            'await wait(()=>row.querySelector("pre").textContent===secret,section+" isolated value");'
            'row.querySelector("button").click();'
            '}const cookies=await host("siteData.list",{group:"cookies"});'
            'if(cookies.entries.some(row=>row.name==="moon-http-only"||row.name==="forged"))throw Error("cookie scope");'
            'if(document.querySelector("[data-group=indexedDB]")){'
            'const inventory=(group)=>wait(async()=>{const value=await host("siteData.catalog",{group});'
            'return value.state!=="pending"&&value;},"storage catalog "+group);'
            'document.querySelector("[data-group=indexedDB]").click();'
            'const databases=await inventory("indexedDB");'
            'if(databases.state!=="ready"||databases.generation!==result.generation||databases.cacheStorage||'
            '!databases.indexedDB?.entries.some(entry=>entry.name==="moon-inventory"&&entry.version===3)||'
            'databases.indexedDB.entries.some(entry=>entry.name==="forged"))throw Error("database catalog "+JSON.stringify(databases));'
            'await wait(()=>el("results").textContent.includes("版本 3"),"rendered database version");'
            'document.querySelector("[data-group=cacheStorage]").click();'
            'const cached=(await inventory("cacheStorage")).cacheStorage;'
            'if(!cached?.more||cached.entries.length!==32||!cached.entries.some(entry=>entry.name==="moon-request-cache")||'
            '!cached.entries.some(entry=>entry.shortened&&entry.name==="月".repeat(128))||'
            'cached.entries.some(entry=>entry.name==="forged"))throw Error("cache catalog "+JSON.stringify(cached));'
            'await wait(()=>el("results").textContent.includes("moon-request-cache"),"rendered cache");'
            'el("search").value="moon-request";el("search").dispatchEvent(new Event("input"));'
            'if(el("results").children.length!==1)throw Error("catalog search");'
            'el("search").value="";el("search").dispatchEvent(new Event("input"));}'
            'let cookieRejected=false;try{await host("siteData.update",{group:"cookies",id:0,generation:cookies.generation,value:"forbidden"});}'
            'catch(error){cookieRejected=error.message==="INVALID_PARAMS";}if(!cookieRejected)throw Error("cookie mutation");'
            'const rowFor=key=>[...document.querySelectorAll("#results li")].find(r=>r.querySelector("code").textContent===key);'
            'const button=(row,text)=>[...row.querySelectorAll("button")].find(b=>b.textContent===text);'
            'const changed=async(kind,after)=>wait(async()=>{const state=await host("siteData.status");'
            'return state.state==="ready"&&state.generation>after&&state.mutation===kind&&state;},"mutation "+kind);'
            'document.querySelector("[data-group=local]").click();'
            'button(await wait(()=>rowFor("moon-local"),"local row"),"编辑").click();'
            'await wait(()=>!el("editor").hidden&&el("new-value").value==="local-value","editor value");'
            'el("editor").requestSubmit();'
            'await wait(()=>el("editor").hidden&&el("feedback").textContent==="没有修改。","unchanged editor");'
            'if((await host("siteData.status")).generation!==result.generation)throw Error("unchanged editor submitted a write");'
            'button(await wait(()=>rowFor("moon-local"),"local row"),"编辑").click();'
            'await wait(()=>!el("editor").hidden,"reopened editor");'
            'const replacement=["月亮",String.fromCharCode(92,34,10),"next"].join(" ");'
            'el("new-value").value=replacement;el("new-value").dispatchEvent(new Event("input"));'
            'el("editor").requestSubmit();const saved=await changed("saved",result.generation);'
            'const local=await host("siteData.list",{group:"local"});'
            'const item={group:"local",id:local.entries.find(row=>row.name==="moon-local").id,generation:local.generation};'
            'if(await host("siteData.value",item)!==replacement)throw Error("edited local value");'
            'document.querySelector("[data-group=session]").click();'
            'button(await wait(()=>rowFor("moon-session"),"session row"),"删除").click();'
            'await wait(()=>!el("editor").hidden&&el("commit").textContent==="确认删除","delete confirmation");'
            'el("editor").requestSubmit();const removed=await changed("removed",saved.generation);'
            'const session=await host("siteData.list",{group:"session"});'
            'if(session.entries.some(row=>row.name==="moon-session"))throw Error("session item was not deleted");'
            'let oldRejected=false;try{await host("siteData.update",{...item,value:"stale-write"});}'
            'catch(error){oldRejected=error.message==="NOT_FOUND";}if(!oldRejected)throw Error("stale mutation");'
            'const current=await host("siteData.list",{group:"local"});'
            'const target={group:"local",id:current.entries.find(row=>row.name==="moon-local").id,generation:current.generation};'
            'await emit({waitingForConflict:true});'
            'await wait(async()=>JSON.parse(await api.postMessage(JSON.stringify({op:"read"}))).value?.conflictReady,"source mutation signal");'
            'if(!await host("siteData.update",{...target,value:"should-not-win"}))throw Error("conflict request");'
            'await changed("conflict",removed.generation);'
            'const final=await host("siteData.list",{group:"local"});'
            'if(await host("siteData.value",{...target,generation:final.generation})!=="page-change")throw Error("conflict wrote value");'
            'if(!await host("siteData.refresh"))throw Error("refresh request");'
            'await wait(async()=>{const data=await host("siteData.status");'
            'return data.state==="ready"&&data.generation>result.generation;},"new generation");'
            'await emit({ready:true});'
            'await wait(async()=>(await host("siteData.status")).state==="stale","navigation cleanup");'
            'await wait(()=>!document.querySelector("#results li"),"clear rows");'
            'let rejected=false;try{await host("siteData.value",{group:"cookies",id:0,generation:result.generation});}'
            'catch(error){rejected=error.message==="NOT_FOUND";}if(!rejected)throw Error("stale credential read");'
            'if(document.querySelector("[data-group=indexedDB]")){let staleCatalog=false;'
            'try{await host("siteData.catalog",{group:"indexedDB"});}catch(error){staleCatalog=error.message==="NOT_FOUND";}'
            'if(!staleCatalog)throw Error("catalog after navigation");}'
            'let writeRejected=false;try{await host("siteData.update",{...target,value:"after-navigation"});}'
            'catch(error){writeRejected=error.message==="NOT_FOUND";}if(!writeRejected)throw Error("mutation after navigation");'
            'await emit({passed:true});}catch(error){await emit({error:String(error)});}})();</script>'
        )
        (fixture / "site-data.html").write_text(page.replace("</html>", contract + "</html>"), encoding="utf-8")
    if recent.exists():
        fixture = profile / "plugins" / "recent-contract"
        fixture.mkdir(parents=True)
        (fixture / "plugin.json").write_text(json.dumps({
            "id": "moon.closed-fixture", "name": "Closed tabs contract", "version": "1.0.0",
            "apiVersion": 2, "runtime": "native", "entry": "Unused.exe", "settingsPage": "recent.html",
            "permissions": ["tabs.closed.manage"], "contributes": {"commands": [{"id": "open", "label": "Fixture"}]},
        }), encoding="utf-8")
        page = recent.with_name("recent.html").read_text(encoding="utf-8")
        contract = (
            '<script>(async()=>{'
            'const emit=value=>window.webkit.messageHandlers.moonSettings.postMessage(JSON.stringify({op:"write",value}));'
            'const wait=async(fn,label)=>{for(let i=0;i<200;i++){if(await fn())return;'
            'await new Promise(r=>setTimeout(r,50));}throw Error(label);};'
            'try{await wait(()=>clear.disabled===false,"loading");'
            'const entries=await host("tabs.closed.list");'
            'if(entries.map(v=>v.title).join(",")!=="Moon fixture closed-item,Moon fixture closed-second")'
            'throw Error("closed order or unsafe entry: "+JSON.stringify(entries));'
            f'if(entries.some(entry=>entry.origin!=="{base}"))throw Error("entry origin");'
            'if(list.children.length!==2)throw Error("rendered rows");'
            'clear.click();if(!confirm.open)throw Error("clear confirmation");'
            'confirm.querySelector(\'[value="cancel"]\').click();'
            'await wait(()=>!confirm.open,"cancel confirmation");'
            'if((await host("tabs.closed.list")).length!==2)throw Error("cancel changed list");'
            'list.children[1].querySelector("button").click();'
            'await wait(()=>list.children.length===1,"targeted reopen");'
            'if(!(await host("tabs.closed.list"))[0].title.endsWith("closed-item"))throw Error("wrong entry restored");'
            'clear.click();confirm.querySelector("#confirm-clear").click();'
            'await wait(()=>list.children.length===0&&status.textContent.includes("没有可恢复"),"confirmed clear");'
            'await emit({passed:true});}catch(error){await emit({error:String(error)});}})();</script>'
        )
        (fixture / "recent.html").write_text(page.replace("</html>", contract + "</html>"), encoding="utf-8")
    if privacy.exists():
        page = privacy.with_name("privacy.html").read_text(encoding="utf-8")
        for choice in ("cache", "data"):
            fixture = profile / "plugins" / f"privacy-{choice}-contract"
            fixture.mkdir(parents=True)
            (fixture / "plugin.json").write_text(json.dumps({
                "id": f"moon.privacy-{choice}-fixture", "name": "Privacy contract", "version": "1.0.0",
                "apiVersion": 2, "runtime": "native", "entry": "Unused.exe", "settingsPage": "privacy.html",
                "permissions": ["privacy.clear"], "contributes": {"commands": [{"id": "open", "label": "Fixture"}]},
            }), encoding="utf-8")
            preparation = (
                'for(const input of options)input.checked=true;updateControls();'
                'erase.click();await wait(()=>status.textContent.includes("已取消"),"cancel");'
                'if((await host("privacy.status")).state!=="idle")throw Error("cancel started an operation");'
                'for(const input of options)input.checked=input.name==="cache";updateControls();'
                if choice == "cache" else
                'for(const input of options)input.checked=input.name!=="cache";updateControls();'
            )
            contract = (
                '<script>(async()=>{'
                'const emit=value=>window.webkit.messageHandlers.moonSettings.postMessage(JSON.stringify({op:"write",value}));'
                'const wait=async(fn,label)=>{for(let i=0;i<220;i++){if(await fn())return;'
                'await new Promise(r=>setTimeout(r,50));}throw Error(label+": "+status.textContent);};'
                'try{await wait(()=>!erase.disabled,"ready");' + preparation +
                'erase.click();await wait(()=>status.textContent.includes("已清除"),"clear");'
                'const state=await host("privacy.status");'
                'if(state.state!=="complete"||Object.values(state.failed).some(Boolean))throw Error(JSON.stringify(state));'
                'await emit({passed:true});}catch(error){await emit({error:String(error)});}})();</script>'
            )
            (fixture / "privacy.html").write_text(page.replace("</html>", contract + "</html>"), encoding="utf-8")
    if task_manager.exists():
        fixture = profile / "plugins" / "task-contract"
        fixture.mkdir(parents=True)
        (fixture / "plugin.json").write_text(json.dumps({
            "id": "moon.task-fixture", "name": "Task manager contract", "version": "1.0.0",
            "apiVersion": 2, "runtime": "native", "entry": "Unused.exe", "settingsPage": "tasks.html",
            "permissions": ["taskManager.manage"], "contributes": {"commands": [{"id": "open", "label": "Fixture"}]},
        }), encoding="utf-8")
        page = task_manager.with_name("tasks.html").read_text(encoding="utf-8")
        contract = (
            '<script>(async()=>{'
            'const emit=value=>window.webkit.messageHandlers.moonSettings.postMessage(JSON.stringify({op:"write",value}));'
            'const wait=async(fn,label)=>{for(let i=0;i<200;i++){if(await fn())return;'
            'await new Promise(r=>setTimeout(r,50));}throw Error(label);};'
            'try{const tabPage=await host("taskManager.snapshot",{view:"tabs"});'
            'const ready=tabPage.tabs.find(tab=>tab.title==="Moon fixture task-eligible");'
            'const held=tabPage.tabs.find(tab=>tab.title==="Moon fixture task-protected");'
            'if(!ready?.pid||ready?.protection!==null||held?.protection!=="input")'
            'throw Error("eligibility: "+JSON.stringify({ready,held}));'
            'if(tabPage.tabs.length!==24||tabPage.next!==24)throw Error("tab pagination");'
            'const remaining=await host("taskManager.snapshot",{view:"tabs",offset:tabPage.next});'
            'const current=remaining.tabs.find(tab=>tab.protection==="current");'
            'if(!current||tabPage.overview.open!==tabPage.tabs.length+remaining.tabs.length)throw Error("second page");'
            'if(await host("taskManager.discard",{id:current.id})!=="protected"||'
            'await host("taskManager.discard",{id:held.id})!=="protected")throw Error("protection bypass");'
            'find("view-processes").click();'
            'await wait(()=>find("rows").rows.length,"process view");'
            'let processPage;await wait(async()=>{processPage=await host("taskManager.snapshot",{view:"processes"});'
            'return processPage.processes.some(p=>p.pid===ready.pid&&p.tabs>=1);},"process sample containing the target tab");'
            'const processes=processPage.processes;'
            'if(processes.length!==new Set(processes.map(p=>p.pid)).size||'
            'processPage.next!==null||processes.reduce((sum,p)=>sum+p.privateBytes,0)!==processPage.overview.privateBytes||'
            '!processes.some(p=>p.browser))'
            'throw Error("process accounting: "+JSON.stringify(processPage));'
            'find("view-tabs").click();'
            'const button=action=>[...find("rows").querySelectorAll("button")].find(b=>b.dataset.action===action&&b.dataset.tab===ready.id);'
            'await wait(()=>button("discard")&&!button("discard").disabled,"discard button");button("discard").click();'
            'await wait(()=>find("status").textContent.includes("已卸载"),"manual discard");'
            'await wait(async()=>{const snap=await host("taskManager.snapshot",{view:"tabs"});'
            'const tab=snap.tabs.find(t=>t.id===ready.id);return tab.phase==="dormant"&&tab.pid===null&&'
            'snap.overview.beforeBytes>0&&snap.overview.afterBytes>0;},"sample after discard");'
            'button("focus").click();await wait(()=>!busy,"focus");'
            'await emit({passed:true,shared:processes.some(p=>p.tabs>1)});}'
            'catch(error){await emit({error:String(error)});}})();</script>'
        )
        (fixture / "tasks.html").write_text(page.replace("</html>", contract + "</html>"), encoding="utf-8")
    if commands.exists():
        fixture = profile / "plugins" / "command-contract"
        fixture.mkdir(parents=True)
        manifest = json.loads(commands.with_name("plugin.json").read_text(encoding="utf-8"))
        manifest.update(id="moon.command-fixture",name="命令唤醒验收")
        if has_site_menu:
            next(command for command in manifest["contributes"]["commands"] if command["id"] == "hello")["siteMenu"] = True
        (fixture / "plugin.json").write_text(json.dumps(manifest),encoding="utf-8")
        shutil.copyfile(commands,fixture / commands.name)
        page = commands.with_name("commands.html").read_text(encoding="utf-8")
        contract = (
            '<script>(async()=>{let sequence=0;const settings=window.webkit.messageHandlers.moonSettings;'
            'const emit=value=>settings.postMessage(JSON.stringify({op:"write",value}));'
            'const host=async(method,params={})=>JSON.parse(await window.webkit.messageHandlers.moonHost.postMessage('
            'JSON.stringify({jsonrpc:"2.0",id:String(++sequence),method,params}))).result;'
            'const expect=async(method,params,result)=>{const got=await host(method,params);'
            'if(got!==result)throw Error(method+" expected "+result+" got "+got);};'
            'const key=(shortcut,scope)=>({id:"hello",shortcut,scope});'
            'try{const old=JSON.parse(await settings.postMessage(JSON.stringify({op:"read"}))).value;'
            'if(old?.phase==="installed"){'
            'await expect("ui.menu.remove",{id:"hello"},"saved");'
            'await expect("ui.shortcuts.unregister",{id:"hello"},"saved");'
            'await emit({phase:"removed"});return;}'
            'await expect("ui.menu.add",{id:"missing"},"notFound");'
            'await expect("ui.menu.add",{id:"hello"},"saved");'
            'await expect("ui.shortcuts.register",key("Ctrl+C","browser"),"invalidShortcut");'
            'await expect("ui.shortcuts.register",key("Ctrl+Shift+M","browser"),"reserved");'
            'await expect("ui.shortcuts.register",key("Ctrl+Shift+K","browser"),"reserved");'
            'await expect("ui.shortcuts.register",key("Ctrl+Shift+Y","browser"),"saved");'
            'await expect("ui.shortcuts.register",key("Ctrl+Shift+9","global"),"conflict");'
            'await expect("ui.shortcuts.register",key("Ctrl+Shift+8","global"),"cancelled");'
            'await expect("ui.shortcuts.register",key("Ctrl+Shift+8","global"),"saved");'
            'await emit({phase:"installed"});}catch(error){await emit({error:String(error)});}})();</script>'
        )
        (fixture / "commands.html").write_text(page.replace("</html>",contract+"</html>"),encoding="utf-8")
    if search_plugin.exists():
        fixture = profile / "plugins" / "search-contract"
        fixture.mkdir(parents=True)
        manifest = json.loads(search_plugin.with_name("plugin.json").read_text(encoding="utf-8"))
        manifest.update(id="moon.search-fixture",name="Search settings fixture")
        manifest["contributes"]["commands"][0].pop("menu")
        (fixture / "plugin.json").write_text(json.dumps(manifest),encoding="utf-8")
        shutil.copyfile(search_plugin,fixture / search_plugin.name)
        page = search_plugin.with_name("engines.html").read_text(encoding="utf-8")
        contract = (
            '<script>(async()=>{const settings=window.webkit.messageHandlers.moonSettings;'
            'const emit=value=>settings.postMessage(JSON.stringify({op:"write",value}));'
            'const wait=async(fn,label)=>{for(let i=0;i<160;i++){if(fn())return;'
            'await new Promise(r=>setTimeout(r,40));}throw Error(label);};'
            'try{await wait(()=>!save.disabled,"search settings did not load");'
            'const first={name:"Fixture Search",alias:"probe",template:"https://search-test.invalid/find?q={query}&scope=title"};'
            'const other={name:"Second Search",alias:"other",template:"https://other-search.invalid/?terms={query}"};'
            'for(const engine of [first,other]){add.click();const row=rows().at(-1);'
            'for(const field of row.querySelectorAll("[data-field]")){field.value=engine[field.dataset.field];'
            'field.dispatchEvent(new Event("input",{bubbles:true}));}}'
            'preferred.value=rows()[0].dataset.key;'
            'if(!el("settings").checkValidity())throw Error("form rejected a valid engine");'
            'el("settings").requestSubmit();await wait(()=>!save.disabled&&status.textContent.length,"save did not finish");'
            'const state=await call("search.getConfig");'
            'if(state.config.preferred!=="probe"||state.config.custom.length!==2||!state.builtins.some(e=>e.alias==="ddg"))'
            'throw Error(status.textContent||"valid config did not persist");'
            'for(const template of ["http://search-test.invalid/?q={query}",'
            '"https://search-test.invalid/{query}?x=1","https://safe.invalid@other.invalid/?q={query}",'
            '"https://search-test.invalid/?q={query}&x={query}","https://search-test.invalid/?{query}=x"]) {'
            'if(await call("search.setConfig",{preferred:"probe",custom:[{...first,template}]})!=="invalidTemplate")'
            'throw Error("accepted an invalid template");}'
            'if(await call("search.setConfig",{preferred:"g",custom:[{...first,alias:"g"}]})!=="duplicateAlias")'
            'throw Error("accepted a reserved alias");'
            'if((await call("search.getConfig")).config.preferred!=="probe")throw Error("invalid save changed the active configuration");'
            'await emit({passed:true});}catch(error){await emit({error:String(error)});}})();</script>'
        )
        (fixture / "engines.html").write_text(page.replace("</html>",contract+"</html>"),encoding="utf-8")
    def browser_frame(process):
        deadline = monotonic() + 20
        while monotonic() < deadline:
            candidate = None
            while candidate := user.FindWindowExW(None, candidate, "MoonBrowserWindow", None):
                owner = wt.DWORD()
                user.GetWindowThreadProcessId(candidate, ctypes.byref(owner))
                if owner.value == process.pid and user.IsWindowVisible(candidate):
                    return candidate
            if process.poll() is not None:
                raise RuntimeError(f"Win32 smoke startup exited with {process.returncode}")
            sleep(0.1)
        raise RuntimeError("Win32 shell not found")

    proc = subprocess.Popen([str(exe), "--gdi"], env=preview_env(root))
    frame = None
    try:
        frame = browser_frame(proc)
        style = user.GetWindowLongPtrW(frame, -16)  # GWL_STYLE
        if style & 0x00C00000 == 0x00C00000:  # WS_CAPTION
            raise RuntimeError(f'Duplicate Windows title bar style is present: {style:#x}')
        outer, origin = wt.RECT(), wt.POINT()
        if (not user.GetWindowRect(frame, ctypes.byref(outer))
                or not user.ClientToScreen(frame, ctypes.byref(origin))
                or origin.y != outer.top):
            raise RuntimeError('Native non-client area added a second row above the toolbar')
        print('single_titlebar=ok', flush=True)
        if bookmarks.exists():
            if not user.GetClassLongPtrW(frame,-14) or not user.GetClassLongPtrW(frame,-34):
                raise RuntimeError("Moon Browser did not register the bundled large and small window icons")
            print("application_window_icon=ok",flush=True)
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

        def wait_for(predicate, reason, seconds=10):
            deadline = monotonic() + seconds
            while monotonic() < deadline:
                value = predicate()
                if value:
                    return value
                sleep(0.05)
            raise RuntimeError(reason)

        def owned_window(class_name, title=None):
            candidate = None
            while candidate := user.FindWindowExW(None, candidate, class_name, title):
                if user.GetWindow(candidate, 4) == frame and user.IsWindowVisible(candidate):  # GW_OWNER
                    return candidate
            return None

        def set_control(control, text):
            value = ctypes.create_unicode_buffer(text)
            user.SendMessageW(control, 0x000C, 0, ctypes.addressof(value))  # WM_SETTEXT

        def invoke(query):
            click(px(70), px(65))
            palette_window = find_palette()
            query_edit = user.GetDlgItem(palette_window, 1003)
            set_control(query_edit, query)
            user.PostMessageW(query_edit, 0x0100, 0x0D, 1)

        def library_result(plugin):
            config = profile / f'extension-{sha256(plugin.encode()).hexdigest()}.json'
            result = wait_for(lambda: read_settings(config),
                              f"No contract result from {plugin}",15)
            if not result.get("passed"):
                raise RuntimeError(f"{plugin}: {result.get('error')}")

        def read_settings(path):
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except (FileNotFoundError, PermissionError):
                # The browser replaces settings atomically and Windows can lock the path briefly.
                return {}

        def read_control(control):
            text = ctypes.create_unicode_buffer(4096)
            user.SendMessageW(control, 0x000D, len(text), ctypes.addressof(text))
            return text.value

        def read_address():
            return read_control(edit)

        def visible_children(parent):
            child = None
            while child := user.FindWindowExW(parent,child,None,None):
                if user.IsWindowVisible(child):
                    yield child

        def visible_page_view():
            surface = next(visible_children(content),None)
            return next(visible_children(surface),None) if docked_devtools and surface else surface

        invoke("版本与更新")
        popup = wait_for(lambda: owned_window("#32770", "版本与更新"), "Compact update dialog did not open")
        popup_rect = wt.RECT()
        user.GetWindowRect(popup, ctypes.byref(popup_rect))
        if popup_rect.bottom - popup_rect.top > px(180) or user.GetWindowLongPtrW(popup, -16) & 0x00C00000 == 0x00C00000:
            raise RuntimeError("Update info still uses a large system-framed window")
        close = user.GetDlgItem(popup, 1)  # IDOK
        user.PostMessageW(close, 0x0100, 0x1B, 1)  # Escape
        wait_for(lambda: not user.IsWindow(popup), "Escape did not close the info dialog")
        print("themed_dialog=ok", flush=True)

        if manager.exists():
            extension_address = "extension://moon.settings-fixture/settings.html"
            set_control(edit, extension_address)
            user.PostMessageW(edit, 0x0100, 0x0D, 1)
            config = profile / f'extension-{sha256(b"moon.settings-fixture").hexdigest()}.json'
            wait_for(lambda: read_settings(config).get("passed"),
                     "Extension page did not complete its scoped settings round trip", 15)
            foreign = profile / f'extension-{sha256(b"moon.lua-manager").hexdigest()}.json'
            if foreign.exists() or Fixture.seen_extension_network.is_set():
                raise RuntimeError("The extension page crossed its settings or network boundary")
            print("extension_settings=ok", flush=True)

            for attempt in range(2):
                set_control(edit, base + "/page/editor")
                user.PostMessageW(edit, 0x0100, 0x0D, 1)
                if Fixture.seen_editor_ready.wait(8 if attempt == 0 else 15):
                    break
                if attempt == 0:
                    print("Retrying the editor fixture navigation after its readiness signal was absent.",flush=True)
            else:
                raise RuntimeError("The editor fixture did not finish loading its original Lua script")
            invoke("打开 Lua 脚本编辑器")
            tool = wait_for(lambda: owned_window("MoonLuaEditor"), "Lua editor plugin did not open", 12)
            user.PostMessageW(tool, 0x0111, 102, 0)  # OPEN_SCRIPT
            source = user.GetDlgItem(tool, 104)
            wait_for(lambda: user.SendMessageW(source, 0x000E, 0, 0) > 0, "Lua editor did not show the installed source")
            set_control(source, lua_source.replace("Old Lua source", "Lua editor reloaded"))
            user.PostMessageW(tool, 0x0111, 105, 0)  # SAVE_SCRIPT
            if not Fixture.seen_editor_reload.wait(15):
                raise RuntimeError("Saving through the system plugin did not reload the matching page")
            user.PostMessageW(tool, 0x0010, 0, 0)
            wait_for(lambda: not user.IsWindow(tool), "Lua editor did not close after save")
            print("lua_editor_live_reload=ok", flush=True)

        if manager.exists():
            set_control(edit, base + "/page/中文")
            user.PostMessageW(edit, 0x0100, 0x0D, 1)
        else:
            set_control(home, base + "/page/中文")
            user.PostMessageW(home, 0x0100, 0x0D, 1)  # WM_KEYDOWN / Enter
        if not Fixture.seen_unicode.wait(15):
            raise RuntimeError("Unicode address did not reach the loopback fixture")
        setup = base + "/page/chrome-window"
        set_control(edit,setup)
        user.PostMessageW(edit,0x0100,0x0D,1)
        baseline = wait_for(lambda: Fixture.chrome_layout if Fixture.chrome_layout and Fixture.chrome_layout[3]==280 else None,
                            "The compositor fixture did not load and scroll")
        rect = wt.RECT()
        user.GetWindowRect(frame,ctypes.byref(rect))
        selected_text = "https://moon.example/Selection-Wgq-中文示例"
        # Native selection must survive geometry changes without an address rewrite.
        user.PostMessageW(frame,0x0100,0x75,1)  # VK_F6
        sleep(0.08)
        set_control(edit,selected_text)
        user.SendMessageW(edit,0x00B1,0,len(selected_text))  # EM_SETSEL
        user.SendMessageW(frame,0x0231,0,0)  # WM_ENTERSIZEMOVE
        for left, width in ((-260,820),(140,970),(225,1050),(rect.left,rect.right-rect.left))*3:
            user.SetWindowPos(frame,None,left,rect.top,width,rect.bottom-rect.top,0x0014)
            sleep(0.02)
        user.SendMessageW(frame,0x0232,0,0)  # WM_EXITSIZEMOVE
        user.ShowWindow(frame,3)  # SW_MAXIMIZE
        wait_for(lambda: Fixture.chrome_layout and Fixture.chrome_layout[1]>baseline[1],
                 "WebKit viewport did not expand after maximizing")
        user.ShowWindow(frame,9)  # SW_RESTORE
        user.SetWindowPos(frame,None,rect.left,rect.top,rect.right-rect.left,rect.bottom-rect.top,0x0014)
        try:
            wait_for(lambda: Fixture.chrome_layout and Fixture.chrome_layout[:3]==baseline[:3] and
                     abs(Fixture.chrome_layout[3]-baseline[3])<=3,
                     "Moving and restoring changed the document, viewport or scroll position")
        except RuntimeError as error:
            raise RuntimeError(f"{error}: {baseline} --> {Fixture.chrome_layout}") from error
        addr_bounds, text_bounds = wt.RECT(), wt.RECT()
        user.GetClientRect(edit,ctypes.byref(addr_bounds))
        user.SendMessageW(edit,0x00B2,0,ctypes.addressof(text_bounds))  # EM_GETRECT
        if addr_bounds.bottom < px(25) or text_bounds.bottom > addr_bounds.bottom:
            raise RuntimeError("Address text formatting is clipped by the native input bounds")
        selection = user.SendMessageW(edit,0x00B0,0,0)  # EM_GETSEL
        if selection != (len(selected_text)<<16) or read_control(edit)!=selected_text:
            raise RuntimeError("Window movement lost the selected address text")
        window_rect, client_origin = wt.RECT(), wt.POINT()
        user.GetWindowRect(frame,ctypes.byref(window_rect))
        user.ClientToScreen(frame,ctypes.byref(client_origin))
        if user.GetWindowLongPtrW(frame,-16)&0x00C00000 or client_origin.y!=window_rect.top:
            raise RuntimeError("A system caption returned after maximize and restore")
        print("chrome_move_reflow=ok scroll_retained=ok native_address_selection=ok",flush=True)
        if not user.IsWindowVisible(content) or user.IsWindowVisible(home):
            raise RuntimeError("The WebKit view did not replace the native new-tab view")
        print(f"win32_unicode_address=ok resized_dpi={dpi} chrome_px={expected_chrome} fallback=GDI+")
        if devtools.exists():
            sleep(0.3)
            def inspector_window():
                candidate = None
                while candidate := user.FindWindowExW(None, candidate, "WebInspectorUIProxyClass", None):
                    owner = wt.DWORD()
                    user.GetWindowThreadProcessId(candidate, ctypes.byref(owner))
                    if owner.value == proc.pid and user.IsWindowVisible(candidate):
                        return candidate
                return None
            def close_independent_inspector():
                inspector = wait_for(inspector_window,"The independent WebKit inspector did not open",20)
                user.PostMessageW(inspector,0x0010,0,0)
                wait_for(lambda: not inspector_window(),"Web Inspector did not close")

            if docked_devtools:
                large = (px(1080),px(690))
                user.SetWindowPos(frame,None,window_rect.left,window_rect.top,*large,0x0014)
                surface = next(visible_children(content))
                page = next(visible_children(surface))

                def attached_inspector():
                    return next((child for child in visible_children(surface) if child != page),None)

                def covers_surface(panel):
                    a,b,host = wt.RECT(),wt.RECT(),wt.RECT()
                    user.GetWindowRect(page,ctypes.byref(a))
                    user.GetWindowRect(panel,ctypes.byref(b))
                    user.GetWindowRect(surface,ctypes.byref(host))
                    return ((a.left,a.top,b.right,b.bottom)==(host.left,host.top,host.right,host.bottom)
                            and ((a.bottom==b.top and a.right==b.right) or (a.right==b.left and a.bottom==b.bottom)))

                invoke("打开网页控制台")
                panel = wait_for(attached_inspector,"The console did not dock in the source tab",20)
                wait_for(lambda: covers_surface(panel),"The dock and page overlap or leave a gap")
                if inspector_window():
                    raise RuntimeError("A separate inspector is still visible while the console is docked")
                user.SetWindowPos(frame,None,window_rect.left+20,window_rect.top+10,px(970),px(610),0x0014)
                wait_for(lambda: covers_surface(panel),"The dock lost its bounds on resize")
                invoke("新建标签页")
                wait_for(lambda: user.IsWindowVisible(home) and not user.IsWindowVisible(panel),"The dock leaked into another tab")
                invoke("Moon fixture chrome-window")
                wait_for(lambda: user.IsWindowVisible(panel) and covers_surface(panel),"The dock did not return to its own tab")
                click(px(250),px(222))
                invoke("在独立窗口打开开发者工具")
                close_independent_inspector()
                wait_for(lambda: not attached_inspector(),"The detached inspector remained in the tab")
                user.PostMessageW(edit,0x0100,0x7B,1)  # F12 through the installed system plugin
                wait_for(attached_inspector,"F12 did not dock the inspector",20)
                user.SetWindowPos(frame,None,window_rect.left,window_rect.top,px(700),px(375),0x0014)
                close_independent_inspector()
                user.SetWindowPos(frame,None,window_rect.left,window_rect.top,
                    window_rect.right-window_rect.left,window_rect.bottom-window_rect.top,0x0014)
                print("inspector_docking=ok layout_reflow=ok tab_isolation=ok detach=ok narrow_fallback=ok",flush=True)
            else:
                invoke("打开网页控制台")
                close_independent_inspector()
                if history.exists():
                    user.PostMessageW(edit,0x0100,0x7B,1)
                    close_independent_inspector()
            print("devtools_system_plugin=ok", flush=True)
            invoke("插件市场")
            wait_for(lambda: read_address() == "moon://market/", "Browser did not open the built-in plugin market")
            print("plugin_market_entry=ok", flush=True)
            invoke("管理插件")
            wait_for(lambda: read_address() == "moon://plugins/", "Browser did not open the built-in plugin manager")
            invoke("插件市场")
            wait_for(lambda: read_address() == "moon://market/", "Could not return to the plugin market")
            invoke("管理插件")
            wait_for(lambda: read_address() == "moon://plugins/", "Could not return to the plugin manager")
            click(px(70),px(65))
            palette_window = find_palette()
            palette_items = user.GetDlgItem(palette_window,1004)
            labels = []
            for i in range(user.SendMessageW(palette_items,0x018B,0,0)):  # LB_GETCOUNT
                label = ctypes.create_unicode_buffer(512)
                user.SendMessageW(palette_items,0x0189,i,ctypes.addressof(label))  # LB_GETTEXT
                labels.append(label.value)
            user.PostMessageW(user.GetDlgItem(palette_window,1003),0x0100,0x1B,1)
            if labels.count("管理插件 · Moon Browser") != 1:
                raise RuntimeError(f"Expected one loaded plugin manager tab: {labels}")
            print("plugin_manager_entry=ok plugin_manager_tab_reuse=ok extension_admin_isolation=ok",flush=True)
        if history.exists():
            database = profile / "history.sqlite3"
            target = base + "/page/history-contract"

            def history_rows(query, params=()):
                if not database.is_file():
                    return []
                try:
                    with closing(sqlite3.connect(database, timeout=0.2)) as connection:
                        return connection.execute(query, params).fetchall()
                except sqlite3.OperationalError:
                    return []

            set_control(edit, target)
            user.PostMessageW(edit, 0x0100, 0x0D, 1)
            wait_for(lambda: history_rows("SELECT title FROM visits WHERE url=?", (target,)) == [("Moon fixture history-contract",)],
                     "Successful navigation and its title did not reach the history database")
            invoke("历史记录")
            wait_for(lambda: read_address() == "extension://moon.history/history.html",
                     "The history executable did not open its bundled page")
            config = profile / f'extension-{sha256(b"moon.history-fixture").hexdigest()}.json'
            set_control(edit, "extension://moon.history-fixture/history.html")
            user.PostMessageW(edit, 0x0100, 0x0D, 1)
            result = wait_for(lambda: config.exists() and json.loads(config.read_text(encoding="utf-8")),
                              "History page API did not complete search and record removal", 15)
            if not result.get("passed"):
                raise RuntimeError("History contract failed: " + result.get("error", "Unknown error"))
            if history_rows("SELECT title FROM visits WHERE url=?", (target,)):
                raise RuntimeError("Removing a history record did not persist its deletion")
            if history_rows("SELECT count(*) FROM visits") != [(0,)]:
                raise RuntimeError("Clearing history left visits in the database")
            print("history_system_plugin=ok history_page_contract=ok", flush=True)
        if blocker.exists():
            invoke("管理网页过滤")
            wait_for(lambda: read_address() == "extension://moon.filter-settings-fixture/filter.html",
                     "The filter system executable did not open its page")
            config = profile / f'extension-{sha256(b"moon.filter-settings-fixture").hexdigest()}.json'
            wait_for(lambda: config.exists() and json.loads(config.read_text(encoding="utf-8")).get("pausedSites") == ["127.0.0.1"],
                     "The filter page did not save the site exception")
            set_control(edit, base + "/page/filter-allowed")
            user.PostMessageW(edit, 0x0100, 0x0D, 1)
            if not Fixture.seen_allowed_request.wait(12):
                raise RuntimeError("The new site exception did not resume requests")
            print("filter_site_exception=ok", flush=True)
        if bookmarks.exists():
            if blocker.exists():
                wait_for(lambda: history_rows("SELECT title FROM visits WHERE url=?",(base + "/page/filter-allowed",)),
                         "The allowed-site fixture had not finished navigating")
            target = base + "/page/bookmark-contract"
            set_control(edit,target)
            user.PostMessageW(edit,0x0100,0x0D,1)
            try:
                wait_for(lambda: ("Moon fixture bookmark-contract",) in history_rows("SELECT title FROM visits WHERE url=?",(target,)),
                         "Bookmark fixture never finished loading")
            except RuntimeError as error:
                raise RuntimeError(f"{error}. Address: {read_address()}. "
                                   f"Recent visits: {history_rows('SELECT title,url FROM visits ORDER BY id DESC LIMIT 3')}") from error
            invoke("将当前页加入书签")
            notice = wait_for(lambda: owned_window("#32770","书签"),"Bookmark save feedback did not open")
            wait_for(lambda: not user.IsWindow(notice),"Bookmark feedback did not dismiss itself")
            invoke("管理书签")
            wait_for(lambda: read_address() == "extension://moon.bookmarks/bookmarks.html",
                     "The bookmark system executable did not open its page")
            set_control(edit,"extension://moon.bookmark-fixture/bookmarks.html")
            user.PostMessageW(edit,0x0100,0x0D,1)

            def pick_bookmark_file(title, selected):
                dialog = wait_for(lambda: owned_window("#32770",title),f"The {title} dialog did not open")
                if selected is None:
                    user.PostMessageW(dialog,0x0111,2,0)  # IDCANCEL
                else:
                    field = user.GetDlgItem(dialog,0x0480)  # edt1
                    if not field:
                        combo = user.GetDlgItem(dialog,0x047C)  # cmb13
                        field = user.SendMessageW(combo,0x0407,0,0) if combo else None  # CBEM_GETEDITCONTROL
                    if not field:
                        callback = ctypes.WINFUNCTYPE(wt.BOOL,wt.HWND,wt.LPARAM)
                        user.EnumChildWindows.argtypes = [wt.HWND,callback,wt.LPARAM]
                        user.GetClassNameW.argtypes = [wt.HWND,wt.LPWSTR,ctypes.c_int]
                        user.GetDlgCtrlID.argtypes = [wt.HWND]

                        @callback
                        def find_filename(child,_):
                            nonlocal field
                            kind = ctypes.create_unicode_buffer(64)
                            user.GetClassNameW(child,kind,len(kind))
                            if kind.value=="Edit" and user.GetDlgCtrlID(child)==1001:
                                field = child
                                return False
                            return True

                        user.EnumChildWindows(dialog,find_filename,0)
                    if not field:
                        raise RuntimeError("The bookmark file chooser's filename edit is unavailable")
                    set_control(field,str(selected))
                    if read_control(field)!=str(selected):
                        raise RuntimeError("The bookmark file chooser did not accept the test path")
                    user.PostMessageW(dialog,0x0111,1,0)  # IDOK
                wait_for(lambda: not user.IsWindow(dialog),f"The {title} dialog did not close")

            if bookmark_transfer:
                page_export = profile / "书签页导出.html"
                pick_bookmark_file("导出 HTML 书签",page_export)
            library_result("moon.bookmark-fixture")
            with closing(sqlite3.connect(profile / "bookmarks.sqlite3")) as db:
                row = db.execute("SELECT title,url,folder FROM bookmarks").fetchall()
            if row != [("编辑后的书签",target,"测试文件夹")]:
                raise RuntimeError(f"Bookmark save or edit was not persisted: {row}")
            print("bookmark_system_plugin=ok native_bookmark_toast=ok bookmark_edit=ok",flush=True)
            if bookmark_transfer:
                if "编辑后的书签" not in page_export.read_text(encoding="utf-8"):
                    raise RuntimeError("Exporting from the bookmark page did not write its bookmark")
                imported = profile / "导入书签.html"
                exported = profile / "迁移结果.html"
                invalid = profile / "非书签文件.html"
                invalid.write_text('<a href="https://invalid-file.invalid/">not a bookmark file</a>',encoding="utf-8")
                unicode_url = "https://search-example.invalid/?a=1&b=2"
                nested_url = "https://folder-example.invalid/page"
                root_url = "https://root-example.invalid/"
                imported.write_text(
                    '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<!-- <A HREF="https://comment.invalid/">ignored</A> -->\n'
                    '<DL><p><DT><H3 PERSONAL_TOOLBAR_FOLDER="true">收藏 &amp; 工具</H3><DL><p>'
                    f'<DT><A HREF="{target}">A duplicate must keep the original</A>'
                    '<DT><A ADD_DATE="42" HREF=\'https://search-example.invalid/?a=1&amp;b=2\' '
                    'ICON="data:image/png;base64,eA==">中文 &#x6708; &quot;书签&quot;</A>'
                    '<DT><H3>子目录</H3><DL><p>'
                    '<DT><A HREF=https://folder-example.invalid/page>Nested &lt;title&gt;</A>'
                    '<DT><A HREF="file:///C:/ignored.html">Unsupported file URL</A>'
                    '</DL><p></DL><p>'
                    '<DT><A HREF="https://root-example.invalid/">Root</A>'
                    '<script>const text=\'<A HREF="https://script.invalid/">ignored</A>\';</script>'
                    '</DL><p>',encoding="utf-8-sig")

                def read_bookmarks():
                    with closing(sqlite3.connect(profile / "bookmarks.sqlite3")) as db:
                        return set(db.execute("SELECT title,url,folder FROM bookmarks"))

                def import_bookmarks(path, *, feedback=True):
                    invoke("导入 HTML 书签")
                    pick_bookmark_file("导入 HTML 书签",path)
                    if feedback:
                        result = wait_for(lambda: owned_window("#32770","书签"),"The bookmark import did not report a result")
                        wait_for(lambda: not user.IsWindow(result),"The bookmark transfer feedback did not close")

                expected_rows = set(row) | {
                    ('中文 月 "书签"',unicode_url,"收藏 & 工具"),
                    ("Nested <title>",nested_url,"收藏 & 工具 / 子目录"),
                    ("Root",root_url,""),
                }
                import_bookmarks(imported)
                if read_bookmarks()!=expected_rows:
                    raise RuntimeError("Import changed an existing bookmark, imported unsupported content or lost a folder")
                import_bookmarks(invalid)
                if read_bookmarks()!=expected_rows:
                    raise RuntimeError("Importing invalid HTML changed the bookmark database")
                invoke("导出 HTML 书签")
                pick_bookmark_file("导出 HTML 书签",exported)
                wait_for(exported.is_file,"The exported HTML was not saved")
                result = wait_for(lambda: owned_window("#32770","书签"),"Bookmark export did not report completion")
                wait_for(lambda: not user.IsWindow(result),"The bookmark export feedback did not close")
                text = exported.read_text(encoding="utf-8")
                if ('<!DOCTYPE NETSCAPE-Bookmark-file-1>' not in text
                        or '<H3>收藏 &amp; 工具</H3>' not in text or '<H3>子目录</H3>' not in text
                        or 'HREF="https://search-example.invalid/?a=1&amp;b=2"' not in text):
                    raise RuntimeError("Export dropped folder structure or failed to escape HTML")
                with closing(sqlite3.connect(profile / "bookmarks.sqlite3")) as db, db:
                    db.execute("DELETE FROM bookmarks WHERE url=?",(nested_url,))
                import_bookmarks(exported)
                if read_bookmarks()!=expected_rows:
                    raise RuntimeError("The exported file did not round-trip with its original bookmark and folder")
                import_bookmarks(None,feedback=False)
                if read_bookmarks()!=expected_rows:
                    raise RuntimeError("Cancelling the file chooser changed bookmarks")
                print("bookmark_transfer=ok native_open_and_save=ok dedup=ok nested_folders=ok unicode_path=ok round_trip=ok cancel=ok",flush=True)
        if downloads.exists():
            set_control(edit,base + "/slow-download")
            user.PostMessageW(edit,0x0100,0x0D,1)
            dialog = wait_for(lambda: owned_window("#32770","保存下载"),"The real save dialog did not open")
            filename = ctypes.create_unicode_buffer(str(profile / "slow-test.bin"))
            user.SendMessageW(dialog,0x0468,0x0480,ctypes.addressof(filename))  # CDM_SETCONTROLTEXT / edt1
            user.PostMessageW(dialog,0x0111,1,0)  # IDOK
            wait_for(lambda: not user.IsWindow(dialog),"Saving the download did not close the dialog")
            downloads_db = profile / "downloads.sqlite3"
            saved_download = profile / "completed-proof.txt"
            if has_bulk_clear:
                saved_download.write_bytes(b"completed download fixture")
                with closing(sqlite3.connect(downloads_db)) as db, db:
                    db.execute("INSERT INTO downloads(path,state,started,owner_pid,owner_birth) VALUES (?,2,1,0,0)",
                               (str(saved_download),))
                    db.execute("INSERT INTO downloads(path,state,started,owner_pid,owner_birth) VALUES ('failed-proof.txt',3,1,0,0)")
            invoke("查看下载")
            wait_for(lambda: read_address() == "extension://moon.downloads/downloads.html",
                     "The download system executable did not open its page")
            set_control(edit,"extension://moon.download-fixture/downloads.html")
            user.PostMessageW(edit,0x0100,0x0D,1)
            library_result("moon.download-fixture")
            with closing(sqlite3.connect(downloads_db)) as db:
                row = db.execute("SELECT state,received FROM downloads WHERE state=4 ORDER BY id DESC LIMIT 1").fetchone()
                states = db.execute("SELECT state FROM downloads ORDER BY state").fetchall()
            if not row or row[0] != 4 or not 0 < row[1] < 8 * 64 * 1024:
                raise RuntimeError(f"Download cancellation and progress were not recorded: {row}")
            if has_bulk_clear:
                if states != [(3,),(4,)] or saved_download.read_bytes() != b"completed download fixture":
                    raise RuntimeError(f"Clearing completed downloads changed a file or other record: {states}")
                print("download_bulk_clear=ok search_scope=ok file_retained=ok active_transfer_retained=ok clear_cancel=ok",flush=True)
            print("download_system_plugin=ok download_live_progress=ok download_cancel=ok",flush=True)
        if site_data.exists():
            target = base + "/page/site-data-contract"
            set_control(edit,target)
            user.PostMessageW(edit,0x0100,0x0D,1)
            wait_for(lambda: ("Moon fixture site-data-contract",) in history_rows("SELECT title FROM visits WHERE url=?",(target,)),
                     "Site data fixture did not finish loading")
            has_catalog = 'data-group="indexedDB"' in (site_data.parent / "site-data.html").read_text(encoding="utf-8")
            if has_catalog:
                if not Fixture.site_data_catalog_ready.wait(8):
                    raise RuntimeError("The IndexedDB and Cache Storage fixture was not seeded")
            invoke("查看当前站点数据")
            wait_for(lambda: read_address() == "extension://moon.site-data/site-data.html",
                     "The bundled site data plugin did not open its page")
            invoke("Moon fixture site-data-contract")
            wait_for(lambda: read_address() == target,"The original site data source could not be selected")
            invoke("运行站点数据验收")
            wait_for(lambda: read_address() == "extension://moon.site-data-fixture/site-data.html",
                     "The site data contract did not bind its page")
            config = profile / f'extension-{sha256(b"moon.site-data-fixture").hexdigest()}.json'
            phase = wait_for(lambda: read_settings(config),
                             "The site data contract did not start the conflict test",15)
            if not phase.get("waitingForConflict"):
                raise RuntimeError(f"Site data edits: {phase}")
            Fixture.change_site_data_entry.set()
            if not Fixture.site_data_entry_changed.wait(8):
                raise RuntimeError("The source page did not change its own stored value")
            signal = config.with_suffix(".signal")
            signal.write_text('{"conflictReady":true}',encoding="utf-8")
            signal.replace(config)
            phase = wait_for(lambda: (current := read_settings(config)) and
                             (current.get("ready") or current.get("error")) and current,
                             "The site data contract reported no initial result",15)
            if not phase.get("ready"):
                raise RuntimeError(f"Site data fixture: {phase}")
            Fixture.change_site_data_source.set()
            result = wait_for(lambda: (current := read_settings(config)) and not current.get("ready") and current,
                              "The site data contract reported no navigation result",15)
            if not result.get("passed"):
                raise RuntimeError(f"Site data invalidation: {result}")
            if has_catalog:
                print("site_catalog=ok indexeddb_version=ok cache_limit=ok isolated_apis=ok catalog_search=ok stale_catalog=ok",flush=True)
            print("site_data_system_plugin=ok isolated_storage=ok storage_edit=ok storage_remove=ok stale_write_rejected=ok conflict_preserved=ok site_data_navigation_cleanup=ok",flush=True)
        if page_source.exists():
            target = base + "/page/source-contract"
            set_control(edit,target)
            user.PostMessageW(edit,0x0100,0x0D,1)
            wait_for(lambda: ("Moon fixture source-contract",) in history_rows("SELECT title FROM visits WHERE url=?",(target,)),
                     "Page source fixture did not finish loading")
            invoke("查看网页源代码")
            wait_for(lambda: read_address() == "extension://moon.source/source.html",
                     "The bundled page source plugin did not open its page")
            invoke("新建标签页")
            wait_for(lambda: user.IsWindowVisible(home),"Could not open the isolated source panel in a new tab")
            set_control(edit,"extension://moon.source-fixture/source.html")
            user.PostMessageW(edit,0x0100,0x0D,1)
            config = profile / f'extension-{sha256(b"moon.source-fixture").hexdigest()}.json'
            isolated = wait_for(lambda: read_settings(config),
                                "Source owner check did not report")
            if not isolated.get("isolated"):
                raise RuntimeError(f"Source owner check: {isolated}")
            invoke("Moon fixture source-contract")
            wait_for(lambda: read_address() == target,"Could not select the page source fixture")
            invoke("运行网页源代码验收")
            ready = wait_for(lambda: (current := read_settings(config)) and
                             (current.get("ready") or current.get("error")) and current,
                             "The source viewer did not display the snapshot",15)
            if not ready.get("ready") or Fixture.page_source_requests != 1:
                raise RuntimeError(f"Page source fixture: {ready}, network requests: {Fixture.page_source_requests}")
            invoke("页内查找")
            find = wait_for(lambda: user.FindWindowExW(frame,None,"MoonFind",None),
                            "The source panel did not open the native find bar")
            search = user.GetDlgItem(find,1201)
            set_control(search,"源码雪月")
            wait_for(lambda: read_control(user.GetDlgItem(find,1202)) == "1 项匹配",
                     "The native find bar could not find the original source comment")
            user.PostMessageW(search,0x0100,0x1B,1)
            wait_for(lambda: not user.IsWindowVisible(find),"The source find bar did not close")
            Fixture.change_page_source.set()
            result = wait_for(lambda: (current := read_settings(config)) and
                              (current.get("passed") or current.get("error")) and current,
                              "The source viewer did not clear stale contents",15)
            if not result.get("passed"):
                raise RuntimeError(f"Page source invalidation: {result}")
            print("page_source_plugin=ok page_source_original=ok utf8_truncation=ok owner_isolation=ok no_refetch=ok source_find=ok stale_source=ok",flush=True)
        if popups.exists():
            user.ChildWindowFromPointEx.argtypes = [wt.HWND,wt.POINT,wt.UINT]
            user.ChildWindowFromPointEx.restype = wt.HWND
            user.MapWindowPoints.argtypes = [wt.HWND,wt.HWND,ctypes.POINTER(wt.POINT),wt.UINT]

            def popup_click(x,y):
                point = wt.POINT(x,y)
                view = content
                while (child := user.ChildWindowFromPointEx(view,point,1)) and child != view:
                    user.MapWindowPoints(view,child,ctypes.byref(point),1)
                    view = child
                coords = point.y << 16 | point.x
                user.PostMessageW(view,0x0201,1,coords)
                user.PostMessageW(view,0x0202,0,coords)

            def popup_loaded(stage, origin):
                wait_for(lambda: stage in Fixture.popup_destinations,
                         f"The {stage} popup did not reach its target")
                destination = origin + "/popup-target/" + stage
                wait_for(lambda: history_rows("SELECT id FROM visits WHERE url=?",(destination,)),
                         f"The {stage} popup never finished loading")

            target = base + "/page/popup-default"
            set_control(edit,target)
            user.PostMessageW(edit,0x0100,0x0D,1)
            wait_for(lambda: "default" in Fixture.popup_attempts,"Automatic popup fixture did not run")
            invoke("管理网站弹窗")
            wait_for(lambda: read_address() == "extension://moon.popups/popups.html",
                     "The website popup settings did not open")
            if "default" in Fixture.popup_destinations:
                raise RuntimeError("An unsolicited popup opened under the default rule")
            panel = wt.RECT()
            user.GetClientRect(content,ctypes.byref(panel))
            # Click the bound notice action in the bundled page at the fixed smoke viewport size.
            sleep(0.45)
            popup_click(panel.right-px(88),px(245))
            confirm = wait_for(lambda: owned_window("#32770","打开一次弹窗？"),
                               "The blocked popup did not offer a one-time confirmation")
            user.SendMessageW(confirm,0x0111,6,0)  # IDYES
            popup_loaded("default",base)

            target = base + "/page/popup-click"
            set_control(edit,target)
            user.PostMessageW(edit,0x0100,0x0D,1)
            wait_for(lambda: history_rows("SELECT id FROM visits WHERE url=?",(target,)),
                     "User-initiated popup fixture did not load")
            popup_click(px(30),px(20))
            popup_loaded("click",base)

            def configure_popups(origin, mode, *, confirm=None, expected="saved"):
                path = profile / f'extension-{sha256(b"moon.history-fixture").hexdigest()}.json'
                pending = path.with_suffix(".popup-signal")
                pending.write_text(json.dumps({"popupOrigin":origin,"popupMode":mode}),encoding="utf-8")
                pending.replace(path)
                set_control(edit,"extension://moon.history-fixture/history.html")
                user.PostMessageW(edit,0x0100,0x0D,1)
                if confirm is not None:
                    try:
                        question = wait_for(lambda: owned_window("#32770","允许网站弹窗？"),
                                            "Adding an allow exception did not prompt for confirmation")
                    except RuntimeError as error:
                        raise RuntimeError(f"{error}: address={read_address()}, fixture={read_settings(path)}") from error
                    user.SendMessageW(question,0x0111,confirm,0)
                result = wait_for(lambda: read_settings(path).get("popupResult"),"Popup rule request did not complete")
                if result != expected:
                    raise RuntimeError(f"Popup rule result was {result!r}, expected {expected!r}")

            allow_origin = base.replace("127.0.0.1","localhost")
            configure_popups(allow_origin,"allow",confirm=7,expected="CANCELLED")
            configure_popups(allow_origin,"allow",confirm=6)
            target = allow_origin + "/page/popup-allow"
            set_control(edit,target)
            user.PostMessageW(edit,0x0100,0x0D,1)
            popup_loaded("allow",allow_origin)
            for stage, mode in (("click-blocked","block"),("click-reset","automatic")):
                configure_popups(base,mode)
                target = base + "/page/popup-" + stage
                set_control(edit,target)
                user.PostMessageW(edit,0x0100,0x0D,1)
                wait_for(lambda: history_rows("SELECT id FROM visits WHERE url=?",(target,)),
                         "Popup rule link fixture did not load")
                popup_click(px(30),px(20))
                wait_for(lambda: stage in Fixture.popup_attempts,"Popup link did not receive a click")
                if mode == "block":
                    sleep(0.35)
                    if stage in Fixture.popup_destinations:
                        raise RuntimeError("Explicit block rule allowed a clicked link")
                else:
                    popup_loaded(stage,base)
            rules = json.loads((profile / "popup-rules.json").read_text(encoding="utf-8"))
            if rules != [{"origin":allow_origin,"mode":"allow"}]:
                raise RuntimeError(f"Unexpected persisted popup rules: {rules}")
            print("popup_policy=ok default_block=ok open_once=ok user_clicked_link=ok saved_origin_exception=ok block_and_reset=ok allow_confirmation=ok",flush=True)
        if reading.exists():
            def navigate_reading(url):
                set_control(edit,url)
                user.PostMessageW(edit,0x0100,0x0D,1)
                wait_for(lambda: history_rows("SELECT id FROM visits WHERE url=?",(url,)),
                         f"Reading fixture did not finish loading: {url}",15)

            def find_bar():
                found = user.FindWindowExW(frame,None,"MoonFind",None)
                return found if found and user.IsWindowVisible(found) else None

            def viewport(page):
                return Fixture.reading_layout.get(page,(0,0))

            target = base + "/page/reading-contract"
            navigate_reading(target)
            normal_width = wait_for(lambda: viewport("reading-contract")[0],"Reading viewport was not reported")

            class MonitorInfo(ctypes.Structure):
                _fields_ = [("size", wt.DWORD), ("monitor", wt.RECT),
                            ("work", wt.RECT), ("flags", wt.DWORD)]

            def rect_tuple(rect):
                return rect.left, rect.top, rect.right, rect.bottom

            def outer_rect(window):
                rect = wt.RECT()
                if not user.GetWindowRect(window, ctypes.byref(rect)):
                    raise RuntimeError("Could not read the test window bounds")
                return rect_tuple(rect)

            def fullscreen_covers_monitor():
                return (not user.IsWindowVisible(edit)
                        and outer_rect(frame) == full_bounds and outer_rect(content) == full_bounds
                        and viewport("reading-contract")[0] > normal_width)

            original_bounds = outer_rect(frame)
            monitor = MonitorInfo(ctypes.sizeof(MonitorInfo))
            if not user.GetMonitorInfoW(user.MonitorFromWindow(frame,2), ctypes.byref(monitor)):
                raise RuntimeError("Could not read bounds of the browser monitor")
            full_bounds = rect_tuple(monitor.monitor)
            user.PostMessageW(edit,0x0100,0x7A,1)  # F11
            wait_for(fullscreen_covers_monitor,"F11 did not fill the monitor with the actual WebKit viewport")
            user.PostMessageW(frame,0x0100,0x7A,1|(1<<30))
            sleep(0.35)
            if not fullscreen_covers_monitor():
                raise RuntimeError("A held F11 toggled fullscreen again")
            exit_button = user.GetDlgItem(frame,1005)
            if not user.IsWindowVisible(exit_button):
                raise RuntimeError("The native fullscreen exit button did not appear")
            user.SendMessageW(exit_button,0x00F5,0,0)  # BM_CLICK
            wait_for(lambda: user.IsWindowVisible(edit) and outer_rect(frame)==original_bounds,
                     "The fullscreen exit button did not restore the normal window")

            invoke("切换浏览器全屏")
            wait_for(fullscreen_covers_monitor,"The reading plugin command did not toggle fullscreen")
            user.PostMessageW(frame,0x0100,0x1B,1)  # Escape
            wait_for(lambda: user.IsWindowVisible(edit) and outer_rect(frame)==original_bounds,
                     "Escape did not restore the normal window")

            user.ShowWindow(frame,3)  # SW_MAXIMIZE
            wait_for(lambda: user.IsZoomed(frame),"Could not maximize the browser before F11")
            maximized_bounds = outer_rect(frame)
            user.PostMessageW(edit,0x0100,0x7A,1)
            wait_for(fullscreen_covers_monitor,"F11 did not cover the taskbar from a maximized window")
            user.PostMessageW(frame,0x0100,0x7A,1)
            wait_for(lambda: user.IsZoomed(frame) and user.IsWindowVisible(edit) and outer_rect(frame)==maximized_bounds,
                     "F11 did not restore the maximized window")
            user.ShowWindow(frame,9)  # SW_RESTORE
            wait_for(lambda: outer_rect(frame)==original_bounds and viewport("reading-contract")[0]==normal_width,
                     "Restoring after fullscreen did not recover the earlier window and viewport size")
            print("fullscreen_system_plugin=ok monitor_coverage=ok repeat_suppression=ok mouse_escape_f11=ok placement_restored=ok",flush=True)

            invoke("页内查找")
            bar = wait_for(find_bar,"The reading plugin did not open the find bar")
            search = user.GetDlgItem(bar,1201)
            matches = user.GetDlgItem(bar,1202)
            set_control(search,"没有这个词")
            wait_for(lambda: read_control(matches) == "无匹配","Find did not report zero matches")
            set_control(search,"月亮查找词")
            wait_for(lambda: read_control(matches) == "2 项匹配","WebKit did not return two Chinese matches")
            initial_offset = wait_for(lambda: viewport("reading-contract")[1],"Find did not scroll to a match")
            user.PostMessageW(search,0x0100,0x0D,1)  # Enter
            wait_for(lambda: abs(viewport("reading-contract")[1]-initial_offset)>700,
                     "Enter did not move to the other occurrence")
            user.SendMessageW(user.GetDlgItem(bar,1203),0x00F5,0,0)  # BM_CLICK
            wait_for(lambda: abs(viewport("reading-contract")[1]-initial_offset)<100,
                     "Previous did not return to the first occurrence")
            user.PostMessageW(search,0x0100,0x1B,1)  # Escape
            wait_for(lambda: not find_bar(),"Escape did not close the find bar")

            invoke("放大页面")
            wait_for(lambda: 0 < viewport("reading-contract")[0] < normal_width*0.94,
                     "Zoom did not reflow the webpage")
            wait_for(lambda: owned_window("#32770","查找与缩放"),"Zoom did not report its result")
            with closing(sqlite3.connect(profile / "page-zoom.sqlite3")) as db:
                if db.execute("SELECT origin,percent FROM zoom").fetchall() != [(base,110)]:
                    raise RuntimeError("Zoom did not store the active site's 110% setting")

            invoke("页内查找")
            wait_for(find_bar,"The find bar did not reopen")
            invoke("新建标签页")
            wait_for(lambda: not find_bar() and user.IsWindowVisible(home),"Find bar leaked across tabs")
            other_origin = base.replace("127.0.0.1","localhost") + "/page/reading-other-origin"
            navigate_reading(other_origin)
            wait_for(lambda: viewport("reading-other-origin")[0] == normal_width,
                     "Zoom preference leaked to another origin")

            user.PostMessageW(frame,0x0010,0,0)
            if proc.wait(8) != 0:
                raise RuntimeError("Browser failed to shut down before reading preference check")
            frame = None
            persisted = base + "/page/reading-restart"
            proc = subprocess.Popen([str(exe),"--gdi",persisted],env=preview_env(root))
            frame = browser_frame(proc)
            edit = user.GetDlgItem(frame,1001)
            home = user.GetDlgItem(frame,1002)
            content = user.FindWindowExW(frame,None,"MoonContent",None)
            user.SetWindowPos(frame,None,0,0,840,590,0x0016)
            wait_for(lambda: history_rows("SELECT id FROM visits WHERE url=?",(persisted,)),
                     "The reading preference restart fixture did not finish loading",15)
            wait_for(lambda: 0 < viewport("reading-restart")[0] < normal_width*0.94,
                     "Persistent site zoom was not restored after restarting the browser")
            invoke("重置页面缩放")
            wait_for(lambda: viewport("reading-restart")[0] == normal_width,
                     "Reset did not restore the default webpage layout")
            with closing(sqlite3.connect(profile / "page-zoom.sqlite3")) as db:
                if db.execute("SELECT origin FROM zoom").fetchall():
                    raise RuntimeError("Reset left a stored non-default zoom preference")
            print("reading_plugin=ok native_unicode_find=ok find_tab_scope=ok site_zoom_restart=ok",flush=True)
        if recent.exists():
            def closed_page(name):
                address = base + "/page/" + name
                previous = Fixture.closed_loaded.get(name,0)
                set_control(edit,address)
                user.PostMessageW(edit,0x0100,0x0D,1)
                wait_for(lambda: Fixture.closed_loaded.get(name,0)>previous,f"{name} did not finish loading",15)
                wait_for(lambda: history_rows("SELECT id FROM visits WHERE url=?",(address,)),
                         f"{name} did not commit")
                return address

            def close_first():
                click(px(251),px(150))
                wait_for(lambda: user.IsWindowVisible(home),"Closing the only tab did not return to home")

            before = closed_page("closed-first")
            after = closed_page("closed-second")
            close_first()
            previous = Fixture.closed_loaded.get("closed-second",0)
            invoke("恢复上一个关闭的标签")
            wait_for(lambda: Fixture.closed_loaded.get("closed-second",0)>previous,
                     "The restore command did not load the latest closed tab",15)
            back_count = Fixture.closed_loaded.get("closed-first",0)
            click(px(285),px(24))
            wait_for(lambda: read_address()==before and Fixture.closed_loaded.get("closed-first",0)>back_count,
                     "Restored tab lost its Back entry")
            click(px(319),px(24))
            wait_for(lambda: read_address()==after and Fixture.closed_loaded.get("closed-second",0)>previous+1,
                     "Restored tab lost its Forward entry")
            wait_for(lambda: len(history_rows("SELECT id FROM visits WHERE url=?",(after,)))>=2,
                     "The restored forward page did not finish")
            close_first()
            closed_page("closed-item")
            close_first()
            closed_page("closed-protected")
            web_view = visible_page_view()
            if not web_view:
                raise RuntimeError("Missing WebKit view for protected input exercise")
            user.PostMessageW(web_view,0x0102,ord('x'),1)  # WM_CHAR delivered to the protected page
            close_first()

            set_control(edit,base + "/page/closed-post")
            user.PostMessageW(edit,0x0100,0x0D,1)
            wait_for(lambda: history_rows("SELECT id FROM visits WHERE url=?",(base + "/closed-submit",)),
                     "The non-GET fixture did not finish")
            close_first()

            invoke("最近关闭的标签")
            wait_for(lambda: read_address()=="extension://moon.recent-tabs/recent.html",
                     "The bundled recent tabs plugin did not open its page")
            restore_count = Fixture.closed_loaded.get("closed-second",0)
            set_control(edit,"extension://moon.closed-fixture/recent.html")
            user.PostMessageW(edit,0x0100,0x0D,1)
            library_result("moon.closed-fixture")
            wait_for(lambda: read_address()==after and Fixture.closed_loaded.get("closed-second",0)>restore_count,
                     "Restoring a selected entry did not reopen the actual webpage")
            print("recent_tabs_plugin=ok back_forward=ok protected_input=ok non_get=ok targeted_reopen=ok clear_confirmation=ok",flush=True)
        if privacy.exists():
            def visit_privacy(stage):
                set_control(edit,base + "/page/" + stage)
                user.PostMessageW(edit,0x0100,0x0D,1)
                result = wait_for(lambda: Fixture.privacy_reports.get(stage),f"{stage} did not report data",18)
                if result.get("error"):
                    raise RuntimeError(f"{stage}: {result}")
                return result

            def privacy_prompt(button):
                popup = wait_for(lambda: owned_window("#32770","清除浏览数据？"),
                                 "The privacy plugin did not display the host confirmation")
                user.PostMessageW(popup,0x0111,button,0)
                wait_for(lambda: not user.IsWindow(popup),"Privacy confirmation did not close")

            def count_rows(filename,table):
                with closing(sqlite3.connect(profile / filename)) as db:
                    return db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]

            def check_site(report,present,worker):
                flag = str(present).lower()
                if any(report.get(key)!=flag for key in ("local","idb","domCache")):
                    raise RuntimeError(f"Wrong persistent site storage: {report}")
                if worker and report.get("worker")!=flag:
                    raise RuntimeError(f"Wrong Service Worker registration: {report}")
                if any((key + "=present" in report["cookies"])!=present
                       for key in ("moon-privacy-visible","moon-privacy-http")):
                    raise RuntimeError(f"Wrong HTTP or HttpOnly cookie storage: {report}")

            seeded = visit_privacy("privacy-seed")
            worker = seeded.get("worker")=="true"
            check_site(seeded,True,worker)
            warm = Fixture.privacy_asset_requests
            check_site(visit_privacy("privacy-warm"),True,worker)
            if Fixture.privacy_asset_requests != warm:
                raise RuntimeError("The HTTP cache fixture was not reused before clearing")

            saved_bookmarks = count_rows("bookmarks.sqlite3","bookmarks")
            saved_downloads = count_rows("downloads.sqlite3","downloads")
            session_checkpoint = profile / "last-session.json"
            if session_plugin.exists():
                session_checkpoint.write_text(json.dumps({"version":1,"tabs":[{"url":base,"title":"Previous session"}],"selected":0}),
                                              encoding="utf-8")
            invoke("清除浏览数据")
            wait_for(lambda: read_address()=="extension://moon.privacy/privacy.html",
                     "The bundled privacy plugin did not open its page")
            set_control(edit,"extension://moon.privacy-cache-fixture/privacy.html")
            user.PostMessageW(edit,0x0100,0x0D,1)
            privacy_prompt(7)  # IDNO
            privacy_prompt(6)  # IDYES
            library_result("moon.privacy-cache-fixture")
            if not history_rows("SELECT id FROM visits WHERE url=?",(base + "/page/privacy-seed",)):
                raise RuntimeError("Cache-only clearing removed history")
            if session_plugin.exists() and not json.loads(session_checkpoint.read_text(encoding="utf-8"))["tabs"]:
                raise RuntimeError("Cache-only clearing removed the previous session")
            check_site(visit_privacy("privacy-after-cache"),True,worker)
            if Fixture.privacy_asset_requests != warm + 1:
                raise RuntimeError("Clearing the resource cache did not refetch the cached response")

            set_control(edit,"extension://moon.privacy-data-fixture/privacy.html")
            user.PostMessageW(edit,0x0100,0x0D,1)
            privacy_prompt(6)  # IDYES
            library_result("moon.privacy-data-fixture")
            if history_rows("SELECT COUNT(*) FROM visits") != [(0,)]:
                raise RuntimeError("Selected browsing history was not cleared")
            if session_plugin.exists() and json.loads(session_checkpoint.read_text(encoding="utf-8"))["tabs"]:
                raise RuntimeError("Privacy history clearing did not forget the previous session")
            check_site(visit_privacy("privacy-after-data"),False,worker)
            if count_rows("bookmarks.sqlite3","bookmarks") != saved_bookmarks or \
                    count_rows("downloads.sqlite3","downloads") != saved_downloads:
                raise RuntimeError("Privacy clearing modified the bookmark or download library")
            print(f"privacy_plugin=ok native_cancel=ok scoped_clear=ok http_cache=ok http_only=ok "
                  f"private_site_storage=ok service_worker={'ok' if worker else 'unavailable'}",flush=True)
        if task_manager.exists():
            target = closed_page("task-eligible")
            invoke("新建标签页")
            wait_for(lambda: user.IsWindowVisible(home),"Could not create the protected task tab")
            closed_page("task-protected")
            protected_view = visible_page_view()
            if not protected_view:
                raise RuntimeError("The protected task's WebKit window was unavailable")
            user.PostMessageW(protected_view,0x0102,ord('x'),1)
            for _ in range(24):
                click(px(251),px(104))
            wait_for(lambda: user.IsWindowVisible(home),"Could not create blank tabs for task pagination")
            client = wt.RECT()
            user.GetClientRect(frame,ctypes.byref(client))
            click(px(70),client.bottom-px(26))
            wait_for(lambda: read_address()=="extension://moon.task-manager/tasks.html",
                     "Native diagnostics did not open the packaged task manager")
            initial = Fixture.closed_loaded.get("task-eligible",0)
            set_control(edit,"extension://moon.task-fixture/tasks.html")
            user.PostMessageW(edit,0x0100,0x0D,1)
            library_result("moon.task-fixture")
            wait_for(lambda: read_address()==target and Fixture.closed_loaded.get("task-eligible",0)>initial,
                     "A manually unloaded tab did not recover on switching back")
            report = profile / f'extension-{sha256(b"moon.task-fixture").hexdigest()}.json'
            shared = bool(json.loads(report.read_text(encoding="utf-8")).get("shared"))
            print(f"task_manager=ok unique_pid_accounting=ok paging=ok protected_discard=ok reload_on_focus=ok shared_pid={'observed' if shared else 'not_observed'}",flush=True)
        if commands.exists():
            config = profile / f'extension-{sha256(b"moon.command-fixture").hexdigest()}.json'
            address = "extension://moon.command-fixture/commands.html"
            modifiers = 6  # MOD_CONTROL | MOD_SHIFT

            def confirmation(button):
                def requested():
                    if config.exists():
                        result = json.loads(config.read_text(encoding="utf-8"))
                        if result.get("error"):
                            raise RuntimeError(result["error"])
                    return owned_window("#32770","注册全局快捷键？")
                popup = wait_for(requested,
                                 "Expected the global shortcut confirmation")
                user.SendMessageW(popup,0x0111,button,0)
                wait_for(lambda: not user.IsWindow(popup),"The hotkey confirmation did not close")

            def registration_phase(phase):
                result = wait_for(lambda: config.exists() and (state:=json.loads(config.read_text(encoding="utf-8"))) and
                                  (state.get("phase")==phase or state.get("error")) and state,
                                  f"The command fixture did not reach {phase}",15)
                if result.get("error"):
                    raise RuntimeError(result["error"])

            def native_entries(trigger=None, choose=None, before_choose=None, popup_at=None, owner_window=None):
                dimensions = wt.RECT()
                user.GetClientRect(frame,ctypes.byref(dimensions))
                if trigger:
                    trigger()
                else:
                    click(dimensions.right-px(159),px(24))
                def open_menu():
                    menu = None
                    while menu := user.FindWindowExW(None,menu,"#32768",None):
                        owner = wt.DWORD()
                        user.GetWindowThreadProcessId(menu,ctypes.byref(owner))
                        if owner.value==proc.pid and user.IsWindowVisible(menu):
                            return menu
                    return None
                popup = wait_for(open_menu,"The native main menu did not open")
                try:
                    if popup_at:
                        bounds = wt.RECT()
                        user.GetWindowRect(popup,ctypes.byref(bounds))
                        if abs(bounds.left-popup_at.x)>px(16) or abs(bounds.top-popup_at.y)>px(16):
                            raise RuntimeError(f"Site menu is not anchored to the address button: {bounds.left}, {bounds.top}")
                    handle = user.SendMessageW(popup,0x01E1,0,0)  # MN_GETHMENU
                    if user.GetMenuItemCount(handle)<1:
                        raise RuntimeError("Could not read the native main menu entries")

                    def entries(menu):
                        result = {}
                        for index in range(user.GetMenuItemCount(menu)):
                            label = ctypes.create_unicode_buffer(300)
                            user.GetMenuStringW(menu,index,label,len(label),0x400)  # MF_BYPOSITION
                            child = user.GetSubMenu(menu,index)
                            result[label.value] = entries(child) if child else {}
                        return result

                    result = entries(handle)
                    if choose:
                        menu_count = user.GetMenuItemCount(handle)
                        for position in range(menu_count):
                            label = ctypes.create_unicode_buffer(300)
                            user.GetMenuStringW(handle,position,label,len(label),0x400)
                            if label.value == choose:
                                break
                        else:
                            raise RuntimeError(f"Native menu entry {choose!r} was missing: {result}")
                        if before_choose:
                            before_choose()
                            if owner_window and not open_menu():
                                return result
                        for _ in range(menu_count):
                            user.SendMessageW(popup,0x0100,0x28,1)  # WM_KEYDOWN / VK_DOWN
                            if user.GetMenuState(handle,position,0x400)&0x80:  # MF_HILITE
                                break
                        else:
                            raise RuntimeError(f"Native menu entry {choose!r} could not be selected")
                        user.PostMessageW(popup,0x0100,0x0D,1)
                        wait_for(lambda: not open_menu(),"Selecting the native menu item did not dismiss the menu")
                    return result
                finally:
                    user.PostMessageW(owner_window or frame,0x001F,0,0)  # WM_CANCELMODE
                    wait_for(lambda: not open_menu(),"Main menu did not dismiss")

            if has_site_menu:
                target = base + "/page/site-menu-contract"
                moved = base + "/page/site-menu-after"
                set_control(edit,target)
                user.PostMessageW(edit,0x0100,0x0D,1)
                wait_for(lambda: history_rows("SELECT id FROM visits WHERE url=?",(target,)),"Site command fixture did not load")
                edit_bounds = wt.RECT()
                user.GetWindowRect(edit,ctypes.byref(edit_bounds))
                icon = wt.POINT(edit_bounds.left-px(16),edit_bounds.top+px(10))
                anchor = wt.POINT(edit_bounds.left-px(26),edit_bounds.bottom+px(3))
                user.ScreenToClient.argtypes = [wt.HWND,ctypes.POINTER(wt.POINT)]
                user.ScreenToClient(frame,ctypes.byref(icon))

                def click_site_menu():
                    click(icon.x,icon.y)

                # Text in the address control may have been edited without navigating.
                set_control(edit,"https://uncommitted.invalid/")
                site_entries = native_entries(trigger=click_site_menu,popup_at=anchor)
                expected_site = {base,"HTTP · 未加密","管理网站弹窗","查看当前站点数据","查看网页源代码\tCtrl+Shift+7",
                                 "打开网页控制台\tCtrl+Shift+J","显示 Moon 命令提示"}
                if not expected_site.issubset(site_entries) or "运行站点数据验收" in site_entries:
                    raise RuntimeError(f"Unexpected entries in the site menu: {site_entries}")

                def navigate_while_open():
                    Fixture.navigate_from_site_menu.set()
                    wait_for(lambda: history_rows("SELECT id FROM visits WHERE url=?",(moved,)),"The site did not navigate while its menu was open")

                native_entries(trigger=click_site_menu,choose="查看当前站点数据",before_choose=navigate_while_open)
                sleep(0.45)
                if read_address() == "extension://moon.site-data/site-data.html":
                    raise RuntimeError("A stale site menu command used the newly navigated page")
                native_entries(trigger=lambda: user.PostMessageW(edit,0x0104,ord('I'),0x20000001),choose="查看当前站点数据")
                try:
                    wait_for(lambda: read_address()=="extension://moon.site-data/site-data.html","The site menu did not execute the real site data plugin")
                except RuntimeError as error:
                    raise RuntimeError(f"{error}: {read_address()!r}") from error
                print("site_menu=ok address_anchor=ok committed_origin=ok contribution_grant=ok stale_navigation=ok keyboard=ok",flush=True)

            if has_web_link_menu and bookmarks.exists():
                def visit_link_fixture(path):
                    url = base + "/page/" + path
                    set_control(edit,url)
                    user.PostMessageW(edit,0x0100,0x0D,1)
                    wait_for(lambda: history_rows("SELECT id FROM visits WHERE url=?",(url,)),f"{path} did not load")
                    return url

                source = visit_link_fixture("link-menu-contract")
                target = base + "/page/link-menu-target"
                view = visible_page_view()

                def link_menu(y=18, choose=None, before_choose=None):
                    def right_click():
                        point = px(y)<<16 | px(30)
                        user.PostMessageW(view,0x0204,2,point)  # WM_RBUTTONDOWN / MK_RBUTTON
                        user.PostMessageW(view,0x0205,0,point)
                    return native_entries(trigger=right_click,choose=choose,before_choose=before_choose,owner_window=view)

                actions = {"在后台标签打开链接","复制链接地址","将链接加入书签"}
                menu_items = link_menu()
                if not actions.issubset(menu_items) or "未授权的书签链接命令" in menu_items:
                    raise RuntimeError(f"Unexpected link menu entries: {menu_items}")
                if actions & link_menu(y=54).keys():
                    raise RuntimeError("Plugins were offered for a non-HTTP link")

                def saved_link(url):
                    database = profile / "bookmarks.sqlite3"
                    if not database.is_file():
                        return None
                    try:
                        with closing(sqlite3.connect(database,timeout=.2)) as db:
                            return db.execute("SELECT title FROM bookmarks WHERE url=?",(url,)).fetchone()
                    except sqlite3.OperationalError:
                        return None

                link_menu(choose="将链接加入书签")
                wait_for(lambda: saved_link(target)==("本地链接验收",),"Right click did not save the selected href and label")
                if user.CountClipboardFormats()==0:
                    user.GetClipboardOwner.restype = wt.HWND
                    user.GetClipboardData.argtypes = [wt.UINT]
                    user.GetClipboardData.restype = wt.HANDLE
                    kernel = ctypes.WinDLL("kernel32",use_last_error=True)
                    kernel.GlobalLock.argtypes = [wt.HANDLE]
                    kernel.GlobalLock.restype = ctypes.c_void_p
                    kernel.GlobalUnlock.argtypes = [wt.HANDLE]

                    def copied_target():
                        if user.GetClipboardOwner()!=frame or not user.OpenClipboard(None):
                            return False
                        try:
                            data = user.GetClipboardData(13)  # CF_UNICODETEXT
                            pointer = kernel.GlobalLock(data) if data else None
                            if not pointer:
                                return False
                            try:
                                return ctypes.wstring_at(pointer)==target
                            finally:
                                kernel.GlobalUnlock(data)
                        finally:
                            user.CloseClipboard()

                    try:
                        link_menu(choose="复制链接地址")
                        wait_for(copied_target,"Right click did not copy the exact destination URL")
                        print("link_clipboard=ok",flush=True)
                    finally:
                        if user.GetClipboardOwner()==frame and user.OpenClipboard(None):
                            user.EmptyClipboard()
                            user.CloseClipboard()
                    sleep(0.3)
                link_menu(choose="在后台标签打开链接")
                sleep(0.55)
                if read_address()!=source or history_rows("SELECT id FROM visits WHERE url=?",(target,)):
                    raise RuntimeError("A background link changed the current page or loaded before selection")
                invoke("本地链接验收")
                wait_for(lambda: read_address()==target,"Selecting the background tab did not use the selected link")
                wait_for(lambda: history_rows("SELECT id FROM visits WHERE url=?",(target,)),"The background link did not load on selection")

                visit_link_fixture("link-menu-stale")
                view = visible_page_view()
                moved = base + "/page/link-menu-after"

                def change_link_source():
                    Fixture.navigate_from_link_menu.set()
                    wait_for(lambda: history_rows("SELECT id FROM visits WHERE url=?",(moved,)),"Link source did not navigate")

                link_menu(choose="将链接加入书签",before_choose=change_link_source)
                sleep(0.45)
                if saved_link(base + "/page/link-menu-stale-target"):
                    raise RuntimeError("A stale menu saved a link from an earlier document")
                print("link_menu=ok webkit_hit_test=ok bookmark_target=ok lazy_background=ok non_http=ok stale_navigation=ok",flush=True)

            groups = native_entries()
            if "管理插件" not in groups:
                raise RuntimeError("The native menu has no plugin management entry")
            expected = {
                "标签与页面": {"页内查找\tCtrl+F","放大页面\tCtrl++","切换浏览器全屏\tF11","恢复上一个关闭的标签\tCtrl+Shift+T"},
                "浏览资料": {"历史记录\tCtrl+H","查看下载\tCtrl+J","管理书签\tCtrl+Shift+O"},
                "隐私与安全": {"清除浏览数据\tCtrl+Shift+Delete","查看当前站点数据"},
                "开发与诊断": {"打开网页开发者工具\tF12","打开网页控制台\tCtrl+Shift+J","浏览器任务管理器\tCtrl+Shift+M"},
                "扩展工具": {"打开 Lua 脚本编辑器","配置菜单与快捷键示例","显示 Moon 命令提示"},
            }
            if tab_tools.exists():
                expected["标签与页面"].update({"切换当前标签的固定状态","切换当前标签的静音状态",
                                                 "复制当前标签","复制当前标签网址","关闭其他标签","关闭下方标签"})
            if search_plugin.exists():
                expected["标签与页面"].add("管理搜索引擎")
            if session_plugin.exists():
                expected["标签与页面"].update({"管理启动与会话","恢复上次会话"})
            if bookmark_transfer:
                expected["浏览资料"].update({"导入 HTML 书签","导出 HTML 书签"})
            if private_window.exists():
                expected["隐私与安全"].add("新建隐私窗口\tCtrl+Shift+N")
            if popups.exists():
                expected["隐私与安全"].add("管理网站弹窗")
            if page_source.exists():
                expected["开发与诊断"].add("查看网页源代码\tCtrl+Shift+7")
            for group, labels in expected.items():
                if missing := labels - groups.get(group,{}).keys():
                    raise RuntimeError(f"Native menu group {group} is missing {missing}")
            if "管理网页过滤" in groups["隐私与安全"] or "Inspect active tab" in groups["扩展工具"]:
                raise RuntimeError("A disabled optional plugin appeared in the grouped menu")

            if not user.RegisterHotKey(None,901,modifiers,ord('9')):
                raise RuntimeError("Could not reserve the test's conflicting shortcut")
            try:
                set_control(edit,address)
                user.PostMessageW(edit,0x0100,0x0D,1)
                confirmation(6)  # Allow, but the OS key above is occupied
                confirmation(7)  # Cancel
                confirmation(6)  # Allow the available combination
                registration_phase("installed")
            finally:
                user.UnregisterHotKey(None,901)
            groups = native_entries()
            if "显示 Moon 命令提示\tCtrl+Shift+8" not in groups:
                raise RuntimeError("The plugin command is missing from the actual native main menu")
            if any(item.startswith("显示 Moon 命令提示") for item in groups["扩展工具"]):
                raise RuntimeError("The pinned command was duplicated in its original menu group")
            if user.RegisterHotKey(None,902,modifiers,ord('8')):
                user.UnregisterHotKey(None,902)
                raise RuntimeError("The browser did not reserve its global shortcut in Windows")
            user.ShowWindow(frame,6)  # SW_MINIMIZE
            for token in range(0x4100,0x4140):
                user.PostMessageW(frame,0x0312,token,(ord('8')<<16)|modifiers)
            wait_for(lambda: not user.IsIconic(frame) and owned_window("#32770","命令唤醒验收"),
                     "The global shortcut did not wake the browser and launch the plugin")
            user.PostMessageW(frame,0x0010,0,0)
            if proc.wait(8)!=0:
                raise RuntimeError("Browser failed to exit before the registered shortcut restart check")
            frame = None
            proc = subprocess.Popen([str(exe),"--gdi"],env=preview_env(root))
            frame = browser_frame(proc)
            edit = user.GetDlgItem(frame,1001)
            wait_for(lambda: user.IsWindowVisible(user.GetDlgItem(frame,1002)),"Restarted shell did not initialize")
            if user.RegisterHotKey(None,902,modifiers,ord('8')):
                user.UnregisterHotKey(None,902)
                raise RuntimeError("The global registration did not survive a restart")
            restarted_menu = native_entries()
            if "显示 Moon 命令提示\tCtrl+Shift+8" not in restarted_menu:
                raise RuntimeError("The menu registration did not survive a restart")
            if page_source.exists():
                if "查看网页源代码\tCtrl+Shift+7" not in restarted_menu["开发与诊断"]:
                    raise RuntimeError("The user shortcut did not survive a restart")
                print("user_shortcuts=ok menu_override=ok reserved_and_conflicting_preferences_rejected=ok restart=ok",flush=True)
            set_control(edit,address)
            user.PostMessageW(edit,0x0100,0x0D,1)
            registration_phase("removed")
            if not user.RegisterHotKey(None,902,modifiers,ord('8')):
                raise RuntimeError("Unregistering did not release the Windows shortcut")
            user.UnregisterHotKey(None,902)
            groups = native_entries()
            if any(item.startswith("显示 Moon 命令提示") for item in (*groups,*groups["扩展工具"])):
                raise RuntimeError("The removed command remained in the native main menu")
            if "显示 Moon 命令提示" not in groups["插件"]["命令唤醒验收"]:
                raise RuntimeError("Removing the main menu placement also removed the plugin's command")
            print("command_contributions=ok native_groups=ok pin_no_duplicate=ok global_wake=ok conflict_cancel=ok restart=ok removal=ok",flush=True)
        if tab_tools.exists():
            pins = profile / "pinned-tabs.json"

            def restart_tabs():
                user.PostMessageW(frame,0x0010,0,0)
                if proc.wait(8)!=0:
                    raise RuntimeError("Browser did not exit before the pinned tab check")
                restarted = subprocess.Popen([str(exe),"--gdi"],env=preview_env(root))
                return restarted,browser_frame(restarted)

            def tab_menu(row, choose=None):
                point = wt.POINT(px(100),px(148+37*row))
                user.ClientToScreen(frame,ctypes.byref(point))
                coords = ((point.y & 0xFFFF)<<16) | (point.x & 0xFFFF)
                return native_entries(lambda: user.PostMessageW(frame,0x007B,frame,coords),choose)

            proc,frame = restart_tabs()
            edit = user.GetDlgItem(frame,1001)
            wait_for(lambda: user.IsWindowVisible(user.GetDlgItem(frame,1002)),"Fresh shell did not show its new-tab page")
            first = closed_page("pinned-first")
            invoke("新建标签页")
            wait_for(lambda: user.IsWindowVisible(user.GetDlgItem(frame,1002)),"Opening a second test tab failed")
            second = closed_page("pinned-second")
            click(px(110),px(148))
            wait_for(lambda: read_address()==first,"Switching to the first tab failed")
            if "固定标签" not in tab_menu(1,"固定标签"):
                raise RuntimeError("No pin action on the background tab")
            wait_for(lambda: pins.exists() and json.loads(pins.read_text(encoding="utf-8"))[0]["url"]==second,
                     "The background tab was not saved as pinned")
            if read_address()!=first or "取消固定标签" not in tab_menu(0):
                raise RuntimeError("Pinning activated the background tab or did not move it to the top")
            tab_menu(0,"静音此标签")
            wait_for(lambda: "取消标签静音" in tab_menu(0),"Selected background tab was not muted")
            if "静音此标签" not in tab_menu(1):
                raise RuntimeError("Muting a background tab also muted the active tab")
            click(px(110),px(148))
            wait_for(lambda: read_address()==second,"Pinned tab did not activate for reload")
            previous = Fixture.closed_loaded.get("pinned-second",0)
            user.PostMessageW(edit,0x0100,0x74,1)  # F5
            wait_for(lambda: Fixture.closed_loaded.get("pinned-second",0)>previous,"Reloading the muted tab failed")
            if "取消标签静音" not in tab_menu(0):
                raise RuntimeError("Reloading the tab lost its mute state")
            tab_menu(0,"取消标签静音")
            wait_for(lambda: "静音此标签" in tab_menu(0),"Selected background tab stayed muted")

            loads = Fixture.closed_loaded.get("pinned-second",0)
            proc,frame = restart_tabs()
            edit = user.GetDlgItem(frame,1001)
            home = user.GetDlgItem(frame,1002)
            wait_for(lambda: user.IsWindowVisible(home),"Restarted shell did not show its new-tab page")
            if "取消固定标签" not in tab_menu(0) or Fixture.closed_loaded.get("pinned-second",0)!=loads:
                raise RuntimeError("The pinned tab was not restored dormant")
            click(px(110),px(148))
            wait_for(lambda: read_address()==second and Fixture.closed_loaded.get("pinned-second",0)>loads,
                     "Selecting the restored pinned tab did not load its page")
            tab_menu(0,"取消固定标签")
            wait_for(lambda: json.loads(pins.read_text(encoding="utf-8"))==[],"Unpinning did not clear the saved pin")
            print("tab_tools=ok background_target=ok single_tab_mute_state=ok mute_reload=ok pinned_order=ok restart_lazy_restore=ok",flush=True)

            def palette_rows():
                click(px(70),px(65))
                dialog = find_palette()
                count = user.SendMessageW(user.GetDlgItem(dialog,1004),0x018B,0,0)  # LB_GETCOUNT
                user.PostMessageW(dialog,0x0010,0,0)
                wait_for(lambda: not user.IsWindow(dialog),"The tab-count command palette did not close")
                return count

            closed_page("pinned-first")
            closed_page("pinned-second")
            click(px(110),px(185))
            wait_for(lambda: user.IsWindowVisible(home),"The source tab did not move to the background")
            before = palette_rows()
            previous = Fixture.closed_loaded.get("pinned-second",0)
            if "复制标签网址" not in tab_menu(0,"复制标签"):
                raise RuntimeError("The background-tab menu did not offer copying its address")
            wait_for(lambda: read_address()==second and Fixture.closed_loaded.get("pinned-second",0)>previous,
                     "Duplicating the background tab did not open its page")
            if palette_rows()!=before+1:
                raise RuntimeError("Duplicating did not create exactly one tab")
            previous = Fixture.closed_loaded.get("pinned-first",0)
            click(px(285),px(24))
            wait_for(lambda: read_address()==first and Fixture.closed_loaded.get("pinned-first",0)>previous,
                     "The duplicate's Back entry was not preserved")
            previous = Fixture.closed_loaded.get("pinned-second",0)
            click(px(319),px(24))
            wait_for(lambda: read_address()==second and Fixture.closed_loaded.get("pinned-second",0)>previous,
                     "The duplicate's Forward entry was not preserved")
            tab_menu(0,"固定标签")
            wait_for(lambda: json.loads(pins.read_text(encoding="utf-8")) and
                     json.loads(pins.read_text(encoding="utf-8"))[0]["url"]==second,
                     "The bulk-close test did not pin the source")
            invoke("新建标签页")
            wait_for(lambda: user.IsWindowVisible(home),"Opening the last tab failed")
            before = palette_rows()
            tab_menu(1,"关闭下方标签")
            wait_for(lambda: read_address()==second and palette_rows()==before-2,
                     "Closing the tabs below did not keep their source tab active")

            content = user.FindWindowExW(frame,None,"MoonContent",None)
            view = visible_page_view()
            if not view:
                raise RuntimeError("The duplicate's WebKit view was not visible")
            user.PostMessageW(view,0x0102,ord('x'),1)  # WM_CHAR makes the live tab protected
            invoke("新建标签页")
            wait_for(lambda: user.IsWindowVisible(home),"Opening a disposable tab failed")
            closed_page("pinned-first")
            invoke("新建标签页")
            wait_for(lambda: user.IsWindowVisible(home),"Opening the bulk-close target failed")
            keep = closed_page("closed-item")
            before = palette_rows()
            tab_menu(3,"关闭其他标签")
            wait_for(lambda: palette_rows()==before-1,"Closing other tabs did not preserve pinned and edited tabs")
            if read_address()!=keep or "取消固定标签" not in tab_menu(0):
                raise RuntimeError("Bulk closing changed the retained active tab or removed the pin")
            click(px(110),px(185))
            wait_for(lambda: read_address()==second,"The protected edited tab was not retained")
            print("tab_batch_tools=ok duplicate_target=ok duplicate_history=ok close_below=ok pinned_kept=ok edited_tab_kept=ok",flush=True)

            def sidebar_point(y):
                return ((px(y)&0xFFFF)<<16) | (px(110)&0xFFFF)

            def drag_tab(source, anchor, *, after=False, cancel=False):
                start = sidebar_point(148+37*source)
                destination = sidebar_point((163 if after else 143)+37*anchor)
                user.PostMessageW(frame,0x0201,1,start)  # WM_LBUTTONDOWN
                user.PostMessageW(frame,0x0200,1,destination)  # WM_MOUSEMOVE
                if cancel:
                    user.PostMessageW(frame,0x0100,0x1B,1)  # Escape
                user.PostMessageW(frame,0x0202,0,destination)  # WM_LBUTTONUP

            invoke("新建标签页")
            wait_for(lambda: user.IsWindowVisible(home),"Opening a tab for drag sorting failed")
            last = closed_page("order-last")
            drag_tab(2,3,after=True)
            sleep(0.35)
            if read_address()!=last:
                raise RuntimeError("Dragging a background tab activated it")
            click(px(110),px(148+37*3))
            wait_for(lambda: read_address()==keep,"A drag did not move the background tab after its target")
            drag_tab(3,2,cancel=True)
            sleep(0.35)
            if read_address()!=keep:
                raise RuntimeError("Escape followed by release unexpectedly selected another tab")
            click(px(110),px(148+37*2))
            wait_for(lambda: read_address()==last,"Escape did not cancel the pending reorder")
            drag_tab(0,2,after=True)
            sleep(0.35)
            if "取消固定标签" not in tab_menu(0) or read_address()!=last:
                raise RuntimeError("A drag moved a pinned tab across partitions")
            tab_menu(3,"固定标签")
            wait_for(lambda: [item["url"] for item in read_settings(pins)]==[second,keep],
                     "Could not add the second fixed tab")
            drag_tab(1,0)
            wait_for(lambda: [item["url"] for item in read_settings(pins)]==[keep,second],
                     "Dragging fixed tabs did not write the new pin order")
            if read_address()!=last:
                raise RuntimeError("Reordering fixed tabs changed the active page")

            proc,frame = restart_tabs()
            edit = user.GetDlgItem(frame,1001)
            home = user.GetDlgItem(frame,1002)
            wait_for(lambda: user.IsWindowVisible(home),"Restarted shell did not show its new-tab page")
            click(px(110),px(148))
            wait_for(lambda: read_address()==keep,"Restart did not restore the new order of fixed tabs")
            bounds = wt.RECT()
            user.GetClientRect(frame,ctypes.byref(bounds))
            capacity = (round(bounds.bottom*96/dpi)-134-48-6)//37
            for _ in range(capacity+4):
                click(px(253),px(105))
            wait_for(lambda: user.IsWindowVisible(home),"Could not open enough tabs to scroll the sidebar")
            closed_page("order-last")
            user.PostMessageW(frame,0x0201,1,sidebar_point(148+37*(capacity-1)))
            user.PostMessageW(frame,0x0200,1,sidebar_point(138))
            sleep(1.45)
            user.PostMessageW(frame,0x0200,1,sidebar_point(143+37*2))
            user.PostMessageW(frame,0x0202,0,sidebar_point(143+37*2))
            sleep(0.35)
            click(px(110),px(148))
            wait_for(lambda: read_address()==keep,"Dragging near the top edge did not scroll to the pinned rows")
            click(px(110),px(148+37*2))
            wait_for(lambda: read_address()==last,"Dropping after auto-scroll did not use the visible target")
            proc,frame = restart_tabs()
            edit = user.GetDlgItem(frame,1001)
            home = user.GetDlgItem(frame,1002)
            print("tab_drag_system_plugin=ok background_target=ok escape_cancel=ok edge_scroll=ok pinned_boundary=ok pinned_order_restart=ok",flush=True)
        if private_window.exists():
            private_title = "Moon Browser · 隐私浏览"
            kernel = ctypes.WinDLL("kernel32",use_last_error=True)
            kernel.OpenProcess.argtypes = [wt.DWORD,wt.BOOL,wt.DWORD]
            kernel.OpenProcess.restype = wt.HANDLE
            kernel.CloseHandle.argtypes = [wt.HANDLE]
            kernel.QueryFullProcessImageNameW.argtypes = [wt.HANDLE,wt.DWORD,wt.LPWSTR,ctypes.POINTER(wt.DWORD)]
            kernel.WaitForSingleObject.argtypes = [wt.HANDLE,wt.DWORD]
            kernel.WaitForSingleObject.restype = wt.DWORD

            def private_frames():
                result = set()
                win = None
                while win := user.FindWindowExW(None,win,"MoonBrowserWindow",private_title):
                    pid = wt.DWORD()
                    user.GetWindowThreadProcessId(win,ctypes.byref(pid))
                    handle = kernel.OpenProcess(0x1000,False,pid.value)  # PROCESS_QUERY_LIMITED_INFORMATION
                    if not handle:
                        continue
                    try:
                        path = ctypes.create_unicode_buffer(2048)
                        size = wt.DWORD(len(path))
                        if kernel.QueryFullProcessImageNameW(handle,0,path,ctypes.byref(size)) and Path(path.value)==exe:
                            result.add(win)
                    finally:
                        kernel.CloseHandle(handle)
                return result

            def private_probe(window, token, expected, *, cache_required=True):
                control = user.GetDlgItem(window,1001)
                set_control(control,base + "/private-window-probe/" + token)
                user.PostMessageW(control,0x0100,0x0D,1)
                result = wait_for(lambda: Fixture.private_window_reports.get(token),f"No storage report from {token}",18)
                database_name = "moon-window-"+expected if expected else ""
                cache = result.get("cache","")
                if (result.get("error") or any(result.get(k,"")!=expected for k in ("http","local"))
                        or result.get("idb","")!=database_name or cache not in (expected,"") or (cache_required and cache!=expected)):
                    raise RuntimeError(f"Incorrect private browsing state for {token}: {result}")
                return cache==expected

            def close_private(window):
                pid = wt.DWORD()
                user.GetWindowThreadProcessId(window,ctypes.byref(pid))
                handle = kernel.OpenProcess(0x100000,False,pid.value)  # SYNCHRONIZE
                if not handle:
                    raise RuntimeError("Could not wait on the test private-window process")
                try:
                    user.PostMessageW(window,0x0010,0,0)
                    if kernel.WaitForSingleObject(handle,10000)!=0:
                        raise RuntimeError("Closing the private window did not end its process")
                finally:
                    kernel.CloseHandle(handle)

            def open_private():
                existing = private_frames()
                invoke("新建隐私窗口")
                guest = wait_for(lambda: next(iter(private_frames()-existing),None),"The privacy plugin did not open an isolated window")
                wait_for(lambda: user.IsWindowVisible(user.GetDlgItem(guest,1002)),"The private window did not initialize")
                return guest

            private_probe(frame,"regular-seed","regular")
            previous_private = private_frames()
            try:
                guest = open_private()
                guest_home = user.GetDlgItem(guest,1002)
                if popups.exists():
                    guest_edit = user.GetDlgItem(guest,1001)
                    set_control(guest_edit,base.replace("127.0.0.1","localhost") + "/page/popup-private")
                    user.PostMessageW(guest_edit,0x0100,0x0D,1)
                    wait_for(lambda: "private" in Fixture.popup_attempts,"Private popup probe did not run")
                private_probe(guest,"private-empty","")
                if popups.exists():
                    if "private" in Fixture.popup_destinations:
                        raise RuntimeError("Ordinary window popup rules changed a private window")
                    print("private_popup_default=ok",flush=True)
                private_probe(guest,"private-seed","private")
                guest_dpi = user.GetDpiForWindow(guest)
                x,y = (251*guest_dpi+48)//96,(104*guest_dpi+48)//96
                user.PostMessageW(guest,0x0202,0,(y<<16)|x)
                wait_for(lambda: user.IsWindowVisible(guest_home),"Opening a second private tab failed")
                shared_cache = private_probe(guest,"private-second-tab","private",cache_required=False)
                private_probe(frame,"regular-unchanged","regular")
                other_guest = open_private()
                private_probe(other_guest,"private-parallel","")
                close_private(other_guest)
                close_private(guest)
                guest = open_private()
                private_probe(guest,"private-reopened","")
                close_private(guest)
            finally:
                for window in private_frames()-previous_private:
                    user.PostMessageW(window,0x0010,0,0)
            leaked = history_rows("SELECT url FROM visits WHERE url LIKE '%/private-window-probe/private-%'")
            if leaked:
                raise RuntimeError("Private navigations landed in the ordinary history database")
            print("private_window=ok separate_store=ok independent_private_windows=ok ephemeral_reopen=ok "
                  "cookies=ok local_storage=ok indexed_db=ok cache_isolation=ok no_history=ok "
                  f"private_cache_shared={'yes' if shared_cache else 'no'}",flush=True)
        if search_plugin.exists():
            invoke("管理搜索引擎")
            wait_for(lambda: read_address()=="extension://moon.search/engines.html","The search command did not open its packaged settings page")
            set_control(edit,"extension://moon.search-fixture/engines.html")
            user.PostMessageW(edit,0x0100,0x0D,1)
            library_result("moon.search-fixture")

            def search_input(control, value, expected):
                set_control(control,value)
                user.PostMessageW(control,0x0100,0x0D,1)
                wait_for(lambda: read_address()==expected,"Unexpected URL for the submitted search: "+read_address())

            query = "月亮 +& /"
            encoded = quote(query,safe="")
            expected = "https://search-test.invalid/find?q="+encoded+"&scope=title"
            search_input(edit,query,expected)
            invoke("@Other "+query)
            wait_for(lambda: read_address()=="https://other-search.invalid/?terms="+encoded,"The command palette did not resolve the custom alias")
            normal = base + "/page/search-direct"
            search_input(edit,normal,normal)
            invoke("新建标签页")
            home = user.GetDlgItem(frame,1002)
            wait_for(lambda: user.IsWindowVisible(home),"The new tab did not show the home search")
            search_input(home,query,expected)

            user.PostMessageW(frame,0x0010,0,0)
            if proc.wait(8)!=0:
                raise RuntimeError("Browser did not exit for the search preference restart check")
            frame = None
            proc = subprocess.Popen([str(exe),"--gdi"],env=preview_env(root))
            frame = browser_frame(proc)
            edit = user.GetDlgItem(frame,1001)
            wait_for(lambda: user.IsWindowVisible(user.GetDlgItem(frame,1002)),"Restarted shell did not initialize")
            search_input(edit,query,expected)
            print("search_engines=ok live_config=ok custom_default=ok palette_alias=ok home_search=ok utf8_encoding=ok validation=ok restart=ok",flush=True)
        if session_plugin.exists():
            session_root = root / "session-check"
            session_profile = session_root / "profile"
            saved_session = session_profile / "last-session.json"
            fixture = session_profile / "plugins" / "session-contract"
            fixture.mkdir(parents=True)
            (session_profile / "memory.json").write_text(json.dumps({
                "warm_tabs":10,"idle_seconds":3600,"pressure_mib":32768,"target_mib":32000,
            }),encoding="utf-8")
            manifest = json.loads(session_plugin.with_name("plugin.json").read_text(encoding="utf-8"))
            manifest.update(id="moon.session-fixture",name="Session preference fixture")
            for command in manifest["contributes"]["commands"]:
                command.pop("menu")
                command["label"] = "Session fixture " + command["id"]
            (fixture / "plugin.json").write_text(json.dumps(manifest),encoding="utf-8")
            shutil.copyfile(session_plugin,fixture / session_plugin.name)
            (session_profile / "plugin-state.json").write_text(json.dumps([
                {"id":"moon.session-fixture","enabled":True,"tabs_read":False,"tabs_session_manage":True},
            ]),encoding="utf-8")
            page = session_plugin.with_name("session.html").read_text(encoding="utf-8")
            contract = (
                '<script>(async()=>{const settings=window.webkit.messageHandlers.moonSettings;'
                'const emit=value=>settings.postMessage(JSON.stringify({op:"write",value}));'
                'const wait=async(check)=>{for(let i=0;i<120;i++){if(await check())return;'
                'await new Promise(r=>setTimeout(r,40));}throw Error("session settings timeout");};'
                'try{await wait(()=>!automatic.disabled);if(automatic.checked)throw Error("startup enabled by default");'
                'automatic.click();await wait(async()=>!automatic.disabled&&(await host("tabs.session.status")).autoRestore);'
                'if(forget.disabled)throw Error("saved checkpoint cannot be cleared after restore");'
                'forget.click();confirm.querySelector("[value=cancel]").click();'
                'await wait(async()=>!confirm.open&&(await host("tabs.session.status")).alreadyRestored);'
                'forget.click();confirm.querySelector("[value=forget]").click();'
                'await wait(async()=>forget.disabled&&!(await host("tabs.session.status")).alreadyRestored);'
                'await emit({passed:true});}catch(e){await emit({error:String(e)});}})();</script>'
            )
            (fixture / "session.html").write_text(page.replace("</html>",contract+"</html>"),encoding="utf-8")

            def restart_session(*args, message=0x0010):
                user.PostMessageW(frame,message,1 if message==0x0016 else 0,0)
                if proc.wait(8)!=0:
                    raise RuntimeError("Browser did not finish the session checkpoint")
                restarted = subprocess.Popen([str(exe),*args],env=preview_env(session_root))
                return restarted,browser_frame(restarted)

            def counts():
                return tuple(Fixture.closed_loaded.get(name,0) for name in ("session-first","session-second","session-pinned"))

            database = session_profile / "history.sqlite3"
            proc,frame = restart_session("--gdi")
            edit = user.GetDlgItem(frame,1001)
            home = user.GetDlgItem(frame,1002)
            wait_for(lambda: user.IsWindowVisible(home),"The fresh session browser did not initialize")
            pinned_url = closed_page("session-pinned")
            tab_menu(0,"固定标签")
            pin_file = session_profile / "pinned-tabs.json"
            wait_for(lambda: pin_file.exists() and json.loads(pin_file.read_text(encoding="utf-8")),
                     "Could not pin the test session's first webpage")
            invoke("新建标签页")
            wait_for(lambda: user.IsWindowVisible(home),"Opening the first session tab failed")
            first_url = closed_page("session-first")
            invoke("新建标签页")
            wait_for(lambda: user.IsWindowVisible(home),"Opening the last active session tab failed")
            selected_url = closed_page("session-second")
            invoke("新建标签页")
            wait_for(lambda: user.IsWindowVisible(home),"Opening the session's POST tab failed")
            posted = base + "/closed-submit"
            set_control(edit,base + "/page/closed-post")
            user.PostMessageW(edit,0x0100,0x0D,1)
            wait_for(lambda: history_rows("SELECT id FROM visits WHERE url=?",(posted,)),
                     "The session's POST request did not finish")
            click(px(110),px(222))
            wait_for(lambda: read_address()==selected_url,"Could not select the last ordinary session tab")
            initial = counts()
            proc,frame = restart_session("--gdi")
            edit = user.GetDlgItem(frame,1001)
            home = user.GetDlgItem(frame,1002)
            wait_for(lambda: user.IsWindowVisible(home),"A fresh start unexpectedly restored the old session")
            recorded = json.loads(saved_session.read_text(encoding="utf-8"))
            if [tab["url"] for tab in recorded["tabs"]] != [first_url,selected_url] or recorded["selected"]!=1:
                raise RuntimeError("Session checkpoint lost tab order, included a pin or POST, or lost the selected tab")
            if counts()!=initial:
                raise RuntimeError("Previous webpages loaded before the user restored the session")
            before = palette_rows()
            invoke("恢复上次会话")
            wait_for(lambda: read_address()==selected_url and counts()[1]>initial[1],"Manual restore did not load the selected tab")
            if counts()[0]!=initial[0] or counts()[2]!=initial[2] or palette_rows()!=before+1:
                raise RuntimeError("Manual restore duplicated the pin or loaded a background tab")
            invoke("恢复上次会话")
            wait_for(lambda: owned_window("#32770","上次会话"),"The consumed session did not report an empty state")
            if palette_rows()!=before+1:
                raise RuntimeError("A second manual restore duplicated the session")
            click(px(110),px(185))
            wait_for(lambda: read_address()==first_url and counts()[0]>initial[0],"Selecting a restored background tab did not load it")

            invoke("管理启动与会话")
            wait_for(lambda: read_address()=="extension://moon.session/session.html","The packaged startup preferences did not open")
            set_control(edit,"extension://moon.session-fixture/session.html")
            user.PostMessageW(edit,0x0100,0x0D,1)
            preference_report = session_profile / f'extension-{sha256(b"moon.session-fixture").hexdigest()}.json'
            result = wait_for(lambda: preference_report.exists() and json.loads(preference_report.read_text(encoding="utf-8")),
                              "The session preferences fixture did not finish")
            if not result.get("passed"):
                raise RuntimeError(f"Session preferences: {result}")
            invoke("Moon fixture session-second")
            wait_for(lambda: read_address()==selected_url,"The last active session tab did not regain focus")
            proc,frame = restart_session("--private","--gdi",base + "/page/session-private",message=0x0016)
            wait_for(lambda: Fixture.closed_loaded.get("session-private"),"The isolated private-window fixture did not load")
            saved_bytes = saved_session.read_bytes()
            initial = counts()
            proc,frame = restart_session("--gdi")
            edit = user.GetDlgItem(frame,1001)
            wait_for(lambda: read_address()==selected_url and counts()[1]>initial[1],"Automatic restore did not reopen the selected tab")
            if saved_session.read_bytes()!=saved_bytes or counts()[0]!=initial[0] or counts()[2]!=initial[2]:
                raise RuntimeError("Private browsing rewrote the previous session or auto restore loaded its background tabs")
            external = base + "/page/session-external"
            initial = counts()
            proc,frame = restart_session("--gdi",external)
            edit = user.GetDlgItem(frame,1001)
            wait_for(lambda: read_address()==external and Fixture.closed_loaded.get("session-external"),
                     "An explicit startup address did not take precedence over session restore")
            if counts()!=initial:
                raise RuntimeError("Opening an explicit address also loaded the previous session")
            invoke("恢复上次会话")
            wait_for(lambda: read_address()==selected_url and counts()[1]>initial[1],
                     "The previous session was unavailable after explicit startup")
            print("last_session=ok safe_checkpoint=ok selected_restore=ok no_duplicate=ok lazy_load=ok "
                  "auto_startup=ok private_excluded=ok external_url_priority=ok forget_confirmation=ok",flush=True)
    finally:
        Fixture.slow_download_release.set()
        if frame:
            user.PostMessageW(frame, 0x0010, 0, 0)
        try:
            proc.wait(8)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("exe", type=Path)
    parser.add_argument("--pressure", action="store_true")
    parser.add_argument("--gdi", action="store_true")
    parser.add_argument("--ui", action="store_true", help="Also test actual Win32 resizing and Unicode navigation")
    parser.add_argument("--quick", action="store_true", help="Skip the 50-tab stress and run the engine/plugin/download checks")
    parser.add_argument("--report", type=Path, help="Copy browser metrics to this path")
    args = parser.parse_args()
    source = args.exe.resolve(strict=True)
    # WebKit's Windows Cache Storage backend needs room for hashed paths under the profile.
    temp_root = Path(os.environ["LOCALAPPDATA"]) / "Temp"
    temp_root.mkdir(exist_ok=True)
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server, tempfile.TemporaryDirectory(prefix="moon-", dir=temp_root) as directory:
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
