const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");
const api = @import("plugin_host_api.zig");
const network = @import("network_policy.zig");
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
const Grant = struct {
    id: []const u8, enabled: bool, tabs_read: bool,
    lua_scripts_manage: bool = false, page_inspect: bool = false, history_manage: bool = false, network_filter: bool = false,
    bookmarks_manage: bool = false, downloads_manage: bool = false, site_data_read: bool = false,
};
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
    target_tab_id: u64,
    trigger: Trigger,
    plugin_id: [*:0]const u8,
    command_id: [*:0]const u8,
    interactive: bool,
    owner: u64,
    dark: bool,
    grants: Permissions,
    rpc: ?*Rpc = null,
    outcome: Outcome = .failed,
    message: [512:0]u8 = @splat(0),
    toast: bool = false,
};
const Command = struct { id: [64:0]u8 = @splat(0), label: [256:0]u8 = @splat(0), interactive: bool = false, shortcut: ?sdk.Shortcut = null };
const Plugin = struct {
    id: [96:0]u8,
    label: [256:0]u8,
    actions: [sdk.command_limit]Command = undefined,
    action_count: usize,
    executable: [4096:0]u8,
    settings_page: [96:0]u8 = @splat(0),
    network_rules: [96:0]u8 = @splat(0),
    protocol: Protocol,
    requests: Permissions,
    default_grants: Permissions = .empty,
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

fn addManifest(directory: []const u8, sub: []const u8, id: []const u8, name: []const u8, entry: []const u8, settings_page: ?[]const u8, network_rules: ?[]const u8, commands: []const sdk.Command, requests: Permissions, subscribes: bool, protocol: Protocol, bundled: bool) void {
    if (!validComponent(id) or !validComponent(entry) or !std.ascii.endsWithIgnoreCase(entry, ".exe") or
        name.len == 0 or commands.len == 0 or commands.len > sdk.command_limit) return;
    if (protocol == .v2 and std.mem.indexOfScalar(u8, id, '.') == null) return;
    if (settings_page) |page| {
        if (!validComponent(page) or !std.mem.endsWith(u8,page,".html")) return;
    }
    if (network_rules) |file| {
        if (!validComponent(file) or !std.mem.endsWith(u8,file,".rules") or !requests.contains(.@"network.filter")) return;
    } else if (requests.contains(.@"network.filter")) return;
    for (all[0..len]) |*existing| if (std.ascii.eqlIgnoreCase(std.mem.sliceTo(&existing.id, 0), id)) return;
    var path: [4096]u8 = undefined;
    const executable = std.fmt.bufPrint(&path, "{s}\\{s}\\{s}", .{ directory, sub, entry }) catch return;
    const plugin = &all[len];
    plugin.* = .{
        .id = @splat(0), .label = @splat(0), .executable = @splat(0), .action_count = commands.len,
        .protocol = protocol, .requests = requests, .subscribes = subscribes,
    };
    if (!copy(&plugin.id, id) or !copy(&plugin.label, name) or !copy(&plugin.executable, executable)) return;
    if (!copy(&plugin.settings_page,settings_page orelse "")) return;
    if (!copy(&plugin.network_rules,network_rules orelse "")) return;
    for (commands, 0..) |item, index| {
        if (!validComponent(item.id) or item.label.len == 0) return;
        for (commands[0..index]) |prior| if (std.mem.eql(u8, prior.id, item.id)) return;
        plugin.actions[index] = .{};
        plugin.actions[index].interactive = item.interactive;
        plugin.actions[index].shortcut = item.shortcut;
        if (!copy(&plugin.actions[index].id, item.id) or !copy(&plugin.actions[index].label, item.label)) return;
    }
    if (bundled) {
        const default_permission: ?sdk.Permission = if (std.mem.eql(u8,id,"moon.history")) .@"history.manage"
            else if (std.mem.eql(u8,id,"moon.devtools")) .@"page.inspect"
            else if (std.mem.eql(u8,id,"moon.bookmarks")) .@"bookmarks.manage"
            else if (std.mem.eql(u8,id,"moon.downloads")) .@"downloads.manage"
            else if (std.mem.eql(u8,id,"moon.site-data")) .@"siteData.read" else null;
        if (default_permission) |scope| {
            if (requests.contains(scope)) {
                plugin.enabled = true;
                plugin.default_grants = .initOne(scope);
                plugin.grants = plugin.default_grants;
            }
        }
        if (std.mem.eql(u8,id,"moon.blocker") and requests.contains(.@"network.filter"))
            plugin.default_grants.insert(.@"network.filter");
    }
    len += 1;
}

fn discover(root: []const u8, bundled: bool) void {
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
            addManifest(directory, sub, manifest.id, manifest.name, manifest.entry, manifest.settingsPage, manifest.networkRules, manifest.contributes.commands, requested, subscribes, .v2, bundled);
        } else |_| {
            const parsed = std.json.parseFromSlice(LegacyManifest, allocator, bytes, .{}) catch continue;
            defer parsed.deinit();
            const manifest = parsed.value;
            if (manifest.api_version != 1) continue;
            var requested = Permissions.empty;
            if (contains(manifest.permissions, "tabs.read")) requested.insert(.@"tabs.read");
            addManifest(directory, sub, manifest.id, manifest.name, manifest.executable, null, null, &.{.{ .id = "run", .label = manifest.command }},
                requested, contains(manifest.events, "tabs.changed"), .legacy, bundled);
        }
    }
}

