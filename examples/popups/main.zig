const std = @import("std");
const sdk = @import("moon_plugin");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var client: sdk.Client = .{ .allocator=arena.allocator() };
    _ = try client.initialize();
    const command = try client.receive();
    if (!std.mem.eql(u8,sdk.string(command.get("method")) orelse "","commands.run")) return error.InvalidCommand;
    const id = sdk.string(command.get("id")) orelse return error.InvalidCommand;
    const reply = try client.call(.@"popups.open",.{});
    const value = reply.get("result") orelse std.json.Value.null;
    try client.reply(id,sdk.CommandResult{
        .message = if (value == .bool and value.bool) null else "无法打开网站弹窗设置。请检查插件是否已启用。",
        .toast = true,
    });
}
