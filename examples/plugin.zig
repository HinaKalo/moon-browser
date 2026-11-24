const std = @import("std");
const sdk = @import("moon_plugin");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var client: sdk.Client = .{ .allocator = arena.allocator() };
    _ = try client.initialize();
    const invocation = try client.receive();
    const method = sdk.string(invocation.get("method")) orelse return error.InvalidCommand;
    if (std.mem.eql(u8, method, "tabs.changed")) return;
    if (!std.mem.eql(u8, method, "commands.run")) return error.InvalidCommand;
    const id = sdk.string(invocation.get("id")) orelse return error.InvalidCommand;
    const params = invocation.get("params") orelse return error.InvalidCommand;
    if (params != .object or !std.mem.eql(u8, sdk.string(params.object.get("id")) orelse "", "run"))
        return error.InvalidCommand;

    const reply = try client.call(.@"tabs.getActive", .{});
    const message = if (reply.get("result")) |value| switch (value) {
        .null => "当前没有活动标签。",
        .object => title: {
            const tab = try std.json.parseFromValueLeaky(sdk.Tab, client.allocator, value, .{ .ignore_unknown_fields = true });
            break :title if (tab.title.len == 0) "当前标签没有标题。" else tab.title;
        },
        else => return error.InvalidResponse,
    } else "请在插件管理中授予读取标签权限。";
    try client.reply(id, sdk.CommandResult{ .message = message, .toast = true });
}
