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
    const phone = std.mem.eql(u8,action,"viewportPhone");
    if (phone or std.mem.eql(u8,action,"viewport")) {
        const options: sdk.ViewportOptions = if (phone) .{ .preset=.compactPhone,.fit=true } else .{};
        const reply = try client.call(.@"devtools.viewport",options);
        const state = sdk.string(reply.get("result")) orelse "";
        return client.reply(id,.{ .message=if (std.mem.eql(u8,state,"enabled") or std.mem.eql(u8,state,"disabled")) null
            else "请在已加载的网页上打开响应式预览，并检查开发者工具权限。",.toast=true });
    }
    if (std.mem.eql(u8,action,"settings")) {
        const reply = try client.call(.@"ui.openPage",.{});
        const value = reply.get("result");
        const opened = if (value) |result| result==.bool and result.bool else false;
        return client.reply(id,.{ .message=if (opened) null else "无法打开开发者工具设置。",.toast=true });
    }
    if (std.mem.eql(u8,action,"hardReload")) {
        const reply = try client.call(.@"devtools.hardReload",.{});
        const status = sdk.string(reply.get("result")) orelse "";
        const result = std.meta.stringToEnum(sdk.HardReloadResult,status);
        const message: ?[]const u8 = if (result) |outcome| switch (outcome) {
            .started => null,
            .unavailable => "请等当前网页加载完成后再强制刷新。",
            .edited => "网页有未提交的输入，请先保存或提交。",
            .resubmission => "此标签页可能重新提交表单。可在新标签页打开网页地址。",
        } else "请在浏览器菜单授予开发者工具权限。";
        return client.reply(id,.{ .message=message,.toast=true });
    }
    const toggle = std.mem.eql(u8,action,"inspector");
    const reply = if (toggle) try client.call(.@"devtools.toggle",.{}) else open: {
        const placement: sdk.InspectorPlacement = if (std.mem.eql(u8,action,"window")) .window
            else if (std.mem.eql(u8,action,"dock")) .docked else .preferred;
        const panel = if (placement!=.preferred) .inspector else std.meta.stringToEnum(sdk.InspectorPanel,action) orelse return error.InvalidCommand;
        break :open try client.call(.@"devtools.open",.{ .panel=panel, .placement=placement });
    };
    const value = reply.get("result");
    try client.reply(id,sdk.CommandResult{ .message = if (value) |opened|
        if (opened == .bool and (toggle or opened.bool)) null else "请选择一个已加载的网页标签。"
    else "请在浏览器菜单授予开发者工具权限。" });
}
