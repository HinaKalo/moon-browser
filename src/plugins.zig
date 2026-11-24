const std = @import("std");
const native = @import("native");
const allocator = std.heap.page_allocator;

pub const Snapshot = struct {
    id: u64,
    title: [512:0]u8,
    url: [4096:0]u8,
};

const Manifest = struct {
    api_version: u32,
    id: []const u8,
    name: []const u8,
    executable: []const u8,
    command: []const u8,
    permissions: []const []const u8 = &.{},
    events: []const []const u8 = &.{},
};
const Grant = struct { id: []const u8, enabled: bool, tabs_read: bool };
const Outcome = enum { ok, failed, timed_out, crashed };
const Trigger = enum { command, changed, timeout_test, crash_test };
const Task = struct {
    done: std.atomic.Value(bool) = .init(false),
    executable: [*:0]const u8,
    epoch: *const std.atomic.Value(u32),
    expected_epoch: u32,
    snapshot: ?Snapshot,
    trigger: Trigger,
    outcome: Outcome = .failed,
    message: [512:0]u8 = @splat(0),
};
const Plugin = struct {
    id: [96:0]u8,
    label: [256:0]u8,
    action: [256:0]u8,
    executable: [4096:0]u8,
    can_read: bool,
    subscribes: bool,
    enabled: bool = false,
    grant: bool = false,
    epoch: std.atomic.Value(u32) = .init(0),
    work: ?*Task = null,
    queued_change: bool = false,
};

var all: [16]Plugin = undefined;
var len: usize = 0;
var file_path: [4096:0]u8 = @splat(0);
var smoke_message: [512:0]u8 = @splat(0);
var smoke_outcome: ?Outcome = null;

fn copy(output: []u8, value: []const u8) bool {
    if (value.len >= output.len or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value))
        return false;
    @memcpy(output[0..value.len], value);
    output[value.len] = 0;
    return true;
}

fn validComponent(value: []const u8) bool {
    if (value.len == 0 or value[0] == '.' or value[value.len - 1] == '.') return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    }
    return true;
}

fn contains(items: []const []const u8, value: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}

fn discover(root: []const u8) void {
    var c_path: [4096]u8 = undefined;
    const directory = std.fmt.bufPrintSentinel(&c_path, "{s}\\plugins", .{root}, 0) catch return;
    var names: [32][256]u8 = undefined;
    const found = native.moon_plugin_directories(directory.ptr, &names[0][0], names[0].len, names.len);
    for (names[0..found]) |*name| {
        if (len == all.len) break;
        const sub = std.mem.sliceTo(name, 0);
        var path: [4096]u8 = undefined;
        var json: [8192]u8 = undefined;
        const manifest_path = std.fmt.bufPrintSentinel(&path, "{s}\\{s}\\plugin.json", .{ directory, sub }, 0) catch continue;
        if (!native.moon_read_text(manifest_path.ptr, &json, json.len)) continue;
        const parsed = std.json.parseFromSlice(Manifest, allocator, std.mem.sliceTo(&json, 0), .{}) catch continue;
        defer parsed.deinit();
        const manifest = parsed.value;
        if (manifest.api_version != 1 or !validComponent(manifest.id) or !validComponent(manifest.executable) or
            !std.ascii.endsWithIgnoreCase(manifest.executable, ".exe") or manifest.name.len == 0 or manifest.command.len == 0) continue;
        for (all[0..len]) |existing| {
            if (std.mem.eql(u8, std.mem.sliceTo(&existing.id, 0), manifest.id)) break;
        } else {
            const slot = &all[len];
            slot.* = .{
                .id = @splat(0),
                .label = @splat(0),
                .action = @splat(0),
                .executable = @splat(0),
                .can_read = contains(manifest.permissions, "tabs.read"),
                .subscribes = contains(manifest.events, "tabs.changed"),
            };
            const executable = std.fmt.bufPrint(&path, "{s}\\{s}\\{s}", .{ directory, sub, manifest.executable }) catch continue;
            if (!copy(&slot.id, manifest.id) or !copy(&slot.label, manifest.name) or
                !copy(&slot.action, manifest.command) or !copy(&slot.executable, executable)) continue;
            len += 1;
        }
    }
}

pub fn init(app: []const u8, profile: []const u8) void {
    discover(app);
    discover(profile);
    _ = std.fmt.bufPrintSentinel(&file_path, "{s}\\plugin-state.json", .{profile}, 0) catch return;
    var raw: [16384]u8 = undefined;
    if (!native.moon_read_text(&file_path, &raw, raw.len)) return;
    const saved = std.json.parseFromSlice([]Grant, allocator, std.mem.sliceTo(&raw, 0), .{}) catch return;
    defer saved.deinit();
    for (all[0..len]) |*plugin| for (saved.value) |grant| {
        if (!std.mem.eql(u8, grant.id, std.mem.sliceTo(&plugin.id, 0))) continue;
        plugin.enabled = grant.enabled;
        plugin.grant = plugin.can_read and grant.enabled and grant.tabs_read;
        break;
    };
}

