const std = @import("std");
const native = @import("native");
const policy = @import("policy.zig");
const plugins = @import("plugins.zig");
const userscripts = @import("userscripts.zig");
const extension_settings = @import("extension_settings.zig");
const api = @import("plugin_host_api.zig");
const sdk = @import("moon_plugin");
const history = @import("history.zig");
const network = @import("network_policy.zig");
const bookmarks = @import("bookmarks.zig");
const downloads = @import("downloads.zig");
const site_data = @import("site_data.zig");
const page_source = @import("page_source.zig");
const popups = @import("popup_policy.zig");
const reading = @import("reading.zig");
const recent_tabs = @import("recent_tabs.zig");
const market = @import("market.zig");
const plugin_manager = @import("plugin_manager.zig");
const updater = @import("updater.zig");
const search = @import("search.zig");
const last_session = @import("session.zig");

const max_tabs = last_session.limit;
const max_pinned = 24;
const PinnedEntry = struct { url: []const u8, title: []const u8 };
const Phase = sdk.TaskTabPhase;
const Opening = enum { none, navigate, restore };
const Tab = struct {
    id: u64,
    phase: Phase = .blank,
    view: ?*native.MoonView = null,
    session: ?*const anyopaque = null,
    title: [512:0]u8 = @splat(0),
    url: [4096:0]u8 = @splat(0),
    last_used: u64,
    deadline: u64 = 0,
    dirty: bool = false,
    unsafe_history: bool = false,
    loading: bool = false,
    loaded: bool = false,
    has_document: bool = false,
    extension: bool = false,
    restoring_history: bool = false,
    document_committed: bool = false,
    navigation: u64 = 0,
    history_visit: ?u32 = null,
    download_count: usize = 0,
    activity: bool = false,
    pinned: bool = false,
    muted: bool = false,
    opening: Opening = .none,
    requested_at: u64 = 0,
};
const Retiring = struct { handle: *anyopaque, pid: u32 };

var tabs: [max_tabs]Tab = undefined;
var count: usize = 0;
var active: usize = 0;
var find_tab: u64 = 0;
var find_owner: [96:0]u8 = @splat(0);
var fullscreen_owner: [96:0]u8 = @splat(0);
const PageSaveJob = struct {
    request: u64, tab: u64, navigation: u64, deadline: u64,
    owner: [96:0]u8, path: [4096:0]u8, replace: bool,
};
var page_save_job: ?PageSaveJob = null;
var page_save_serial: u64 = 0;
var site_clear_confirming = false;
var next_id: u64 = 1;
var pins_path: [4096:0]u8 = @splat(0);
var pins_save_at: ?u64 = null;
var boot: u64 = 0;
var settings: policy.Settings = .{};
var pressure = false;
var commit: u64 = 0;
var process_samples: [1024]native.MoonSample = undefined;
var process_count: usize = 0;
var sampled: u64 = 0;
var last_before: u64 = 0;
var last_after: u64 = 0;
var settle_at: u64 = 0;
var next_evict: u64 = 0;
var evictions: usize = 0;
var snapshots_saved: usize = 0;
var last_trim: u64 = 0;
var peak_commit: u64 = 0;
var retiring: [max_tabs]Retiring = undefined;
var retiring_count: usize = 0;
var stopped = false;
const ShortcutCapture = struct { tab: u64, deadline: u64 };
var shortcut_capture: ?ShortcutCapture = null;
var popup: [4096:0]u8 = @splat(0);
var error_text: [512:0]u8 = @splat(0);

const ShellAction = struct {
    label: [:0]const u8,
    command: c_int,
    home: bool = false,
};
const shell_actions = [_]ShellAction{
    .{ .label = "新建标签页", .command = native.MOON_NEW },
    .{ .label = "聚焦地址栏", .command = native.MOON_FOCUS_ADDRESS },
    .{ .label = "切换侧边栏", .command = native.MOON_TOGGLE_SIDEBAR },
    .{ .label = "切换亮色 / 深色主题", .command = native.MOON_TOGGLE_THEME },
    .{ .label = "内存诊断", .command = native.MOON_DIAGNOSTICS, .home = true },
    .{ .label = "管理插件", .command = native.MOON_OPEN_PLUGINS, .home = true },
    .{ .label = "版本与更新", .command = native.MOON_UPDATES, .home = true },
    .{ .label = "插件市场", .command = native.MOON_MARKET },
};

const SmokeStep = enum { off, first, second, load_tabs, settle, warm_prepare, warm, restore, back, forward, plugin, download, crash, recover };
var smoke: SmokeStep = .off;
var smoke_base: [2048:0]u8 = @splat(0);
var smoke_log: [4096:0]u8 = @splat(0);
var smoke_download: [4096:0]u8 = @splat(0);
var smoke_deadline: u64 = 0;
var smoke_painted: bool = false;
var smoke_paint_requested: bool = false;
var smoke_started: u64 = 0;
var warm_started_us: u64 = 0;
var load_step: u64 = 0;
var plugin_step: usize = 0;
var warm_samples: [20]u64 = undefined;
var warm_count: usize = 0;
var recovery_started = false;
var smoke_quick = false;

pub fn main() u8 {
    boot = native.moon_clock();
    return @intCast(native.moon_shell_run());
}

fn slice(text: anytype) []const u8 {
    return std.mem.sliceTo(text, 0);
}
fn equals(first: []const u8, second: []const u8) bool {
    return std.mem.eql(u8, first, second);
}
fn copy(out: []u8, value: []const u8) bool {
    if (value.len >= out.len or std.mem.indexOfScalar(u8, value, 0) != null) return false;
    @memcpy(out[0..value.len], value);
    out[value.len] = 0;
    return true;
}
fn log(comptime format: []const u8, args: anytype) void {
    if (smoke_log[0] == 0) return;
    var buffer: [4096]u8 = undefined;
    const line = std.fmt.bufPrintSentinel(&buffer, format ++ "\n", args, 0) catch return;
    native.moon_log(&smoke_log, line.ptr);
}
fn failSmoke(message: []const u8) void {
    log("FAIL {s} stage={s} last_error={s}", .{ message, @tagName(smoke), slice(&error_text) });
    native.moon_quit(1);
}
fn safeURL(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "http://");
}
fn normalize(input: []const u8, buffer: []u8) ?[:0]const u8 {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (value.len == 0) return null;
    for (value) |ch| if (std.ascii.isControl(ch)) return null;
    if (std.mem.startsWith(u8,value,"extension://") or equals(value,market.address) or equals(value,plugin_manager.address))
        return std.fmt.bufPrintSentinel(buffer,"{s}",.{value},0) catch null;
    if (safeURL(value)) {
        const scheme_len: usize = if (value[4] == ':') 7 else 8;
        const after = value[scheme_len..];
        const authority = after[0 .. std.mem.indexOfAny(u8, after, "/?#") orelse after.len];
        if (authority.len == 0 or std.mem.indexOfAny(u8, authority, " @\\") != null) return null;
        return std.fmt.bufPrintSentinel(buffer, "{s}", .{value}, 0) catch null;
    }
    if (std.mem.indexOfScalar(u8, value, ' ') == null) {
        const prefix = value[0 .. std.mem.indexOfAny(u8, value, "/?#") orelse value.len];
        const port_at = std.mem.lastIndexOfScalar(u8, prefix, ':');
        const host = if (port_at) |index| prefix[0..index] else prefix;
        if (port_at) |index| {
            const port = std.fmt.parseUnsigned(u16, prefix[index + 1 ..], 10) catch return null;
            if (port == 0) return null;
        }
        if (std.mem.indexOfScalar(u8, host, '.') != null or std.ascii.eqlIgnoreCase(host, "localhost") or
            equals(host, "[::1]")) return std.fmt.bufPrintSentinel(buffer, "{s}://{s}", .{
            if (std.ascii.eqlIgnoreCase(host, "localhost") or equals(host, "[::1]") or
                std.mem.startsWith(u8, host, "127.")) "http" else "https",
            value,
        }, 0) catch null;
        if (std.mem.indexOfScalar(u8, value, ':') != null) return null;
    }

    return search.resolve(value,buffer,plugins.systemEnabled(.@"search.manage"));
}
fn applySettings(profile: []const u8) void {
    var path: [4096]u8 = undefined;
    const file = std.fmt.bufPrintSentinel(&path, "{s}\\memory.json", .{profile}, 0) catch return;
    var data: [4096]u8 = undefined;
    if (!native.moon_read_text(file.ptr, &data, data.len)) return;
    const json = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, slice(&data), .{}) catch return;
    defer json.deinit();
    if (json.value != .object) return;
    const fields = json.value.object;
    settings.warm_limit = @intCast(jsonSetting(fields.get("warm_tabs"), settings.warm_limit, 0, 80));
    settings.idle_ms = 1000 * jsonSetting(fields.get("idle_seconds"), settings.idle_ms / 1000, 1, 86400);
    settings.high_bytes = policy.mib * jsonSetting(fields.get("pressure_mib"), settings.high_bytes / policy.mib, 64, 32768);
    const default_target = @min(settings.target_bytes / policy.mib, settings.high_bytes / policy.mib - 1);
    settings.target_bytes = policy.mib * jsonSetting(fields.get("target_mib"), default_target, 1, settings.high_bytes / policy.mib - 1);
}
fn jsonSetting(field: ?std.json.Value, default: u64, min: u64, max: u64) u64 {
    const value = field orelse return default;
    if (value != .integer or value.integer < 0) return default;
    const parsed: u64 = @intCast(value.integer);
    return if (parsed >= min and parsed <= max) parsed else default;
}
fn tabSnapshot() ?plugins.Snapshot {
    if (count == 0) return null;
    return snapshotFor(&tabs[active]);
}
fn snapshotFor(tab: *const Tab) plugins.Snapshot {
    return .{
        .id = tab.id, .title = tab.title, .url = tab.url,
        .bookmarkable = tab.has_document and !tab.extension and !tab.loading,
        .navigation = tab.navigation,
    };
}
fn tabIndex(id: u64) ?usize {
    for (tabs[0..count], 0..) |tab, index| if (tab.id == id) return index;
    return null;
}
fn updateChrome(force_address: bool) void {
    if (count == 0 or stopped) return;
    const tab = &tabs[active];
    native.moon_shell_show_home(tab.phase == .blank and tab.opening == .none);
    native.moon_shell_address(&tab.url, force_address);
    native.moon_shell_status(if (tab.opening != .none) "Waiting for an available WebKit process..." else switch (tab.phase) {
        .blank => "Open a page from the address bar",
        .failed => if (error_text[0] != 0) &error_text else "Page load failed. Enter an address to try again.",
        .crashed => "This tab's web process stopped. Press F5 to recover the page.",
        .dormant, .restoring => "Restoring tab...",
        .live => "",
    });
    native.moon_shell_refresh();
}
fn openView(tab: *Tab) bool {
    if (tab.phase == .crashed and tab.view != null) detach(tab);
    if (tab.view != null) return true;
    const view = native.moon_engine_open(tab.id) orelse return false;
    tab.view = view;
    if (tab.muted) native.moon_engine_mute(view,true);
    tab.has_document = false;
    return true;
}
fn forgetSession(tab: *Tab) void {
    if (tab.session) |state| native.moon_engine_release_state(state);
    tab.session = null;
}
fn storeSession(tab: *Tab) void {
    if (tab.unsafe_history) return;
    if (tab.view) |view| {
        if (native.moon_engine_save(view)) |state| {
            forgetSession(tab);
            tab.session = state;
            snapshots_saved += 1;
            if (smoke != .off and tab.id == 1) log("snapshot tab=1 controls={d}", .{native.moon_engine_controls(view)});
        }
    }
}
fn detach(tab: *Tab) void {
    if (shortcut_capture) |capture| {
        if (capture.tab == tab.id) shortcut_capture = null;
    }
    site_data.invalidate(tab.id);
    page_source.invalidate(tab.id);
    popups.clear(tab.id);
    tab.document_committed = false;
    tab.navigation +%= 1;
    if (find_tab == tab.id) moon_find_dismiss(false);
    const view = tab.view orelse return;
    tab.view = null;
    tab.loaded = false;
    tab.history_visit = null;
    if (!stopped) watchRetirement(native.moon_engine_pid(view));
    native.moon_engine_close(view);
}
fn watchRetirement(pid: u32) void {
    if (pid == 0 or retiring_count == retiring.len) return;
    for (tabs[0..count]) |*other| {
        if (other.view) |view| if (native.moon_engine_pid(view) == pid) return;
    }
    for (retiring[0..retiring_count]) |watch| if (watch.pid == pid) return;
    const handle = native.moon_process_watch(pid) orelse return;
    retiring[retiring_count] = .{ .handle = handle, .pid = pid };
    retiring_count += 1;
}
fn collectRetirements() void {
    var remaining: usize = 0;
    for (retiring[0..retiring_count]) |watch| {
        if (native.moon_process_exited(watch.handle)) {
            native.moon_process_unwatch(watch.handle);
        } else {
            retiring[remaining] = watch;
            remaining += 1;
        }
    }
    retiring_count = remaining;
}
fn delayOpening(tab: *Tab, reason: Opening) bool {
    if (tab.view != null or (smoke == .warm_prepare or smoke == .warm) or (!pressure and retiring_count < 2)) return false;
    const now = native.moon_clock();
    if (tab.opening == .none) tab.requested_at = now;
    if (now -| tab.requested_at >= 5000) return false;
    var reclaimable = false;
    var loading_count: usize = 0;
    for (tabs[0..count]) |*other| {
        if (other == tab or other.view == null) continue;
        if (other.loading) loading_count += 1;
        if (other.phase == .live and !protected(other)) reclaimable = true;
    }
    if (retiring_count == 0 and !reclaimable and loading_count < 2) return false;
    tab.opening = reason;
    return true;
}
fn show(tab: *Tab) void {
    if (tab.view) |view| native.moon_engine_show(view, true);
}

