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
    if (std.mem.eql(u8,action,"bar")) {
        const response=try client.call(.@"bookmarks.bar.toggle",.{});
        const outcome=std.meta.stringToEnum(sdk.BookmarksBarChange,sdk.string(response.get("result")) orelse "") orelse .unavailable;
        try client.reply(id,sdk.CommandResult{
            .message=if (outcome==.unavailable) "无法更新书签栏，请检查插件权限和配置目录。" else null,
            .toast=true,
        });
        return;
    }
    if (std.mem.eql(u8,action,"open")) {
        const response = try client.call(.@"ui.openPage",.{});
        const value = response.get("result") orelse std.json.Value.null;
        try client.reply(id,sdk.CommandResult{ .message=if (value == .bool and value.bool) null else "无法打开书签页。" });
        return;
    }
    const exporting = std.mem.eql(u8,action,"export");
    if (exporting or std.mem.eql(u8,action,"import")) {
        const response = try client.call(if (exporting) .@"bookmarks.exportHtml" else .@"bookmarks.importHtml",.{});
        const message: ?[]const u8 = transferMessage(client.allocator,response.get("result"),exporting);
        try client.reply(id,sdk.CommandResult{ .message=message,.toast=true });
        return;
    }
    const link = std.mem.eql(u8,action,"saveLink");
    if (!link and !std.mem.eql(u8,action,"save")) return error.InvalidCommand;
    const response = try client.call(if (link) .@"bookmarks.saveLink" else .@"bookmarks.saveActive",.{});
    const value = sdk.string(response.get("result")) orelse "";
    const message: []const u8 = if (std.mem.eql(u8,value,"saved")) (if (link) "已将链接加入书签。" else "已将当前网页加入书签。")
        else if (std.mem.eql(u8,value,"alreadySaved")) (if (link) "这个链接已在书签中。" else "这页已在书签中。")
        else if (std.mem.eql(u8,value,"noPage")) "请切换到已打开的网页。"
        else "无法保存书签。请检查插件权限。";
    try client.reply(id,sdk.CommandResult{ .message=message,.toast=true });
}

fn transferMessage(allocator: std.mem.Allocator, value: ?std.json.Value, exporting: bool) ?[]const u8 {
    const failure = "无法完成书签迁移，请检查插件权限和文件位置。";
    const result = std.json.parseFromValueLeaky(sdk.BookmarkTransfer,allocator,value orelse return failure,.{}) catch return failure;
    return switch (result.state) {
        .done => if (exporting)
            std.fmt.allocPrint(allocator,"已导出 {d} 个书签。",.{result.count}) catch failure
        else
            std.fmt.allocPrint(allocator,"已导入 {d} 个，跳过 {d} 个。",.{result.count,result.skipped}) catch failure,
        .cancelled => null,
        .invalidFile => "请选择有效的 UTF-8 HTML 书签文件，最大 8 MiB。",
        .limitExceeded => "书签数量、文件大小或文件夹深度超出支持范围。",
        .unavailable => failure,
    };
}
