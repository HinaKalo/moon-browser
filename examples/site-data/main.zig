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
    const response = try client.call(.@"siteData.open",.{});
    const result = response.get("result") orelse std.json.Value.null;
    try client.reply(id,sdk.CommandResult{
        .message=if (result == .bool and result.bool) null else "请在已加载的网页上执行此命令，并检查插件权限。",
        .toast=true,
    });
}