fn loadInternal(tab: *Tab, address: [4096:0]u8, id: ?[:0]const u8, html: [*:0]const u8) void {
    if (tab.extension and !equals(slice(&tab.url),slice(&address))) {
        site_data.closed(tab.id);
        page_source.closed(tab.id);
    }
    detach(tab);
    forgetSession(tab);
    tab.extension = true;
    if (tab.pinned and pins_save_at==null) pins_save_at = native.moon_clock()+750;
    tab.unsafe_history = false;
    tab.opening = .none;
    tab.url = address;
    tab.title[0] = 0;
    tab.phase = .live;
    tab.loading = true;
    tab.deadline = 0;
    error_text[0] = 0;
    tab.view = native.moon_engine_open_extension(tab.id,if (id) |value| value.ptr else null,&address);
    if (tab.view) |view| {
        if (tab == &tabs[active]) show(tab);
        if (native.moon_engine_load_extension(view,html)) {
            updateChrome(true);
            return;
        }
        detach(tab);
    }
    tab.phase = .failed;
    tab.loading = false;
    _ = copy(&error_text,"无法打开内置页面。");
    updateChrome(true);
}

fn navigate(tab: *Tab, url: []const u8) void {
    var storage: [4096:0]u8 = @splat(0);
    if (!copy(&storage, url)) return;
    const allocator = std.heap.page_allocator;
    if (equals(url,plugin_manager.address)) {
        if (!native.moon_shell_private()) loadInternal(tab,storage,null,plugin_manager.document.ptr);
        return;
    }
    if (equals(url,market.address)) {
        if (native.moon_shell_private()) return;
        market.start();
        const html = market.document(allocator) catch return;
        defer allocator.free(html);
        loadInternal(tab,storage,null,html.ptr);
        return;
    }
    if (std.mem.startsWith(u8,url,"extension://")) {
        const html = allocator.alloc(u8,128*1024+1) catch return;
        defer allocator.free(html);
        const id = plugins.readSettingsPage(url,html) orelse {
            native.moon_shell_info("插件配置","此配置页不可用。请检查插件是否已启用及地址是否正确。");
            return;
        };
        loadInternal(tab,storage,id,@ptrCast(html.ptr));
        return;
    }
    if (!network.mayNavigate()) {
        native.moon_shell_info("请求过滤不可用","浏览器未发送这次导航。请修复规则文件，或在插件菜单暂停请求过滤。");
        return;
    }
    if (tab.extension) {
        site_data.closed(tab.id);
        page_source.closed(tab.id);
        detach(tab);
        tab.extension = false;
        tab.unsafe_history = false;
    }
    const already_queued = tab.opening == .navigate and equals(slice(&tab.url), url);
    if (delayOpening(tab, .navigate)) {
        tab.url = storage;
        tab.title[0] = 0;
        if (!already_queued) updateChrome(true);
        return;
    }
    tab.opening = .none;
    if (!openView(tab)) {
        tab.phase = .failed;
        _ = copy(&error_text, "Could not create a WebKit view or use this address.");
        updateChrome(false);
        return;
    }
    tab.url = storage;
    tab.title[0] = 0;
    tab.phase = .live;
    tab.loaded = false;
    tab.loading = true;
    tab.deadline = 0;
    error_text[0] = 0;
    if (&tabs[active] == tab) {
        updateChrome(true);
        show(tab);
    }
    if (!native.moon_engine_load(tab.view.?, &storage)) {
        tab.phase = .failed;
        tab.loading = false;
        updateChrome(false);
    }
}
fn restore(tab: *Tab) void {
    if (!network.mayNavigate()) return;
    if (tab.unsafe_history or !safeURL(slice(&tab.url))) {
        tab.phase = .crashed;
        return;
    }
    if (delayOpening(tab, .restore)) return;
    tab.restoring_history = tab.has_document;
    tab.opening = .none;
    if (tab.session) |session| {
        if (openView(tab)) {
            tab.phase = .restoring;
            tab.loaded = false;
            tab.loading = true;
            tab.deadline = native.moon_clock() + 8000;
            show(tab);
            if (native.moon_engine_restore(tab.view.?, session)) {
                if (smoke != .off and tab.id == 1) log("restoring tab=1 controls={d}", .{native.moon_engine_controls(tab.view.?)});
                return;
            }
        }
    }
    const url = tab.url;
    navigate(tab, slice(&url));
}
fn chooseTab(index: usize, notify: bool) void {
    if (index >= count or index == active) return;
    shortcut_capture = null;
    moon_find_dismiss(false);
    const now = native.moon_clock();
    tabs[active].last_used = now;
    if (tabs[active].view) |view| native.moon_engine_show(view, false);
    active = index;
    const tab = &tabs[index];
    tab.last_used = now;
    updateChrome(true);
    if (tab.phase == .dormant) restore(tab) else if (tab.phase != .crashed and tab.phase != .failed) show(tab);
    updateChrome(false);
    if (notify) plugins.changed(tabSnapshot());
}

fn readPinnedTabs() void {
    if (pins_path[0]==0) return;
    const allocator = std.heap.page_allocator;
    // JSON escaping can increase the size of the stored URL and title.
    const data = allocator.alloc(u8,max_pinned*(4096*2+512*6+32)+1) catch return;
    defer allocator.free(data);
    if (!native.moon_read_text(&pins_path,data.ptr,data.len)) return;
    const parsed = std.json.parseFromSlice([]PinnedEntry,allocator,slice(data),.{}) catch return;
    defer parsed.deinit();
    for (parsed.value[0..@min(parsed.value.len,max_pinned)]) |entry| {
        if (!history.validURL(entry.url)) continue;
        var tab: Tab = .{ .id=next_id, .phase=.dormant, .pinned=true, .has_document=true, .loaded=true, .last_used=native.moon_clock() };
        if (!copy(&tab.url,entry.url)) continue;
        _ = copy(&tab.title,entry.title);
        tabs[count] = tab;
        count += 1;
        next_id += 1;
    }
}

fn readCommittedAddress(tab: *const Tab, buffer: *[4096:0]u8) bool {
    if (tab.extension or !tab.has_document) return false;
    if (tab.view) |view| {
        native.moon_engine_committed_url(view,buffer,buffer.len);
    } else {
        buffer.* = tab.url;
    }
    return history.validURL(slice(buffer));
}

fn pinnedAddress(tab: *const Tab, buffer: *[4096:0]u8) ?[]const u8 {
    return if (!tab.unsafe_history and readCommittedAddress(tab,buffer)) slice(buffer) else null;
}

fn saveLastSession() void {
    const allocator = std.heap.page_allocator;
    const addresses = allocator.alloc([4096:0]u8,count) catch return;
    defer allocator.free(addresses);
    var entries: [max_tabs]last_session.Entry = undefined;
    var used: usize = 0;
    var selected: ?usize = null;
    for (tabs[0..count],0..) |*tab,index| {
        if (tab.pinned or tab.unsafe_history or tab.loading or tab.opening!=.none or
            (tab.phase!=.live and tab.phase!=.dormant) or !readCommittedAddress(tab,&addresses[used])) continue;
        const title = slice(&tab.title);
        entries[used] = .{ .title=if (std.unicode.utf8ValidateSlice(title)) title else "", .url=slice(&addresses[used]) };
        if (index==active) selected = used;
        used += 1;
    }
    _ = last_session.save(.{ .tabs=entries[0..used], .selected=selected });
}

fn resumeLastSession() sdk.SessionRestore {
    if (count==0 or !plugins.systemEnabled(.@"tabs.session.manage") or !network.mayNavigate()) return .unavailable;
    const saved = last_session.read() orelse return .empty;
    defer saved.deinit();
    const snapshot = saved.value;
    if (snapshot.tabs.len==0) return .empty;
    const current = &tabs[active];
    const reuse = active==count-1 and !current.pinned and current.phase==.blank and current.opening==.none and current.view==null;
    const start = if (reuse) active else count;
    if (snapshot.tabs.len > tabs.len-count+@intFromBool(reuse)) return .tabLimit;

    const append_from: usize = if (reuse) 1 else 0;
    const appended_at = count;
    const now = native.moon_clock();
    for (snapshot.tabs,0..) |saved_tab,offset| {
        const index = if (reuse and offset==0) start else appended_at+offset-append_from;
        var tab: Tab = .{ .id=next_id, .phase=.dormant, .has_document=true, .loaded=true, .last_used=now };
        _ = copy(&tab.url,saved_tab.url);
        _ = copy(&tab.title,saved_tab.title);
        tabs[index] = tab;
        next_id += 1;
    }
    count += snapshot.tabs.len-append_from;
    last_session.markRestored();
    const offset = snapshot.selected orelse 0;
    const target = if (reuse and offset==0) start else appended_at+offset-append_from;
    if (target==active) {
        updateChrome(true);
        restore(&tabs[target]);
        updateChrome(false);
        plugins.changed(tabSnapshot());
    } else {
        chooseTab(target,true);
    }
    return .restored;
}

export fn moon_session_restore(source: u64) c_int {
    if (stopped or count==0 or tabs[active].id!=source) return @intFromEnum(sdk.SessionRestore.unavailable);
    return @intFromEnum(resumeLastSession());
}

fn savePinnedTabs() bool {
    if (pins_path[0]==0) return false;
    var addresses: [max_pinned][4096:0]u8 = undefined;
    var entries: [max_pinned]PinnedEntry = undefined;
    var used: usize = 0;
    for (tabs[0..count]) |*tab| {
        if (!tab.pinned) break;
        const address = pinnedAddress(tab,&addresses[used]) orelse continue;
        entries[used] = .{ .url=address, .title=slice(&tab.title) };
        used += 1;
    }
    const allocator = std.heap.page_allocator;
    const bytes = std.json.Stringify.valueAlloc(allocator,entries[0..used],.{}) catch return false;
    defer allocator.free(bytes);
    const file = allocator.dupeSentinel(u8,bytes,0) catch return false;
    defer allocator.free(file);
    if (!native.moon_write_text(&pins_path,file.ptr)) return false;
    pins_save_at = null;
    return true;
}

fn moveTab(from: usize, to: usize) void {
    if (from==to) return;
    const active_id = tabs[active].id;
    const moved = tabs[from];
    if (from<to) {
        std.mem.copyForwards(Tab,tabs[from..to],tabs[from+1..to+1]);
    } else {
        std.mem.copyBackwards(Tab,tabs[to+1..from+1],tabs[to..from]);
    }
    tabs[to] = moved;
    active = tabIndex(active_id).?;
}

fn dropPosition(drop: *const native.MoonTabDrop) ?struct { from: usize, to: usize } {
    if (stopped or drop.source == drop.anchor) return null;
    const from = tabIndex(drop.source) orelse return null;
    const anchor = tabIndex(drop.anchor) orelse return null;
    if (tabs[from].pinned != tabs[anchor].pinned) return null;
    const to = if (drop.after) anchor+@intFromBool(from>anchor) else anchor-@intFromBool(from<anchor);
    return if (from==to) null else .{ .from=from, .to=to };
}

export fn moon_tab_drop_enabled() bool {
    return !stopped and count>1 and plugins.tabDropProvider()!=null;
}

export fn moon_tab_drop_valid(drop: *const native.MoonTabDrop) bool {
    return dropPosition(drop)!=null;
}

export fn moon_tab_drop_run(drop: *const native.MoonTabDrop) void {
    const position = dropPosition(drop) orelse return;
    if (!plugins.tabDropCommand(drop.*,snapshotFor(&tabs[position.from])))
        native.moon_shell_toast("标签管理","排序插件暂不可用，请重试。");
}

