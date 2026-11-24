const std = @import("std");
const sdk = @import("moon_plugin");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var client: sdk.Client = .{ .allocator = arena.allocator() };
    _ = try client.initialize();
    const request = try client.receive();
    if (!std.mem.eql(u8,sdk.string(request.get("method")) orelse "","commands.run")) return error.InvalidCommand;
    const id = sdk.string(request.get("id")) orelse return error.InvalidCommand;
    const params = request.get("params") orelse return error.InvalidCommand;
    if (params != .object) return error.InvalidCommand;
    const action = sdk.string(params.object.get("id")) orelse return error.InvalidCommand;
    const Action = enum { settings, theme, focus };
    const selected = std.meta.stringToEnum(Action,action) orelse return error.InvalidCommand;
    const message: ?[]const u8 = switch (selected) {
        .settings => open: {
            const reply = try client.call(.@"ui.openPage",.{});
            const value = reply.get("result") orelse std.json.Value.null;
            break :open if (value==.bool and value.bool) null else "无法打开外观设置。";
        },
        .theme, .focus => apply: {
            const target: sdk.AppearanceTarget = if (selected==.theme) .theme else .focusMode;
            const reply = try client.call(.@"window.appearance.toggle",.{ .target=target });
            if (reply.contains("result")) break :apply null;
            break :apply "无法更新外观。请检查插件权限和配置目录。";
        },
    };
    try client.reply(id,sdk.CommandResult{ .message=message,.toast=true });
}