fn persist() bool {
    var items: [16]Grant = undefined;
    for (all[0..len], 0..) |*plugin, index| items[index] = .{
        .id = std.mem.sliceTo(&plugin.id, 0),
        .enabled = plugin.enabled,
        .tabs_read = plugin.grant,
    };
    const bytes = std.json.Stringify.valueAlloc(allocator, items[0..len], .{}) catch return false;
    defer allocator.free(bytes);
    const string = allocator.dupeSentinel(u8, bytes, 0) catch return false;
    defer allocator.free(string);
    return native.moon_write_text(&file_path, string.ptr);
}
fn toggle(index: usize, permission: bool) void {
    if (index >= len) return;
    const plugin = &all[index];
    const enabled = plugin.enabled;
    const grant = plugin.grant;
    if (permission) {
        if (!plugin.can_read or !enabled) {
            native.moon_shell_info("Plugin permission", "Enable a plugin that requests tabs.read first.");
            return;
        }
        if (!grant and !native.moon_shell_confirm("Share active tab details?", "This plugin will receive the active tab title and URL.")) return;
        plugin.grant = !grant;
    } else {
        if (!enabled and !native.moon_shell_confirm("Enable this local plugin?", &plugin.executable)) return;
        plugin.enabled = !enabled;
        if (!plugin.enabled) plugin.grant = false;
    }
    if (!persist()) {
        plugin.enabled = enabled;
        plugin.grant = grant;
        native.moon_shell_info("Plugin settings", "Could not save the plugin settings.");
        return;
    }
    _ = plugin.epoch.fetchAdd(1, .acq_rel);
    plugin.queued_change = false;
}

pub fn enable(index: usize) void {
    toggle(index, false);
}
pub fn toggleGrant(index: usize) void {
    toggle(index, true);
}
pub fn count() usize {
    return len;
}
pub fn label(index: usize) [*:0]const u8 {
    return &all[index].label;
}
pub fn action(index: usize) [*:0]const u8 {
    return &all[index].action;
}
pub fn flags(index: usize) c_uint {
    return @as(c_uint, @intFromBool(all[index].enabled)) | (@as(c_uint, @intFromBool(all[index].grant)) << 1);
}

fn launch(index: usize, trigger: Trigger, snapshot: ?Snapshot) bool {
    if (index >= len) return false;
    const plugin = &all[index];
    if (!plugin.enabled or plugin.work != null) return false;
    const task = allocator.create(Task) catch return false;
    task.* = .{
        .executable = &plugin.executable,
        .epoch = &plugin.epoch,
        .expected_epoch = plugin.epoch.load(.acquire),
        .snapshot = if (plugin.grant) snapshot else null,
        .trigger = trigger,
    };
    plugin.work = task;
    if (!native.moon_plugin_thread(task)) {
        plugin.work = null;
        allocator.destroy(task);
        return false;
    }
    return true;
}

pub fn command(index: usize, snapshot: ?Snapshot) void {
    if (!launch(index, .command, snapshot))
        native.moon_shell_info("Plugin", "This plugin is disabled, busy, or could not start.");
}
pub fn changed(snapshot: ?Snapshot) void {
    for (all[0..len], 0..) |*plugin, index| {
        if (!plugin.enabled or !plugin.subscribes) continue;
        if (!launch(index, .changed, snapshot)) plugin.queued_change = true;
    }
}
pub fn tick(snapshot: ?Snapshot, smoking: bool) void {
    for (all[0..len], 0..) |*plugin, index| {
        const task = plugin.work orelse continue;
        if (!task.done.load(.acquire)) continue;
        plugin.work = null;
        if (smoking) {
            smoke_outcome = task.outcome;
            smoke_message = task.message;
        } else if (task.trigger == .command) {
            native.moon_shell_info(&plugin.label, switch (task.outcome) {
                .ok => &task.message,
                .timed_out => "The plugin timed out.",
                .crashed => "The plugin exited unexpectedly.",
                .failed => "Could not start the plugin or read its response.",
            });
        }
        allocator.destroy(task);
        if (plugin.queued_change) {
            plugin.queued_change = false;
            _ = launch(index, .changed, snapshot);
        }
    }
}