export fn moon_tab_nudge(down: bool) void {
    if (!moon_tab_drop_enabled()) return;
    if ((down and active+1==count) or (!down and active==0)) return;
    const anchor = if (down) active+1 else active-1;
    moon_tab_drop_run(&.{ .source=tabs[active].id,.anchor=tabs[anchor].id,.after=down });
}

export fn moon_tabs_reorder(drop: *const native.MoonTabDrop) c_int {
    const position = dropPosition(drop) orelse return @intFromEnum(sdk.TabReorder.unavailable);
    const pinned = tabs[position.from].pinned;
    moveTab(position.from,position.to);
    if (pinned and !savePinnedTabs()) {
        moveTab(position.to,position.from);
        return @intFromEnum(sdk.TabReorder.saveFailed);
    }
    native.moon_shell_refresh_tab_order(tabs[active].id==drop.source);
    return @intFromEnum(sdk.TabReorder.moved);
}

fn pinnedCount() usize {
    for (tabs[0..count],0..) |*entry,position| if (!entry.pinned) return position;
    return count;
}

export fn moon_tabs_organize(id: u64, operation: c_int) c_int {
    const action = std.enums.fromInt(sdk.TabOperation,operation) orelse return @intFromEnum(sdk.TabOrganization.unavailable);
    return @intFromEnum(organizeTab(id,action));
}

fn organizeTab(id: u64, action: sdk.TabOperation) sdk.TabOrganization {
    if (stopped) return .unavailable;
    const index = tabIndex(id) orelse return .unavailable;
    const tab = &tabs[index];
    if (action==.copyAddress) {
        var address: [4096:0]u8 = undefined;
        if (!readCommittedAddress(tab,&address)) return .unavailable;
        return if (native.moon_shell_copy_text(&address)) .copied else .clipboardBusy;
    }
    if (action==.duplicate) return duplicateTab(index);
    if (action==.mute) {
        if (!tab.muted and (tab.extension or !safeURL(slice(&tab.url)))) return .unavailable;
        tab.muted = !tab.muted;
        if (tab.view) |view| {
            if (!tab.extension) native.moon_engine_mute(view,tab.muted);
        }
        native.moon_shell_refresh();
        return if (tab.muted) .muted else .unmuted;
    }
    if (native.moon_shell_private()) return .unavailable;
    const was_pinned = tab.pinned;
    const pinned_count = pinnedCount();
    if (!was_pinned) {
        var buffer: [4096:0]u8 = undefined;
        if (tab.loading or pinnedAddress(tab,&buffer)==null) return .unavailable;
        if (pinned_count==max_pinned) return .limitReached;
    }
    tab.pinned = !was_pinned;
    const destination = if (was_pinned) pinned_count-1 else pinned_count;
    moveTab(index,destination);
    if (!savePinnedTabs()) {
        moveTab(destination,index);
        tabs[index].pinned = was_pinned;
        return .saveFailed;
    }
    native.moon_shell_refresh();
    return if (was_pinned) .unpinned else .pinned;
}

fn canDuplicate(tab: *const Tab) bool {
    return tab.has_document and !tab.extension and !tab.unsafe_history and !tab.dirty and
        !tab.loading and tab.opening==.none and tab.download_count==0 and
        (tab.phase==.dormant or (tab.phase==.live and tab.loaded));
}

fn duplicateTab(index: usize) sdk.TabOrganization {
    const source = &tabs[index];
    var address: [4096:0]u8 = undefined;
    if (!canDuplicate(source) or !readCommittedAddress(source,&address) or !network.mayNavigate()) return .unavailable;
    if (count==tabs.len) return .limitReached;
    const session = if (source.view) |view| native.moon_engine_save(view)
        else native.moon_engine_retain_state(source.session);
    const destination = if (source.pinned) pinnedCount() else index+1;
    if (destination<count) std.mem.copyBackwards(Tab,tabs[destination+1..count+1],tabs[destination..count]);
    if (active>=destination) active += 1;
    tabs[destination] = .{
        .id=next_id, .phase=.dormant, .url=address, .title=source.title,
        .session=session, .muted=source.muted, .has_document=true, .loaded=true,
        .last_used=native.moon_clock(),
    };
    count += 1;
    next_id += 1;
    chooseTab(destination,true);
    return .duplicated;
}

fn checkTabToolsGrant() void {
    if (plugins.systemEnabled(.@"tabs.organize")) return;
    for (tabs[0..count]) |*tab| {
        if (!tab.muted) continue;
        tab.muted = false;
        if (tab.view) |view| {
            if (!tab.extension) native.moon_engine_mute(view,false);
        }
    }
}
fn addTab(url: ?[]const u8, notify: bool) void {
    if (count == tabs.len) {
        if (smoke == .off) native.moon_shell_info("Tab limit", "This preview supports up to 128 open tabs.");
        return;
    }
    const index = count;
    const now = native.moon_clock();
    tabs[index] = .{ .id = next_id, .last_used = now };
    next_id += 1;
    count += 1;
    if (index != 0) chooseTab(index, false);
    if (url) |value| navigate(&tabs[index], value) else {
        updateChrome(true);
        native.moon_shell_focus_address();
    }
    if (notify) plugins.changed(tabSnapshot());
}
fn closeTab(index: usize) void {
    if (index >= count) return;
    site_data.closed(tabs[index].id);
    page_source.closed(tabs[index].id);
    const was_active = index == active;
    const was_pinned = tabs[index].pinned;
    rememberClosedTab(&tabs[index]);
    detach(&tabs[index]);
    forgetSession(&tabs[index]);
    count -= 1;
    if (index < count) std.mem.copyForwards(Tab, tabs[index..count], tabs[index + 1 .. count + 1]);
    if (was_pinned and !savePinnedTabs()) pins_save_at = native.moon_clock()+2000;
    if (count == 0) {
        active = 0;
        addTab(null, true);
        return;
    }
    if (active > index) active -= 1;
    if (active >= count) active = count - 1;
    if (was_active) {
        if (tabs[active].phase == .dormant) restore(&tabs[active]) else if (tabs[active].phase != .crashed and tabs[active].phase != .failed) show(&tabs[active]);
        tabs[active].last_used = native.moon_clock();
        plugins.changed(tabSnapshot());
    }
    updateChrome(was_active);
}

fn canCloseInGroup(tab: *const Tab) bool {
    if (tab.pinned or tab.opening!=.none) return false;
    if (tab.phase==.blank and tab.view==null) return true;
    if (tab.phase!=.live and tab.phase!=.dormant) return false;
    if (tabProtection(tab)) |reason| {
        if (reason!=.loading or tab.phase!=.dormant or tab.loading or !tab.has_document) return false;
    }
    if (tab.view) |view| return !native.moon_engine_media(view);
    return true;
}

export fn moon_tabs_close_group(id: u64, below: bool, result: *native.MoonTabCloseResult) bool {
    if (stopped) return false;
    const target = tabIndex(id) orelse return false;
    const start = if (below) target+1 else 0;
    var selected: [max_tabs]bool = @splat(false);
    result.* = .{ .closed=0, .kept=0 };
    for (tabs[start..count],start..) |*tab,index| {
        if (index==target) continue;
        if (canCloseInGroup(tab)) selected[index] = true else result.kept += 1;
    }
    if (selected[active]) chooseTab(target,true);
    var index = count;
    while (index>start) {
        index -= 1;
        if (!selected[index]) continue;
        if (!canCloseInGroup(&tabs[index])) {
            result.kept += 1;
            continue;
        }
        closeTab(index);
        result.closed += 1;
    }
    return true;
}
fn rememberClosedTab(tab: *Tab) void {
    if (!plugins.systemEnabled(.@"tabs.closed.manage") or tab.extension or !tab.has_document or
        tab.dirty or tab.unsafe_history or tab.loading or tab.opening != .none or tab.download_count != 0 or
        !history.validURL(slice(&tab.url))) return;
    switch (tab.phase) {
        .live => {
            const view = tab.view orelse return;
            if (!tab.loaded or native.moon_engine_media(view)) return;
            forgetSession(tab);
            storeSession(tab);
        },
        .dormant => {},
        else => return,
    }
    recent_tabs.record(.{ .title=tab.title,.url=tab.url,.state=tab.session });
    tab.session = null;
}

export fn moon_recent_reopen(source: u64, specific: bool, entry_id: u32) c_int {
    if (stopped or count == 0 or tabs[active].id != source or !network.mayNavigate())
        return @intFromEnum(sdk.ReopenClosedTab.unavailable);
    const current = &tabs[active];
    const reuse = current.phase == .blank and current.opening == .none and current.view == null;
    if (!reuse and count == tabs.len) return @intFromEnum(sdk.ReopenClosedTab.tabLimit);
    const entry = recent_tabs.take(if (specific) entry_id else null) orelse return @intFromEnum(sdk.ReopenClosedTab.notFound);
    const index = if (reuse) active else count;
    tabs[index] = .{
        .id=next_id,.phase=.dormant,.url=entry.url,.title=entry.title,.session=entry.state,
        .last_used=native.moon_clock(),
    };
    next_id += 1;
    if (reuse) {
        updateChrome(true);
        restore(&tabs[index]);
        updateChrome(false);
        plugins.changed(tabSnapshot());
    } else {
        count += 1;
        chooseTab(index,true);
    }
    return @intFromEnum(sdk.ReopenClosedTab.reopened);
}

fn checkClosedTabGrant() void {
    if (!plugins.systemEnabled(.@"tabs.closed.manage")) recent_tabs.clear();
}

