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
    const message: ?[]const u8 = if (std.mem.eql(u8, action, "hello")) "Moon 命令已由插件执行。" else if (std.mem.eql(u8, action, "settings")) open: {
        const response = try client.call(.@"ui.openPage", .{});
        const result = response.get("result") orelse std.json.Value.null;
        break :open if (result == .bool and result.bool) null else "无法打开命令示例。";
    } else return error.InvalidCommand;
    try client.reply(id, sdk.CommandResult{ .message = message, .toast = true });
}
