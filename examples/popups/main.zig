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
    if (params != .object) return error.InvalidCommand;
    const action = sdk.string(params.object.get("id")) orelse return error.InvalidCommand;
    if (std.mem.eql(u8,action,"sound")) {
        const reply = try client.call(.@"siteSettings.sound.toggle",.{});
        const result = sdk.string(reply.get("result")) orelse "unavailable";
        try client.reply(id,sdk.CommandResult{
            .message = if (std.mem.eql(u8,result,"muted")) "此网站已静音。"
                else if (std.mem.eql(u8,result,"unmuted")) "已取消网站静音。"
                else if (std.mem.eql(u8,result,"limitReached")) "静音例外已达上限。"
                else "请在网页上使用此命令，并检查网站静音权限。",
            .toast = true,
        });
        return;
    }
    const reply = try client.call(.@"popups.open",.{});
    const value = reply.get("result") orelse std.json.Value.null;
    try client.reply(id,sdk.CommandResult{
        .message = if (value == .bool and value.bool) null else "无法打开站点设置。请检查插件是否已启用。",
        .toast = true,
    });
}