fn sync(tab: *Tab) void {
    const view = tab.view orelse return;
    var url: [4096:0]u8 = @splat(0);
    var title: [512:0]u8 = @splat(0);
    native.moon_engine_read(view, &title, title.len, &url, url.len);
    if (!tab.extension and url[0] != 0 and !equals(slice(&url), "about:blank")) tab.url = url;
    if (title[0] != 0 and !equals(slice(&tab.title),slice(&title))) {
        tab.title = title;
        if (tab.history_visit) |visit| {
            if (plugins.systemEnabled(.@"history.manage")) history.updateTitle(visit,slice(&tab.url),slice(&title));
        }
    }
}
fn tabProtection(tab: *const Tab) ?sdk.TaskProtection {
    if (count != 0 and site_data.protected(tab.id,tabs[active].id)) return .siteInspection;
    if (tab.view) |view| if (native.moon_engine_inspecting(view)) return .developerTools;
    if (tab.download_count != 0) return .download;
    if (tab.activity) return .media;
    if (tab.unsafe_history) return .nonGet;
    if (tab.dirty) return .input;
    if (tab.loading or !tab.loaded) return .loading;
    if (!safeURL(slice(&tab.url))) return .internal;
    return null;
}
fn protected(tab: *const Tab) bool {
    return tabProtection(tab) != null;
}
export fn moon_userscript_reload_active(id: [*c]const u8) c_int {
    if (stopped or count == 0) return native.MOON_RELOAD_NO_MATCH;
    const tab = &tabs[active];
    const view = tab.view orelse return native.MOON_RELOAD_NO_MATCH;
    var address: [4096:0]u8 = @splat(0);
    native.moon_engine_committed_url(view,&address,address.len);
    if (!userscripts.matchesEnabled(slice(id),slice(&address))) return native.MOON_RELOAD_NO_MATCH;
    if (protected(tab) or native.moon_engine_media(view)) return native.MOON_RELOAD_PROTECTED;
    native.moon_engine_reload(view);
    return native.MOON_RELOAD_OK;
}
fn devtoolsTarget(tab_id: u64, navigation: u64) ?*native.MoonView {
    if (stopped or count==0) return null;
    const tab = &tabs[active];
    if (tab.id!=tab_id or tab.navigation!=navigation or !hasSite(tab)) return null;
    return tab.view;
}
export fn moon_devtools_open(panel: c_int, independent: bool, tab_id: u64, navigation: u64) bool {
    const view = devtoolsTarget(tab_id,navigation) orelse return false;
    return native.moon_engine_inspect(view,panel,independent);
}
export fn moon_devtools_toggle(tab_id: u64, navigation: u64) c_int {
    const view = devtoolsTarget(tab_id,navigation) orelse return -1;
    if (native.moon_engine_close_inspector(view)) return 0;
    return if (native.moon_engine_inspect(view,@intFromEnum(sdk.InspectorPanel.inspector),false)) 1 else -1;
}
export fn moon_devtools_cancel_picker() bool {
    if (stopped or count==0) return false;
    const view = tabs[active].view orelse return false;
    return native.moon_engine_cancel_pick(view);
}
fn sampleMemory() u64 {
    process_count = native.moon_memory_samples(&process_samples[0],process_samples.len);
    var present: [process_samples.len]policy.Sample = undefined;
    for (process_samples[0..process_count],0..) |sample,index| present[index] = .{ .pid=sample.pid,.bytes=sample.bytes };
    return policy.totalCommit(present[0..process_count]);
}
fn stateCounts() struct { live: usize = 0, sleep: usize = 0, protected: usize = 0 } {
    var result: @typeInfo(@TypeOf(stateCounts)).@"fn".return_type.? = .{};
    for (tabs[0..count], 0..) |*tab, index| {
        if (tab.phase == .dormant) result.sleep += 1;
        if (tab.view != null) {
            result.live += 1;
            if (index == active or protected(tab)) result.protected += 1;
        }
    }
    return result;
}
fn manage(now: u64) void {
    if (sampled == 0 or now - sampled >= (if (pressure) @as(u64, 350) else 1000)) {
        const low = native.moon_low_memory();
        commit = sampleMemory();
        peak_commit = @max(peak_commit, commit);
        sampled = now;
        pressure = policy.underPressure(pressure, commit, low, settings);
        if (pressure and now -| last_trim >= 2500) {
            native.moon_engine_trim();
            last_trim = now;
        }
        if (settle_at != 0 and now >= settle_at) {
            last_after = commit;
            settle_at = 0;
        }
    }
    if (now < next_evict) return;
    var candidates: [max_tabs]policy.Tab = undefined;
    for (tabs[0..count], 0..) |*tab, index| {
        const live = tab.phase == .live and tab.view != null;
        if (live) tab.activity = native.moon_engine_media(tab.view.?);
        candidates[index] = .{ .live = live, .protected = protected(tab), .last_used = tab.last_used, .pid = if (live) native.moon_engine_pid(tab.view.?) else 0 };
    }
    if (policy.choose(candidates[0..count], active, now, pressure, settings)) |index| {
        discardTab(&tabs[index],candidates[index].pid,now);
    }
}
fn discardTab(tab: *Tab, pid: u32, now: u64) void {
    if (settle_at == 0) last_before = commit;
    settle_at = now + 500;
    storeSession(tab);
    tab.phase = .dormant;
    detach(tab);
    evictions += 1;
    next_evict = now + (if (pressure) @as(u64,350) else 150);
    if (smoke != .off) log("evict tab={d} pid={d} pressure={d} commit={d}", .{
        tab.id,pid,@intFromBool(pressure),commit,
    });
    native.moon_shell_refresh();
}
fn maintenance() void {
    const now = native.moon_clock();
    if (smoke == .off and !native.moon_shell_private()) updater.tick(now);
    if (stopped) return;
    if (pins_save_at) |save_at| {
        if (now>=save_at and !savePinnedTabs()) pins_save_at = now+5000;
    }
    native.moon_engine_update_inspectors();
    downloads.flush();
    site_data.tick(now);
    page_source.tick(now);
    if (page_save_job) |job| if (now>=job.deadline) {
        page_save_job = null;
        native.moon_shell_toast("网页另存为","读取网页超时。请重试。");
    };
    if (market.changed()) {
        const allocator = std.heap.page_allocator;
        if (market.document(allocator)) |html| {
            defer allocator.free(html);
            for (tabs[0..count]) |*tab| {
                if (tab.extension and equals(slice(&tab.url),market.address)) {
                    if (tab.view) |view| _ = native.moon_engine_load_extension(view,html.ptr);
                }
            }
        } else |_| {}
    }
    collectRetirements();
    if (popup[0] != 0) {
        const target = popup;
        popup[0] = 0;
        if (equals(slice(&target),plugin_manager.address)) {
            if (!native.moon_shell_private()) _ = openInternalPage(plugin_manager.address);
        } else addTab(slice(&target), smoke == .off);
    }
    for (tabs[0..count]) |*tab| {
        if (tab.phase == .crashed) detach(tab);
        if (tab.phase == .restoring and now >= tab.deadline) {
            if (smoke != .off and tab.id == 1) log("session_fallback tab=1", .{});
            const url = tab.url;
            detach(tab);
            forgetSession(tab);
            navigate(tab, slice(&url));
        }
    }
    if (count != 0 and smoke != .warm_prepare and smoke != .warm) manage(now);
    if (count != 0) {
        const tab = &tabs[active];
        if (tab.opening == .restore) restore(tab);
        if (tab.opening == .navigate) {
            const url = tab.url;
            navigate(tab, slice(&url));
        }
    }
    plugins.tick(tabSnapshot(), smoke != .off);
    if (smoke != .off) smokeTick(now);
}
export fn moon_tasks_overview(output: *native.MoonTaskOverview) void {
    const counts = stateCounts();
    output.* = .{
        .private_bytes=commit,.peak_bytes=peak_commit,.high_bytes=settings.high_bytes,.target_bytes=settings.target_bytes,
        .before_bytes=last_before,.after_bytes=last_after,.pressure=pressure,.has_sweep=evictions!=0,.sweep_pending=settle_at!=0,
        .open=@intCast(count),.live=@intCast(counts.live),.dormant=@intCast(counts.sleep),.protected_tabs=@intCast(counts.protected),
        .processes=@intCast(process_count),.retiring=@intCast(retiring_count),.evictions=@intCast(@min(evictions,std.math.maxInt(u32))),
        .warm_limit=@intCast(settings.warm_limit),.idle_seconds=@intCast(settings.idle_ms/1000),
    };
}
export fn moon_tasks_tabs(offset: u32, rows: [*]native.MoonTaskTab, cap: usize) usize {
    const width = @min(cap,count -| offset);
    for (rows[0..width],0..) |*row,i| {
        const index = offset+i;
        const tab = &tabs[index];
        const protection: ?sdk.TaskProtection = if (index==active) .current else if (tab.phase==.live and tab.view!=null) tabProtection(tab) else null;
        row.* = .{
            .id=tab.id,.phase=@intFromEnum(tab.phase),.pid=if (tab.view) |view| native.moon_engine_pid(view) else 0,
            .protection=if (protection) |reason| @intCast(@intFromEnum(reason)) else -1,.title=@splat(0),
        };
        const title = slice(&tab.title);
        var end = @min(title.len,row.title.len-1);
        while (end != 0 and end < title.len and title[end] & 0xc0 == 0x80) end -= 1;
        if (end != 0 and std.unicode.utf8ValidateSlice(title[0..end])) @memcpy(row.title[0..end],title[0..end]);
    }
    return width;
}
export fn moon_tasks_processes(offset: u32, rows: [*]native.MoonTaskProcess, cap: usize) usize {
    const width = @min(cap,process_count -| offset);
    var pids: [max_tabs]u32 = undefined;
    for (tabs[0..count],0..) |tab,i| pids[i] = if (tab.view) |view| native.moon_engine_pid(view) else 0;
    for (rows[0..width],0..) |*row,i| {
        const sample = process_samples[offset+i];
        row.* = .{
            .private_bytes=sample.bytes,.pid=sample.pid,.browser=sample.pid==native.moon_current_pid(),
            .tabs=@intCast(std.mem.countScalar(u32,pids[0..count],sample.pid)),
        };
    }
    return width;
}
export fn moon_tasks_action(source: u64, id: u64, discard: bool) c_uint {
    if (stopped or count==0 or tabs[active].id!=source) return @intFromEnum(sdk.TaskAction.unavailable);
    const index = tabIndex(id) orelse return @intFromEnum(sdk.TaskAction.notFound);
    if (!discard) {
        chooseTab(index,true);
        return @intFromEnum(sdk.TaskAction.done);
    }
    const tab = &tabs[index];
    if (index==active) return @intFromEnum(sdk.TaskAction.protected);
    if (tab.phase!=.live or tab.view==null) return @intFromEnum(sdk.TaskAction.unavailable);
    if (protected(tab) or native.moon_engine_media(tab.view.?)) return @intFromEnum(sdk.TaskAction.protected);
    discardTab(tab,native.moon_engine_pid(tab.view.?),native.moon_clock());
    return @intFromEnum(sdk.TaskAction.done);
}

