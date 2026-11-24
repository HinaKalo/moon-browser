const std = @import("std");
const sdk = @import("moon_plugin");

extern "c" fn exit(c_int) noreturn;
extern "c" fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern "c" fn fputs([*:0]const u8, *anyopaque) c_int;
extern "c" fn fclose(*anyopaque) c_int;

fn same(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn result(response: std.json.ObjectMap) !std.json.Value {
    return response.get("result") orelse error.ExpectedResult;
}

fn expectReason(response: std.json.ObjectMap, reason: sdk.Reason) !void {
    const failure = response.get("error") orelse return error.ExpectedRejection;
    if (failure != .object) return error.ExpectedRejection;
    const code = failure.object.get("code") orelse return error.ExpectedRejection;
    const data = failure.object.get("data") orelse return error.ExpectedRejection;
    if (code != .integer or code.integer != @intFromEnum(reason) or data != .object or
        !same(sdk.string(data.object.get("reason")) orelse "", reason.code())) return error.UnexpectedReason;
}

fn run(allocator: std.mem.Allocator) !void {
    var client: sdk.Client = .{ .allocator = allocator };
    const welcome = try client.initialize();
    if (!same(welcome.pluginId, "moon.api-contract")) return error.IdentityMismatch;
    const invocation = try client.receive();
    const method = sdk.string(invocation.get("method")) orelse return error.MissingInvocation;
    const params = invocation.get("params") orelse return error.MissingInvocation;
    if (params != .object) return error.MissingInvocation;
    if (same(method, "tabs.changed")) {
        if (invocation.contains("id") or sdk.string(params.object.get("tabId")) == null) return error.MalformedNotification;
        _ = try result(try client.call(.@"tabs.getActive", .{}));
        return;
    }
    if (!same(method, "commands.run")) return error.MissingInvocation;
    const invocation_id = sdk.string(invocation.get("id")) orelse return error.MissingInvocation;
    const command = sdk.string(params.object.get("id")) orelse return error.MissingInvocation;
    const info = try result(try client.call(.@"host.getInfo", .{}));
    const host = try std.json.parseFromValueLeaky(sdk.HostInfo, allocator, info, .{});
    if (host.apiVersion != sdk.api_version or !std.mem.startsWith(u8, host.luaVersion, "5.4.") or host.browserVersion.len == 0)
        return error.UnexpectedHost;
    try expectReason(try client.call(.@"host.getInfo", .{ .unexpected = true }), .InvalidParams);
    if (same(command, "deny")) {
        if (welcome.permissions.len != 0) return error.UnexpectedPermission;
        try expectReason(try client.call(.@"tabs.getActive", .{}), .PermissionDenied);
        try expectReason(try client.installScript(""), .PermissionDenied);
        return client.reply(invocation_id, sdk.CommandResult{ .message = "V2 consent denied" });
    }
    if (!same(command, "exercise") or welcome.permissions.len != 2) return error.WrongCommand;
    const tab = try result(try client.call(.@"tabs.getActive", .{}));
    const active = try std.json.parseFromValueLeaky(sdk.Tab, allocator, tab, .{});
    if (!std.mem.startsWith(u8, active.id, "t-") or !same(active.title, "Moon fixture second"))
        return error.UnexpectedTab;
    const source =
        \\-- ==MoonUserScript==
        \\-- @name Contract test
        \\-- @api 1
        \\-- @match https://example.com/
        \\-- ==/MoonUserScript==
        \\moon.dom.hide("aside")
    ;
    try expectReason(try client.installScript("return 0"), .InvalidScript);
    const raw = try result(try client.installScript(source));
    const script = try std.json.parseFromValueLeaky(sdk.Script, allocator, raw, .{});
    if (script.enabled or !same(script.name, "Contract test") or script.id.len != 64) return error.UnsafeDefault;
    try expectReason(try client.installScript(source), .AlreadyExists);
    const listing = try result(try client.call(.@"lua.scripts.list", .{}));
    const entries = try std.json.parseFromValueLeaky([]sdk.Script, allocator, listing, .{});
    for (entries) |entry| {
        if (same(entry.id, script.id) and !entry.enabled) break;
    } else return error.MissingRegisteredScript;
    const enable = sdk.ScriptSwitch{ .id = script.id, .enabled = true };
    try expectReason(try client.call(.@"lua.scripts.setEnabled", enable), .Cancelled);
    _ = try result(try client.call(.@"lua.scripts.setEnabled", enable));
    const changed = try result(try client.call(.@"lua.scripts.list", .{}));
    const enabled_entries = try std.json.parseFromValueLeaky([]sdk.Script, allocator, changed, .{});
    for (enabled_entries) |entry| {
        if (same(entry.id, script.id) and entry.enabled) break;
    } else return error.ApprovalNotApplied;
    _ = try result(try client.call(.@"lua.scripts.setEnabled", sdk.ScriptSwitch{ .id = script.id, .enabled = false }));
    _ = try result(try client.call(.@"lua.scripts.remove", sdk.ScriptId{ .id = script.id }));
    try expectReason(try client.call(.@"lua.scripts.remove", sdk.ScriptId{ .id = script.id }), .NotFound);
    return client.reply(invocation_id, sdk.CommandResult{ .message = "V2 contract passed" });
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    run(arena.allocator()) catch |err| {
        if (fopen("contract-error.txt", "w")) |file| {
            _ = fputs(@errorName(err).ptr, file);
            _ = fclose(file);
        }
        exit(61);
    };
}
