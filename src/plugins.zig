const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");
const api = @import("plugin_host_api.zig");
const allocator = std.heap.page_allocator;

pub const Snapshot = api.Snapshot;
const Permissions = api.Permissions;
const Protocol = enum { legacy, v2 };

const LegacyManifest = struct {
    api_version: u32,
    id: []const u8,
    name: []const u8,
    executable: []const u8,
    command: []const u8,
    permissions: []const []const u8 = &.{},
    events: []const []const u8 = &.{},
};
const Grant = struct { id: []const u8, enabled: bool, tabs_read: bool, lua_scripts_manage: bool = false };
const Outcome = enum { ok, failed, timed_out, crashed };
const Trigger = enum { command, changed, timeout_test, crash_test };
const CallState = enum(u8) { idle, queued, serving, ready };
const Rpc = struct {
    state: std.atomic.Value(CallState) = .init(.idle),
    buffer: [sdk.frame_limit]u8 = undefined,
    size: usize = 0,
    deadline: u64 = 0,
    sent: usize = 0,
};
const Task = struct {
    done: std.atomic.Value(bool) = .init(false),
    executable: [*:0]const u8,
    epoch: *const std.atomic.Value(u32),
    expected_epoch: u32,
    snapshot: ?Snapshot,
    trigger: Trigger,
    plugin_id: [*:0]const u8,
    command_id: [*:0]const u8,
    grants: Permissions,
    rpc: ?*Rpc = null,
    outcome: Outcome = .failed,
    message: [512:0]u8 = @splat(0),
};
const Command = struct { id: [64:0]u8 = @splat(0), label: [256:0]u8 = @splat(0) };
const Plugin = struct {
    id: [96:0]u8,
    label: [256:0]u8,
    actions: [sdk.command_limit]Command = undefined,
    action_count: usize,
    executable: [4096:0]u8,
    protocol: Protocol,
    requests: Permissions,
    subscribes: bool,
    enabled: bool = false,
    grants: Permissions = .empty,
    epoch: std.atomic.Value(u32) = .init(0),
    work: ?*Task = null,
    queued_change: bool = false,
};

var all: [16]Plugin = undefined;
var len: usize = 0;
var file_path: [4096:0]u8 = @splat(0);
var smoke_message: [512:0]u8 = @splat(0);
var smoke_outcome: ?Outcome = null;
var serving_rpc = false;

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

fn addManifest(directory: []const u8, sub: []const u8, id: []const u8, name: []const u8, entry: []const u8, commands: []const sdk.Command, requests: Permissions, subscribes: bool, protocol: Protocol) void {
    if (!validComponent(id) or !validComponent(entry) or !std.ascii.endsWithIgnoreCase(entry, ".exe") or
        name.len == 0 or commands.len == 0 or commands.len > sdk.command_limit) return;
    if (protocol == .v2 and std.mem.indexOfScalar(u8, id, '.') == null) return;
    for (all[0..len]) |*existing| if (std.ascii.eqlIgnoreCase(std.mem.sliceTo(&existing.id, 0), id)) return;
    var path: [4096]u8 = undefined;
    const executable = std.fmt.bufPrint(&path, "{s}\\{s}\\{s}", .{ directory, sub, entry }) catch return;
    const plugin = &all[len];
    plugin.* = .{
        .id = @splat(0), .label = @splat(0), .executable = @splat(0), .action_count = commands.len,
        .protocol = protocol, .requests = requests, .subscribes = subscribes,
    };
    if (!copy(&plugin.id, id) or !copy(&plugin.label, name) or !copy(&plugin.executable, executable)) return;
    for (commands, 0..) |item, index| {
        if (!validComponent(item.id) or item.label.len == 0) return;
        for (commands[0..index]) |prior| if (std.mem.eql(u8, prior.id, item.id)) return;
        plugin.actions[index] = .{};
        if (!copy(&plugin.actions[index].id, item.id) or !copy(&plugin.actions[index].label, item.label)) return;
    }
    len += 1;
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
        const bytes = std.mem.sliceTo(&json, 0);
        if (std.json.parseFromSlice(sdk.Manifest, allocator, bytes, .{})) |parsed| {
            defer parsed.deinit();
            const manifest = parsed.value;
            if (manifest.apiVersion != sdk.api_version) continue;
            _ = std.SemanticVersion.parse(manifest.version) catch continue;
            var requested = Permissions.empty;
            for (manifest.permissions) |permission| requested.insert(permission);
            const subscribes = std.mem.indexOfScalar(sdk.Event, manifest.events, .@"tabs.changed") != null;
            if (subscribes and !requested.contains(.@"tabs.read")) continue;
            addManifest(directory, sub, manifest.id, manifest.name, manifest.entry, manifest.contributes.commands, requested, subscribes, .v2);
        } else |_| {
            const parsed = std.json.parseFromSlice(LegacyManifest, allocator, bytes, .{}) catch continue;
            defer parsed.deinit();
            const manifest = parsed.value;
            if (manifest.api_version != 1) continue;
            var requested = Permissions.empty;
            if (contains(manifest.permissions, "tabs.read")) requested.insert(.@"tabs.read");
            addManifest(directory, sub, manifest.id, manifest.name, manifest.executable, &.{.{ .id = "run", .label = manifest.command }},
                requested, contains(manifest.events, "tabs.changed"), .legacy);
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
        if (grant.enabled and grant.tabs_read and plugin.requests.contains(.@"tabs.read")) plugin.grants.insert(.@"tabs.read");
        if (grant.enabled and grant.lua_scripts_manage and plugin.requests.contains(.@"lua.scripts.manage")) plugin.grants.insert(.@"lua.scripts.manage");
        break;
    };
}