const WireTab = struct { id: u64, title: []const u8, url: []const u8 };
fn permitted(task: *const Task) ?WireTab {
    if (task.epoch.load(.acquire) != task.expected_epoch) return null;
    if (task.snapshot) |*tab| return .{ .id = tab.id, .title = std.mem.sliceTo(&tab.title, 0), .url = std.mem.sliceTo(&tab.url, 0) };
    return null;
}
fn send(pipe: *native.MoonPipe, message: anytype) bool {
    const json = std.json.Stringify.valueAlloc(allocator, message, .{}) catch return false;
    defer allocator.free(json);
    var frame: [16384]u8 = undefined;
    const line = std.fmt.bufPrintSentinel(&frame, "{s}\n", .{json}, 0) catch return false;
    return native.moon_pipe_send(pipe, line.ptr);
}
fn exchange(task: *Task, pipe: *native.MoonPipe) Outcome {
    const method: []const u8 = switch (task.trigger) {
        .command => "plugin.command",
        .changed => "tabs.changed",
        .timeout_test => "test.timeout",
        .crash_test => "test.crash",
    };
    if (task.epoch.load(.acquire) != task.expected_epoch) return .failed;
    if (!send(pipe, .{ .jsonrpc = "2.0", .id = @as(u32, 1), .method = method, .params = .{
        .version = @as(u32, 1),
        .tab = if (task.trigger == .changed) permitted(task) else null,
    } })) return .failed;
    var frame: [16384]u8 = undefined;
    var answered = false;
    for (0..2) |_| {
        const read = native.moon_pipe_read(pipe, &frame, frame.len);
        if (read == -2) return .timed_out;
        if (read == -3) return .crashed;
        if (read <= 0) return .failed;
        const message = std.json.parseFromSlice(std.json.Value, allocator, frame[0..@intCast(read)], .{}) catch return .failed;
        defer message.deinit();
        if (message.value != .object) return .failed;
        const version = message.value.object.get("jsonrpc") orelse return .failed;
        const id = message.value.object.get("id") orelse return .failed;
        if (version != .string or !std.mem.eql(u8, version.string, "2.0") or id != .integer) return .failed;
        if (id.integer == 1) {
            const result = message.value.object.get("result") orelse return .failed;
            if (result != .string or !copy(&task.message, result.string)) return .failed;
            return .ok;
        }
        if (id.integer != 2 or answered) return .failed;
        const request = message.value.object.get("method") orelse return .failed;
        if (request != .string or !std.mem.eql(u8, request.string, "tabs.getActive")) return .failed;
        answered = true;
        if (permitted(task)) |tab| {
            if (!send(pipe, .{ .jsonrpc = "2.0", .id = @as(u32, 2), .result = tab })) return .failed;
        } else if (!send(pipe, .{ .jsonrpc = "2.0", .id = @as(u32, 2), .@"error" = .{
            .code = @as(i32, -32001),
            .message = "tabs.read denied",
        } })) return .failed;
    }
    return .failed;
}

pub fn worker(opaque_task: ?*anyopaque) void {
    const task: *Task = @ptrCast(@alignCast(opaque_task orelse return));
    defer task.done.store(true, .release);
    var win_error: u32 = 0;
    const pipe = native.moon_pipe_open(task.executable, &win_error) orelse {
        _ = std.fmt.bufPrintSentinel(&task.message, "Could not launch plugin (Windows error {d}).", .{win_error}, 0) catch {};
        return;
    };
    task.outcome = exchange(task, pipe);
    const exited_cleanly = native.moon_pipe_close(pipe);
    if (task.outcome == .ok and !exited_cleanly) task.outcome = .crashed;
}

pub fn smokeStart(index: usize, step: usize, snapshot: ?Snapshot) bool {
    if (index >= len) return false;
    smoke_outcome = null;
    all[index].enabled = true;
    all[index].grant = step != 0;
    if (step == 2) return launch(index, .changed, snapshot);
    return launch(index, if (step == 3) .timeout_test else if (step == 4) .crash_test else .command, snapshot);
}

pub fn smokeStatus(step: usize, title: []const u8) ?bool {
    const outcome = smoke_outcome orelse return null;
    const message = std.mem.sliceTo(&smoke_message, 0);
    return switch (step) {
        0 => outcome == .ok and std.mem.eql(u8, message, "No access to active tab details"),
        1 => outcome == .ok and std.mem.eql(u8, message, title),
        2 => outcome == .ok and std.mem.eql(u8, message, "Tab change received"),
        3 => outcome == .timed_out,
        4 => outcome == .crashed,
        else => false,
    };
}

pub fn smokeDetail() struct { outcome: []const u8, message: []const u8 } {
    return .{ .outcome = if (smoke_outcome) |value| @tagName(value) else "pending", .message = std.mem.sliceTo(&smoke_message, 0) };
}
