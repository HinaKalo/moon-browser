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
    const params = command.get("params") orelse return error.InvalidCommand;
    if (params!=.object) return error.InvalidCommand;
    const action = sdk.string(params.object.get("id")) orelse return error.InvalidCommand;
    const Action = enum { restore, preferences };
    const message: ?[]const u8 = switch (std.meta.stringToEnum(Action,action) orelse return error.InvalidCommand) {
        .restore => restore: {
            const response = try client.call(.@"tabs.session.restore",.{});
            const value = sdk.string(response.get("result")) orelse "";
            const outcome = std.meta.stringToEnum(sdk.SessionRestore,value) orelse .unavailable;
            break :restore switch (outcome) {
                .restored => null,
                .empty => "没有可恢复的上次会话。",
                .tabLimit => "当前窗口没有足够的标签位置。",
                .unavailable => "当前无法恢复会话。",
            };
        },
        .preferences => open: {
            const response = try client.call(.@"ui.openPage",.{});
            const value = response.get("result") orelse std.json.Value.null;
            break :open if (value==.bool and value.bool) null else "无法打开会话设置。";
        },
    };
    try client.reply(id,sdk.CommandResult{ .message=message,.toast=true });
}