fn persist() bool {
    var items: [16]Grant = undefined;
    for (all[0..len], 0..) |*plugin, index| items[index] = .{
        .id = std.mem.sliceTo(&plugin.id, 0),
        .enabled = plugin.enabled,
        .tabs_read = plugin.grants.contains(.@"tabs.read"),
        .lua_scripts_manage = plugin.grants.contains(.@"lua.scripts.manage"),
    };
    const bytes = std.json.Stringify.valueAlloc(allocator, items[0..len], .{}) catch return false;
    defer allocator.free(bytes);
    const string = allocator.dupeSentinel(u8, bytes, 0) catch return false;
    defer allocator.free(string);
    return native.moon_write_text(&file_path, string.ptr);
}
fn toggle(index: usize, permission: ?sdk.Permission) void {
    if (index >= len) return;
    const plugin = &all[index];
    const enabled = plugin.enabled;
    const grants = plugin.grants;
    if (permission) |scope| {
        if (!plugin.requests.contains(scope) or !enabled) {
            native.moon_shell_info("插件权限", "请先启用声明此权限的插件。");
            return;
        }
        if (grants.contains(scope)) {
            plugin.grants.remove(scope);
        } else {
            const disclosure = switch (scope) {
                .@"tabs.read" => "此插件可读取触发时的活动标签标题和网址。",
                .@"lua.scripts.manage" => "此插件可导入、停用或移除 Lua 用户脚本。新脚本首次启用时，浏览器会单独确认网站范围。",
            };
            if (!native.moon_shell_confirm("授予插件权限？", disclosure)) return;
            plugin.grants.insert(scope);
        }
    } else {
        if (!enabled and !native.moon_shell_confirm("Enable this local plugin?", &plugin.executable)) return;
        plugin.enabled = !plugin.enabled;
        if (!plugin.enabled) plugin.grants = .empty;
    }
    if (!persist()) {
        plugin.enabled = enabled;
        plugin.grants = grants;
        native.moon_shell_info("Plugin settings", "Could not save the plugin settings.");
        return;
    }
    _ = plugin.epoch.fetchAdd(1, .acq_rel);
    plugin.queued_change = false;
}