export fn moon_start(argc: c_int, argv: [*c]const [*c]const u16) bool {
    const allocator = std.heap.page_allocator;
    const app = slice(native.moon_app_dir());
    const profile = slice(native.moon_profile_dir());
    const private = native.moon_shell_private();
    if (!private) {
        updater.configure(app, native.moon_clock());
        applySettings(profile);
        history.init(profile);
        bookmarks.init(profile);
        downloads.init(profile);
        reading.init(profile);
        popups.init(profile);
        userscripts.init(profile);
        search.init();
    }
    plugins.init(app, profile);
    var first_url: ?[:0]u8 = null;
    defer if (first_url) |allocated| allocator.free(allocated);
    var index: usize = 1;
    while (index < @as(usize, @intCast(@max(0, argc)))) : (index += 1) {
        const argument = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.sliceTo(argv[index], 0)) catch return false;
        defer allocator.free(argument);
        if (equals(argument, "--gdi")) {
            native.moon_engine_test_fallback(true);
        } else if (private and std.mem.startsWith(u8,argument,"-")) {
            continue;
        } else if (equals(argument, "--relhub-probe") and index + 3 < @as(usize, @intCast(argc))) {
            const report = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.sliceTo(argv[index + 1], 0)) catch return false;
            defer allocator.free(report);
            const mode = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.sliceTo(argv[index + 2], 0)) catch return false;
            defer allocator.free(mode);
            const raw_code = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.sliceTo(argv[index + 3], 0)) catch return false;
            defer allocator.free(raw_code);
            const code = std.fmt.parseUnsigned(u64, raw_code, 10) catch return false;
            if (!updater.configureProbe(report, mode, code)) return false;
            addTab(null, false);
            return true;
        } else if (equals(argument, "--smoke-quick")) {
            smoke_quick = true;
        } else if (equals(argument, "--smoke") and index + 2 < @as(usize, @intCast(argc))) {
            const base = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.sliceTo(argv[index + 1], 0)) catch return false;
            defer allocator.free(base);
            const report = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.sliceTo(argv[index + 2], 0)) catch return false;
            defer allocator.free(report);
            if (!std.mem.startsWith(u8, base, "http://127.0.0.1:") or !copy(&smoke_base, base) or
                !copy(&smoke_log, report)) return false;
            smoke = .first;
            index += 2;
        } else if (first_url == null and !std.mem.startsWith(u8, argument, "-")) {
            first_url = allocator.dupeSentinel(u8, argument, 0) catch return false;
        }
    }
    log("window_ms={d}", .{native.moon_clock() -| boot});
    if (smoke != .off) {
        const tested_dpi = native.moon_shell_test_dpi();
        if (tested_dpi == 0) {
            log("FAIL DPI relayout", .{});
            return false;
        }
        log("dpi_reflow=ok simulated_dpi={d}", .{tested_dpi});
    }
    if (native.moon_engine_init()) |engine_error| {
        if (smoke != .off) {
            log("FAIL engine: {s}", .{slice(engine_error)});
        } else native.moon_shell_error(engine_error);
        return false;
    }
    network.select(plugins.networkSource());
    if (smoke==.off and !private) {
        last_session.init(profile);
        if (std.fmt.bufPrintSentinel(&pins_path,"{s}\\pinned-tabs.json",.{profile},0)) |_|
            readPinnedTabs()
        else |_| pins_path[0] = 0;
    }
    addTab(null, false);
    if (smoke != .off) {
        smoke_deadline = native.moon_clock() + 300000;
        _ = std.fmt.bufPrintSentinel(&smoke_download, "{s}\\smoke-download.txt", .{profile}, 0) catch return false;
        smokeNavigate(&tabs[0], "/page/initial");
    } else if (first_url) |initial| {
        var buffer: [4096]u8 = undefined;
        if (normalize(initial, &buffer)) |url| navigate(&tabs[active], url);
    } else if (last_session.automatic()) {
        _ = resumeLastSession();
    }
    return true;
}
export fn moon_command(command: c_int, argument: u64, c_text: [*c]const u8) void {
    if (stopped) return;
    if (command == native.MOON_SHUTDOWN) {
        if (pins_save_at!=null) _ = savePinnedTabs();
        if (argument==0 and smoke==.off and plugins.systemEnabled(.@"tabs.session.manage")) saveLastSession();
        stopped = true;
        history.close();
        bookmarks.close();
        downloads.close();
        reading.close();
        recent_tabs.clear();
        site_data.reset();
        page_source.reset();
        for (tabs[0..count]) |*tab| {
            detach(tab);
            forgetSession(tab);
        }
        for (retiring[0..retiring_count]) |watch| native.moon_process_unwatch(watch.handle);
        retiring_count = 0;
        native.moon_engine_shutdown();
        return;
    }
    if (count == 0) return;
    const index: usize = @intCast(argument);
    const tab = &tabs[active];
    switch (command) {
        native.MOON_NEW => addTab(null, true),
        native.MOON_CLOSE => closeTab(index),
        native.MOON_SELECT => chooseTab(index, true),
        native.MOON_TAB_PIN, native.MOON_TAB_MUTE, native.MOON_TAB_DUPLICATE, native.MOON_TAB_COPY_ADDRESS,
        native.MOON_TAB_CLOSE_OTHERS, native.MOON_TAB_CLOSE_BELOW => {
            const permission: sdk.Permission = if (command==native.MOON_TAB_PIN or command==native.MOON_TAB_MUTE)
                .@"tabs.organize" else .@"tabs.manage";
            if (!plugins.systemEnabled(permission)) return;
            const target = tabIndex(argument) orelse return;
            const action: []const u8 = switch (command) {
                native.MOON_TAB_PIN => "pin",
                native.MOON_TAB_MUTE => "mute",
                native.MOON_TAB_DUPLICATE => "duplicate",
                native.MOON_TAB_COPY_ADDRESS => "copyAddress",
                native.MOON_TAB_CLOSE_OTHERS => "closeOthers",
                native.MOON_TAB_CLOSE_BELOW => "closeBelow",
                else => unreachable,
            };
            _ = plugins.namedCommand("moon.tab-tools",action,snapshotFor(&tabs[target]));
        },
        native.MOON_TAB_CLOSE_TARGET => closeTab(tabIndex(argument) orelse return),
        native.MOON_KEY_NEXT => chooseTab((active + 1) % count, true),
        native.MOON_KEY_PREV => chooseTab((active + count - 1) % count, true),
        native.MOON_ADDRESS => {
            tab.restoring_history = false;
            var buffer: [4096]u8 = undefined;
            if (normalize(slice(c_text), &buffer)) |url| {
                navigate(tab, url);
            } else native.moon_shell_info("Address", "Enter a valid HTTP or HTTPS address.");
        },
        native.MOON_BACK => if (tab.view) |view| native.moon_engine_back(view),
        native.MOON_FORWARD => if (tab.view) |view| native.moon_engine_forward(view),
        native.MOON_RELOAD => {
            if (tab.extension) {
                const url = tab.url;
                navigate(tab,slice(&url));
            } else if (tab.phase == .crashed or tab.phase == .dormant) {
                restore(tab);
            } else if (tab.view) |view| native.moon_engine_reload(view);
            updateChrome(false);
        },
        native.MOON_INPUT => if (tab.view != null) {
            tab.dirty = true;
        },
        native.MOON_DIAGNOSTICS => if (!plugins.namedCommand("moon.task-manager","open",tabSnapshot()))
            native.moon_shell_toast("内存诊断","请在插件菜单启用浏览器任务管理器。"),
        native.MOON_TICK => maintenance(),
        native.MOON_PLUGIN_ENABLE => {
            if (native.moon_shell_private()) return;
            if (changePlugin(index,null)==.unavailable)
                native.moon_shell_info("插件设置","无法保存插件设置。");
        },
        native.MOON_PLUGIN_GRANT => {
            if (native.moon_shell_private()) return;
            const permission = std.enums.fromInt(sdk.Permission,index & 0xffffffff) orelse return;
            if (changePlugin(index >> 32,permission)==.unavailable)
                native.moon_shell_info("插件设置","无法保存插件设置。");
        },
        native.MOON_PLUGIN_SETTINGS => {
            var address: [256]u8 = undefined;
            if (plugins.settingsAddress(index,&address)) |url| _ = openInternalPage(url);
        },
        native.MOON_PLUGIN_COMMAND => plugins.command(index >> 32, index & 0xffffffff, tabSnapshot()),
        native.MOON_FOCUS_ADDRESS => native.moon_shell_focus_address(),
        native.MOON_TOGGLE_SIDEBAR => native.moon_shell_toggle_sidebar(),
        native.MOON_TOGGLE_THEME => native.moon_shell_toggle_theme(),
        native.MOON_OPEN_PLUGINS => if (!native.moon_shell_private()) { _ = openInternalPage(plugin_manager.address); },
        native.MOON_UPDATES => if (!native.moon_shell_private()) updater.open(native.moon_clock()),
        native.MOON_MARKET => if (!native.moon_shell_private()) { _ = openInternalPage(market.address); },
        native.MOON_SCRIPTS_INSTALL => if (!native.moon_shell_private()) userscripts.install(slice(c_text)),
        native.MOON_SCRIPTS_TOGGLE => if (!native.moon_shell_private()) userscripts.toggle(index),
        native.MOON_SCRIPTS_REMOVE => if (!native.moon_shell_private()) userscripts.remove(index),
        else => {},
    }
}
export fn moon_engine_event(kind: c_int, id: u64, detail: [*c]const u8) void {
    if (stopped) return;
    const index = tabIndex(id) orelse return;
    const tab = &tabs[index];
    switch (kind) {
        native.MOON_STARTED => {
            site_data.invalidate(id);
            page_source.invalidate(id);
            popups.invalidate(id);
            tab.document_committed = false;
            tab.navigation +%= 1;
            if (find_tab == id) moon_find_dismiss(true);
            tab.loading = true;
            tab.loaded = false;
            tab.history_visit = null;
        },
        native.MOON_COMMITTED => {
            page_source.invalidate(id);
            tab.document_committed = true;
            tab.dirty = false;
            tab.has_document = true;
            tab.deadline = 0;
            tab.phase = .live;
            sync(tab);
            if (tab.view) |view| {
                var url: [4096:0]u8 = @splat(0);
                if (!native.moon_shell_private()) {
                    const percent = if (zoomOrigin(tab,&url)) |key| reading.load(key) else 100;
                    native.moon_engine_set_zoom(view,percent);
                }
            }
        },
        native.MOON_FINISHED => {
            tab.loading = false;
            tab.loaded = true;
            tab.phase = .live;
            tab.deadline = 0;
            sync(tab);
            if (!tab.extension) {
                if (!tab.restoring_history and plugins.systemEnabled(.@"history.manage")) tab.history_visit = history.record(slice(&tab.url),slice(&tab.title));
                tab.restoring_history = false;
                storeSession(tab);
                if (tab.view) |view| userscripts.apply(view);
            }
        },
        native.MOON_FAILED => {
            const message = if (detail != null) slice(detail) else "";
            if (smoke != .off and tab.id == 1) log("navigation_failure stage={s} phase={s} detail={s}", .{ @tagName(smoke), @tagName(tab.phase), message });
            if (index == active) _ = copy(&error_text, message);
            tab.loading = false;
            tab.loaded = tab.has_document;
            if (tab.phase == .restoring) {
                tab.deadline = 1;
            } else if (tab.phase != .crashed and !tab.has_document and tab.download_count == 0) {
                tab.phase = .failed;
                if (tab.view) |view| native.moon_engine_show(view, false);
            }
        },
        native.MOON_CHANGED => sync(tab),
        native.MOON_SAME_DOCUMENT => {
            site_data.invalidate(id);
            page_source.invalidate(id);
            tab.navigation +%= 1;
            sync(tab);
            if (!tab.extension and !tab.restoring_history and plugins.systemEnabled(.@"history.manage")) tab.history_visit = history.record(slice(&tab.url),slice(&tab.title));
        },
        native.MOON_TERMINATED => {
            site_data.closed(id);
            page_source.closed(id);
            popups.clear(id);
            tab.document_committed = false;
            tab.navigation +%= 1;
            if (find_tab == id) {
                find_tab = 0;
                find_owner[0] = 0;
                if (native.moon_shell_find_hide()) native.moon_shell_focus_address();
            }
            tab.phase = .crashed;
            tab.loading = false;
            tab.loaded = false;
            if (tab.view) |view| native.moon_engine_show(view, false);
            if (smoke != .off) log("process_terminated tab={d}", .{id});
        },
        native.MOON_UNSAFE => {
            tab.unsafe_history = true;
            forgetSession(tab);
        },
        native.MOON_DOWNLOAD_START => {
            tab.download_count += 1;
        },
        native.MOON_DOWNLOAD_END => {
            tab.download_count -|= 1;
            if (detail != null and index == active and smoke == .off and !plugins.systemEnabled(.@"downloads.manage"))
                native.moon_shell_toast("下载", detail);
        },
        native.MOON_POPUP => if (detail != null and popup[0] == 0) {
            _ = copy(&popup, slice(detail));
        },
        native.MOON_PAINTED => {
            if (index == active and smoke != .off and !smoke_painted) {
                smoke_painted = true;
                if (smoke == .first)
                    log("first_page_paint_ms={d} signal={s}", .{ native.moon_clock() -| smoke_started, if (detail != null) slice(detail) else "unknown" });
                if (smoke == .warm and warm_count < warm_samples.len) {
                    warm_samples[warm_count] = native.moon_perf_us() -| warm_started_us;
                    warm_count += 1;
                }
            }
        },
        else => {},
    }
    if (tab.pinned and pins_save_at==null) switch (kind) {
        native.MOON_COMMITTED, native.MOON_FINISHED, native.MOON_SAME_DOCUMENT, native.MOON_UNSAFE =>
            pins_save_at = native.moon_clock()+750,
        else => {},
    };
    if (index == active) updateChrome(false) else native.moon_shell_refresh();
}
export fn moon_download_begin() u32 {
    if (stopped or !plugins.systemEnabled(.@"downloads.manage")) return 0;
    return downloads.begin();
}
export fn moon_download_destination(id: u32, path: [*c]const u8) void {
    if (!stopped) downloads.destination(id,slice(path));
}
export fn moon_download_progress(id: u32, chunk: u64, total: u64) void {
    if (!stopped) downloads.progress(id,chunk,total);
}
export fn moon_download_finish(id: u32, result: c_int) void {
    if (stopped) return;
    const state: sdk.DownloadState = switch (result) {
        native.MOON_DL_COMPLETE => .complete,
        native.MOON_DL_FAILED => .failed,
        native.MOON_DL_CANCELLED => .cancelled,
        else => .interrupted,
    };
    downloads.finish(id,state);
    if (smoke == .off and plugins.systemEnabled(.@"downloads.manage")) {
        native.moon_shell_toast("下载",switch (state) {
            .complete => "下载已完成，可在下载页查看。",
            .failed => "下载失败，可在下载页查看。",
            .cancelled => "下载已取消。",
            .interrupted => "下载已中断。",
            else => unreachable,
        });
    }
}
export fn moon_tab_count() usize {
    return count;
}
export fn moon_active_index() usize {
    return active;
}
export fn moon_tab_label(index: usize) [*:0]const u8 {
    if (index >= count) return "新标签页";
    const tab = &tabs[index];
    if (tab.title[0] != 0) return &tab.title;
    if (tab.url[0] != 0) return &tab.url;
    return "新标签页";
}
export fn moon_tab_flags(index: usize) c_uint {
    if (index >= count) return 0;
    const tab = &tabs[index];
    return (if (tab.phase==.dormant) @as(c_uint,native.MOON_TAB_DORMANT) else 0) |
        (if (tab.phase==.crashed or tab.phase==.failed) @as(c_uint,native.MOON_TAB_FAILED) else 0) |
        (if (tab.loading) @as(c_uint,native.MOON_TAB_LOADING) else 0) |
        (if (tab.pinned) @as(c_uint,native.MOON_TAB_PINNED) else 0) |
        (if (tab.muted) @as(c_uint,native.MOON_TAB_MUTED) else 0) |
        (if (!native.moon_shell_private() and (tab.pinned or (!tab.extension and tab.has_document and !tab.unsafe_history and !tab.loading and safeURL(slice(&tab.url)))))
            @as(c_uint,native.MOON_TAB_CAN_PIN) else 0) |
        (if (tab.muted or (!tab.extension and safeURL(slice(&tab.url)))) @as(c_uint,native.MOON_TAB_CAN_MUTE) else 0) |
        (if (canDuplicate(tab) and safeURL(slice(&tab.url))) @as(c_uint,native.MOON_TAB_CAN_DUPLICATE) else 0) |
        (if (tab.has_document and !tab.extension and safeURL(slice(&tab.url))) @as(c_uint,native.MOON_TAB_CAN_COPY_ADDRESS) else 0) |
        (if (hasSite(tab)) @as(c_uint,native.MOON_TAB_HAS_SITE) else 0);
}

fn hasSite(tab: *const Tab) bool {
    return tab.document_committed and tab.phase == .live and !tab.extension and tab.view != null and safeURL(slice(&tab.url));
}

export fn moon_site_context(site: *native.MoonSiteContext) bool {
    if (stopped or count == 0) return false;
    const tab = &tabs[active];
    if (!hasSite(tab)) return false;
    var url: [4096:0]u8 = @splat(0);
    native.moon_engine_committed_url(tab.view.?,&url,url.len);
    const origin = popups.origin(slice(&url)) orelse return false;
    site.* = .{ .tab_id=tab.id, .navigation=tab.navigation, .origin=origin[0..site.origin.len].* };
    return true;
}

export fn moon_site_menu_run(site: *const native.MoonSiteContext, index: usize, command: usize) void {
    if (stopped or count == 0 or !plugins.siteMenuVisible(index,command)) return;
    const tab = &tabs[active];
    if (!hasSite(tab) or tab.id != site.tab_id or tab.navigation != site.navigation) return;
    plugins.command(index,command,tabSnapshot());
}

