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
    const message: ?[]const u8 = if (std.mem.eql(u8,action,"save")) save: {
        const response = try client.call(.@"page.saveHtml",.{});
        const outcome = std.meta.stringToEnum(sdk.PageSaveStart,sdk.string(response.get("result")) orelse "") orelse .unavailable;
        break :save switch (outcome) {
            .started, .cancelled => null,
            .unavailable => "请在已加载的网页上操作，并检查插件的保存权限。",
            .unsupported => "当前内容无法保存为 HTML 文档。",
            .invalidFilename => "请选择扩展名为 .html 或 .htm 的文件。",
            .busy => "另一项网页保存正在进行。",
            .failed => "无法启动网页保存。",
        };
    } else if (std.mem.eql(u8,action,"open")) open: {
        const response = try client.call(.@"pageSource.open",.{});
        const result = response.get("result") orelse std.json.Value.null;
        break :open if (result==.bool and result.bool) null else "请在已加载的网页上执行此命令，并检查插件权限。";
    } else return error.InvalidCommand;
    try client.reply(id,sdk.CommandResult{ .message=message,.toast=true });
}