pub fn enable(index: usize) void {
    toggle(index, null);
}
pub fn toggleGrant(index: usize, permission: sdk.Permission) void {
    toggle(index, permission);
}
pub fn count() usize {
    return len;
}
pub fn label(index: usize) [*:0]const u8 {
    return &all[index].label;
}
pub fn actionCount(index: usize) usize {
    return all[index].action_count;
}
pub fn action(index: usize, command_index: usize) [*:0]const u8 {
    return &all[index].actions[command_index].label;
}
pub fn flags(index: usize) c_uint {
    const plugin = &all[index];
    return @as(c_uint, @intFromBool(plugin.enabled)) |
        (@as(c_uint, @intFromBool(plugin.grants.contains(.@"tabs.read"))) << 1) |
        (@as(c_uint, @intFromBool(plugin.grants.contains(.@"lua.scripts.manage"))) << 2) |
        (@as(c_uint, @intFromBool(plugin.requests.contains(.@"lua.scripts.manage"))) << 3);
}

fn launch(index: usize, command_index: usize, trigger: Trigger, snapshot: ?Snapshot) bool {
    if (index >= len) return false;
    const plugin = &all[index];
    if (!plugin.enabled or plugin.work != null or command_index >= plugin.action_count) return false;
    const task = allocator.create(Task) catch return false;
    const rpc = if (plugin.protocol == .v2) allocator.create(Rpc) catch {
        allocator.destroy(task);
        return false;
    } else null;
    if (rpc) |state| state.* = .{};
    task.* = .{
        .executable = &plugin.executable,
        .epoch = &plugin.epoch,
        .expected_epoch = plugin.epoch.load(.acquire),
        .snapshot = if (plugin.grants.contains(.@"tabs.read")) snapshot else null,
        .trigger = trigger,
        .plugin_id = &plugin.id,
        .command_id = &plugin.actions[command_index].id,
        .grants = plugin.grants,
        .rpc = rpc,
    };
    plugin.work = task;
    if (!native.moon_plugin_thread(task)) {
        plugin.work = null;
        if (rpc) |state| allocator.destroy(state);
        allocator.destroy(task);
        return false;
    }
    return true;
}

pub fn command(index: usize, command_index: usize, snapshot: ?Snapshot) void {
    if (!launch(index, command_index, .command, snapshot))
        native.moon_shell_info("Plugin", "This plugin is disabled, busy, or could not start.");
}
pub fn changed(snapshot: ?Snapshot) void {
    for (all[0..len], 0..) |*plugin, index| {
        if (!plugin.enabled or !plugin.subscribes) continue;
        if (plugin.protocol == .v2 and !plugin.grants.contains(.@"tabs.read")) continue;
        if (!launch(index, 0, .changed, snapshot)) plugin.queued_change = true;
    }
}

fn invocationActive(context: ?*const anyopaque) callconv(.c) bool {
    const task: *const Task = @ptrCast(@alignCast(context orelse return false));
    return !task.done.load(.acquire) and task.epoch.load(.acquire) == task.expected_epoch and
        native.moon_clock() < task.rpc.?.deadline;
}

fn serviceRpc(task: *Task, rpc: *Rpc) void {
    if (rpc.state.load(.acquire) != .queued) return;
    rpc.state.store(.serving, .release);
    defer rpc.state.store(.ready, .release);
    serving_rpc = true;
    defer serving_rpc = false;
    const reply = api.dispatch(allocator, rpc.buffer[0..rpc.size], .{
        .grants = task.grants,
        .tab = if (task.snapshot) |*snapshot| snapshot else null,
        .consent = .{ .context = task, .valid = invocationActive },
    }) catch {
        rpc.size = 0;
        return;
    };
    defer allocator.free(reply);
    @memcpy(rpc.buffer[0..reply.len], reply);
    rpc.size = reply.len;
}

