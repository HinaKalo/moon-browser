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
    if (std.mem.eql(u8,action,"open")) {
        const response = try client.call(.@"ui.openPage",.{});
        const value = response.get("result") orelse std.json.Value.null;
        try client.reply(id,sdk.CommandResult{ .message=if (value == .bool and value.bool) null else "无法打开书签页。" });
        return;
    }
    if (!std.mem.eql(u8,action,"save")) return error.InvalidCommand;
    const response = try client.call(.@"bookmarks.saveActive",.{});
    const value = sdk.string(response.get("result")) orelse "";
    const message: []const u8 = if (std.mem.eql(u8,value,"saved")) "已将当前网页加入书签。"
        else if (std.mem.eql(u8,value,"alreadySaved")) "这页已在书签中。"
        else if (std.mem.eql(u8,value,"noPage")) "请切换到已打开的网页。"
        else "无法保存书签。请检查插件权限。";
    try client.reply(id,sdk.CommandResult{ .message=message,.toast=true });
}
