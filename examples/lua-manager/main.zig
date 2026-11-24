const std = @import("std");
const sdk = @import("moon_plugin");

extern "c" fn moon_manager_window(owner: u64, dark: bool) bool;
extern "c" fn moon_manager_status(text: [*:0]const u8) void;

var client: sdk.Client = undefined;
var scripts: [16]sdk.Script = undefined;
var count: usize = 0;
var selected: ?usize = null;
var refresh_on_save = true;

fn response(method: sdk.Method, params: anytype) ?std.json.Value {
    const reply = client.call(method,params) catch {
        moon_manager_status("与浏览器的连接已关闭。");
        return null;
    };
    if (reply.get("result")) |value| return value;
    const failure = reply.get("error") orelse return null;
    const data = if (failure == .object) failure.object.get("data") else null;
    const reason = if (data != null and data.? == .object) sdk.string(data.?.object.get("reason")) orelse "" else "";
    if (std.mem.eql(u8,reason,"INVALID_SCRIPT")) moon_manager_status("脚本语法或元数据有误。原脚本仍可用。")
    else if (std.mem.eql(u8,reason,"CANCELLED")) moon_manager_status("已取消。")
    else if (std.mem.eql(u8,reason,"ALREADY_EXISTS")) moon_manager_status("同一份脚本已安装。")
    else if (std.mem.eql(u8,reason,"PERMISSION_DENIED")) moon_manager_status("请在浏览器菜单为管理器授予 Lua 脚本管理权限。")
    else if (std.mem.eql(u8,reason,"NOT_FOUND")) moon_manager_status("此脚本已在其他入口修改或移除。请重新打开管理器。")
    else moon_manager_status("浏览器无法完成这项操作。");
    return null;
}

fn record(value: std.json.Value) ?sdk.Script {
    return std.json.parseFromValueLeaky(sdk.Script,client.allocator,value,.{}) catch null;
}

export fn moon_manager_count() usize { return count; }
export fn moon_manager_name(index: usize) [*:0]const u8 {
    if (index >= count) return "";
    const script = scripts[index];
    return (std.fmt.allocPrintSentinel(client.allocator,"{s}  ·  {s}",.{
        script.name,if (script.enabled) "已启用" else "已停用",
    },0) catch return "").ptr;
}
export fn moon_manager_enabled() bool {
    return if (selected) |index| scripts[index].enabled else false;
}
export fn moon_manager_read(index: usize, output: [*]u8, cap: usize) bool {
    if (index >= count) return false;
    const value = response(.@"lua.scripts.getSource",sdk.ScriptId{ .id=scripts[index].id }) orelse return false;
    const source = std.json.parseFromValueLeaky(sdk.ScriptSource,client.allocator,value,.{}) catch return false;
    const decoder = std.base64.standard.Decoder;
    const bytes = decoder.calcSizeForSlice(source.sourceBase64) catch return false;
    if (bytes >= cap) return false;
    decoder.decode(output[0..bytes],source.sourceBase64) catch return false;
    output[bytes] = 0;
    selected = index;
    return true;
}

fn encode(source: []const u8) ?[]const u8 {
    if (source.len > sdk.lua_source_limit + 3) {
        moon_manager_status("Lua 脚本最多 16 KiB。");
        return null;
    }
    const encoder = std.base64.standard.Encoder;
    const output = client.allocator.alloc(u8,encoder.calcSize(source.len)) catch return null;
    return encoder.encode(output,source);
}

export fn moon_manager_import(source: [*]const u8, size: usize) bool {
    if (count == scripts.len) {
        moon_manager_status("已达到脚本数量上限。");
        return false;
    }
    const payload = encode(source[0..size]) orelse return false;
    const value = response(.@"lua.scripts.install",sdk.ScriptSource{ .sourceBase64=payload }) orelse return false;
    scripts[count] = record(value) orelse return false;
    count += 1;
    moon_manager_status("已导入。启用前需要确认网站范围。");
    return true;
}