pub fn tick(snapshot: ?Snapshot, smoking: bool) void {
    if (serving_rpc) return;
    for (all[0..len], 0..) |*plugin, index| {
        const task = plugin.work orelse continue;
        if (task.rpc) |rpc| if (!task.done.load(.acquire)) serviceRpc(task, rpc);
        if (!task.done.load(.acquire)) continue;
        plugin.work = null;
        if (smoking) {
            smoke_outcome = task.outcome;
            smoke_message = task.message;
        } else if (task.trigger == .command and (task.rpc == null or task.outcome != .ok or task.message[0] != 0)) {
            native.moon_shell_info(&plugin.label, switch (task.outcome) {
                .ok => &task.message,
                .timed_out => "The plugin timed out.",
                .crashed => "The plugin exited unexpectedly.",
                .failed => "Could not start the plugin or read its response.",
            });
        }
        if (task.rpc) |rpc| allocator.destroy(rpc);
        allocator.destroy(task);
        if (plugin.queued_change) {
            plugin.queued_change = false;
            _ = launch(index, 0, .changed, snapshot);
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
fn exchangeLegacy(task: *Task, pipe: *native.MoonPipe) Outcome {
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

fn sendRpc(rpc: *Rpc, pipe: *native.MoonPipe, bytes: []const u8) bool {
    // The anonymous pipe has 64 KiB of capacity. Bound cumulative output so
    // a client that writes requests without draining replies cannot block us.
    const total = bytes.len + 1;
    if (total >= sdk.frame_limit or rpc.sent + total > 48 * 1024) return false;
    rpc.sent += total;
    var line: [sdk.frame_limit]u8 = undefined;
    @memcpy(line[0..bytes.len], bytes);
    line[bytes.len] = '\n';
    line[total] = 0;
    return native.moon_pipe_send(pipe, line[0..total :0].ptr);
}

fn exchangeV2(task: *Task, pipe: *native.MoonPipe, rpc: *Rpc) Outcome {
    if (task.epoch.load(.acquire) != task.expected_epoch) return .failed;
    var grants: [@typeInfo(sdk.Permission).@"enum".field_names.len]sdk.Permission = undefined;
    var count_grants: usize = 0;
    var iterator = task.grants.iterator();
    while (iterator.next()) |scope| {
        grants[count_grants] = scope;
        count_grants += 1;
    }
    const hello = sdk.request(allocator, "h:1", "plugin.initialize", sdk.Initialization{
        .apiVersion = sdk.api_version, .pluginId = std.mem.span(task.plugin_id), .permissions = grants[0..count_grants],
    }) catch return .failed;
    defer allocator.free(hello);
    if (!sendRpc(rpc, pipe, hello)) return .failed;

    var frame: [sdk.frame_limit]u8 = undefined;
    const handshake = native.moon_pipe_read(pipe, &frame, frame.len);
    if (handshake <= 0) return pipeOutcome(handshake);
    {
        const decoded = std.json.parseFromSlice(std.json.Value, allocator, frame[0..@intCast(handshake)], .{}) catch return .failed;
        defer decoded.deinit();
        const ack = sdk.envelope(decoded.value) orelse return .failed;
        if (!std.mem.eql(u8, sdk.string(ack.get("id")) orelse return .failed, "h:1")) return .failed;
        if (ack.contains("method") or ack.contains("error") or (ack.get("result") orelse return .failed) != .null) return .failed;
    }
    if (task.epoch.load(.acquire) != task.expected_epoch) return .failed;
    const budget: c_uint = if (task.trigger == .command) 120000 else 2000;
    rpc.deadline = native.moon_clock() + budget;
    native.moon_pipe_set_budget(pipe, budget);
    const event = task.trigger == .changed;
    var tab_buffer: [24]u8 = undefined;
    const invocation = if (event) sdk.serialize(allocator, .{
        .jsonrpc = sdk.rpc_version, .method = "tabs.changed", .params = sdk.TabChange{
            .tabId = if (task.snapshot) |tab| api.tabId(tab.id, &tab_buffer) else null,
        },
    }) catch return .failed else sdk.request(allocator, "h:2", "commands.run", .{
        .id = std.mem.span(task.command_id),
    }) catch return .failed;
    defer allocator.free(invocation);
    if (!sendRpc(rpc, pipe, invocation)) return .failed;

    var sequence: u32 = 0;
    for (0..sdk.request_limit + 1) |_| {
        if (!invocationActive(task)) return .timed_out;
        const read = native.moon_pipe_read_active(pipe, &frame, frame.len, invocationActive, task);
        if (event and read == -3) return .ok;
        if (read <= 0) return pipeOutcome(read);
        const bytes = frame[0..@intCast(read)];
        const decoded = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return .failed;
        defer decoded.deinit();
        const message = sdk.envelope(decoded.value) orelse return .failed;
        const id = sdk.string(message.get("id")) orelse return .failed;
        if (!event and std.mem.eql(u8, id, "h:2")) {
            if (message.contains("method") or message.contains("error")) return .failed;
            const reply = std.json.parseFromValue(sdk.CommandResult, allocator, message.get("result") orelse return .failed, .{}) catch return .failed;
            defer reply.deinit();
            if (!copy(&task.message, reply.value.message orelse "")) return .failed;
            return .ok;
        }
        if (!std.mem.startsWith(u8, id, "p:") or id.len > 11) return .failed;
        for (id[2..]) |ch| if (!std.ascii.isDigit(ch)) return .failed;
        const next = std.fmt.parseUnsigned(u32, id[2..], 10) catch return .failed;
        if (next != sequence + 1 or sequence >= sdk.request_limit) return .failed;
        sequence = next;
        if (!invocationActive(task)) return .timed_out;
        @memcpy(rpc.buffer[0..bytes.len], bytes);
        rpc.size = bytes.len;
        rpc.state.store(.queued, .release);
        while (rpc.state.load(.acquire) != .ready) {
            if (!invocationActive(task)) return .timed_out;
            native.moon_plugin_wait();
        }
        if (rpc.size == 0 or !sendRpc(rpc, pipe, rpc.buffer[0..rpc.size])) return .failed;
        rpc.state.store(.idle, .release);
    }
    return .failed;
}

fn pipeOutcome(code: c_int) Outcome {
    return switch (code) {
        -2 => .timed_out,
        -3 => .crashed,
        else => .failed,
    };
}

pub fn worker(opaque_task: ?*anyopaque) void {
    const task: *Task = @ptrCast(@alignCast(opaque_task orelse return));
    defer task.done.store(true, .release);
    var win_error: u32 = 0;
    const pipe = native.moon_pipe_open(task.executable, &win_error) orelse {
        _ = std.fmt.bufPrintSentinel(&task.message, "Could not launch plugin (Windows error {d}).", .{win_error}, 0) catch {};
        return;
    };
    task.outcome = if (task.rpc) |rpc| exchangeV2(task, pipe, rpc) else exchangeLegacy(task, pipe);
    const exited_cleanly = native.moon_pipe_close(pipe);
    if (task.outcome == .ok and !exited_cleanly) task.outcome = .crashed;
}

pub fn smokeStart(index: usize, step: usize, snapshot: ?Snapshot) bool {
    if (index >= len) return false;
    smoke_outcome = null;
    all[index].enabled = true;
    all[index].grants = if (step == 0) .empty else .initOne(.@"tabs.read");
    if (step == 2) return launch(index, 0, .changed, snapshot);
    return launch(index, 0, if (step == 3) .timeout_test else if (step == 4) .crash_test else .command, snapshot);
}

fn contractFixture() ?usize {
    for (all[0..len], 0..) |*plugin, index| {
        if (plugin.protocol == .v2 and std.mem.eql(u8, std.mem.sliceTo(&plugin.id, 0), "moon.api-contract")) return index;
    }
    return null;
}

pub fn smokeHasContract() bool {
    return contractFixture() != null;
}

pub fn smokeContract(step: usize, snapshot: ?Snapshot) bool {
    const index = contractFixture() orelse return false;
    const plugin = &all[index];
    const permitted_calls = step == 6 or step == 7;
    _ = plugin.epoch.fetchAdd(1, .acq_rel);
    plugin.enabled = true;
    plugin.grants = if (permitted_calls) .initMany(&.{ .@"tabs.read", .@"lua.scripts.manage" }) else .empty;
    smoke_outcome = null;
    return launch(index, if (step == 6) 1 else 0, if (step == 7) .changed else .command, snapshot);
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
        5, 8 => outcome == .ok and std.mem.eql(u8, message, "V2 consent denied"),
        6 => outcome == .ok and std.mem.eql(u8, message, "V2 contract passed"),
        7 => outcome == .ok,
        else => false,
    };
}

pub fn smokeDetail() struct { outcome: []const u8, message: []const u8 } {
    return .{ .outcome = if (smoke_outcome) |value| @tagName(value) else "pending", .message = std.mem.sliceTo(&smoke_message, 0) };
}