pub fn init(app: []const u8, profile: []const u8) void {
    discover(app,true);
    discover(profile,false);
    _ = std.fmt.bufPrintSentinel(&file_path, "{s}\\plugin-state.json", .{profile}, 0) catch return;
    var raw: [16384]u8 = undefined;
    if (!native.moon_read_text(&file_path, &raw, raw.len)) return;
    const saved = std.json.parseFromSlice([]Grant, allocator, std.mem.sliceTo(&raw, 0), .{}) catch return;
    defer saved.deinit();
    for (all[0..len]) |*plugin| for (saved.value) |grant| {
        if (!std.mem.eql(u8, grant.id, std.mem.sliceTo(&plugin.id, 0))) continue;
        plugin.enabled = grant.enabled;
        plugin.grants = .empty;
        if (grant.enabled and grant.tabs_read and plugin.requests.contains(.@"tabs.read")) plugin.grants.insert(.@"tabs.read");
        if (grant.enabled and grant.lua_scripts_manage and plugin.requests.contains(.@"lua.scripts.manage")) plugin.grants.insert(.@"lua.scripts.manage");
        if (grant.enabled and grant.page_inspect and plugin.requests.contains(.@"page.inspect")) plugin.grants.insert(.@"page.inspect");
        if (grant.enabled and grant.history_manage and plugin.requests.contains(.@"history.manage")) plugin.grants.insert(.@"history.manage");
        if (grant.enabled and grant.network_filter and plugin.requests.contains(.@"network.filter")) plugin.grants.insert(.@"network.filter");
        if (grant.enabled and grant.bookmarks_manage and plugin.requests.contains(.@"bookmarks.manage")) plugin.grants.insert(.@"bookmarks.manage");
        if (grant.enabled and grant.downloads_manage and plugin.requests.contains(.@"downloads.manage")) plugin.grants.insert(.@"downloads.manage");
        if (grant.enabled and grant.site_data_read and plugin.requests.contains(.@"siteData.read")) plugin.grants.insert(.@"siteData.read");
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
        .page_inspect = plugin.grants.contains(.@"page.inspect"),
        .history_manage = plugin.grants.contains(.@"history.manage"),
        .network_filter = plugin.grants.contains(.@"network.filter"),
        .bookmarks_manage = plugin.grants.contains(.@"bookmarks.manage"),
        .downloads_manage = plugin.grants.contains(.@"downloads.manage"),
        .site_data_read = plugin.grants.contains(.@"siteData.read"),
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
                .@"page.inspect" => "此插件可为触发命令时的网页打开开发者工具。控制台和站点存储可在工具中查看。",
                .@"history.manage" => "此插件可读取和删除本机浏览记录，包括网页标题、网址和访问时间。",
                .@"network.filter" => "此插件可阻止匹配规则的网页请求，并为你指定的站点停用过滤。",
                .@"bookmarks.manage" => "此插件可读取、添加、编辑和删除本机书签。",
                .@"downloads.manage" => "此插件可读取本机下载记录、取消传输，并在文件夹中显示已保存的文件。",
                .@"siteData.read" => "你从网页触发此插件命令时，它的页面可读取该网页可见的 Cookie 和站点存储。",
            };
            if (!native.moon_shell_confirm("授予插件权限？", disclosure)) return;
            plugin.grants.insert(scope);
        }
    } else {
        if (!enabled) {
            const disclosure = if (plugin.default_grants.contains(.@"network.filter"))
                "启用后将立即拦截匹配规则的网页请求。你可以在插件面板为单个站点暂停过滤。"
            else &plugin.executable;
            if (!native.moon_shell_confirm("启用本地插件？",disclosure)) return;
        }
        plugin.enabled = !plugin.enabled;
        plugin.grants = if (plugin.enabled) plugin.default_grants else .empty;
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
pub fn actionShortcut(index: usize, command_index: usize) ?sdk.Shortcut {
    return all[index].actions[command_index].shortcut;
}
pub fn isEnabled(index: usize) bool {
    return all[index].enabled;
}

pub fn permissionFlags(index: usize, permission: sdk.Permission) c_uint {
    const plugin = &all[index];
    return @as(c_uint,@intFromBool(plugin.requests.contains(permission))) |
        (@as(c_uint,@intFromBool(plugin.grants.contains(permission))) << 1);
}

pub fn hasSettings(index: usize) bool {
    return index < len and all[index].settings_page[0] != 0;
}

pub fn settingsAddress(index: usize, buffer: []u8) ?[:0]u8 {
    if (!hasSettings(index) or !all[index].enabled) return null;
    const plugin = &all[index];
    return std.fmt.bufPrintSentinel(buffer,"extension://{s}/{s}",.{ std.mem.sliceTo(&plugin.id,0),std.mem.sliceTo(&plugin.settings_page,0) },0) catch null;
}

pub fn pageGrants(id: []const u8) ?Permissions {
    for (all[0..len]) |*plugin| {
        if (plugin.enabled and plugin.settings_page[0] != 0 and std.mem.eql(u8,std.mem.sliceTo(&plugin.id,0),id)) return plugin.grants;
    }
    return null;
}

pub fn systemEnabled(permission: sdk.Permission) bool {
    for (all[0..len]) |*plugin| {
        if (plugin.default_grants.contains(permission)) return plugin.enabled and plugin.grants.contains(permission);
    }
    return false;
}

pub fn networkSource() ?network.Source {
    for (all[0..len]) |*plugin| {
        if (plugin.enabled and plugin.grants.contains(.@"network.filter") and plugin.network_rules[0] != 0)
            return .{ .id=std.mem.sliceTo(&plugin.id,0),.executable=std.mem.sliceTo(&plugin.executable,0),.filename=std.mem.sliceTo(&plugin.network_rules,0) };
    }
    return null;
}

pub fn addressForId(id: []const u8, buffer: []u8) ?[:0]u8 {
    for (all[0..len],0..) |*plugin,index| {
        if (std.mem.eql(u8,std.mem.sliceTo(&plugin.id,0),id)) return settingsAddress(index,buffer);
    }
    return null;
}

pub fn readSettingsPage(address: []const u8, body: []u8) ?[:0]const u8 {
    if (!std.mem.startsWith(u8,address,"extension://")) return null;
    const route = address["extension://".len..];
    const slash = std.mem.indexOfScalar(u8,route,'/') orelse return null;
    const id = route[0..slash];
    const page = route[slash+1..];
    for (all[0..len]) |*plugin| {
        if (!plugin.enabled or plugin.settings_page[0] == 0 or
            !std.ascii.eqlIgnoreCase(std.mem.sliceTo(&plugin.id,0),id) or
            !std.mem.eql(u8,std.mem.sliceTo(&plugin.settings_page,0),page)) continue;
        const executable = std.mem.sliceTo(&plugin.executable,0);
        const folder_end = std.mem.lastIndexOfScalar(u8,executable,'\\') orelse return null;
        var filename: [4096]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&filename,"{s}\\{s}",.{ executable[0..folder_end],page },0) catch return null;
        if (!native.moon_read_plain_text(path.ptr,body.ptr,body.len)) return null;
        return &plugin.id;
    }
    return null;
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
        .snapshot = if (plugin.grants.contains(.@"tabs.read") or plugin.grants.contains(.@"bookmarks.manage") or
            plugin.grants.contains(.@"siteData.read")) snapshot else null,
        .target_tab_id = if (snapshot) |tab| tab.id else 0,
        .trigger = trigger,
        .plugin_id = &plugin.id,
        .command_id = &plugin.actions[command_index].id,
        .interactive = plugin.actions[command_index].interactive,
        .owner = native.moon_shell_window_handle(),
        .dark = native.moon_shell_dark_mode(),
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

pub fn shortcut(key: sdk.Shortcut, snapshot: ?Snapshot) bool {
    for (all[0..len],0..) |*plugin,index| {
        if (!plugin.enabled) continue;
        for (plugin.actions[0..plugin.action_count],0..) |action_entry,command_index| {
            if (action_entry.shortcut != key) continue;
            // Repeated shortcuts should not interrupt a plugin that's still opening its page.
            if (plugin.work == null) command(index,command_index,snapshot);
            return true;
        }
    }
    return false;
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
        .plugin_id = std.mem.span(task.plugin_id),
        .target_tab_id = task.target_tab_id,
        .tab = if (task.snapshot) |*snapshot| snapshot else null,
        .consent = .{ .context = task, .valid = invocationActive },
        .user_command = task.trigger == .command,
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
        } else if (task.trigger == .command and task.outcome == .ok and task.toast and task.message[0] != 0) {
            native.moon_shell_toast(&plugin.label,&task.message);
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
        .browserWindow = task.owner, .darkMode = task.dark,
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
    const budget: c_uint = if (task.trigger != .command) 2000 else if (task.interactive) 30*60*1000 else 120000;
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
            task.toast = reply.value.toast;
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

pub fn smokeStart(step: usize, snapshot: ?Snapshot) bool {
    const index = for (all[0..len],0..) |*plugin,i| {
        if (plugin.protocol == .legacy and std.mem.eql(u8,std.mem.sliceTo(&plugin.id,0),"moon.example")) break i;
    } else return false;
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