export fn moon_manager_save(source: [*]const u8, size: usize) bool {
    const index = selected orelse return false;
    const payload = encode(source[0..size]) orelse return false;
    const was_enabled = scripts[index].enabled;
    const value = response(.@"lua.scripts.update",sdk.ScriptUpdate{ .id=scripts[index].id,.sourceBase64=payload }) orelse return false;
    scripts[index] = record(value) orelse return false;
    if (was_enabled and !scripts[index].enabled) {
        moon_manager_status("源码已保存。网站范围已变化，启用时需重新授权。");
        return true;
    }
    if (!refresh_on_save) {
        moon_manager_status("源码已保存。下次加载匹配页面时使用新源码。");
        return true;
    }
    const outcome = response(.@"lua.scripts.reloadActive",sdk.ScriptId{ .id=scripts[index].id }) orelse {
        moon_manager_status("源码已保存。请手动刷新网页。");
        return true;
    };
    const state = std.json.parseFromValueLeaky(sdk.ReloadResult,client.allocator,outcome,.{}) catch return true;
    moon_manager_status(switch (state) {
        .reloaded => "已保存，正在重载当前匹配页面。",
        .protectedPage => "已保存。当前页面正在使用或有输入，请在方便时刷新。",
        .noMatchingPage => "已保存。启用脚本后，下次加载匹配页面时生效。",
    });
    return true;
}

export fn moon_manager_toggle() bool {
    const index = selected orelse return false;
    const enabled = !scripts[index].enabled;
    _ = response(.@"lua.scripts.setEnabled",sdk.ScriptSwitch{ .id=scripts[index].id,.enabled=enabled }) orelse return false;
    scripts[index].enabled = enabled;
    moon_manager_status(if (enabled) "脚本已启用。刷新匹配页面即可运行。" else "脚本已停用。刷新页面可恢复原站内容。");
    return true;
}

export fn moon_manager_remove(index: usize) bool {
    if (index>=count) return false;
    const query: sdk.ScriptRemoval = .{ .id=scripts[index].id,.confirm=true };
    _ = response(.@"lua.scripts.remove",query) orelse return false;
    std.mem.copyForwards(sdk.Script,scripts[index..count-1],scripts[index+1..count]);
    count -= 1;
    selected = null;
    moon_manager_status("脚本已移除。刷新原网页可恢复站点内容。");
    return true;
}

export fn moon_manager_error() void {
    const index = selected orelse return;
    const value = response(.@"lua.scripts.lastError",sdk.ScriptId{ .id=scripts[index].id }) orelse return;
    const message = sdk.string(value) orelse {
        moon_manager_status("当前没有记录到运行错误。");
        return;
    };
    moon_manager_status((client.allocator.dupeSentinel(u8,message,0) catch return).ptr);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    client = .{ .allocator=arena.allocator() };
    const init = try client.initialize();
    client.request_budget = init.requestLimit;
    const command = try client.receive();
    const id = sdk.string(command.get("id")) orelse return error.InvalidCommand;
    if (!std.mem.eql(u8,sdk.string(command.get("method")) orelse "", "commands.run")) return error.InvalidCommand;
    const list = response(.@"lua.scripts.list",.{}) orelse {
        try client.reply(id,sdk.CommandResult{ .message="请先启用管理器并授予 Lua 用户脚本管理权限。" });
        return;
    };
    const values = try std.json.parseFromValueLeaky([]sdk.Script,client.allocator,list,.{});
    if (values.len > scripts.len) return error.InvalidList;
    count = values.len;
    @memcpy(scripts[0..count],values);
    if (response(.@"settings.read",.{})) |value| {
        if (value == .object) {
            if (value.object.get("refreshOnSave")) |pref| {
                if (pref == .bool) refresh_on_save = pref.bool;
            }
        }
    }
    if (!moon_manager_window(init.browserWindow,init.darkMode)) return error.CouldNotOpenEditor;
    try client.reply(id,sdk.CommandResult{});
}