export fn moon_link_capture(link: *native.MoonLinkContext, id: u64) bool {
    if (stopped or count==0 or tabs[active].id!=id or !hasSite(&tabs[active])) return false;
    if (!history.validURL(slice(&link.url))) return false;
    link.tab_id = id;
    link.navigation = tabs[active].navigation;
    return true;
}

export fn moon_link_current(link: *const native.MoonLinkContext) bool {
    return !stopped and count!=0 and tabs[active].id==link.tab_id and tabs[active].navigation==link.navigation and hasSite(&tabs[active]);
}

export fn moon_plugin_link_action(index: usize, command: usize) c_uint {
    return if (plugins.linkAction(index,command)) |operation| @intFromEnum(operation) else 0;
}

export fn moon_plugin_bound_action(index: usize, command: usize) bool {
    return plugins.boundOnly(index,command);
}

export fn moon_link_menu_run(link: *const native.MoonLinkContext, index: usize, command: usize) void {
    if (moon_link_current(link)) plugins.linkCommand(index,command,tabSnapshot(),link);
}

export fn moon_link_open(link: *const native.MoonLinkContext) c_uint {
    if (count==tabs.len) return @intFromEnum(sdk.LinkResult.limitReached);
    var address: [4096:0]u8 = @splat(0);
    var label: [512:0]u8 = @splat(0);
    _ = copy(&address,slice(&link.url));
    _ = copy(&label,slice(&link.label));
    tabs[count] = .{ .id=next_id,.phase=.dormant,.url=address,.title=label,.last_used=native.moon_clock() };
    count += 1;
    next_id += 1;
    native.moon_shell_refresh();
    return @intFromEnum(sdk.LinkResult.opened);
}
export fn moon_tab_id(index: usize) u64 {
    return if (index<count) tabs[index].id else 0;
}
export fn moon_tab_tools_permissions() c_uint {
    return (if (plugins.systemEnabled(.@"tabs.organize")) @as(c_uint,native.MOON_TAB_ORGANIZE) else 0) |
        (if (plugins.systemEnabled(.@"tabs.manage")) @as(c_uint,native.MOON_TAB_MANAGE) else 0);
}
export fn moon_controls() c_uint {
    if (count == 0) return 0;
    const tab = &tabs[active];
    return if (tab.view) |view| native.moon_engine_controls(view) else 0;
}
export fn moon_plugin_count() usize {
    return plugins.count();
}
export fn moon_plugin_label(index: usize) [*:0]const u8 {
    return plugins.label(index);
}
export fn moon_plugin_action_count(index: usize) usize {
    return plugins.actionCount(index);
}
export fn moon_plugin_action(index: usize, command: usize) [*:0]const u8 {
    return plugins.action(index, command);
}
export fn moon_plugin_action_shortcut(index: usize, command: usize) [*:0]const u8 {
    if (plugins.userShortcut(index,command)) |shortcut| return shortcut;
    if (plugins.registeredShortcut(index,command)) |shortcut| return shortcut;
    return if (plugins.actionShortcut(index,command)) |key| @tagName(key) else "";
}
export fn moon_plugin_enabled(index: usize) bool {
    return plugins.isEnabled(index);
}
export fn moon_plugin_permission_label(index: usize) [*:0]const u8 {
    const permission = std.enums.fromInt(sdk.Permission,index) orelse return "";
    return switch (permission) {
        .@"tabs.read" => "允许读取标题和网址",
        .@"lua.scripts.manage" => "允许管理 Lua 用户脚本",
        .@"page.inspect" => "允许打开网页开发者工具",
        .@"history.manage" => "允许管理浏览历史",
        .@"network.filter" => "允许拦截网页请求",
        .@"bookmarks.manage" => "允许管理书签",
        .@"bookmarks.transfer" => "允许导入和导出 HTML 书签",
        .@"downloads.manage" => "允许管理下载",
        .@"siteData.read" => "允许查看站点数据",
        .@"siteData.write" => "允许编辑和删除站点存储",
        .@"page.source" => "允许查看当前网页源代码",
        .@"page.save" => "允许通过文件对话框保存当前网页",
        .@"popups.manage" => "允许管理网站弹窗",
        .@"tabs.session.manage" => "允许保存和恢复上次浏览会话",
        .@"page.reading" => "允许打开页内查找和调整缩放",
        .@"window.fullscreen" => "允许切换浏览器全屏",
        .@"tabs.closed.manage" => "允许管理最近关闭的标签",
        .@"privacy.clear" => "允许在确认后清除浏览数据",
        .@"taskManager.manage" => "允许查看和管理标签与进程",
        .@"ui.commands" => "允许添加菜单入口和注册快捷键",
        .@"tabs.organize" => "允许固定、静音和排序标签",
        .@"privacy.privateWindow" => "允许打开隐私浏览窗口",
        .@"tabs.manage" => "允许复制和批量关闭标签",
        .@"search.manage" => "允许调整浏览器搜索引擎",
    };
}
export fn moon_plugin_permission_flags(index: usize, ordinal: usize) c_uint {
    const permission = std.enums.fromInt(sdk.Permission,ordinal) orelse return 0;
    return plugins.permissionFlags(index,permission);
}
export fn moon_plugin_has_settings(index: usize) bool {
    return plugins.hasSettings(index);
}
export fn moon_extension_settings(id: [*c]const u8, request: [*c]const u8, result: [*c]u8, cap: usize) bool {
    if (stopped or plugins.pageGrants(slice(id)) == null) return false;
    return extension_settings.pageReply(slice(id),slice(request),result[0..cap]);
}

fn pageActive(_: ?*const anyopaque) callconv(.c) bool {
    return !stopped;
}

export fn moon_extension_request(panel: u64, id: [*c]const u8, request: [*c]const u8, result: [*c]u8, cap: usize) bool {
    if (stopped) return false;
    const grants = plugins.pageGrants(slice(id)) orelse return false;
    const allocator = std.heap.page_allocator;
    const reply = api.dispatch(allocator,slice(request),.{
        .grants=grants,.plugin_id=slice(id),.target_tab_id=panel,.tab=null,
        .consent=.{ .context=&stopped,.valid=pageActive },.from_page=true,
    }) catch return false;
    defer allocator.free(reply);
    return copy(result[0..cap],reply);
}

fn changePlugin(index: usize, permission: ?sdk.Permission) plugins.Change {
    const result = plugins.toggle(index,permission);
    if (result != .saved) return result;
    if (permission == null or permission == .@"network.filter") network.select(plugins.networkSource());
    if (permission == null or permission == .@"siteData.read") checkSiteDataGrant();
    if (permission == null or permission == .@"page.source") checkPageSourceGrant();
    if (permission == null or permission == .@"page.reading") checkFindGrant();
    if (fullscreen_owner[0]!=0 and !plugins.hasGrant(slice(&fullscreen_owner),.@"window.fullscreen")) {
        native.moon_shell_leave_fullscreen();
        fullscreen_owner[0] = 0;
    }
    if (permission == null or permission == .@"tabs.closed.manage") checkClosedTabGrant();
    if (permission == null or permission == .@"tabs.organize") checkTabToolsGrant();
    native.moon_shell_refresh();
    return result;
}

export fn moon_plugins_request(panel: u64, raw: [*c]const u8, response: [*c]u8, cap: usize) bool {
    if (stopped or native.moon_shell_private()) return false;
    const tab = tabIndex(panel) orelse return false;
    if (!tabs[tab].extension or !equals(slice(&tabs[tab].url),plugin_manager.address)) return false;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const input = std.json.parseFromSliceLeaky(plugin_manager.Request,allocator,slice(raw),.{}) catch return false;
    const output = response[0..cap];
    if (input.op == .list) return plugin_manager.list(allocator,output,input.offset);
    if (input.op == .capture) {
        const enabled = input.enabled orelse return false;
        if (enabled and active != tab) return false;
        if (enabled) {
            shortcut_capture = .{ .tab=panel, .deadline=native.moon_clock()+10_000 };
        } else if (shortcut_capture) |capture| {
            if (capture.tab == panel) shortcut_capture = null;
        }
        return plugin_manager.reply(allocator,output,.{ .recording = enabled });
    }
    if (input.op == .market) {
        if (active != tab) return false;
        return plugin_manager.reply(allocator,output,.{ .opened = openInternalPage(market.address) });
    }

    const index = plugins.indexOf(input.id orelse return false) orelse return false;
    if (input.op == .details) return plugin_manager.details(allocator,output,index);
    if (active != tab) return false;
    switch (input.op) {
        .shortcut => {
            const result = plugins.setUserShortcut(index,input.command orelse return false,input.shortcut);
            if (result == .saved) native.moon_shell_refresh();
            return plugin_manager.reply(allocator,output,.{ .result = result });
        },
        .settings => {
            var buffer: [256]u8 = undefined;
            const address = plugins.settingsAddress(index,&buffer) orelse return false;
            return plugin_manager.reply(allocator,output,.{ .opened = openInternalPage(address) });
        },
        .enable, .grant => {
            const enabled = input.enabled orelse return false;
            const permission = if (input.op == .grant) input.permission orelse return false else null;
            const current = if (permission) |scope| blk: {
                const flags = plugins.permissionFlags(index,scope);
                if (!plugins.isEnabled(index) or flags & 1 == 0) return false;
                break :blk flags & 2 != 0;
            } else plugins.isEnabled(index);
            const result: plugins.Change = if (current == enabled) .saved else changePlugin(index,permission);
            return plugin_manager.reply(allocator,output,.{ .result = result });
        },
        else => unreachable,
    }
}

export fn moon_plugin_capture_key(modifiers: c_uint, key: c_uint) bool {
    const capture = shortcut_capture orelse return false;
    if (stopped or count == 0 or tabs[active].id != capture.tab or native.moon_clock() >= capture.deadline) {
        shortcut_capture = null;
        return false;
    }
    const view = tabs[active].view orelse return false;
    if (key == 0x1b) {
        shortcut_capture = null;
        native.moon_engine_apply_dom(view,"dispatchEvent(new CustomEvent('moon-shortcut',{detail:null}))");
        return true;
    }
    const prefix = switch (modifiers) {
        0x0006 => "Ctrl+Shift+",
        0x0005 => "Alt+Shift+",
        else => return false,
    };
    if (key > 127 or (!std.ascii.isUpper(@intCast(key)) and !std.ascii.isDigit(@intCast(key)))) return false;
    var buffer: [128]u8 = undefined;
    const script = std.fmt.bufPrintSentinel(&buffer,"dispatchEvent(new CustomEvent('moon-shortcut',{{detail:'{s}{c}'}}))",
        .{ prefix, @as(u8,@intCast(key)) },0) catch unreachable;
    shortcut_capture = null;
    native.moon_engine_apply_dom(view,script.ptr);
    return true;
}

export fn moon_privacy_allowed(tab: u64, owner: [*c]const u8) bool {
    return !stopped and count != 0 and tabs[active].id == tab and plugins.hasGrant(slice(owner),.@"privacy.clear");
}

export fn moon_bookmark_transfer_allowed(source: u64, owner: [*c]const u8) bool {
    if (stopped or count==0 or tabs[active].id!=source or native.moon_shell_private()) return false;
    const id = slice(owner);
    return plugins.hasGrant(id,.@"bookmarks.manage") and plugins.hasGrant(id,.@"bookmarks.transfer");
}

export fn moon_plugin_open_page(id: [*c]const u8) bool {
    if (stopped or count == 0) return false;
    var buffer: [256]u8 = undefined;
    const address = plugins.addressForId(slice(id),&buffer) orelse return false;
    return openInternalPage(address);
}

fn openInternalPage(address: []const u8) bool {
    for (tabs[0..count],0..) |*tab,index| {
        if (!tab.extension or !equals(slice(&tab.url),address)) continue;
        chooseTab(index,true);
        if (tab.phase == .crashed or tab.phase == .failed) navigate(tab,address);
        return true;
    }
    if (count == tabs.len) return false;
    addTab(address,true);
    return true;
}

fn checkPageSourceGrant() void {
    const owner = page_source.ownerId() orelse return;
    if (!plugins.hasGrant(owner,.@"page.source")) page_source.reset();
}

export fn moon_page_source_open(id: [*c]const u8, source: u64, expected: [*c]const u8) bool {
    if (stopped or count == 0 or tabs[active].id != source) return false;
    const tab = &tabs[active];
    if (tab.extension or tab.loading or !tab.loaded) return false;
    const view = tab.view orelse return false;
    var committed: [4096:0]u8 = @splat(0);
    native.moon_engine_committed_url(view,&committed,committed.len);
    const url = slice(&committed);
    if (!equals(url,slice(expected)) or !history.validURL(url)) return false;
    if (!moon_plugin_open_page(id)) return false;
    if (!tabs[active].extension or tabs[active].id == source) return false;
    const current = &tabs[tabIndex(source) orelse return false];
    if (current.view != view or current.loading or !current.loaded) return false;
    page_source.begin(slice(id),source,tabs[active].id,url,view);
    return true;
}

