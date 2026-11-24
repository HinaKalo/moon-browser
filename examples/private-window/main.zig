const std = @import("std");
const sdk = @import("moon_plugin");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var client: sdk.Client = .{ .allocator = arena.allocator() };
    _ = try client.initialize();
    const command = try client.receive();
    if (!std.mem.eql(u8,sdk.string(command.get("method")) orelse "", "commands.run")) return error.InvalidCommand;
    const id = sdk.string(command.get("id")) orelse return error.InvalidCommand;
    const params = command.get("params") orelse return error.InvalidCommand;
    if (params!=.object or !std.mem.eql(u8,sdk.string(params.object.get("id")) orelse "", "open")) return error.InvalidCommand;
    const response = try client.call(.@"privacy.openPrivateWindow", .{});
    const result = response.get("result") orelse std.json.Value.null;
    try client.reply(id,sdk.CommandResult{
        .message=if (result==.bool and result.bool) null else "无法打开隐私窗口，请检查插件权限。",
        .toast=true,
    });
}
