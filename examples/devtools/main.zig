const std = @import("std");
const sdk = @import("moon_plugin");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var client: sdk.Client = .{ .allocator=arena.allocator() };
    _ = try client.initialize();
    const command = try client.receive();
    if (!std.mem.eql(u8,sdk.string(command.get("method")) orelse "", "commands.run")) return error.InvalidCommand;
    const id = sdk.string(command.get("id")) orelse return error.InvalidCommand;
    const params = command.get("params") orelse return error.InvalidCommand;
    if (params != .object) return error.InvalidCommand;
    const action = sdk.string(params.object.get("id")) orelse return error.InvalidCommand;
    const toggle = std.mem.eql(u8,action,"inspector");
    const reply = if (toggle) try client.call(.@"devtools.toggle",.{}) else open: {
        const independent = std.mem.eql(u8,action,"window");
        const panel = if (independent) .inspector else std.meta.stringToEnum(sdk.InspectorPanel,action) orelse return error.InvalidCommand;
        const placement: sdk.InspectorPlacement = if (independent) .window else .docked;
        break :open try client.call(.@"devtools.open",.{ .panel=panel, .placement=placement });
    };
    const value = reply.get("result");
    try client.reply(id,sdk.CommandResult{ .message = if (value) |opened|
        if (opened == .bool and (toggle or opened.bool)) null else "请选择一个已加载的网页标签。"
    else "请在浏览器菜单授予开发者工具权限。" });
}
