const std = @import("std");
const sdk = @import("moon_plugin");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var client: sdk.Client = .{ .allocator = arena.allocator() };
    _ = try client.initialize();
    const command = try client.receive();
    if (!std.mem.eql(u8,sdk.string(command.get("method")) orelse "","commands.run")) return error.InvalidCommand;
    const id = sdk.string(command.get("id")) orelse return error.InvalidCommand;
    const response = try client.call(.@"ui.openPage",.{});
    const result = response.get("result") orelse std.json.Value.null;
    try client.reply(id,sdk.CommandResult{
        .message = if (result == .bool and result.bool) null else "无法打开历史记录。",
    });
}
