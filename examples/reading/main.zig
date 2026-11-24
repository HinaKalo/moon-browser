const std = @import("std");
const sdk = @import("moon_plugin");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var client: sdk.Client = .{ .allocator = arena.allocator() };
    _ = try client.initialize();
    const command = try client.receive();
    if (!std.mem.eql(u8, sdk.string(command.get("method")) orelse "", "commands.run")) return error.InvalidCommand;
    const id = sdk.string(command.get("id")) orelse return error.InvalidCommand;
    const params = command.get("params") orelse return error.InvalidCommand;
    if (params != .object) return error.InvalidCommand;
    const action = sdk.string(params.object.get("id")) orelse return error.InvalidCommand;
    const unavailable = "请在已加载的页面上执行此命令，并检查插件权限。";
    const message: ?[]const u8 = if (std.mem.eql(u8, action, "find")) find: {
        const response = try client.call(.@"reading.find", .{});
        const result = response.get("result") orelse std.json.Value.null;
        break :find if (result == .bool and result.bool) null else unavailable;
    } else if (std.mem.eql(u8,action,"reader")) article: {
        const response = try client.call(.@"reading.open", .{});
        const result = response.get("result") orelse std.json.Value.null;
        break :article if (result == .bool and result.bool) null else unavailable;
    } else if (std.mem.eql(u8,action,"fullscreen")) fullscreen: {
        const response = try client.call(.@"window.toggleFullscreen", .{});
        const result = response.get("result") orelse std.json.Value.null;
        break :fullscreen if (result == .bool) null else unavailable;
    } else zoom: {
        const step = std.meta.stringToEnum(sdk.ZoomAction, action) orelse return error.InvalidCommand;
        const response = try client.call(.@"reading.zoom", .{ .action = step });
        const result = response.get("result") orelse std.json.Value.null;
        break :zoom if (result == .integer)
            try std.fmt.allocPrint(client.allocator, "页面缩放 {d}%", .{result.integer})
        else
            unavailable;
    };
    try client.reply(id, sdk.CommandResult{ .message = message, .toast = true });
}