export fn moon_page_source_result(generation: u64, html: [*c]const u8, bytes: usize) void {
    if (!stopped) page_source.complete(generation,if (html!=null) html[0..bytes] else null);
}

fn pageSaveView(id: u64, navigation: u64) ?*native.MoonView {
    if (stopped) return null;
    const tab = &tabs[tabIndex(id) orelse return null];
    if (tab.navigation!=navigation or !hasSite(tab) or !tab.loaded or tab.loading) return null;
    return tab.view;
}

export fn moon_page_save(owner: [*c]const u8, id: u64, navigation: u64,
    context: ?*const anyopaque, consent: native.MoonPluginConsent) c_int {
    return @intFromEnum(startPageSave(owner,id,navigation,context,consent));
}

fn startPageSave(owner: [*c]const u8, id: u64, navigation: u64,
    context: ?*const anyopaque, consent: native.MoonPluginConsent) sdk.PageSaveStart {
    const permitted = consent orelse return .unavailable;
    if (page_save_job!=null) return .busy;
    if (count==0 or tabs[active].id!=id) return .unavailable;
    const view = pageSaveView(id,navigation) orelse return .unavailable;
    if (!native.moon_engine_can_save_html(view)) return .unsupported;
    const title = tabs[active].title;
    var job: PageSaveJob = .{
        .request=0,.tab=id,.navigation=navigation,.deadline=0,.owner=@splat(0),.path=@splat(0),.replace=false,
    };
    if (!copy(&job.owner,slice(owner))) return .unavailable;
    switch (native.moon_shell_pick_html(&title,&job.path,job.path.len,&job.replace)) {
        1 => {},
        0 => return .cancelled,
        -2 => return .invalidFilename,
        else => return .failed,
    }
    if (!permitted(context) or count==0 or tabs[active].id!=id or
        !plugins.hasGrant(slice(&job.owner),.@"page.save")) return .unavailable;
    const confirmed = pageSaveView(id,navigation) orelse return .unavailable;
    page_save_serial += 1;
    job.request = page_save_serial;
    job.deadline = native.moon_clock()+15000;
    page_save_job = job;
    if (native.moon_engine_save_html(confirmed,job.request)) return .started;
    page_save_job = null;
    return .failed;
}

export fn moon_page_save_result(request: u64, html: [*c]const u8, bytes: usize, too_large: bool) void {
    const job = page_save_job orelse return;
    if (stopped or request!=job.request) return;
    page_save_job = null;
    const message = result: {
        if (pageSaveView(job.tab,job.navigation)==null or !plugins.hasGrant(slice(&job.owner),.@"page.save"))
            break :result "原网页已切换或保存权限已撤销。";
        if (too_large) break :result "网页主文档超过 16 MiB。";
        if (html==null or bytes==0) break :result "未能读取网页主文档。";
        if (!native.moon_shell_write_html(&job.path,html,bytes,job.replace))
            break :result "无法写入所选位置。请检查文件和目录权限。";
        if (!native.moon_shell_private() and plugins.systemEnabled(.@"downloads.manage")) {
            const length = bytes + @as(usize,if (std.mem.startsWith(u8,html[0..bytes],"\xef\xbb\xbf")) 0 else 3);
            const id = downloads.begin();
            downloads.destination(id,slice(&job.path));
            downloads.progress(id,length,length);
            downloads.finish(id,.complete);
        }
        break :result "已保存网页主文档。";
    };
    native.moon_shell_toast("网页另存为",message);
}

export fn moon_web_popup(source: u64, opener: [*c]const u8, destination: [*c]const u8, gesture: bool) void {
    if (stopped or count == 0 or tabs[active].id != source or tabs[active].extension) return;
    const target = slice(destination);
    _ = popups.origin(target) orelse return;
    const committed = popups.origin(slice(opener)) orelse return;
    const enabled = !native.moon_shell_private() and plugins.systemEnabled(.@"popups.manage");
    const rule = if (enabled) popups.mode(slice(&committed)) else .automatic;
    if (rule != .block and (gesture or (rule == .allow and tabs[active].document_committed))) {
        if (popup[0] == 0 and count < tabs.len) _ = copy(&popup,target);
    } else if (enabled and tabs[active].document_committed and popups.blocked(source,target)) {
        native.moon_shell_toast("已拦截弹窗","可在「… → 隐私与安全 → 管理网站弹窗」查看并打开一次。");
    }
}

export fn moon_popups_open(owner: [*c]const u8, source: u64) bool {
    if (stopped or count == 0 or tabs[active].id != source or native.moon_shell_private()) return false;
    const tab = &tabs[active];
    var origin: popups.Origin = @splat(0);
    if (!tab.extension and tab.document_committed) {
        if (tab.view) |view| {
            var url: [4096:0]u8 = @splat(0);
            native.moon_engine_committed_url(view,&url,url.len);
            if (popups.origin(slice(&url))) |key| origin = key;
        }
    }
    if (!moon_plugin_open_page(owner)) return false;
    popups.bind(tabs[active].id,slice(owner),source,origin);
    return true;
}

fn popupPanelAllowed(owner: []const u8, panel: u64) bool {
    return !stopped and count != 0 and tabs[active].id == panel and tabs[active].extension and
        !native.moon_shell_private() and plugins.hasGrant(owner,.@"popups.manage");
}

export fn moon_popups_change_allowed(owner: [*c]const u8, panel: u64, origin: [*c]const u8, allow: bool) bool {
    const id = slice(owner);
    if (!popupPanelAllowed(id,panel)) return false;
    if (!allow) return true;
    var body: [640]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&body,"允许 {s} 在当前标签中自动打开新标签页？",.{slice(origin)},0) catch return false;
    return native.moon_shell_confirm("允许网站弹窗？",message.ptr) and popupPanelAllowed(id,panel);
}

export fn moon_popups_open_blocked(owner: [*c]const u8, panel: u64, notice_id: u64) bool {
    const id = slice(owner);
    if (!popupPanelAllowed(id,panel) or popup[0] != 0 or count == tabs.len) return false;
    var rules: popups.RuleBuffer = undefined;
    var target: popups.Origin = undefined;
    const notice = popups.status(panel,id,&rules,&target).blocked orelse return false;
    if (notice.id != notice_id) return false;
    var body: [640]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&body,"打开刚才拦截的链接？目标站点为 {s}。",.{notice.targetOrigin},0) catch return false;
    return native.moon_shell_confirm("打开一次弹窗？",message.ptr) and popupPanelAllowed(id,panel) and
        popup[0] == 0 and count < tabs.len and popups.openOnce(panel,id,notice_id,&popup);
}

fn checkSiteDataGrant() void {
    const owner = site_data.ownerId() orelse return;
    const grants = plugins.pageGrants(owner) orelse {
        site_data.reset();
        return;
    };
    if (!grants.contains(.@"siteData.read")) site_data.reset();
}

export fn moon_site_data_open(id: [*c]const u8, source: u64, expected: [*c]const u8) bool {
    if (stopped or count == 0 or tabs[active].id != source) return false;
    const tab = &tabs[active];
    const view = tab.view orelse return false;
    if (tab.extension or tab.loading or !tab.loaded) return false;
    var committed: [4096:0]u8 = @splat(0);
    native.moon_engine_committed_url(view,&committed,committed.len);
    const url = slice(&committed);
    if (!equals(url,slice(expected)) or !history.validURL(url)) return false;
    const scheme: usize = if (url[4] == ':') 7 else 8;
    const authority = std.mem.indexOfAny(u8,url[scheme..],"/?#") orelse url.len - scheme;
    site_data.begin(slice(id),source,url[0..scheme+authority],view);
    if (!moon_plugin_open_page(id)) {
        site_data.reset();
        return false;
    }
    site_data.bindPanel(tabs[active].id);
    return true;
}

export fn moon_site_data_action(panel: u64, id: [*c]const u8, action: c_int) bool {
    if (stopped or count == 0 or tabs[active].id != panel) return false;
    const source = site_data.selected(panel,slice(id)) orelse return false;
    const index = tabIndex(source) orelse return false;
    const tab = &tabs[index];
    const view = tab.view orelse return false;
    if (tab.extension or tab.loading or !tab.loaded) return false;
    if (action == native.MOON_SITE_REFRESH) return site_data.request(view);
    if (action == native.MOON_SITE_CATALOG) {
        site_data.requestCatalog(view);
        return true;
    }
    if (!plugins.systemEnabled(.@"page.inspect")) return false;
    chooseTab(index,true);
    return native.moon_engine_inspect(view,@intFromEnum(sdk.InspectorPanel.resources),false);
}

fn siteWriteView(panel: u64, owner: []const u8) ?*native.MoonView {
    if (stopped or count==0 or tabs[active].id!=panel or
        !plugins.hasGrant(owner,.@"siteData.read") or !plugins.hasGrant(owner,.@"siteData.write")) return null;
    const source = site_data.selected(panel,owner) orelse return null;
    const tab = &tabs[tabIndex(source) orelse return null];
    if (!hasSite(tab) or tab.loading or !tab.loaded) return null;
    return tab.view;
}

export fn moon_site_data_update(panel: u64, id: [*c]const u8, session: bool, entry: u32, generation: u64,
    value: [*c]const u8, length: usize) bool {
    if (site_clear_confirming) return false;
    const owner = slice(id);
    const view = siteWriteView(panel,owner) orelse return false;
    const target: sdk.SiteDataItem = .{ .group=if (session) .session else .local, .id=entry, .generation=generation };
    return site_data.update(view,panel,owner,target,if (value!=null) value[0..length] else null);
}

export fn moon_site_data_create(panel: u64, id: [*c]const u8, session: bool, generation: u64,
    key: [*c]const u8, key_length: usize, value: [*c]const u8, value_length: usize) bool {
    if (site_clear_confirming) return false;
    const owner = slice(id);
    const view = siteWriteView(panel,owner) orelse return false;
    return site_data.create(view,panel,owner,.{
        .group=if (session) .session else .local,.generation=generation,
        .key=key[0..key_length],.value=value[0..value_length],
    });
}

export fn moon_site_data_clear(panel: u64, id: [*c]const u8, session: bool, generation: u64) c_int {
    return @intFromEnum(clearSiteStorage(panel,slice(id),session,generation));
}

fn clearSiteStorage(panel: u64, owner: []const u8, session: bool, generation: u64) sdk.SiteDataClearStart {
    const group: sdk.SiteDataGroup = if (session) .session else .local;
    if (site_clear_confirming or siteWriteView(panel,owner)==null or
        !site_data.canMutate(panel,owner,group,generation)) return .unavailable;
    var body: [640]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&body,"清空 {s} 的{s}全部条目？\n此操作也会移除筛选结果之外的条目。",.{
        site_data.status(panel,owner,true).origin,
        if (session) "当前标签 Session Storage " else " Local Storage ",
    },0) catch return .unavailable;
    site_clear_confirming = true;
    defer site_clear_confirming = false;
    if (!native.moon_shell_confirm("清空站点存储？",message.ptr)) return .cancelled;
    const view = siteWriteView(panel,owner) orelse return .unavailable;
    return if (site_data.clear(view,panel,owner,group,generation)) .started else .unavailable;
}

export fn moon_site_data_result(source: u64, request: u64, snapshot: [*c]const u8, catalog: bool) void {
    if (stopped) return;
    if (catalog) site_data.completeCatalog(source,request,slice(snapshot)) else site_data.complete(source,request,slice(snapshot));
}

fn checkFindGrant() void {
    if (find_tab != 0 and !plugins.hasGrant(slice(&find_owner),.@"page.reading"))
        moon_find_dismiss(true);
}

fn readingTarget(id: u64) ?*Tab {
    if (stopped or count == 0) return null;
    const tab = &tabs[active];
    return if (tab.id == id and tab.phase == .live and tab.loaded and !tab.loading and tab.view != null) tab else null;
}

export fn moon_window_fullscreen(id: u64, navigation: u64, owner: [*c]const u8) c_int {
    if (stopped or count == 0 or !plugins.hasGrant(slice(owner),.@"window.fullscreen")) return -1;
    const tab = &tabs[active];
    if (tab.id!=id or tab.navigation!=navigation) return -1;
    const view = tab.view orelse return -1;
    const state = native.moon_shell_toggle_fullscreen();
    if (state == 1) {
        _ = copy(&fullscreen_owner,slice(owner));
        native.moon_engine_show(view,true);
    } else if (state == 0) {
        fullscreen_owner[0] = 0;
    }
    return state;
}

