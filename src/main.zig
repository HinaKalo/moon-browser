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
const network_capture = @import("network_capture.zig");
const reader = @import("reader.zig");
const popups = @import("popup_policy.zig");
const autoplay = @import("autoplay_policy.zig");
const site_sound = @import("site_sound.zig");
const notifications = @import("site_notifications.zig");
const reading = @import("reading.zig");
const recent_tabs = @import("recent_tabs.zig");
const market = @import("market.zig");
const plugin_manager = @import("plugin_manager.zig");
const updater = @import("updater.zig");
const search = @import("search.zig");
const profile_db = @import("profile_db.zig");
const last_session = @import("session.zig");
const tab_groups = @import("tab_groups.zig");

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
    selected: bool = false,
    group: u32 = 0,
    muted: bool = false,
    media: MediaControls = .{},
    opening: Opening = .none,
    requested_at: u64 = 0,
};
const MediaControls = struct {
    paused: bool = false,
    result: sdk.MediaPlayback = .idle,
    kind: c_uint = 0,
    visible_until: u64 = 0,
    pending: ?struct { request: u64, deadline: u64, resuming: bool } = null,
};
const Retiring = struct { handle: *anyopaque, pid: u32 };

var tabs: [max_tabs]Tab = undefined;
var count: usize = 0;
var active: usize = 0;
var selection_count: usize = 0;
var selection_anchor: u64 = 0;
var selection_epoch: u64 = 1;
var find_tab: u64 = 0;
var find_owner: [96:0]u8 = @splat(0);
var fullscreen_owner: [96:0]u8 = @splat(0);
const PageSaveJob = struct {
    request: u64, tab: u64, navigation: u64, deadline: u64,
    owner: [96:0]u8, path: [4096:0]u8, replace: bool,
};
var page_save_job: ?PageSaveJob = null;
var page_save_serial: u64 = 0;
var media_serial: u64 = 0;
var site_clear_confirming = false;
const GroupPanel = struct { tab: u64, source: u64 };
var group_panel: ?GroupPanel = null;
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

fn externalUrl(input: []const u8, buffer: []u8) ?[:0]const u8 {
    if (!safeURL(input) or !std.unicode.utf8ValidateSlice(input)) return null;
    return normalize(input,buffer);
}

export fn moon_external_url_valid(text: [*c]const u8) bool {
    var buffer: [4096]u8 = undefined;
    return text!=null and externalUrl(slice(text),&buffer)!=null;
}

export fn moon_external_url_open(text: [*c]const u8) bool {
    if (stopped or count==0 or native.moon_shell_private() or text==null) return false;
    var buffer: [4096]u8 = undefined;
    const url=externalUrl(slice(text),&buffer) orelse return false;
    const tab=&tabs[active];
    if (tab.phase==.blank and !tab.pinned and tab.opening==.none) {
        navigate(tab,url);
    } else {
        if (count==tabs.len) return false;
        addTab(url,true);
    }
    return true;
}

fn appendSuggestions(output: []native.MoonAddressSuggestion, length: *usize,
    matches: []const profile_db.Link, bookmark: bool) void {
    for (matches) |match| {
        if (length.*==output.len) return;
        if (!history.validURL(match.url)) continue;
        for (output[0..length.*]) |*existing| {
            if (equals(slice(&existing.url),match.url)) break;
        } else {
            const entry=&output[length.*];
            if (!copy(&entry.url,match.url)) continue;
            entry.title[0]=0;
            if (std.unicode.utf8ValidateSlice(match.title) and std.mem.indexOfAny(u8,match.title,"\r\n\t")==null)
                _=copy(&entry.title,match.title);
            entry.bookmark=bookmark;
            length.*+=1;
        }
    }
}

export fn moon_suggest_collect(input: [*c]const u8, rows: [*c]native.MoonAddressSuggestion, capacity: usize) usize {
    if (stopped or input==null or rows==null or capacity==0 or native.moon_shell_private() or !plugins.systemEnabled(.@"search.manage")) return 0;
    const query=std.mem.trim(u8,slice(input)," ");
    if (query.len==0 or query.len>256 or query[0]=='@' or !std.unicode.utf8ValidateSlice(query)) return 0;
    for (query) |byte| if (std.ascii.isControl(byte)) return 0;
    const output=rows[0..@min(capacity,native.MOON_ADDRESS_SUGGESTION_LIMIT)];
    const enabled=search.suggestionSources();
    var arena=std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator=arena.allocator();
    var matches: [native.MOON_ADDRESS_SUGGESTION_LIMIT*2]profile_db.Link=undefined;
    var length: usize=0;
    if (enabled.bookmarks and plugins.systemEnabled(.@"bookmarks.manage")) {
        const results: []const profile_db.Link=bookmarks.suggest(allocator,query,matches[0..output.len]) catch &.{};
        appendSuggestions(output,&length,results,true);
    }
    if (length<output.len and enabled.history and plugins.systemEnabled(.@"history.manage")) {
        const results: []const profile_db.Link=history.suggest(allocator,query,&matches) catch &.{};
        appendSuggestions(output,&length,results,false);
    }
    return length;
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
    network_capture.closed(tab.id);
    site_data.invalidate(tab.id);
    page_source.invalidate(tab.id);
    reader.invalidate(tab.id);
    popups.clear(tab.id);
    tab.media = .{};
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
        reader.closed(tab.id);
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
        reader.closed(tab.id);
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
    selectTab(index,notify,true);
}

fn selectTab(index: usize, notify: bool, expand_group: bool) void {
    if (index >= count) return;
    const cleared = discardTabSelection();
    if (index == active) {
        if (cleared) native.moon_shell_refresh_tab_order(false);
        return;
    }
    shortcut_capture = null;
    moon_find_dismiss(false);
    const now = native.moon_clock();
    tabs[active].last_used = now;
    if (site_data.ownerId()) |owner| {
        if (site_data.owns(tabs[active].id,owner)) {
            site_data.dropStoragePage();
            site_data.dropCookies();
        }
    }
    if (tabs[active].view) |view| native.moon_engine_show(view, false);
    active = index;
    const tab = &tabs[index];
    if (expand_group) if (tab_groups.get(tab.group)) |group| { group.collapsed=false; };
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
        if (tab.pinned or tab.unsafe_history or (tab.loading and !tab.document_committed) or tab.opening!=.none or
            (tab.phase!=.live and tab.phase!=.dormant) or !readCommittedAddress(tab,&addresses[used])) continue;
        const title = slice(&tab.title);
        entries[used] = .{ .title=if (std.unicode.utf8ValidateSlice(title)) title else "", .url=slice(&addresses[used]), .group=tab.group };
        if (index==active) selected = used;
        used += 1;
    }
    var groups: [tab_groups.limit]sdk.TabGroup = undefined;
    var group_count: usize = 0;
    for (&tab_groups.groups) |*group| {
        if (group.id==0) continue;
        for (entries[0..used]) |entry| if (entry.group==group.id) {
            groups[group_count] = group.describe();
            group_count+=1;
            break;
        };
    }
    _ = last_session.save(.{ .tabs=entries[0..used], .selected=selected, .groups=groups[0..group_count] });
}

