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
    const Action = enum { open, reopen };
    const message: ?[]const u8 = switch (std.meta.stringToEnum(Action, action) orelse return error.InvalidCommand) {
        .open => open: {
            const response = try client.call(.@"ui.openPage", .{});
            const value = response.get("result") orelse std.json.Value.null;
            break :open if (value == .bool and value.bool) null else "无法打开最近关闭列表。";
        },
        .reopen => reopen: {
            const response = try client.call(.@"tabs.closed.reopen", .{});
            const value = sdk.string(response.get("result")) orelse break :reopen "恢复标签不可用，请检查插件权限。";
            const outcome = std.meta.stringToEnum(sdk.ReopenClosedTab, value) orelse return error.InvalidResponse;
            break :reopen switch (outcome) {
                .reopened => null,
                .notFound => "没有可恢复的标签。",
                .tabLimit => "标签页已满，关闭一页后可尝试恢复。",
                .unavailable => "当前无法恢复标签。",
            };
        },
    };
    try client.reply(id, sdk.CommandResult{ .message = message, .toast = true });
}