export fn moon_reading_find(id: u64, owner: [*c]const u8) bool {
    const tab = readingTarget(id) orelse return false;
    if (!copy(&find_owner,slice(owner))) return false;
    if (!native.moon_shell_find_show()) {
        find_owner[0] = 0;
        return false;
    }
    find_tab = tab.id;
    return true;
}

export fn moon_find_query(query: [*c]const u8, backwards: bool) void {
    const tab = readingTarget(find_tab) orelse return;
    if (query[0] == 0) native.moon_engine_hide_find(tab.view.?) else
        native.moon_engine_find(tab.view.?,query,backwards);
}

export fn moon_find_result(id: u64, query: [*c]const u8, matches: c_uint) void {
    if (id == find_tab and readingTarget(id) != null) native.moon_shell_find_result(query,matches);
}

export fn moon_find_dismiss(refocus: bool) void {
    if (find_tab == 0) return;
    const index = tabIndex(find_tab);
    find_tab = 0;
    find_owner[0] = 0;
    const focused = native.moon_shell_find_hide();
    if (index) |i| if (tabs[i].view) |view| {
        native.moon_engine_hide_find(view);
        if (refocus and focused and active == i) native.moon_engine_show(view,true);
    };
}

fn zoomOrigin(tab: *const Tab, buffer: *[4096:0]u8) ?[]const u8 {
    if (tab.extension) return null;
    const view = tab.view orelse return null;
    native.moon_engine_committed_url(view,buffer,buffer.len);
    return reading.origin(slice(buffer));
}

export fn moon_reading_zoom(id: u64, action: c_int) c_uint {
    const tab = readingTarget(id) orelse return 0;
    const command = std.enums.fromInt(sdk.ZoomAction,action) orelse return 0;
    const view = tab.view.?;
    const percent = reading.next(@intCast(native.moon_engine_zoom(view)),command);
    var url: [4096:0]u8 = @splat(0);
    if (!native.moon_shell_private()) if (zoomOrigin(tab,&url)) |key| {
        reading.save(key,percent) catch return 0;
        for (tabs[0..count]) |*peer| {
            if (peer.id == id or peer.phase != .live or peer.loading) continue;
            var peer_url: [4096:0]u8 = @splat(0);
            const origin = zoomOrigin(peer,&peer_url) orelse continue;
            if (equals(key,origin)) native.moon_engine_set_zoom(peer.view.?,percent);
        }
    };
    native.moon_engine_set_zoom(view,percent);
    return percent;
}

export fn moon_plugin_action_menu(index: usize, command: usize) c_uint {
    return plugins.menuLocation(index,command);
}

export fn moon_plugin_action_site_menu(index: usize, command: usize) bool {
    return plugins.siteMenuVisible(index,command);
}
export fn moon_plugin_key(modifiers: c_uint, key: c_uint, repeated: bool) bool {
    return !stopped and count!=0 and plugins.browserShortcut(modifiers,key,repeated,tabSnapshot());
}
export fn moon_plugin_global_key(id: c_uint, modifiers: c_uint, key: c_uint) bool {
    return !stopped and count!=0 and plugins.globalShortcut(id,modifiers,key,tabSnapshot());
}
export fn moon_plugin_ui_menu(owner: [*c]const u8, command: [*c]const u8, add: bool) c_uint {
    return @intFromEnum(plugins.setMenu(slice(owner),slice(command),add));
}
export fn moon_plugin_ui_shortcut(owner: [*c]const u8, command: [*c]const u8, shortcut: [*c]const u8, global: bool,
    context: ?*const anyopaque, consent: native.MoonPluginConsent) c_uint
{
    const invocation = context orelse return @intFromEnum(sdk.UiRegistration.unavailable);
    const check = consent orelse return @intFromEnum(sdk.UiRegistration.unavailable);
    return @intFromEnum(plugins.setHotkey(slice(owner),slice(command),if (shortcut!=null) slice(shortcut) else null,
        if (global) .global else .browser,.{ .context=invocation,.valid=check }));
}

const Action = union(enum) { built_in: ShellAction, plugin: struct { index: usize, command: usize } };

fn shellActionVisible(action: ShellAction, home: bool) bool {
    if (home and !action.home) return false;
    if (!native.moon_shell_private()) return true;
    return switch (action.command) {
        native.MOON_OPEN_PLUGINS, native.MOON_UPDATES, native.MOON_MARKET => false,
        else => true,
    };
}

fn actionAt(index: usize, home: bool) ?Action {
    var remaining = index;
    for (shell_actions) |action| {
        if (!shellActionVisible(action,home)) continue;
        if (remaining == 0) return .{ .built_in = action };
        remaining -= 1;
    }
    for (0..plugins.count()) |plugin| {
        if (!plugins.isEnabled(plugin)) continue;
        for (0..plugins.actionCount(plugin)) |command| {
            if (plugins.boundOnly(plugin,command)) continue;
            if (remaining==0) return .{ .plugin = .{ .index=plugin,.command=command } };
            remaining -= 1;
        }
    }
    return null;
}

export fn moon_action_count(home: bool) usize {
    var actions: usize = 0;
    for (shell_actions) |action| actions += @intFromBool(shellActionVisible(action,home));
    for (0..plugins.count()) |plugin| {
        if (!plugins.isEnabled(plugin)) continue;
        for (0..plugins.actionCount(plugin)) |command| actions += @intFromBool(!plugins.boundOnly(plugin,command));
    }
    return actions;
}

export fn moon_action_label(index: usize, home: bool) [*:0]const u8 {
    return switch (actionAt(index, home) orelse return "") {
        .built_in => |action| action.label,
        .plugin => |plugin| plugins.action(plugin.index, plugin.command),
    };
}

export fn moon_action_run(index: usize, home: bool) void {
    switch (actionAt(index, home) orelse return) {
        .built_in => |action| moon_command(action.command, 0, null),
        .plugin => |plugin| plugins.command(plugin.index, plugin.command, tabSnapshot()),
    }
}
export fn moon_plugin_worker(task: ?*anyopaque) void {
    plugins.worker(task);
}

fn smokeNavigate(tab: *Tab, path: []const u8) void {
    var uri: [4096]u8 = undefined;
    const value = std.fmt.bufPrint(&uri, "{s}{s}", .{ slice(&smoke_base), path }) catch return failSmoke("fixture URL");
    smoke_started = native.moon_clock();
    smoke_painted = false;
    smoke_paint_requested = false;
    navigate(tab, value);
}
fn smokePage(title: []const u8) bool {
    const tab = &tabs[active];
    return tab.view != null and tab.phase == .live and tab.loaded and equals(slice(&tab.title), title);
}
fn requestSmokePaint() void {
    if (smoke_paint_requested or smoke_painted) return;
    smoke_paint_requested = true;
    if (tabs[active].view) |view| native.moon_engine_probe(view);
}
fn beginWarm() void {
    smoke_painted = false;
    smoke_paint_requested = false;
    warm_started_us = native.moon_perf_us();
    chooseTab(if (active == 48) 49 else 48, false);
    requestSmokePaint();
}
fn smokeTick(now: u64) void {
    if (now >= smoke_deadline) return failSmoke("timeout");
    const lua_fixture = equals(slice(native.moon_userscript_label(0)), "Moon Lua smoke budget");
    const initial_title = if (lua_fixture) "Moon fixture initial Lua ✓" else "Moon fixture initial";
    switch (smoke) {
        .off => {},
        .first => {
            if (!smokePage(initial_title)) return;
            requestSmokePaint();
            if (!smoke_painted) return;
            smoke = .second;
            smokeNavigate(&tabs[0], "/page/second");
        },
        .second => {
            if (!smokePage("Moon fixture second")) return;
            if (lua_fixture) {
                const failure = slice(native.moon_userscript_error(0));
                if (std.mem.indexOf(u8, failure, "instruction limit exceeded") == null) return failSmoke("Lua instruction budget");
                log("lua_userscripts=ok", .{});
            }
            if (moon_controls() & 1 == 0) return failSmoke("initial back history missing");
            log("navigation_ok=1 baseline_commit={d}", .{sampleMemory()});
            if (smoke_quick) {
                smoke = .restore;
                storeSession(&tabs[0]);
                tabs[0].phase = .dormant;
                detach(&tabs[0]);
                restore(&tabs[0]);
                return;
            }
            smoke = .load_tabs;
            load_step = 1;
            addTab(null, false);
            smokeNavigate(&tabs[active], "/page/batch");
        },
        .load_tabs => {
            if (!smokePage("Moon fixture batch")) return;
            if (load_step == 1) moon_command(native.MOON_INPUT, 0, null);
            if (load_step == 49) {
                smoke = .settle;
                return;
            }
            load_step += 1;
            addTab(null, false);
            smokeNavigate(&tabs[active], "/page/batch");
        },
        .settle => {
            const counts = stateCounts();
            if (counts.sleep < 42 or settle_at != 0) return;
            if (count != 50 or !tabs[1].dirty or tabs[1].view == null or tabs[0].phase != .dormant)
                return failSmoke("unexpected eviction set");
            log("tab_stress open={d} live={d} sleeping={d} protected={d} before={d} after={d} current={d} peak={d} snapshots={d}", .{ count, counts.live, counts.sleep, counts.protected, last_before, last_after, sampleMemory(), peak_commit, snapshots_saved });
            smoke = .warm_prepare;
            chooseTab(48, false);
        },
        .warm_prepare => {
            if (!smokePage("Moon fixture batch")) return;
            if (active == 48) {
                chooseTab(49, false);
                return;
            }
            smoke = .warm;
            beginWarm();
        },
        .warm => {
            if (!smoke_painted) return;
            if (warm_count < warm_samples.len) {
                beginWarm();
                return;
            }
            std.mem.sort(u64, &warm_samples, {}, std.sort.asc(u64));
            log("warm_switch_p95_us={d} samples={d}", .{ warm_samples[18], warm_samples.len });
            smoke = .restore;
            chooseTab(0, false);
        },
        .restore => {
            if (!smokePage("Moon fixture second")) return;
            if (moon_controls() & 1 == 0) return failSmoke("session history did not round-trip");
            log("session_roundtrip=1", .{});
            smoke = .back;
            moon_command(native.MOON_BACK, 0, null);
        },
        .back => {
            if (!smokePage(initial_title)) return;
            if (moon_controls() & 2 == 0) return failSmoke("forward navigation unavailable");
            smoke = .forward;
            moon_command(native.MOON_FORWARD, 0, null);
        },
        .forward => {
            if (!smokePage("Moon fixture second")) return;
            log("history_navigation=ok", .{});
            smoke = .plugin;
            if (!plugins.smokeStart(0, tabSnapshot())) return failSmoke("sample plugin unavailable");
        },
        .plugin => {
            const success = plugins.smokeStatus(plugin_step, slice(&tabs[active].title)) orelse return;
            if (!success) {
                const info = plugins.smokeDetail();
                log("plugin_case_{d}={s} message={s}", .{ plugin_step, info.outcome, info.message });
                return failSmoke("plugin protocol check");
            }
            log("plugin_case_{d}=ok", .{plugin_step});
            plugin_step += 1;
            if (plugin_step < 5) {
                if (!plugins.smokeStart(plugin_step, tabSnapshot())) return failSmoke("sample plugin launch");
                return;
            }
            const api_fixture = plugins.smokeHasContract();
            if (api_fixture and plugin_step <= 8) {
                if (!plugins.smokeContract(plugin_step, tabSnapshot())) return failSmoke("V2 contract client launch");
                return;
            }
            if (api_fixture) log("plugin_api_v2=ok", .{});
            smoke = .download;
            _ = native.moon_engine_test_download(null, &smoke_download);
            var url: [4096]u8 = undefined;
            const target = std.fmt.bufPrintSentinel(&url, "{s}/download", .{slice(&smoke_base)}, 0) catch return failSmoke("download URL");
            if (!native.moon_engine_load(tabs[active].view.?, target.ptr)) return failSmoke("download start");
        },
        .download => {
            const result = native.moon_engine_test_download(null, null);
            if (result == 0) return;
            if (result < 0) return failSmoke("download failed");
            log("download=ok", .{});
            // Navigate to a known GET page before simulating web-process exit.
            smoke = .crash;
            smokeNavigate(&tabs[active], "/page/initial");
        },
        .crash => {
            if (!smokePage(initial_title)) return;
            log("fixture_crash_requested=1", .{});
            if (!native.moon_engine_test_crash(tabs[active].view.?)) return failSmoke("could not terminate fixture web process");
            smoke = .recover;
        },
        .recover => {
            if (tabs[active].phase == .crashed) {
                recovery_started = true;
                moon_command(native.MOON_RELOAD, 0, null);
                return;
            }
            if (!recovery_started or !smokePage(initial_title)) return;
            log("crash_recovery=ok", .{});
            log("PASS", .{});
            native.moon_quit(0);
        },
    }
}