fn resumeLastSession() sdk.SessionRestore {
    if (count==0 or !plugins.systemEnabled(.@"tabs.session.manage") or !network.mayNavigate()) return .unavailable;
    const saved = last_session.read() orelse return .empty;
    defer saved.deinit();
    const snapshot = saved.value;
    if (snapshot.tabs.len==0) return .empty;
    const current = &tabs[active];
    const reuse = active==count-1 and !current.pinned and current.group==0 and current.phase==.blank and current.opening==.none and current.view==null;
    const start = if (reuse) active else count;
    if (snapshot.tabs.len > tabs.len-count+@intFromBool(reuse)) return .tabLimit;

    const append_from: usize = if (reuse) 1 else 0;
    const appended_at = count;
    const now = native.moon_clock();
    var remapped: [tab_groups.limit]u32 = @splat(0);
    for (snapshot.groups,0..) |group,index| {
        for (snapshot.tabs) |tab| if (tab.group==group.id) {
            if (tab_groups.create(group)) |entry| remapped[index]=entry.id;
            break;
        };
    }
    for (snapshot.tabs,0..) |saved_tab,offset| {
        const index = if (reuse and offset==0) start else appended_at+offset-append_from;
        var tab: Tab = .{ .id=next_id, .phase=.dormant, .has_document=true, .loaded=true, .last_used=now };
        if (saved_tab.group!=0) for (snapshot.groups,0..) |group,group_index| {
            if (group.id==saved_tab.group) {
                tab.group=remapped[group_index];
                break;
            }
        };
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
        selectTab(target,true,false);
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

fn lastGroupMember(id: u32) ?usize {
    if (id==0) return null;
    var index=count;
    while (index!=0) {
        index-=1;
        if (tabs[index].group==id) return index;
    }
    return null;
}

fn pruneTabGroup(id: u32) void {
    const group=tab_groups.get(id) orelse return;
    if (lastGroupMember(id)==null) group.*=.{};
}

fn assignTabGroup(index: usize, next: u32) void {
    const old=tabs[index].group;
    if (old==next) return;
    const destination=if (lastGroupMember(next)) |anchor|
        anchor+@intFromBool(index>anchor)
    else lastGroupMember(old) orelse index;
    tabs[index].group=next;
    moveTab(index,destination);
    pruneTabGroup(old);
}

export fn moon_sidebar_rows(rows: [*c]native.MoonSidebarRow, capacity: usize, active_row: *usize) usize {
    active_row.*=0;
    if (stopped) return 0;
    const can_collapse=plugins.systemEnabled(.@"tabs.groups");
    var used: usize=0;
    var index: usize=0;
    while (index<count and used<capacity) {
        const group=tab_groups.get(tabs[index].group);
        const start=index;
        index+=1;
        if (group) |entry| {
            while (index<count and tabs[index].group==entry.id) index+=1;
            const contains_active=active>=start and active<index;
            const collapsed=can_collapse and entry.collapsed;
            if (collapsed and contains_active) active_row.*=used;
            rows[used]=.{ .tab=start,.group=entry.id,.color=@intFromEnum(entry.color),.members=@intCast(index-start),
                .header=true,.collapsed=collapsed,.active=collapsed and contains_active };
            used+=1;
            if (collapsed) continue;
        }
        for (start..index) |tab_index| {
            if (used==capacity) return used;
            if (tab_index==active) active_row.*=used;
            rows[used]=.{ .tab=tab_index,.group=if (group) |entry| entry.id else 0,
                .color=if (group) |entry| @intFromEnum(entry.color) else 0,.members=0,
                .header=false,.collapsed=false,.active=tab_index==active };
            used+=1;
        }
    }
    return used;
}

export fn moon_group_name(id: u32) [*:0]const u8 {
    const group=tab_groups.get(id) orelse return "";
    return &group.name;
}

export fn moon_group_toggle(id: u32) void {
    if (stopped or !plugins.systemEnabled(.@"tabs.groups")) return;
    const group=tab_groups.get(id) orelse return;
    _ = discardTabSelection();
    group.collapsed=!group.collapsed;
    native.moon_shell_refresh_tab_order(false);
}

export fn moon_group_panel(id: [*c]const u8, source: u64) bool {
    if (stopped or tabIndex(source)==null or !plugins.hasGrant(slice(id),.@"tabs.groups")) return false;
    if (!moon_plugin_open_page(id)) return false;
    const panel=tabs[active].id;
    group_panel=.{ .tab=panel,.source=if (panel!=source) source else if (group_panel) |previous|
        (if (previous.tab==panel) previous.source else 0) else 0 };
    return true;
}

export fn moon_group_create(source: u64) c_int {
    if (stopped) return @intFromEnum(sdk.TabGroupResult.unavailable);
    const index=tabIndex(source) orelse return @intFromEnum(sdk.TabGroupResult.unavailable);
    if (tabs[index].pinned) return @intFromEnum(sdk.TabGroupResult.unavailable);
    const group=tab_groups.create(null) orelse return @intFromEnum(sdk.TabGroupResult.limitReached);
    assignTabGroup(index,group.id);
    native.moon_shell_refresh();
    return @intFromEnum(sdk.TabGroupResult.saved);
}

export fn moon_group_remove_tab(source: u64) c_int {
    if (stopped) return @intFromEnum(sdk.TabGroupResult.unavailable);
    const index=tabIndex(source) orelse return @intFromEnum(sdk.TabGroupResult.unavailable);
    if (tabs[index].group==0) return @intFromEnum(sdk.TabGroupResult.unavailable);
    assignTabGroup(index,0);
    native.moon_shell_refresh();
    return @intFromEnum(sdk.TabGroupResult.saved);
}

fn activeGroupPanel(panel: u64, owner: []const u8) bool {
    if (stopped or count==0 or tabs[active].id!=panel or !tabs[active].extension or
        !plugins.hasGrant(owner,.@"tabs.groups")) return false;
    var buffer: [256]u8 = undefined;
    const address=plugins.addressForId(owner,&buffer) orelse return false;
    return equals(address,slice(&tabs[active].url));
}

fn groupPanelSource(panel: u64) ?usize {
    const binding=group_panel orelse return null;
    if (binding.tab!=panel) return null;
    const index=tabIndex(binding.source) orelse return null;
    return if (tabs[index].pinned) null else index;
}

export fn moon_group_list(panel: u64, owner: [*c]const u8, output: [*c]native.MoonTabGroup, capacity: usize,
    total: *usize, assigned: *u32, assignable: *bool) bool {
    if (!activeGroupPanel(panel,slice(owner))) return false;
    const source=groupPanelSource(panel);
    assignable.*=source!=null;
    assigned.*=if (source) |index| tabs[index].group else 0;
    total.*=writeTabGroups(output,capacity);
    return true;
}

fn writeTabGroups(output: [*c]native.MoonTabGroup, capacity: usize) usize {
    var total: usize=0;
    var index: usize=0;
    while (index<count and total<capacity) {
        const id=tabs[index].group;
        index+=1;
        const group=tab_groups.get(id) orelse continue;
        var members: u32=1;
        while (index<count and tabs[index].group==id) : (index+=1) members+=1;
        output[total]=.{ .id=id,.color=@intFromEnum(group.color),.members=members,
            .collapsed=group.collapsed,.name=group.name[0..group.name.len].* };
        total+=1;
    }
    return total;
}

export fn moon_group_selection_choices(output: [*c]native.MoonTabGroup, capacity: usize, can_assign: *bool, can_remove: *bool) usize {
    can_assign.*=false;
    can_remove.*=false;
    if (stopped or !plugins.systemEnabled(.@"tabs.groups")) return 0;
    for (tabs[0..count]) |*tab| {
        if (!tab.selected or tab.pinned) continue;
        can_assign.*=true;
        can_remove.*=can_remove.* or tab.group!=0;
    }
    return if (can_assign.*) writeTabGroups(output,capacity) else 0;
}

export fn moon_group_selection_command(epoch: u64, action: c_int, id: u32) void {
    if (stopped or epoch==0 or epoch!=moon_tab_selection_epoch() or !plugins.systemEnabled(.@"tabs.groups")) return;
    const selection: sdk.TabGroupSelection = .{
        .action=std.enums.fromInt(sdk.TabGroupSelection.Action,action) orelse return,.id=id,
    };
    const snapshot=tabSnapshot() orelse return;
    _=plugins.launchTabGroupSelection(selection,snapshot);
}

export fn moon_group_selection_apply(epoch: u64, action: c_int, id: u32, result: *native.MoonGroupSelectionResult) c_int {
    const outcome: sdk.TabGroupResult = applyGroupSelection(epoch,action,id,result);
    return @intFromEnum(outcome);
}

fn applyGroupSelection(epoch: u64, action: c_int, id: u32, result: *native.MoonGroupSelectionResult) sdk.TabGroupResult {
    result.*=.{ .moved=0,.kept=0 };
    if (stopped or epoch==0 or epoch!=moon_tab_selection_epoch()) return .unavailable;
    var ids: [max_tabs]u64=undefined;
    var length: usize=0;
    for (tabs[0..count]) |*tab| {
        if (!tab.selected) continue;
        if (tab.pinned) {
            result.kept+=1;
            continue;
        }
        ids[length]=tab.id;
        length+=1;
    }
    if (length==0) return .unavailable;
    const destination: u32 = switch (action) {
        native.MOON_GROUP_CREATE => (tab_groups.create(null) orelse return .limitReached).id,
        native.MOON_GROUP_ASSIGN => (tab_groups.get(id) orelse return .unavailable).id,
        native.MOON_GROUP_REMOVE => 0,
        else => return .unavailable,
    };
    const current=&tabs[active];
    const reveal=current.selected and !current.pinned and current.group!=destination;
    for (0..length) |offset| {
        // Removing a member places it just after its old group. Work backwards to preserve order.
        const tab_id=ids[if (destination==0) length-1-offset else offset];
        const index=tabIndex(tab_id) orelse unreachable;
        if (tabs[index].group==destination) continue;
        assignTabGroup(index,destination);
        result.moved+=1;
    }
    if (reveal) {
        if (tab_groups.get(destination)) |group| group.collapsed=false;
    }
    _=discardTabSelection();
    native.moon_shell_refresh();
    return .saved;
}

export fn moon_group_assign(panel: u64, owner: [*c]const u8, id: u32) c_int {
    if (!activeGroupPanel(panel,slice(owner)) or (id!=0 and tab_groups.get(id)==null))
        return @intFromEnum(sdk.TabGroupResult.unavailable);
    const index=groupPanelSource(panel) orelse return @intFromEnum(sdk.TabGroupResult.unavailable);
    assignTabGroup(index,id);
    native.moon_shell_refresh();
    return @intFromEnum(sdk.TabGroupResult.saved);
}

export fn moon_group_update(panel: u64, owner: [*c]const u8, id: u32, name: [*c]const u8, color: c_uint, collapsed: bool) c_int {
    if (!activeGroupPanel(panel,slice(owner))) return @intFromEnum(sdk.TabGroupResult.unavailable);
    const group=tab_groups.get(id) orelse return @intFromEnum(sdk.TabGroupResult.unavailable);
    const display=std.mem.trim(u8,slice(name)," ");
    if (!tab_groups.validName(display)) return @intFromEnum(sdk.TabGroupResult.invalidName);
    const tint=std.enums.fromInt(sdk.TabGroupColor,color) orelse return @intFromEnum(sdk.TabGroupResult.unavailable);
    tab_groups.setName(group,display);
    group.color=tint;
    group.collapsed=collapsed;
    native.moon_shell_refresh();
    return @intFromEnum(sdk.TabGroupResult.saved);
}

export fn moon_group_dissolve(panel: u64, owner: [*c]const u8, id: u32) c_int {
    if (!activeGroupPanel(panel,slice(owner))) return @intFromEnum(sdk.TabGroupResult.unavailable);
    const group=tab_groups.get(id) orelse return @intFromEnum(sdk.TabGroupResult.unavailable);
    for (tabs[0..count]) |*tab| if (tab.group==id) { tab.group=0; };
    group.*=.{};
    native.moon_shell_refresh();
    return @intFromEnum(sdk.TabGroupResult.saved);
}

fn dropPosition(drop: *const native.MoonTabDrop) ?struct { from: usize, to: usize } {
    if (stopped or drop.source == drop.anchor) return null;
    const from = tabIndex(drop.source) orelse return null;
    const anchor = tabIndex(drop.anchor) orelse return null;
    if (tabs[from].pinned != tabs[anchor].pinned) return null;
    if (drop.into_group) {
        const group=tab_groups.get(tabs[anchor].group) orelse return null;
        if (!plugins.systemEnabled(.@"tabs.groups") or tabs[from].group==group.id) return null;
        return .{ .from=from,.to=anchor };
    }
    if (tabs[from].group!=tabs[anchor].group) return null;
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
    moon_tab_drop_run(&.{ .source=tabs[active].id,.anchor=tabs[anchor].id,.after=down,.into_group=false });
}

export fn moon_tabs_reorder(drop: *const native.MoonTabDrop) c_int {
    const position = dropPosition(drop) orelse return @intFromEnum(sdk.TabReorder.unavailable);
    if (drop.into_group) {
        assignTabGroup(position.from,tabs[position.to].group);
        native.moon_shell_refresh();
        return @intFromEnum(sdk.TabReorder.moved);
    }
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
        if (!canMuteTab(tab)) return .unavailable;
        setTabMuted(tab,!tab.muted);
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
    const old_group=tab.group;
    tab.group=0;
    const destination = if (was_pinned) pinned_count-1 else pinned_count;
    moveTab(index,destination);
    if (!savePinnedTabs()) {
        moveTab(destination,index);
        tabs[index].pinned = was_pinned;
        tabs[index].group = old_group;
        return .saveFailed;
    }
    pruneTabGroup(old_group);
    native.moon_shell_refresh();
    return if (was_pinned) .unpinned else .pinned;
}

fn canMuteTab(tab: *const Tab) bool {
    return tab.muted or (!tab.extension and safeURL(slice(&tab.url)));
}

fn setTabMuted(tab: *Tab, muted: bool) void {
    tab.muted = muted;
    if (!tab.extension) if (tab.view) |view| native.moon_engine_mute(view,muted);
}

export fn moon_tab_selection_mute_action() c_int {
    var found = false;
    for (tabs[0..count]) |*tab| {
        if (!tab.selected or !canMuteTab(tab)) continue;
        if (!tab.muted) return 1;
        found = true;
    }
    return if (found) 0 else -1;
}

export fn moon_tab_selection_mute_command(epoch: u64, muted: bool) void {
    if (stopped or epoch==0 or epoch!=moon_tab_selection_epoch() or !plugins.systemEnabled(.@"tabs.organize")) return;
    const snapshot = tabSnapshot() orelse return;
    _ = plugins.launchTabMuteSelection(muted,snapshot);
}

export fn moon_tab_selection_set_muted(epoch: u64, muted: bool) c_int {
    if (stopped or epoch==0 or epoch!=moon_tab_selection_epoch()) return -1;
    var changed: c_int = 0;
    for (tabs[0..count]) |*tab| {
        if (!tab.selected or !canMuteTab(tab) or tab.muted==muted) continue;
        setTabMuted(tab,muted);
        changed += 1;
    }
    if (changed!=0) native.moon_shell_refresh_tab_order(false);
    return changed;
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
    const title=source.title;
    const muted=source.muted;
    const group=source.group;
    const destination = if (source.pinned) pinnedCount() else index+1;
    if (destination<count) std.mem.copyBackwards(Tab,tabs[destination+1..count+1],tabs[destination..count]);
    if (active>=destination) active += 1;
    tabs[destination] = .{
        .id=next_id, .phase=.dormant, .url=address, .title=title,
        .session=session, .muted=muted, .group=group, .has_document=true, .loaded=true,
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
    _ = discardTabSelection();
    site_data.closed(tabs[index].id);
    page_source.closed(tabs[index].id);
    reader.closed(tabs[index].id);
    const was_active = index == active;
    const was_pinned = tabs[index].pinned;
    const old_group = tabs[index].group;
    if (group_panel) |binding| if (binding.tab==tabs[index].id) { group_panel=null; };
    rememberClosedTab(&tabs[index]);
    detach(&tabs[index]);
    forgetSession(&tabs[index]);
    count -= 1;
    if (index < count) std.mem.copyForwards(Tab, tabs[index..count], tabs[index + 1 .. count + 1]);
    pruneTabGroup(old_group);
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
    closeMarkedTabs(selected[0..count], result);
    return true;
}

fn discardTabSelection() bool {
    if (selection_count == 0) return false;
    for (tabs[0..count]) |*tab| tab.selected = false;
    selection_count = 0;
    selection_anchor = 0;
    selection_epoch +%= 1;
    return true;
}

export fn moon_tab_selection_count() usize {
    return selection_count;
}

export fn moon_tab_selection_epoch() u64 {
    return if (selection_count > 0) selection_epoch else 0;
}

export fn moon_tab_selection_clear() bool {
    if (stopped or !discardTabSelection()) return false;
    native.moon_shell_refresh_tab_order(false);
    return true;
}

export fn moon_tab_selection_pick(index: usize, range: bool) bool {
    if (stopped or index >= count or !plugins.systemEnabled(.@"tabs.manage")) return false;
    const target = &tabs[index];
    if (range) {
        const anchor = tabIndex(selection_anchor) orelse active;
        const first = @min(index, anchor);
        const last = @max(index, anchor);
        const show_groups = plugins.systemEnabled(.@"tabs.groups");
        selection_count = 0;
        for (tabs[0..count], 0..) |*tab, position| {
            const collapsed = if (show_groups) if (tab_groups.get(tab.group)) |group| group.collapsed else false else false;
            tab.selected = position >= first and position <= last and !collapsed;
            if (tab.selected) selection_count += 1;
        }
        selection_anchor = tabs[anchor].id;
    } else {
        if (selection_count == 0) {
            const current = &tabs[active];
            const collapsed = if (tab_groups.get(current.group)) |group| group.collapsed and plugins.systemEnabled(.@"tabs.groups") else false;
            if (!collapsed) {
                current.selected = true;
                selection_count = 1;
            }
        }
        target.selected = !target.selected;
        if (target.selected) selection_count += 1 else selection_count -= 1;
        selection_anchor = target.id;
    }
    if (selection_count == 0) selection_anchor = 0;
    selection_epoch +%= 1;
    native.moon_shell_refresh_tab_order(false);
    return true;
}

export fn moon_tabs_close_selection(epoch: u64, result: *native.MoonTabCloseResult) bool {
    if (stopped or epoch == 0 or epoch != moon_tab_selection_epoch() or !plugins.systemEnabled(.@"tabs.manage")) return false;
    var marked: [max_tabs]bool = @splat(false);
    result.* = .{ .closed=0, .kept=0 };
    var first_kept: ?usize = null;
    var next_kept: ?usize = null;
    for (tabs[0..count], 0..) |*tab, index| {
        if (tab.selected) {
            if (canCloseInGroup(tab)) marked[index] = true else result.kept += 1;
        }
        if (marked[index]) continue;
        if (first_kept == null) first_kept = index;
        if (index > active and next_kept == null) next_kept = index;
    }
    _ = discardTabSelection();
    if (marked[active]) {
        if (next_kept orelse first_kept) |index| chooseTab(index, true);
    }
    closeMarkedTabs(marked[0..count], result);
    native.moon_shell_refresh_tab_order(false);
    return true;
}

fn closeMarkedTabs(marked: []const bool, result: *native.MoonTabCloseResult) void {
    var index = marked.len;
    while (index > 0) {
        index -= 1;
        if (!marked[index]) continue;
        if (!canCloseInGroup(&tabs[index])) {
            result.kept += 1;
            continue;
        }
        closeTab(index);
        result.closed += 1;
    }
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
    if (tab.view) |view| if (native.moon_engine_inspecting(view) or native.moon_engine_viewport_active(view)) return .developerTools;
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
export fn moon_devtools_open(panel: c_int, placement: c_int, tab_id: u64, navigation: u64) bool {
    const view = devtoolsTarget(tab_id,navigation) orelse return false;
    return native.moon_engine_inspect(view,panel,placement);
}
export fn moon_devtools_viewport(owner: [*c]const u8, tab_id: u64, navigation: u64, width: c_uint, height: c_uint, fit: c_int) c_int {
    const view = devtoolsTarget(tab_id,navigation) orelse return @intFromEnum(sdk.ViewportResult.unavailable);
    const tab = &tabs[active];
    if (!moon_devtools_viewport_granted(owner) or (!native.moon_engine_viewport_active(view) and (tab.loading or !tab.loaded)))
        return @intFromEnum(sdk.ViewportResult.unavailable);
    return native.moon_engine_viewport(view,owner,width,height,fit);
}

export fn moon_devtools_viewport_granted(owner: [*c]const u8) bool {
    return plugins.hasGrant(slice(owner),.@"page.inspect");
}

export fn moon_devtools_prefer_window() bool {
    if (native.moon_shell_private()) return false;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const preferences = extension_settings.read(arena.allocator(),"moon.devtools") catch return false;
    return equals(sdk.string(preferences.object.get("placement")) orelse "","window");
}

export fn moon_devtools_hard_reload(tab_id: u64, navigation: u64) c_int {
    const view = devtoolsTarget(tab_id,navigation) orelse return @intFromEnum(sdk.HardReloadResult.unavailable);
    const result = hardReloadGuard(&tabs[active]);
    if (result == .started) native.moon_engine_reload_from_origin(view);
    return @intFromEnum(result);
}

fn hardReloadGuard(tab: *const Tab) sdk.HardReloadResult {
    if (tab.loading or !tab.loaded) return .unavailable;
    if (tab.unsafe_history) return .resubmission;
    if (tab.dirty) return .edited;
    return .started;
}
export fn moon_devtools_toggle(tab_id: u64, navigation: u64) c_int {
    const view = devtoolsTarget(tab_id,navigation) orelse return -1;
    if (native.moon_engine_close_inspector(view)) return 0;
    return if (native.moon_engine_inspect(view,@intFromEnum(sdk.InspectorPanel.inspector),native.MOON_INSPECT_PREFERRED)) 1 else -1;
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
    native.moon_engine_retry_poll(now);
    for (tabs[0..count]) |*tab| {
        if (tab.media.pending) |pending| {
            if (now>=pending.deadline) {
                tab.media.pending=null;
                tab.media.result=.failed;
            }
        }
    }
    downloads.flush();
    site_data.tick(now);
    page_source.tick(now);
    reader.tick(now);
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
        copyShortTitle(&row.title,slice(&tab.title));
    }
    return width;
}
fn copyShortTitle(output: []u8, title: []const u8) void {
    var end = @min(title.len,output.len-1);
    while (end!=0 and end<title.len and title[end]&0xc0==0x80) end-=1;
    if (end!=0 and std.unicode.utf8ValidateSlice(title[0..end])) @memcpy(output[0..end],title[0..end]);
}

fn mediaView(tab: *const Tab) ?*native.MoonView {
    if (tab.extension or !tab.document_committed or tab.phase!=.live) return null;
    return tab.view;
}

export fn moon_media_tabs(offset: u32, rows: [*]native.MoonMediaTab, cap: usize) usize {
    if (stopped or native.moon_shell_private()) return 0;
    var skipped: usize = 0;
    var used: usize = 0;
    const can_playback = native.moon_engine_media_actions_available();
    const now = native.moon_clock();
    for (tabs[0..count]) |*tab| {
        const view = mediaView(tab) orelse continue;
        const origin = popups.origin(slice(&tab.url)) orelse continue;
        const playing = native.moon_engine_playing(view);
        if (playing==0 and !tab.media.paused and tab.media.pending==null and now>=tab.media.visible_until) continue;
        if (skipped<offset) {
            skipped+=1;
            continue;
        }
        if (used==cap) break;
        const row = &rows[used];
        row.* = .{
            .id=tab.id,.navigation=tab.navigation,.playing=if (playing!=0) playing else tab.media.kind,
            .playback_result=@intFromEnum(tab.media.result),
            .muted=tab.muted,.site_muted=native.moon_engine_site_muted(view),.paused=tab.media.paused,
            .pending=tab.media.pending!=null,.can_playback=can_playback,.title=@splat(0),.origin=origin[0..320].*,
        };
        copyShortTitle(&row.title,slice(&tab.title));
        used+=1;
    }
    return used;
}

export fn moon_media_control(panel: u64, owner: [*c]const u8, id: u64, navigation: u64, raw: c_uint) c_int {
    return @intFromEnum(controlMedia(panel,slice(owner),id,navigation,raw));
}

fn controlMedia(panel: u64, owner: []const u8, id: u64, navigation: u64, raw: c_uint) sdk.MediaResult {
    if (stopped or count==0 or native.moon_shell_private() or tabs[active].id!=panel or !tabs[active].extension or
        !plugins.hasGrant(owner,.@"media.control")) return .unavailable;
    const action = std.enums.fromInt(sdk.MediaAction,raw) orelse return .unavailable;
    const index = tabIndex(id) orelse return .unavailable;
    const tab = &tabs[index];
    if (tab.navigation!=navigation or popups.origin(slice(&tab.url))==null) return .unavailable;
    const view = mediaView(tab) orelse return .unavailable;
    const playing = native.moon_engine_playing(view);
    const now = native.moon_clock();
    if (playing==0 and !tab.media.paused and tab.media.pending==null and now>=tab.media.visible_until) return .unavailable;
    switch (action) {
        .focus => chooseTab(index,true),
        .mute, .unmute => {
            tab.muted=action==.mute;
            native.moon_engine_mute(view,tab.muted);
            native.moon_shell_refresh();
        },
        .pause, .@"resume" => {
            if (tab.media.pending!=null) return .busy;
            if ((action==.pause and playing==0 and now>=tab.media.visible_until) or
                (action==.@"resume" and !tab.media.paused)) return .unavailable;
            media_serial+%=1;
            if (!native.moon_engine_media_action(view,media_serial,action==.@"resume")) return .unavailable;
            tab.last_used=now;
            if (playing!=0) tab.media.kind=playing;
            tab.media.pending=.{ .request=media_serial,.deadline=now+4500,.resuming=action==.@"resume" };
            tab.media.result=.idle;
            return .pending;
        },
    }
    return .applied;
}

export fn moon_media_action_result(id: u64, request: u64, result: [*c]const u8) void {
    if (stopped) return;
    const index = tabIndex(id) orelse return;
    const tab = &tabs[index];
    const pending = tab.media.pending orelse return;
    if (pending.request!=request) return;
    tab.media.pending=null;
    const raw = slice(result);
    tab.media.result = if (equals(raw,"{\"status\":\"paused\"}")) .paused
        else if (equals(raw,"{\"status\":\"resumed\"}")) .resumed
        else if (equals(raw,"{\"status\":\"partial\"}")) .partial
        else if (equals(raw,"{\"status\":\"unavailable\"}")) .unavailable else .failed;
    if (tab.media.result==.paused) tab.media.paused=true;
    if (tab.media.result==.resumed) tab.media.visible_until=native.moon_clock()+2500;
    if (tab.media.result==.resumed or (pending.resuming and tab.media.result==.unavailable)) tab.media.paused=false;
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
        autoplay.init(profile);
        site_sound.init(profile);
        notifications.init(profile);
        userscripts.init(profile);
        search.init();
    }
    plugins.init(app, profile);
    native.moon_engine_context_inspect_available(plugins.inspectElementLabel()!=null);
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
    if (smoke==.off) native.moon_shell_bookmarks_changed();
    if (smoke != .off) {
        smoke_deadline = native.moon_clock() + 300000;
        _ = std.fmt.bufPrintSentinel(&smoke_download, "{s}\\smoke-download.txt", .{profile}, 0) catch return false;
        smokeNavigate(&tabs[0], "/page/initial");
    } else if (first_url) |initial| {
        var buffer: [4096]u8 = undefined;
        if (normalize(initial, &buffer)) |url| navigate(&tabs[active], url);
    } else if (plugins.systemEnabled(.@"tabs.session.manage")) {
        switch (last_session.mode()) {
            .newTab => {},
            .restore => _ = resumeLastSession(),
            .pages => {
                var buffer: last_session.PageViews = undefined;
                const pages = last_session.pages(&buffer);
                for (pages[1..]) |url| {
                    var address: [4096:0]u8 = @splat(0);
                    _ = copy(&address,url);
                    if (!addBackgroundTab(address,@splat(0))) break;
                }
                navigate(&tabs[active],pages[0]);
            },
        }
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
        reader.reset();
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
        native.MOON_TAB_CLOSE_SELECTED => {
            if (argument == 0 or argument != moon_tab_selection_epoch()) return;
            _ = plugins.namedCommand("moon.tab-tools","closeSelected",tabSnapshot());
        },
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
        native.MOON_TAB_GROUP_NEW, native.MOON_TAB_GROUP_PANEL, native.MOON_TAB_GROUP_REMOVE => {
            if (!plugins.systemEnabled(.@"tabs.groups")) return;
            const target=tabIndex(argument) orelse return;
            const action: []const u8 = switch (command) {
                native.MOON_TAB_GROUP_NEW => "groupCreate",
                native.MOON_TAB_GROUP_PANEL => "groups",
                native.MOON_TAB_GROUP_REMOVE => "groupRemove",
                else => unreachable,
            };
            _=plugins.namedCommand("moon.tab-tools",action,snapshotFor(&tabs[target]));
        },
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
        native.MOON_TOGGLE_SIDEBAR => {
            if (moon_appearance_available()) {
                _ = plugins.namedCommand("moon.appearance","focus",tabSnapshot());
            } else if (native.moon_shell_focus_mode()) {
                _ = native.moon_shell_set_appearance(native.moon_shell_dark_mode(),false);
            }
        },
        native.MOON_OPEN_PLUGINS => if (!native.moon_shell_private()) { _ = openInternalPage(plugin_manager.address); },
        native.MOON_UPDATES => if (!native.moon_shell_private()) updater.open(native.moon_clock()),
        native.MOON_MARKET => if (!native.moon_shell_private()) { _ = openInternalPage(market.address); },
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
            reader.invalidate(id);
            popups.invalidate(id);
            tab.media = .{};
            tab.document_committed = false;
            tab.navigation +%= 1;
            if (find_tab == id) moon_find_dismiss(true);
            tab.loading = true;
            tab.loaded = false;
            tab.history_visit = null;
        },
        native.MOON_COMMITTED => {
            page_source.invalidate(id);
            reader.invalidate(id);
            tab.document_committed = true;
            tab.dirty = false;
            tab.has_document = true;
            tab.deadline = 0;
            tab.phase = .live;
            sync(tab);
            if (tab.view) |view| {
                applySiteSound(view,tab.extension);
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
            if (tab.has_document) {
                if (tab.view) |view| applySiteSound(view,tab.extension);
            }
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
            reader.invalidate(id);
            tab.navigation +%= 1;
            sync(tab);
            if (!tab.extension and !tab.restoring_history and plugins.systemEnabled(.@"history.manage")) tab.history_visit = history.record(slice(&tab.url),slice(&tab.title));
        },
        native.MOON_TERMINATED => {
            network_capture.closed(id);
            site_data.closed(id);
            page_source.closed(id);
            reader.closed(id);
            popups.clear(id);
            tab.media = .{};
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
            if (smoke != .off) {
                log("process_terminated tab={d}", .{id});
                log("process_termination_reason={s} stage={s}", .{slice(detail),@tagName(smoke)});
            }
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
export fn moon_download_source_allowed(source: [*c]const u8) bool {
    return downloads.sourceAllowed(slice(source));
}
export fn moon_download_begin(source: [*c]const u8) u32 {
    if (stopped or native.moon_shell_private() or !plugins.systemEnabled(.@"downloads.manage")) return 0;
    return downloads.begin(slice(source));
}
export fn moon_download_retry(panel: u64, id: u32) c_int {
    if (native.moon_shell_private() or !moon_extension_panel_active(panel) or !network.mayNavigate())
        return @intFromEnum(sdk.DownloadRetry.unavailable);
    return @intFromEnum(downloads.retry(id));
}
export fn moon_download_destination(id: u32, path: [*c]const u8) void {
    if (!stopped) downloads.destination(id,slice(path));
}
export fn moon_download_folder(folder: [*c]u8, capacity: usize, ask: *bool) bool {
    if (stopped or native.moon_shell_private() or !plugins.systemEnabled(.@"downloads.preferences")) return false;
    var buffer: [4096]u8 = undefined;
    const preferences = downloads.preferences(&buffer);
    ask.*=preferences.askWhereToSave;
    return copy(folder[0..capacity],preferences.folder orelse return false);
}

export fn moon_download_preferences_allowed(owner: [*c]const u8, panel: u64) bool {
    return !native.moon_shell_private() and moon_extension_panel_active(panel) and
        plugins.hasGrant(slice(owner),.@"downloads.preferences");
}
export fn moon_download_open_allowed(owner: [*c]const u8, panel: u64) bool {
    if (native.moon_shell_private() or !moon_extension_panel_active(panel)) return false;
    const id = slice(owner);
    if (!plugins.hasGrant(id,.@"downloads.manage") or !plugins.hasGrant(id,.@"downloads.open")) return false;
    var buffer: [256]u8 = undefined;
    const address = plugins.addressForId(id,&buffer) orelse return false;
    return equals(slice(&tabs[active].url),address);
}
var download_open_pending = false;
fn openDownloadedFile(owner: [*c]const u8, panel: u64, id: u32) sdk.DownloadOpen {
    if (download_open_pending or !moon_download_open_allowed(owner,panel)) return .unavailable;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = downloads.completedPath(allocator,id) catch |err| return if (err==error.NotFound) .missing else .unavailable;
    const status = native.moon_shell_download_open_status(path.ptr);
    const system_prompt = status==native.MOON_OPEN_DOWNLOAD_SYSTEM_PROMPT;
    if (!system_prompt and status!=native.MOON_OPEN_DOWNLOAD_DONE)
        return std.enums.fromInt(sdk.DownloadOpen,status) orelse .unavailable;
    download_open_pending = true;
    defer download_open_pending = false;
    if (!system_prompt) {
        const message = std.fmt.allocPrintSentinel(allocator,"用 Windows 默认应用打开此文件？\n\n{s}",.{path},0) catch return .unavailable;
        const navigation = tabs[active].navigation;
        if (!native.moon_shell_confirm("打开下载文件？",message.ptr)) return .cancelled;
        if (!moon_download_open_allowed(owner,panel) or tabs[active].navigation!=navigation) return .unavailable;
        const current = downloads.completedPath(allocator,id) catch |err| return if (err==error.NotFound) .missing else .unavailable;
        if (!std.mem.eql(u8,path,current)) return .unavailable;
    }
    return std.enums.fromInt(sdk.DownloadOpen,native.moon_shell_open_download(path.ptr,system_prompt)) orelse .unavailable;
}
export fn moon_download_open(owner: [*c]const u8, panel: u64, id: u32) c_int {
    return @intFromEnum(openDownloadedFile(owner,panel,id));
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
export fn moon_tab_url(index: usize) [*:0]const u8 {
    return if (index<count) &tabs[index].url else "";
}
export fn moon_tab_index(id: u64) usize {
    return tabIndex(id) orelse count;
}
export fn moon_tabs_open_search(source: u64) bool {
    if (stopped or count==0 or tabs[active].id!=source) return false;
    return native.moon_shell_tab_search();
}
export fn moon_tab_flags(index: usize) c_uint {
    if (index >= count) return 0;
    const tab = &tabs[index];
    return (if (tab.phase==.dormant) @as(c_uint,native.MOON_TAB_DORMANT) else 0) |
        (if (tab.phase==.crashed or tab.phase==.failed) @as(c_uint,native.MOON_TAB_FAILED) else 0) |
        (if (tab.loading) @as(c_uint,native.MOON_TAB_LOADING) else 0) |
        (if (tab.pinned) @as(c_uint,native.MOON_TAB_PINNED) else 0) |
        (if (tab.muted) @as(c_uint,native.MOON_TAB_MUTED) else 0) |
        (if (tab.view!=null and native.moon_engine_site_muted(tab.view.?)) @as(c_uint,native.MOON_TAB_SITE_MUTED) else 0) |
        (if (!native.moon_shell_private() and (tab.pinned or (!tab.extension and tab.has_document and !tab.unsafe_history and !tab.loading and safeURL(slice(&tab.url)))))
            @as(c_uint,native.MOON_TAB_CAN_PIN) else 0) |
        (if (canMuteTab(tab)) @as(c_uint,native.MOON_TAB_CAN_MUTE) else 0) |
        (if (canDuplicate(tab) and safeURL(slice(&tab.url))) @as(c_uint,native.MOON_TAB_CAN_DUPLICATE) else 0) |
        (if (tab.has_document and !tab.extension and safeURL(slice(&tab.url))) @as(c_uint,native.MOON_TAB_CAN_COPY_ADDRESS) else 0) |
        (if (hasSite(tab)) @as(c_uint,native.MOON_TAB_HAS_SITE) else 0) |
        (if (tab.selected) @as(c_uint,native.MOON_TAB_SELECTED) else 0);
}

fn hasSite(tab: *const Tab) bool {
    return tab.document_committed and tab.phase == .live and !tab.extension and tab.view != null and safeURL(slice(&tab.url));
}

export fn moon_context_inspect_label(tab: u64) ?[*:0]const u8 {
    if (stopped or count==0 or tabs[active].id!=tab or !hasSite(&tabs[active])) return null;
    return plugins.inspectElementLabel();
}

export fn moon_context_highlight_label(tab: u64) ?[*:0]const u8 {
    if (stopped or count==0 or tabs[active].id!=tab or !hasSite(&tabs[active])) return null;
    return plugins.highlightLinkLabel();
}

export fn moon_site_context(site: *native.MoonSiteContext) bool {
    if (stopped or count == 0) return false;
    const tab = &tabs[active];
    if (!hasSite(tab)) return false;
    var url: [4096:0]u8 = @splat(0);
    native.moon_engine_committed_url(tab.view.?,&url,url.len);
    const origin = popups.origin(slice(&url)) orelse return false;
    site.* = .{ .tab_id=tab.id, .navigation=tab.navigation, .site_muted=native.moon_engine_site_muted(tab.view.?),
        .tab_muted=tab.muted, .origin=origin[0..site.origin.len].* };
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
    var address: [4096:0]u8 = @splat(0);
    var label: [512:0]u8 = @splat(0);
    _ = copy(&address,slice(&link.url));
    _ = copy(&label,slice(&link.label));
    return @intFromEnum(if (addBackgroundTab(address,label)) sdk.LinkResult.opened else .limitReached);
}

fn addBackgroundTab(address: [4096:0]u8, label: [512:0]u8) bool {
    if (count==tabs.len) return false;
    appendBackgroundTab(address,label);
    native.moon_shell_refresh();
    return true;
}

fn appendBackgroundTab(address: [4096:0]u8, label: [512:0]u8) void {
    tabs[count] = .{ .id=next_id,.phase=.dormant,.url=address,.title=label,.last_used=native.moon_clock() };
    count += 1;
    next_id += 1;
}
export fn moon_tab_id(index: usize) u64 {
    return if (index<count) tabs[index].id else 0;
}
export fn moon_tab_tools_permissions() c_uint {
    return (if (plugins.systemEnabled(.@"tabs.organize")) @as(c_uint,native.MOON_TAB_ORGANIZE) else 0) |
        (if (plugins.systemEnabled(.@"tabs.manage")) @as(c_uint,native.MOON_TAB_MANAGE) else 0) |
        (if (plugins.systemEnabled(.@"tabs.groups")) @as(c_uint,native.MOON_TAB_GROUPS) else 0);
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
        .@"downloads.preferences" => "允许查看和修改下载位置设置",
        .@"downloads.open" => "允许在确认后打开下载文件",
        .@"siteData.read" => "允许查看站点数据",
        .@"siteData.write" => "允许编辑和删除站点存储",
        .@"siteData.cookieDetails" => "允许查看 Cookie 属性和 HttpOnly Cookie",
        .@"siteData.cookieClear" => "允许经确认清除当前站点 Cookie",
        .@"window.appearance" => "允许设置浏览器主题和专注模式",
        .@"siteSettings.zoom" => "允许查看和修改网站缩放比例",
        .@"siteData.cacheWrite" => "允许经确认删除单个站点缓存",
        .@"siteData.records" => "允许查看 IndexedDB 记录预览",
        .@"siteData.databaseWrite" => "允许经确认删除 IndexedDB 记录",
        .@"page.source" => "允许查看当前网页源代码",
        .@"page.reader" => "允许提取当前网页正文以打开阅读模式",
        .@"page.save" => "允许通过文件对话框保存当前网页",
        .@"tabs.groups" => "允许管理标签组",
        .@"browser.defaultApp" => "允许打开 Windows 默认应用设置",
        .@"popups.manage" => "允许管理网站弹窗",
        .@"siteSettings.autoplay" => "允许管理媒体自动播放",
        .@"siteSettings.sound" => "允许管理网站静音",
        .@"siteSettings.notifications" => "允许管理网站通知",
        .@"tabs.session.manage" => "允许保存和恢复上次浏览会话",
        .@"page.reading" => "允许打开页内查找和调整缩放",
        .@"window.fullscreen" => "允许切换浏览器全屏",
        .@"tabs.closed.manage" => "允许管理最近关闭的标签",
        .@"privacy.clear" => "允许在确认后清除浏览数据",
        .@"taskManager.manage" => "允许查看和管理标签与进程",
        .@"media.control" => "允许控制媒体标签",
        .@"network.capture" => "允许记录手动选中的网页标签的网络事件",
        .@"ui.commands" => "允许添加菜单入口和注册快捷键",
        .@"ui.settings" => "允许查看和打开插件设置入口",
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
    if (permission == null or permission == .@"siteData.read" or permission == .@"siteData.cookieDetails" or
        permission == .@"siteData.records") checkSiteDataGrant();
    if (permission == null or permission == .@"page.source") checkPageSourceGrant();
    if (permission == null or permission == .@"network.capture") {
        if (network_capture.ownerId()) |owner| {
            if (!plugins.hasGrant(owner,.@"network.capture")) network_capture.reset();
        }
    }
    if (permission == null or permission == .@"page.reader") {
        if (reader.ownerId()) |id| {
            if (!plugins.hasGrant(id,.@"page.reader")) reader.reset();
        }
    }
    if (permission == null or permission == .@"page.inspect" or permission == .@"ui.commands")
        native.moon_engine_context_inspect_available(plugins.inspectElementLabel()!=null);
    if (permission == null or permission == .@"page.inspect") native.moon_engine_check_viewports();
    if (permission == null or permission == .@"page.reading") checkFindGrant();
    if (fullscreen_owner[0]!=0 and !plugins.hasGrant(slice(&fullscreen_owner),.@"window.fullscreen")) {
        native.moon_shell_leave_fullscreen();
        fullscreen_owner[0] = 0;
    }
    if (permission == null or permission == .@"tabs.closed.manage") checkClosedTabGrant();
    if (permission == null or permission == .@"tabs.organize") checkTabToolsGrant();
    if ((permission == null or permission == .@"tabs.manage") and !plugins.systemEnabled(.@"tabs.manage"))
        _ = discardTabSelection();
    if (permission == null or permission == .@"bookmarks.manage") native.moon_shell_bookmarks_changed();
    if (permission == null or permission == .@"siteSettings.sound") moon_site_sound_update();
    if (permission == null or permission == .@"siteSettings.notifications") {
        var rules: notifications.Buffer = undefined;
        for (notifications.list(&rules)) |rule| {
            const mode: sdk.NotificationMode = if (moon_notification_rules_enabled()) rule.mode else .block;
            native.moon_engine_notification_policy(@ptrCast(rule.origin.ptr),@intFromEnum(mode));
        }
    }
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

fn bookmarkBarAllowed() bool {
    return !stopped and !native.moon_shell_private() and plugins.systemEnabled(.@"bookmarks.manage");
}

export fn moon_bookmark_bar_visible() bool {
    return bookmarkBarAllowed() and bookmarks.show_bar;
}

export fn moon_bookmark_bar_toggle() c_int {
    const change=if (bookmarkBarAllowed()) bookmarks.toggleBar() else sdk.BookmarksBarChange.unavailable;
    return @intFromEnum(change);
}

export fn moon_bookmark_bar_entries(folder: [*c]const u8, offset: usize,
    output: [*c]native.MoonBookmarkBarEntry, capacity: usize, more: *bool) usize {
    more.*=false;
    if (!moon_bookmark_bar_visible() or folder==null or output==null or capacity==0) return 0;
    return bookmarks.barEntries(slice(folder),offset,output[0..@min(capacity,native.MOON_BOOKMARK_BAR_PAGE)],more) catch 0;
}

export fn moon_bookmark_bar_open(id: u32, background: bool) bool {
    if (count==0 or !moon_bookmark_bar_visible() or id==0) return false;
    var address: [4096:0]u8 = @splat(0);
    var label: [512:0]u8 = @splat(0);
    bookmarks.barTarget(id,&address,&label) catch return false;
    if (background) {
        if (!addBackgroundTab(address,label)) {
            native.moon_shell_toast("书签","标签已满。关闭一页后可在后台打开书签。");
            return false;
        }
    } else {
        navigate(&tabs[active],slice(&address));
    }
    return true;
}

export fn moon_bookmarks_open_many(panel: u64, ids: [*]const u32, length: usize, opened: *u32, missing: *u32) c_int {
    opened.* = 0;
    missing.* = 0;
    if (!moon_extension_panel_active(panel) or native.moon_shell_private())
        return @intFromEnum(sdk.BookmarkOpenState.unavailable);
    const allocator = std.heap.page_allocator;
    const Target = struct { address: [4096:0]u8 = @splat(0), title: [512:0]u8 = @splat(0) };
    const targets = allocator.alloc(Target,length) catch return @intFromEnum(sdk.BookmarkOpenState.unavailable);
    defer allocator.free(targets);
    var found: usize = 0;
    for (ids[0..length],0..) |id,index| {
        if (std.mem.indexOfScalar(u32,ids[0..index],id)!=null) continue;
        targets[found] = .{};
        const target = &targets[found];
        bookmarks.barTarget(id,&target.address,&target.title) catch |err| switch (err) {
            error.NotFound, error.InvalidParams => {
                missing.* += 1;
                continue;
            },
            else => return @intFromEnum(sdk.BookmarkOpenState.unavailable),
        };
        found += 1;
    }
    if (found==0) return @intFromEnum(sdk.BookmarkOpenState.empty);
    if (found>tabs.len-count) return @intFromEnum(sdk.BookmarkOpenState.tabLimit);
    for (targets[0..found]) |target| appendBackgroundTab(target.address,target.title);
    opened.* = @intCast(found);
    native.moon_shell_refresh();
    return @intFromEnum(sdk.BookmarkOpenState.opened);
}

export fn moon_plugin_open_page(id: [*c]const u8) bool {
    if (stopped or count == 0) return false;
    var buffer: [256]u8 = undefined;
    const address = plugins.addressForId(slice(id),&buffer) orelse return false;
    return openInternalPage(address);
}

export fn moon_appearance_available() bool {
    return !stopped and plugins.systemEnabled(.@"window.appearance");
}

export fn moon_extension_panel_active(panel: u64) bool {
    return !stopped and count!=0 and tabs[active].id==panel and tabs[active].extension;
}

export fn moon_settings_list(panel: u64, offset: usize, entries: [*c]native.MoonSettingsEntry, capacity: usize, next: *usize) usize {
    next.* = 0;
    if (native.moon_shell_private() or !moon_extension_panel_active(panel) or entries==null or capacity==0) return 0;
    return plugins.listSettings(offset,entries[0..capacity],next);
}

export fn moon_settings_open(panel: u64, target: [*c]const u8) bool {
    if (native.moon_shell_private() or !moon_extension_panel_active(panel)) return false;
    var buffer: [256]u8 = undefined;
    const address = plugins.contributedSettings(slice(target),&buffer) orelse return false;
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

export fn moon_network_capture_open(id: [*c]const u8, source: u64, navigation: u64) bool {
    if (native.moon_shell_private() or !native.moon_engine_supports_network_capture()) return false;
    const view = devtoolsTarget(source, navigation) orelse return false;
    if (!moon_plugin_open_page(id)) return false;
    const panel = tabs[active].id;
    if (!tabs[active].extension or source == panel) return false;
    const tab = &tabs[tabIndex(source) orelse return false];
    if (tab.view != view or tab.navigation != navigation) return false;
    return network_capture.begin(slice(id), source, panel, view);
}

export fn moon_network_capture_event(view: *native.MoonView, tab: u64, url: [*c]const u8, status: u16, kind: c_int) void {
    if (stopped or url == null) return;
    network_capture.add(view, tab, slice(url), status, std.enums.fromInt(sdk.NetworkEventKind, kind) orelse return);
}

export fn moon_network_capture_control(id: [*c]const u8, panel: u64, command: c_int) c_int {
    const result: sdk.NetworkCaptureResult = control: {
        if (!moon_extension_panel_active(panel)) break :control .unavailable;
        const source = network_capture.sourceFor(panel, slice(id)) orelse break :control .unavailable;
        const index = tabIndex(source) orelse break :control .unavailable;
        const tab = &tabs[index];
        const action = std.enums.fromInt(sdk.NetworkCaptureAction, command) orelse break :control .unavailable;
        switch (action) {
            .pause, .@"resume" => if (!network_capture.setRecording(action == .@"resume")) break :control .unavailable,
            .clear => network_capture.clear(),
            .focus => chooseTab(index, true),
            .reload => {
                if (!hasSite(tab)) break :control .unavailable;
                switch (hardReloadGuard(tab)) {
                    .unavailable => break :control .unavailable,
                    .resubmission => break :control .resubmission,
                    .edited => break :control .edited,
                    .started => {},
                }
                if (!network_capture.setRecording(true)) break :control .unavailable;
                native.moon_engine_reload_from_origin(tab.view.?);
            },
        }
        break :control .ok;
    };
    return @intFromEnum(result);
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

export fn moon_reader_open(owner: [*c]const u8, id: u64, navigation: u64) bool {
    if (count==0 or tabs[active].id!=id) return false;
    const view = pageSaveView(id,navigation) orelse return false;
    var committed: [4096:0]u8 = @splat(0);
    native.moon_engine_committed_url(view,&committed,committed.len);
    const address = slice(&committed);
    if (!history.validURL(address) or !moon_plugin_open_page(owner)) return false;
    const selected = &tabs[active];
    if (!selected.extension or selected.id==id or pageSaveView(id,navigation)!=view) return false;
    reader.begin(slice(owner),id,selected.id,address,view);
    return true;
}

export fn moon_reader_result(tab: u64, request: u64, result: [*c]const u8) void {
    if (!stopped and result!=null) reader.complete(tab,request,slice(result));
}

export fn moon_reader_return(panel: u64, owner: [*c]const u8) bool {
    if (stopped or count==0 or tabs[active].id!=panel) return false;
    const id = reader.selected(panel,slice(owner)) orelse return false;
    const index = tabIndex(id) orelse return false;
    chooseTab(index,true);
    return true;
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
            const id = downloads.begin("");
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
        native.moon_shell_toast("已拦截弹窗","可在「站点设置」查看并打开一次。");
    }
}

export fn moon_popups_open(owner: [*c]const u8, source: u64) bool {
    if (stopped or count == 0 or tabs[active].id != source or native.moon_shell_private()) return false;
    const tab = &tabs[active];
    const navigation = tab.navigation;
    var origin: popups.Origin = @splat(0);
    if (!tab.extension and tab.document_committed) {
        if (tab.view) |view| {
            var url: [4096:0]u8 = @splat(0);
            native.moon_engine_committed_url(view,&url,url.len);
            if (popups.origin(slice(&url))) |key| origin = key;
        }
    }
    if (!moon_plugin_open_page(owner)) return false;
    popups.bind(tabs[active].id,slice(owner),source,navigation,origin);
    return true;
}

fn popupPanelAllowed(owner: []const u8, panel: u64) bool {
    return !stopped and count != 0 and tabs[active].id == panel and tabs[active].extension and
        !native.moon_shell_private() and plugins.hasGrant(owner,.@"popups.manage");
}

fn boundSitePage(panel: u64, owner: []const u8) ?struct { index: usize, revision: u64 } {
    if (!popupPanelAllowed(owner,panel)) return null;
    const bound = popups.boundPage(panel,owner) orelse return null;
    const index = tabIndex(bound.source) orelse return null;
    const tab = &tabs[index];
    if (tab.navigation!=bound.navigation or tab.extension) return null;
    const origin = popups.origin(slice(&tab.url)) orelse return null;
    if (!equals(slice(&origin),slice(&bound.origin))) return null;
    return .{ .index=index,.revision=bound.revision };
}

fn siteToolBit(tool: sdk.SiteTool) c_uint {
    return @as(c_uint,1) << @as(u5,@intCast(@intFromEnum(tool)));
}

fn siteToolAvailable(tab: *const Tab, tool: sdk.SiteTool) bool {
    if (tool==.page) return true;
    if (!hasSite(tab) or !tab.loaded or tab.loading) return false;
    return switch (tool) {
        .page => unreachable,
        .data => plugins.hasGrant("moon.site-data",.@"siteData.read"),
        .console => plugins.hasGrant("moon.devtools",.@"page.inspect"),
    };
}

export fn moon_site_settings_tools(panel: u64, owner: [*c]const u8, revision: *u64) c_uint {
    revision.*=0;
    const bound = boundSitePage(panel,slice(owner)) orelse return 0;
    revision.*=bound.revision;
    var available: c_uint=0;
    for (std.enums.values(sdk.SiteTool)) |tool| {
        if (siteToolAvailable(&tabs[bound.index],tool)) available |= siteToolBit(tool);
    }
    return available;
}

export fn moon_site_settings_open_tool(panel: u64, owner: [*c]const u8, revision: u64, raw: c_uint) bool {
    const bound = boundSitePage(panel,slice(owner)) orelse return false;
    const tool = std.enums.fromInt(sdk.SiteTool,raw) orelse return false;
    const tab = &tabs[bound.index];
    if (bound.revision!=revision or !siteToolAvailable(tab,tool)) return false;
    const started = switch (tool) {
        .page => true,
        .data => plugins.launchSystemCommand("moon.site-data","inspect",snapshotFor(tab)),
        .console => plugins.launchSystemCommand("moon.devtools","console",snapshotFor(tab)),
    };
    if (!started) return false;
    chooseTab(bound.index,true);
    return true;
}

export fn moon_site_settings_set_filtering(panel: u64, owner: [*c]const u8, revision: u64, enabled: bool) c_int {
    return @intFromEnum(setBoundSiteFiltering(panel,slice(owner),revision,enabled));
}

fn setBoundSiteFiltering(panel: u64, owner: []const u8, revision: u64, enabled: bool) sdk.SiteFilteringResult {
    const bound = boundSitePage(panel,owner) orelse return .unavailable;
    if (bound.revision!=revision) return .unavailable;
    const origin = popups.origin(slice(&tabs[bound.index].url)) orelse return .unavailable;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const before = (network.boundSite(allocator,slice(&origin)) catch return .failed) orelse return .unavailable;
    if (before.info.state==.inherited) return .inherited;
    if ((before.info.state==.filtering)==enabled) return .applied;
    if (!enabled) {
        var prompt: [620]u8 = undefined;
        const message = std.fmt.bufPrintSentinel(&prompt,"暂停 {s} 及其子域的网页过滤？这些网站将可以加载原先被拦截的广告和跟踪资源。",.{before.info.host},0) catch return .failed;
        if (!native.moon_shell_confirm("暂停网站过滤？",message.ptr)) return .cancelled;
        const confirmed = boundSitePage(panel,owner) orelse return .unavailable;
        if (confirmed.revision!=revision) return .unavailable;
        const after = (network.boundSite(allocator,slice(&origin)) catch return .failed) orelse return .unavailable;
        if (!equals(after.owner,before.owner) or after.info.state!=before.info.state) return .unavailable;
    }
    network.setSite(allocator,before.owner,.{ .host=before.info.host,.enabled=enabled }) catch |err| return switch (err) {
        error.NotSelected => .unavailable,
        error.LimitExceeded => .limitReached,
        else => .failed,
    };
    return .applied;
}

export fn moon_autoplay_rules_active() bool {
    return !stopped and autoplay.hasRules() and plugins.systemEnabled(.@"siteSettings.autoplay");
}

export fn moon_autoplay_mode(url: [*c]const u8) c_uint {
    const key = popups.origin(slice(url)) orelse return native.MOON_AUTOPLAY_DEFAULT;
    return switch (autoplay.mode(slice(&key))) {
        .automatic => native.MOON_AUTOPLAY_DEFAULT,
        .allow => native.MOON_AUTOPLAY_ALLOW,
        .muted => native.MOON_AUTOPLAY_MUTED,
        .block => native.MOON_AUTOPLAY_BLOCK,
    };
}

fn autoplayPanelAllowed(owner: []const u8, panel: u64) bool {
    return !stopped and count!=0 and tabs[active].id==panel and tabs[active].extension and
        !native.moon_shell_private() and plugins.hasGrant(owner,.@"siteSettings.autoplay");
}

export fn moon_autoplay_change_allowed(owner: [*c]const u8, panel: u64, origin: [*c]const u8, allow: bool) bool {
    const id = slice(owner);
    if (!autoplayPanelAllowed(id,panel)) return false;
    if (!allow) return true;
    var body: [640]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&body,"允许 {s} 自动播放有声音的媒体？",.{slice(origin)},0) catch return false;
    return native.moon_shell_confirm("允许有声自动播放？",message.ptr) and autoplayPanelAllowed(id,panel);
}

export fn moon_site_sound_rules_active() bool {
    return !stopped and site_sound.hasRules() and !native.moon_shell_private() and plugins.systemEnabled(.@"siteSettings.sound");
}

export fn moon_notification_rules_enabled() bool {
    return !stopped and !native.moon_shell_private() and plugins.hasGrant("moon.popups",.@"siteSettings.notifications");
}

export fn moon_notification_rules(index: usize, origin: [*c]u8, capacity: usize, allowed: *bool) usize {
    if (!moon_notification_rules_enabled()) return 0;
    var buffer: notifications.Buffer = undefined;
    const rules = notifications.list(&buffer);
    if (index>=rules.len or rules[index].origin.len>=capacity) return 0;
    const rule = rules[index];
    @memcpy(origin[0..rule.origin.len],rule.origin);
    origin[rule.origin.len] = 0;
    allowed.* = rule.mode==.allow;
    return rule.origin.len;
}

fn notificationTabMatches(id: u64, origin: []const u8) bool {
    if (!moon_notification_rules_enabled() or count==0) return false;
    const tab = &tabs[active];
    if (tab.id!=id or tab.extension or !tab.document_committed or tab.loading) return false;
    const page = tab.view orelse return false;
    var url: [4096:0]u8 = @splat(0);
    native.moon_engine_committed_url(page,&url,url.len);
    const key = popups.origin(slice(&url)) orelse return false;
    return equals(slice(&key),origin);
}

export fn moon_notification_display_allowed(id: u64, origin: [*c]const u8) bool {
    return notificationTabMatches(id,slice(origin)) and notifications.mode(slice(origin))==.allow;
}

var notification_prompt = false;
fn confirmNotifications(origin: []const u8) bool {
    if (notification_prompt) return false;
    notification_prompt = true;
    defer notification_prompt = false;
    var body: [640]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&body,"允许 {s} 在浏览器中显示网站通知？你可随时在站点设置中撤销。",.{origin},0) catch return false;
    return native.moon_shell_confirm("允许网站通知？",message.ptr);
}

export fn moon_notification_request(id: u64, origin: [*c]const u8) bool {
    const key = popups.origin(slice(origin)) orelse return false;
    const address = slice(&key);
    if (!notificationTabMatches(id,address)) return false;
    switch (notifications.mode(address)) {
        .allow => return true,
        .block => return false,
        .ask => {},
    }
    const navigation = tabs[active].navigation;
    if (!confirmNotifications(address) or !notificationTabMatches(id,address) or tabs[active].navigation!=navigation) return false;
    notifications.save(std.heap.page_allocator,key,.allow) catch return false;
    native.moon_engine_notification_policy(&key,native.MOON_NOTIFICATION_ALLOW);
    return true;
}

export fn moon_notification_change_allowed(owner: [*c]const u8, panel: u64, origin: [*c]const u8, allow: bool) bool {
    if (!notificationPanelAllowed(slice(owner),panel)) return false;
    return !allow or (confirmNotifications(slice(origin)) and notificationPanelAllowed(slice(owner),panel));
}

fn notificationPanelAllowed(owner: []const u8, panel: u64) bool {
    return native.moon_engine_notifications_available() and moon_notification_rules_enabled() and
        count!=0 and tabs[active].id==panel and tabs[active].extension and
        plugins.hasGrant(owner,.@"siteSettings.notifications");
}

export fn moon_site_sound_mutes(url: [*c]const u8) bool {
    if (!moon_site_sound_rules_active()) return false;
    const key = popups.origin(slice(url)) orelse return false;
    return site_sound.muted(slice(&key));
}

fn applySiteSound(view: *native.MoonView, extension: bool) void {
    if (extension) return;
    var url: [4096:0]u8 = @splat(0);
    if (moon_site_sound_rules_active()) native.moon_engine_committed_url(view,&url,url.len);
    native.moon_engine_site_mute(view,moon_site_sound_mutes(&url));
}

export fn moon_site_sound_update() void {
    for (tabs[0..count]) |*tab| {
        if (tab.document_committed) {
            if (tab.view) |view| applySiteSound(view,tab.extension);
        }
    }
    native.moon_shell_refresh();
}

export fn moon_site_sound_panel_allowed(owner: [*c]const u8, panel: u64) bool {
    return !stopped and count!=0 and tabs[active].id==panel and tabs[active].extension and
        !native.moon_shell_private() and plugins.hasGrant(slice(owner),.@"siteSettings.sound");
}

export fn moon_site_sound_toggle(owner: [*c]const u8, id: u64, navigation: u64) c_uint {
    if (native.moon_shell_private() or !plugins.hasGrant(slice(owner),.@"siteSettings.sound") or
        !plugins.systemEnabled(.@"siteSettings.sound")) return @intFromEnum(sdk.SiteSoundResult.unavailable);
    const view = devtoolsTarget(id,navigation) orelse return @intFromEnum(sdk.SiteSoundResult.unavailable);
    var url: [4096:0]u8 = @splat(0);
    native.moon_engine_committed_url(view,&url,url.len);
    const key = popups.origin(slice(&url)) orelse return @intFromEnum(sdk.SiteSoundResult.unavailable);
    const muted = !site_sound.muted(slice(&key));
    site_sound.save(std.heap.page_allocator,key,muted) catch |err| return @intFromEnum(if (err==error.LimitExceeded)
        sdk.SiteSoundResult.limitReached else .unavailable);
    moon_site_sound_update();
    return @intFromEnum(if (muted) sdk.SiteSoundResult.muted else .unmuted);
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
    if (!grants.contains(.@"siteData.read")) {
        site_data.reset();
        return;
    }
    if (!grants.contains(.@"siteData.cookieDetails")) site_data.dropCookies();
    if (!grants.contains(.@"siteData.records")) site_data.dropRecordPreview();
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
    return native.moon_engine_inspect(view,@intFromEnum(sdk.InspectorPanel.resources),native.MOON_INSPECT_PREFERRED);
}

fn sitePanelView(panel: u64, owner: []const u8, permission: sdk.Permission) ?*native.MoonView {
    if (stopped or count==0 or tabs[active].id!=panel or
        !plugins.hasGrant(owner,.@"siteData.read") or !plugins.hasGrant(owner,permission)) return null;
    const source = site_data.selected(panel,owner) orelse return null;
    const tab = &tabs[tabIndex(source) orelse return null];
    if (!hasSite(tab) or tab.loading or !tab.loaded) return null;
    return tab.view;
}

export fn moon_site_storage_page(panel: u64, id: [*c]const u8, session: bool, generation: u64,
    query: [*c]const u8, length: usize, offset: u32, refresh: bool) bool {
    const owner = slice(id);
    const view = sitePanelView(panel,owner,.@"siteData.read") orelse return false;
    return site_data.requestStoragePage(view,panel,owner,.{
        .group=if (session) .session else .local,.generation=generation,.query=query[0..length],
        .offset=offset,.refresh=refresh,
    });
}

export fn moon_site_storage_page_result(tab: u64, request: u64, result: [*c]const u8) void {
    if (!stopped and result!=null) site_data.completeStoragePage(tab,request,slice(result));
}

export fn moon_site_data_database(panel: u64, id: [*c]const u8, index: c_uint, generation: u64, refresh: bool) bool {
    const owner = slice(id);
    const view = sitePanelView(panel,owner,.@"siteData.read") orelse return false;
    return site_data.requestDatabase(view,panel,owner,.{ .index=index,.generation=generation,.refresh=refresh });
}

export fn moon_site_database_result(view: *native.MoonView, tab: u64, request: u64, result: [*c]const u8) void {
    if (!stopped and result!=null) site_data.completeDatabase(view,tab,request,slice(result));
}

export fn moon_site_database_records(panel: u64, id: [*c]const u8, index: c_uint, generation: u64,
    revision: u64, store: c_uint, offset: u16, refresh: bool) bool {
    const owner = slice(id);
    const view = sitePanelView(panel,owner,.@"siteData.records") orelse return false;
    return site_data.requestRecords(view,panel,owner,.{
        .index=index,.generation=generation,.revision=revision,.store=store,.offset=offset,.refresh=refresh,
    });
}

export fn moon_site_database_clear(panel: u64, id: [*c]const u8, index: c_uint, generation: u64,
    revision: u64, store: c_uint) c_int {
    return @intFromEnum(clearSiteDatabaseStore(panel,slice(id),.{
        .index=index,.generation=generation,.revision=revision,.store=store,
    }));
}

fn clearSiteDatabaseStore(panel: u64, owner: []const u8, target: sdk.SiteDatabaseStoreTarget) sdk.SiteDataClearStart {
    const permission: sdk.Permission = .@"siteData.databaseWrite";
    if (site_clear_confirming or sitePanelView(panel,owner,permission)==null) return .unavailable;
    const store = site_data.objectStore(panel,owner,target) orelse return .unavailable;
    const allocator = std.heap.page_allocator;
    const names = std.json.Stringify.valueAlloc(allocator,.{ store.database.name,store.name },.{}) catch return .unavailable;
    defer allocator.free(names);
    const origin = site_data.status(panel,owner,false,false,false,false).origin;
    const message = std.fmt.allocPrintSentinel(allocator,"清空 {s} 中的 IndexedDB 记录？\n数据库和对象仓库：{s}\n此仓库的所有记录都会删除，索引和其他仓库会保留。",.{origin,names},0) catch return .unavailable;
    defer allocator.free(message);
    site_clear_confirming = true;
    defer site_clear_confirming = false;
    if (!native.moon_shell_confirm("清空对象仓库？",message.ptr)) return .cancelled;
    const view = sitePanelView(panel,owner,permission) orelse return .unavailable;
    return if (site_data.clearObjectStore(view,panel,owner,target)) .started else .unavailable;
}

export fn moon_site_data_cookie_url(panel: u64, id: [*c]const u8, url: [*c]u8, cap: usize) bool {
    if (native.moon_shell_private()) return false;
    const view = sitePanelView(panel,slice(id),.@"siteData.cookieDetails") orelse return false;
    native.moon_engine_committed_url(view,url,cap);
    return history.validURL(slice(url));
}

export fn moon_site_clear_cookies(panel: u64, id: [*c]const u8, generation: u64) c_int {
    return @intFromEnum(clearSiteCookies(panel,slice(id),generation));
}

fn clearSiteCookies(panel: u64, owner: []const u8, generation: u64) sdk.SiteDataClearStart {
    const permission: sdk.Permission = .@"siteData.cookieClear";
    if (site_clear_confirming or !native.moon_engine_clear_site_cookies_available() or
        !site_data.canClearCookies(panel,owner,generation) or sitePanelView(panel,owner,permission)==null)
        return .unavailable;
    const origin = site_data.status(panel,owner,false,false,false,false).origin;
    var body: [4608]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&body,
        "清除 {s} 所属站点的 Cookie？\n将清除同一注册域及其子域的 Cookie，包含登录 Cookie。你可能需要重新登录。",
        .{origin},0) catch return .unavailable;
    site_clear_confirming = true;
    defer site_clear_confirming = false;
    if (!native.moon_shell_confirm("清除站点 Cookie？",message.ptr)) return .cancelled;
    if (!site_data.canClearCookies(panel,owner,generation)) return .unavailable;
    const view = sitePanelView(panel,owner,permission) orelse return .unavailable;
    var url: [4096:0]u8 = @splat(0);
    native.moon_engine_committed_url(view,&url,url.len);
    if (!history.validURL(slice(&url))) return .unavailable;
    return if (site_data.clearCookies(&url)) .started else .unavailable;
}

export fn moon_site_remove_cookie(panel: u64, id: [*c]const u8, entry: u32, generation: u64, page_revision: u64) c_int {
    return @intFromEnum(removeSiteCookie(panel,slice(id),.{ .id=entry,.generation=generation,.pageRevision=page_revision }));
}

fn removeSiteCookie(panel: u64, owner: []const u8, target: sdk.SiteCookieRemoval) sdk.SiteDataClearStart {
    const permission: sdk.Permission = .@"siteData.cookieClear";
    if (site_clear_confirming or native.moon_shell_private() or !plugins.hasGrant(owner,.@"siteData.cookieDetails") or
        sitePanelView(panel,owner,permission)==null) return .unavailable;
    const entry=site_data.removableCookie(panel,owner,target) orelse return .unavailable;
    var buffer: [1024]u8 = undefined;
    const message=std.fmt.bufPrintSentinel(&buffer,"删除 Cookie「{s}」？\n域 {s}\n路径 {s}",
        .{entry.name,entry.domain,entry.path},0) catch return .unavailable;
    site_clear_confirming=true;
    defer site_clear_confirming=false;
    if (!native.moon_shell_confirm("删除 Cookie？",message.ptr)) return .cancelled;
    if (!plugins.hasGrant(owner,.@"siteData.cookieDetails")) return .unavailable;
    const view=sitePanelView(panel,owner,permission) orelse return .unavailable;
    var url: [4096:0]u8 = @splat(0);
    native.moon_engine_committed_url(view,&url,url.len);
    if (!history.validURL(slice(&url))) return .unavailable;
    return if (site_data.removeCookie(view,panel,owner,target,slice(&url))) .started else .unavailable;
}

export fn moon_site_cookies_cleared(request: u64) void {
    if (stopped) return;
    const source = site_data.cookieClearSource(request) orelse return;
    const index = tabIndex(source) orelse return;
    const view = tabs[index].view orelse return;
    site_data.completeCookieClear(view);
}

export fn moon_site_database_remove_record(panel: u64, id: [*c]const u8, index: c_uint, generation: u64,
    revision: u64, store: c_uint, page_revision: u64, row: c_uint) c_int {
    return @intFromEnum(removeSiteRecord(panel,slice(id),.{
        .index=index,.generation=generation,.revision=revision,.store=store,.pageRevision=page_revision,.row=row,
    }));
}

fn removeSiteRecord(panel: u64, owner: []const u8, target: sdk.SiteDatabaseRecordTarget) sdk.SiteDataClearStart {
    const permission: sdk.Permission = .@"siteData.databaseWrite";
    if (site_clear_confirming or !plugins.hasGrant(owner,.@"siteData.records") or
        sitePanelView(panel,owner,permission)==null) return .unavailable;
    const entry = site_data.record(panel,owner,target) orelse return .unavailable;
    const allocator = std.heap.page_allocator;
    const names = std.json.Stringify.valueAlloc(allocator,.{ entry.store.database.name,entry.store.name },.{}) catch return .unavailable;
    defer allocator.free(names);
    const origin = site_data.status(panel,owner,false,false,false,false).origin;
    const message = std.fmt.allocPrintSentinel(allocator,"删除 {s} 的一条 IndexedDB 记录？\n数据库和对象仓库：{s}\n主键：{s}",
        .{origin,names,entry.key},0) catch return .unavailable;
    defer allocator.free(message);
    site_clear_confirming = true;
    defer site_clear_confirming = false;
    if (!native.moon_shell_confirm("删除 IndexedDB 记录？",message.ptr)) return .cancelled;
    if (!plugins.hasGrant(owner,.@"siteData.records")) return .unavailable;
    const view = sitePanelView(panel,owner,permission) orelse return .unavailable;
    return if (site_data.removeRecord(view,panel,owner,target)) .started else .unavailable;
}

export fn moon_site_data_update(panel: u64, id: [*c]const u8, session: bool, entry: u32, generation: u64,
    page_revision: u64, value: [*c]const u8, length: usize) bool {
    if (site_clear_confirming) return false;
    const owner = slice(id);
    const view = sitePanelView(panel,owner,.@"siteData.write") orelse return false;
    const target: sdk.SiteDataItem = .{
        .group=if (session) .session else .local,.id=entry,.generation=generation,
        .pageRevision=if (page_revision!=0) page_revision else null,
    };
    return site_data.update(view,panel,owner,target,if (value!=null) value[0..length] else null);
}

export fn moon_site_data_create(panel: u64, id: [*c]const u8, session: bool, generation: u64,
    key: [*c]const u8, key_length: usize, value: [*c]const u8, value_length: usize) bool {
    if (site_clear_confirming) return false;
    const owner = slice(id);
    const view = sitePanelView(panel,owner,.@"siteData.write") orelse return false;
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
    if (site_clear_confirming or sitePanelView(panel,owner,.@"siteData.write")==null or
        !site_data.canMutate(panel,owner,group,generation)) return .unavailable;
    var body: [640]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&body,"清空 {s} 的{s}全部条目？\n此操作也会移除筛选结果之外的条目。",.{
        site_data.status(panel,owner,true,false,false,false).origin,
        if (session) "当前标签 Session Storage " else " Local Storage ",
    },0) catch return .unavailable;
    site_clear_confirming = true;
    defer site_clear_confirming = false;
    if (!native.moon_shell_confirm("清空站点存储？",message.ptr)) return .cancelled;
    const view = sitePanelView(panel,owner,.@"siteData.write") orelse return .unavailable;
    return if (site_data.clear(view,panel,owner,group,generation)) .started else .unavailable;
}

export fn moon_site_data_result(source: u64, request: u64, snapshot: [*c]const u8, catalog: bool) void {
    if (stopped) return;
    if (catalog) site_data.completeCatalog(source,request,slice(snapshot)) else site_data.complete(source,request,slice(snapshot));
}

export fn moon_site_cache_result(view: *native.MoonView, tab: u64, generation: u64, result: [*c]const u8) void {
    if (!stopped and result!=null) site_data.completeCache(view,tab,generation,slice(result));
}

export fn moon_site_cache_remove(panel: u64, owner_id: [*c]const u8, index: c_uint, generation: u64) c_int {
    return @intFromEnum(removeSiteCache(panel,slice(owner_id),.{ .index=index,.generation=generation }));
}

fn removeSiteCache(panel: u64, owner: []const u8, target: sdk.SiteCacheRemove) sdk.SiteDataClearStart {
    if (site_clear_confirming or sitePanelView(panel,owner,.@"siteData.cacheWrite")==null) return .unavailable;
    const name = site_data.cacheName(panel,owner,target) orelse return .unavailable;
    const allocator = std.heap.page_allocator;
    const quoted = std.json.Stringify.valueAlloc(allocator,name,.{}) catch return .unavailable;
    defer allocator.free(quoted);
    const origin = site_data.status(panel,owner,false,false,true,false).origin;
    var body: [8192]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&body,"删除来源 {s} 的缓存 {s}？\n此缓存中的全部响应都会移除。",.{origin,quoted},0) catch return .unavailable;
    site_clear_confirming = true;
    defer site_clear_confirming = false;
    if (!native.moon_shell_confirm("删除站点缓存？",message.ptr)) return .cancelled;
    const view = sitePanelView(panel,owner,.@"siteData.cacheWrite") orelse return .unavailable;
    return if (site_data.removeCache(view,panel,owner,target)) .started else .unavailable;
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

export fn moon_site_zoom_apply(origin: [*c]const u8, percent: c_uint, except_tab: u64) void {
    for (tabs[0..count]) |*tab| {
        if (tab.id==except_tab or !tab.document_committed or tab.phase!=.live) continue;
        var buffer: [4096:0]u8 = @splat(0);
        const key = zoomOrigin(tab,&buffer) orelse continue;
        if (equals(slice(origin),key)) native.moon_engine_set_zoom(tab.view.?,percent);
    }
}

export fn moon_reading_zoom(id: u64, action: c_int) c_uint {
    const tab = readingTarget(id) orelse return 0;
    const command = std.enums.fromInt(sdk.ZoomAction,action) orelse return 0;
    const view = tab.view.?;
    const percent = reading.next(@intCast(native.moon_engine_zoom(view)),command);
    var url: [4096:0]u8 = @splat(0);
    if (!native.moon_shell_private()) if (zoomOrigin(tab,&url)) |key| {
        reading.save(key,percent) catch return 0;
        url[key.len]=0;
        moon_site_zoom_apply(&url,percent,id);
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
    var script_records: [userscripts.max_scripts]sdk.Script = undefined;
    const records = userscripts.list(&script_records);
    const lua_fixture = records.len != 0 and equals(records[0].name,"Moon Lua smoke budget");
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
                const failure = (userscripts.runtimeError(records[0].id) catch null) orelse "";
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
            plugin_step = plugins.smokeNextStep(0) orelse return failSmoke("sample plugin unavailable");
            if (!plugins.smokeStart(plugin_step, tabSnapshot())) return failSmoke("sample plugin launch");
        },
        .plugin => {
            const success = plugins.smokeStatus(plugin_step, slice(&tabs[active].title)) orelse return;
            if (!success) {
                const info = plugins.smokeDetail();
                log("plugin_case_{d}={s} message={s}", .{ plugin_step, info.outcome, info.message });
                return failSmoke("plugin protocol check");
            }
            log("plugin_case_{d}=ok", .{plugin_step});
            if (plugin_step == 8) log("plugin_api_v2=ok", .{});
            if (plugin_step == 11) log("active_tab_example=ok", .{});
            if (plugins.smokeNextStep(plugin_step+1)) |next| {
                plugin_step = next;
                if (!plugins.smokeStart(plugin_step, tabSnapshot())) return failSmoke("sample plugin launch");
                return;
            }
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
