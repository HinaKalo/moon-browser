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
    const Action = enum { pin, mute };
    const method: sdk.Method = switch (std.meta.stringToEnum(Action, action) orelse return error.InvalidCommand) {
        .pin => .@"tabs.togglePinned",
        .mute => .@"tabs.toggleMuted",
    };
    const response = try client.call(method, .{});
    const outcome = std.meta.stringToEnum(sdk.TabOrganization, sdk.string(response.get("result")) orelse "") orelse .unavailable;
    const message: ?[]const u8 = switch (outcome) {
        .pinned, .unpinned, .muted, .unmuted => null,
        .unavailable => "请在可恢复的网页上执行此命令，并检查插件权限。",
        .limitReached => "已达到固定标签上限。取消固定一个标签后可继续。",
        .saveFailed => "无法保存固定标签。请检查浏览器配置目录。",
    };
    try client.reply(id, sdk.CommandResult{ .message = message, .toast = true });
}
