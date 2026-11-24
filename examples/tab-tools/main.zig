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
    const Action = enum { pin, mute, duplicate, copyAddress, closeOthers, closeBelow, openLink, copyLink };
    const operation = std.meta.stringToEnum(Action,action) orelse return error.InvalidCommand;
    const message = switch (operation) {
        .pin => try organize(&client,.@"tabs.togglePinned"),
        .mute => try organize(&client,.@"tabs.toggleMuted"),
        .duplicate => try organize(&client,.@"tabs.duplicate"),
        .copyAddress => try organize(&client,.@"tabs.copyAddress"),
        .closeOthers => try close(&client,.others),
        .closeBelow => try close(&client,.below),
        .openLink => try link(&client,.@"tabs.openLink"),
        .copyLink => try link(&client,.@"tabs.copyLink"),
    };
    try client.reply(id, sdk.CommandResult{ .message = message, .toast = true });
}

fn link(client: *sdk.Client, method: sdk.Method) !?[]const u8 {
    const response = try client.call(method,.{});
    const outcome = std.meta.stringToEnum(sdk.LinkResult,sdk.string(response.get("result")) orelse "") orelse .unavailable;
    return switch (outcome) {
        .opened => null,
        .copied => "链接已复制。",
        .clipboardBusy => "剪贴板暂不可用，请重试。",
        .limitReached => "标签页已满。关闭一页后可继续。",
        else => "链接操作不可用。请在当前网页重新打开右键菜单。",
    };
}

fn organize(client: *sdk.Client, method: sdk.Method) !?[]const u8 {
    const response = try client.call(method, .{});
    const outcome = std.meta.stringToEnum(sdk.TabOrganization, sdk.string(response.get("result")) orelse "") orelse .unavailable;
    return switch (outcome) {
        .pinned, .unpinned, .muted, .unmuted, .duplicated => null,
        .copied => "网址已复制。",
        .clipboardBusy => "剪贴板暂不可用，请重试。",
        .unavailable => "请在可恢复的网页上执行此命令，并检查插件权限。",
        .limitReached => if (method==.@"tabs.duplicate") "标签页已满。关闭一页后可继续。"
            else "已达到固定标签上限。取消固定一个标签后可继续。",
        .saveFailed => "无法保存固定标签。请检查浏览器配置目录。",
    };
}

fn close(client: *sdk.Client, scope: sdk.TabCloseScope) !?[]const u8 {
    const response = try client.call(.@"tabs.closeGroup",.{ .scope=scope });
    const result = response.get("result") orelse return "当前标签已关闭，或插件权限不可用。";
    if (result==.null) return "当前标签已关闭。";
    const counts = try std.json.parseFromValueLeaky(sdk.TabCloseResult,client.allocator,result,.{});
    if (counts.kept==0) {
        if (counts.closed==0) return "没有可关闭的标签。";
        return try std.fmt.allocPrint(client.allocator,"已关闭 {d} 个标签。",.{counts.closed});
    }
    return try std.fmt.allocPrint(client.allocator,"已关闭 {d} 个，保留 {d} 个固定或受保护的标签。",.{counts.closed,counts.kept});
}
