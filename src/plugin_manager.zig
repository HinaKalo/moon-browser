const std = @import("std");
const native = @import("native");
const plugins = @import("plugins.zig");
const sdk = @import("moon_plugin");

pub const address: [:0]const u8 = native.MOON_PLUGIN_MANAGER_ADDRESS;
pub const document: [:0]const u8 = @embedFile("plugin_manager.html");

pub const Request = struct {
    op: enum { list, details, enable, grant, settings, market, shortcut, capture },
    offset: usize = 0,
    id: ?[]const u8 = null,
    permission: ?sdk.Permission = null,
    enabled: ?bool = null,
    command: ?[]const u8 = null,
    shortcut: ?[]const u8 = null,
};

const Entry = struct { id: []const u8, name: []const u8, enabled: bool, bundled: bool };
const Permission = struct { id: sdk.Permission, label: []const u8, granted: bool };
const Command = struct {
    id: []const u8,
    label: []const u8,
    shortcut: []const u8,
    custom: bool,
    globalShortcut: ?[]const u8,
    linkMenu: bool,
    tabDrop: bool,
};

pub fn reply(allocator: std.mem.Allocator, output: []u8, data: anytype) bool {
    const json = std.json.Stringify.valueAlloc(allocator, data, .{}) catch return false;
    if (json.len >= output.len) return false;
    @memcpy(output[0..json.len], json);
    output[json.len] = 0;
    return true;
}

pub fn list(allocator: std.mem.Allocator, output: []u8, offset: usize) bool {
    const count = plugins.count();
    if (offset > count) return false;
    var items: [8]Entry = undefined;
    const size = @min(items.len, count - offset);
    for (items[0..size], offset..) |*item, index| item.* = .{
        .id = plugins.idAt(index),
        .name = std.mem.span(plugins.label(index)),
        .enabled = plugins.isEnabled(index),
        .bundled = plugins.isBundled(index),
    };
    return reply(allocator, output, .{
        .items=items[0..size],.next=if (offset+size<count) offset+size else null,
        .limit=native.MOON_PLUGIN_LIMIT,
    });
}

pub fn details(allocator: std.mem.Allocator, output: []u8, index: usize) bool {
    var permissions: [std.enums.values(sdk.Permission).len]Permission = undefined;
    var count: usize = 0;
    for (std.enums.values(sdk.Permission)) |permission| {
        const flags = plugins.permissionFlags(index, permission);
        if (flags & 1 == 0) continue;
        permissions[count] = .{
            .id = permission,
            .label = std.mem.span(native.moon_plugin_permission_label(@intFromEnum(permission))),
            .granted = flags & 2 != 0,
        };
        count += 1;
    }
    var commands: [sdk.command_limit]Command = undefined;
    const used = plugins.actionCount(index);
    for (commands[0..used], 0..) |*command, i| {
        const user = plugins.userShortcut(index,i);
        const global = plugins.pluginGlobalShortcut(index,i);
        command.* = .{
            .id = plugins.actionId(index,i),
            .label = std.mem.span(plugins.action(index,i)),
            .shortcut = if (global != null and user == null) "" else std.mem.span(native.moon_plugin_action_shortcut(index,i)),
            .custom = user != null,
            .globalShortcut = if (global) |key| std.mem.span(key) else null,
            .linkMenu = plugins.linkOnly(index,i),
            .tabDrop = plugins.tabDropOnly(index,i),
        };
    }
    return reply(allocator, output, .{
        .enabled = plugins.isEnabled(index),
        .settings = plugins.hasSettings(index),
        .permissions = permissions[0..count],
        .commands = commands[0..used],
    });
}
