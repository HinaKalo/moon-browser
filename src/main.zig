const std = @import("std");
const native = @import("native");
const policy = @import("policy.zig");
const plugins = @import("plugins.zig");

const max_tabs = 128;
const Phase = enum { blank, live, dormant, crashed, restoring, failed };
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
    download_count: usize = 0,
    activity: bool = false,
    opening: Opening = .none,
    requested_at: u64 = 0,
};
const Retiring = struct { handle: *anyopaque, pid: u32 };

var tabs: [max_tabs]Tab = undefined;
var count: usize = 0;
var active: usize = 0;
var next_id: u64 = 1;
var boot: u64 = 0;
var settings: policy.Settings = .{};
var pressure = false;
var commit: u64 = 0;
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
var popup: [4096:0]u8 = @splat(0);
var error_text: [512:0]u8 = @splat(0);

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

    const search = "https://www.google.com/search?q=";
    if (buffer.len <= search.len) return null;
    @memcpy(buffer[0..search.len], search);
    var len = search.len;
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~", ch) != null) {
            if (len + 1 >= buffer.len) return null;
            buffer[len] = ch;
            len += 1;
        } else {
            if (len + 3 >= buffer.len) return null;
            buffer[len..][0..3].* = .{ '%', hex[ch >> 4], hex[ch & 15] };
            len += 3;
        }
    }
    buffer[len] = 0;
    return buffer[0..len :0];
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
    const tab = &tabs[active];
    return .{ .id = tab.id, .title = tab.title, .url = tab.url };
}
fn tabIndex(id: u64) ?usize {
    for (tabs[0..count], 0..) |tab, index| if (tab.id == id) return index;
    return null;
}
fn updateChrome(force_address: bool) void {
    if (count == 0 or stopped) return;
    const tab = &tabs[active];
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
    tab.view = native.moon_engine_open(tab.id) orelse return false;
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
    const view = tab.view orelse return;
    tab.view = null;
    tab.loaded = false;
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
fn navigate(tab: *Tab, url: []const u8) void {
    var storage: [4096:0]u8 = @splat(0);
    if (!copy(&storage, url)) return;
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
        show(tab);
        updateChrome(true);
    }
    if (!native.moon_engine_load(tab.view.?, &storage)) {
        tab.phase = .failed;
        tab.loading = false;
        updateChrome(false);
    }
}
fn restore(tab: *Tab) void {
    if (tab.unsafe_history or !safeURL(slice(&tab.url))) {
        tab.phase = .crashed;
        return;
    }
    if (delayOpening(tab, .restore)) return;
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
    const now = native.moon_clock();
    tabs[active].last_used = now;
    if (tabs[active].view) |view| native.moon_engine_show(view, false);
    active = index;
    const tab = &tabs[index];
    tab.last_used = now;
    if (tab.phase == .dormant) restore(tab) else if (tab.phase != .crashed and tab.phase != .failed) show(tab);
    updateChrome(true);
    if (notify) plugins.changed(tabSnapshot());
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
    const was_active = index == active;
    detach(&tabs[index]);
    forgetSession(&tabs[index]);
    count -= 1;
    if (index < count) std.mem.copyForwards(Tab, tabs[index..count], tabs[index + 1 .. count + 1]);
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
fn sync(tab: *Tab) void {
    const view = tab.view orelse return;
    var url: [4096:0]u8 = @splat(0);
    var title: [512:0]u8 = @splat(0);
    native.moon_engine_read(view, &title, title.len, &url, url.len);
    if (title[0] != 0) tab.title = title;
    if (url[0] != 0 and !equals(slice(&url), "about:blank")) tab.url = url;
}
fn protected(tab: *const Tab) bool {
    return tab.loading or !tab.loaded or tab.dirty or tab.unsafe_history or tab.download_count != 0 or
        tab.activity or !safeURL(slice(&tab.url));
}
fn sampleMemory() u64 {
    var samples: [1024]native.MoonSample = undefined;
    var present: [samples.len]policy.Sample = undefined;
    const used = native.moon_memory_samples(&samples[0], samples.len);
    for (samples[0..used], 0..) |sample, index| present[index] = .{ .pid = sample.pid, .bytes = sample.bytes };
    return policy.totalCommit(present[0..used]);
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
        const tab = &tabs[index];
        if (settle_at == 0) last_before = commit;
        settle_at = now + 500;
        storeSession(tab);
        const pid = candidates[index].pid;
        tab.phase = .dormant;
        detach(tab);
        evictions += 1;
        next_evict = now + (if (pressure) @as(u64, 350) else 150);
        if (smoke != .off) log("evict tab={d} pid={d} pressure={d} commit={d}", .{
            tab.id, pid, @intFromBool(pressure), commit,
        });
        native.moon_shell_refresh();
    }
}
fn maintenance() void {
    const now = native.moon_clock();
    collectRetirements();
    if (popup[0] != 0) {
        const target = popup;
        popup[0] = 0;
        addTab(slice(&target), smoke == .off);
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
fn diagnostics() void {
    const current = sampleMemory();
    const counts = stateCounts();
    var buffer: [8192]u8 = undefined;
    const basic = std.fmt.bufPrint(&buffer, "Private commit: {d} MiB\r\nTabs: {d} open, {d} live, {d} sleeping, {d} protected\r\n" ++
        "Pressure: {s}. Threshold {d} MiB, target {d} MiB.\r\nWarm background limit: {d}, idle time: {d}s\r\n" ++
        "Evictions: {d}. Last sweep before / after: {d} / {d} MiB. Peak: {d} MiB.\r\nPending exits: {d}\r\n\r\n", .{ current / policy.mib, count, counts.live, counts.sleep, counts.protected, if (pressure) "active" else "normal", settings.high_bytes / policy.mib, settings.target_bytes / policy.mib, settings.warm_limit, settings.idle_ms / 1000, evictions, last_before / policy.mib, last_after / policy.mib, peak_commit / policy.mib, retiring_count }) catch return;
    var length = basic.len;
    for (tabs[0..count], 0..) |*tab, index| {
        const pid = if (tab.view) |view| native.moon_engine_pid(view) else 0;
        const label = slice(moon_tab_label(index));
        const row = std.fmt.bufPrint(buffer[length .. buffer.len - 1], "{d}. {s} {s} · PID {d} · {s}\r\n", .{
            index + 1, if (index == active or (tab.view != null and protected(tab))) "protected" else "eligible", @tagName(tab.phase), pid, label,
        }) catch break;
        length += row.len;
    }
    buffer[length] = 0;
    native.moon_shell_info("Memory & diagnostics", buffer[0..length :0].ptr);
}

export fn moon_start(argc: c_int, argv: [*c]const [*c]const u16) bool {
    const allocator = std.heap.page_allocator;
    const app = slice(native.moon_app_dir());
    const profile = slice(native.moon_profile_dir());
    applySettings(profile);
    plugins.init(app, profile);
    var first_url: ?[:0]u8 = null;
    defer if (first_url) |allocated| allocator.free(allocated);
    var index: usize = 1;
    while (index < @as(usize, @intCast(@max(0, argc)))) : (index += 1) {
        const argument = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.sliceTo(argv[index], 0)) catch return false;
        defer allocator.free(argument);
        if (equals(argument, "--gdi")) {
            native.moon_engine_test_fallback(true);
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
    addTab(null, false);
    if (smoke != .off) {
        smoke_deadline = native.moon_clock() + 300000;
        _ = std.fmt.bufPrintSentinel(&smoke_download, "{s}\\smoke-download.txt", .{profile}, 0) catch return false;
        smokeNavigate(&tabs[0], "/page/initial");
    } else if (first_url) |initial| {
        var buffer: [4096]u8 = undefined;
        if (normalize(initial, &buffer)) |url| navigate(&tabs[0], url);
    }
    return true;
}
export fn moon_command(command: c_int, argument: u64, c_text: [*c]const u8) void {
    if (stopped) return;
    if (command == native.MOON_SHUTDOWN) {
        stopped = true;
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
        native.MOON_KEY_NEXT => chooseTab((active + 1) % count, true),
        native.MOON_KEY_PREV => chooseTab((active + count - 1) % count, true),
        native.MOON_ADDRESS => {
            var buffer: [4096]u8 = undefined;
            if (normalize(slice(c_text), &buffer)) |url| {
                navigate(tab, url);
            } else native.moon_shell_info("Address", "Enter a valid HTTP or HTTPS address.");
        },
        native.MOON_BACK => if (tab.view) |view| native.moon_engine_back(view),
        native.MOON_FORWARD => if (tab.view) |view| native.moon_engine_forward(view),
        native.MOON_RELOAD => {
            if (tab.phase == .crashed or tab.phase == .dormant) {
                restore(tab);
            } else if (tab.view) |view| native.moon_engine_reload(view);
            updateChrome(false);
        },
        native.MOON_INPUT => if (tab.view != null) {
            tab.dirty = true;
        },
        native.MOON_DIAGNOSTICS => diagnostics(),
        native.MOON_TICK => maintenance(),
        native.MOON_PLUGIN_ENABLE => plugins.enable(index),
        native.MOON_PLUGIN_GRANT => plugins.toggleGrant(index),
        native.MOON_PLUGIN_COMMAND => plugins.command(index, tabSnapshot()),
        else => {},
    }
}
export fn moon_engine_event(kind: c_int, id: u64, detail: [*c]const u8) void {
    if (stopped) return;
    const index = tabIndex(id) orelse return;
    const tab = &tabs[index];
    switch (kind) {
        native.MOON_STARTED => {
            tab.loading = true;
            tab.loaded = false;
        },
        native.MOON_COMMITTED => {
            tab.dirty = false;
            tab.has_document = true;
            tab.deadline = 0;
            tab.phase = .live;
            sync(tab);
        },
        native.MOON_FINISHED => {
            tab.loading = false;
            tab.loaded = true;
            tab.phase = .live;
            tab.deadline = 0;
            sync(tab);
            storeSession(tab);
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
        native.MOON_TERMINATED => {
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
            if (detail != null and index == active and smoke == .off)
                native.moon_shell_info("Downloads", detail);
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
    if (index == active) updateChrome(false) else native.moon_shell_refresh();
}
export fn moon_tab_count() usize {
    return count;
}
export fn moon_active_index() usize {
    return active;
}
export fn moon_tab_label(index: usize) [*:0]const u8 {
    if (index >= count) return "New tab";
    const tab = &tabs[index];
    if (tab.title[0] != 0) return &tab.title;
    if (tab.url[0] != 0) return &tab.url;
    return "New tab";
}
export fn moon_tab_flags(index: usize) c_uint {
    if (index >= count) return 0;
    const tab = &tabs[index];
    return @as(c_uint, @intFromBool(tab.phase == .dormant)) |
        (@as(c_uint, @intFromBool(tab.phase == .crashed or tab.phase == .failed)) << 1) |
        (@as(c_uint, @intFromBool(tab.loading)) << 2);
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
export fn moon_plugin_action(index: usize) [*:0]const u8 {
    return plugins.action(index);
}
export fn moon_plugin_flags(index: usize) c_uint {
    return plugins.flags(index);
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
    switch (smoke) {
        .off => {},
        .first => {
            if (!smokePage("Moon fixture initial")) return;
            requestSmokePaint();
            if (!smoke_painted) return;
            smoke = .second;
            smokeNavigate(&tabs[0], "/page/second");
        },
        .second => {
            if (!smokePage("Moon fixture second")) return;
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
            if (!smokePage("Moon fixture initial")) return;
            if (moon_controls() & 2 == 0) return failSmoke("forward navigation unavailable");
            smoke = .forward;
            moon_command(native.MOON_FORWARD, 0, null);
        },
        .forward => {
            if (!smokePage("Moon fixture second")) return;
            log("history_navigation=ok", .{});
            smoke = .plugin;
            if (!plugins.smokeStart(0, 0, tabSnapshot())) return failSmoke("sample plugin unavailable");
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
                if (!plugins.smokeStart(0, plugin_step, tabSnapshot())) return failSmoke("sample plugin launch");
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
            if (!smokePage("Moon fixture initial")) return;
            if (!native.moon_engine_test_crash(tabs[active].view.?)) return failSmoke("could not terminate fixture web process");
            smoke = .recover;
        },
        .recover => {
            if (tabs[active].phase == .crashed) {
                recovery_started = true;
                moon_command(native.MOON_RELOAD, 0, null);
                return;
            }
            if (!recovery_started or !smokePage("Moon fixture initial")) return;
            log("crash_recovery=ok", .{});
            log("PASS", .{});
            native.moon_quit(0);
        },
    }
}
