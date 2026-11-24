const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");
const updater = @import("updater.zig");
const userscripts = @import("userscripts.zig");

pub const Permissions = std.EnumSet(sdk.Permission);
pub const Snapshot = struct { id: u64, title: [512:0]u8, url: [4096:0]u8 };
pub const Context = struct {
    grants: Permissions,
    tab: ?*const Snapshot,
    consent: userscripts.Consent,
};

pub fn permissionFor(method: sdk.Method) ?sdk.Permission {
    return switch (method) {
        .@"host.getInfo" => null,
        .@"tabs.getActive" => .@"tabs.read",
        .@"lua.scripts.list", .@"lua.scripts.install", .@"lua.scripts.setEnabled", .@"lua.scripts.remove" => .@"lua.scripts.manage",
    };
}

fn serviceFailure(allocator: std.mem.Allocator, id: []const u8, err: userscripts.ServiceError) ![]u8 {
    const reason: sdk.Reason = switch (err) {
        error.InvalidScript => .InvalidScript,
        error.AlreadyExists => .AlreadyExists,
        error.LimitExceeded => .LimitExceeded,
        error.NotFound => .NotFound,
        error.Cancelled => .Cancelled,
        error.InternalError => .InternalError,
    };
    return sdk.failure(allocator, id, reason);
}

fn decode(comptime T: type, allocator: std.mem.Allocator, value: ?std.json.Value) !T {
    const item = value orelse return error.InvalidParams;
    if (item != .object) return error.InvalidParams;
    return std.json.parseFromValueLeaky(T, allocator, item, .{});
}

fn noParams(value: ?std.json.Value) bool {
    const item = value orelse return true;
    return item == .object and item.object.count() == 0;
}

pub fn tabId(id: u64, buffer: *[24]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "t-{d}", .{id}) catch unreachable;
}

pub fn dispatch(output: std.mem.Allocator, bytes: []const u8, context: Context) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(output);
    defer arena.deinit();
    const allocator = arena.allocator();
    const incoming = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{}) catch
        return sdk.failure(output, null, .ParseError);
    const object = sdk.envelope(incoming) orelse return sdk.failure(output, null, .InvalidRequest);
    const id = sdk.string(object.get("id")) orelse return sdk.failure(output, null, .InvalidRequest);
    const method_name = sdk.string(object.get("method")) orelse return sdk.failure(output, id, .InvalidRequest);
    if (object.contains("result") or object.contains("error")) return sdk.failure(output, id, .InvalidRequest);
    const method = std.meta.stringToEnum(sdk.Method, method_name) orelse return sdk.failure(output, id, .MethodNotFound);
    if (!context.consent.valid(context.consent.context)) return sdk.failure(output, id, .Cancelled);
    if (permissionFor(method)) |permission| {
        if (!context.grants.contains(permission)) return sdk.failure(output, id, .PermissionDenied);
    }
    const params = object.get("params");
    switch (method) {
        .@"host.getInfo", .@"tabs.getActive", .@"lua.scripts.list" => {
            if (!noParams(params)) return sdk.failure(output, id, .InvalidParams);
        },
        else => {},
    }
    return switch (method) {
        .@"host.getInfo" => sdk.result(output, id, sdk.HostInfo{
            .apiVersion = sdk.api_version,
            .browserVersion = updater.versionName(),
            .luaVersion = std.mem.span(native.moon_lua_version()),
        }),
        .@"tabs.getActive" => if (context.tab) |tab| tab: {
            var buffer: [24]u8 = undefined;
            break :tab sdk.result(output, id, sdk.Tab{
                .id = tabId(tab.id, &buffer),
                .title = std.mem.sliceTo(&tab.title, 0),
                .url = std.mem.sliceTo(&tab.url, 0),
            });
        } else sdk.result(output, id, null),
        .@"lua.scripts.list" => list: {
            var items: [userscripts.max_scripts]sdk.Script = undefined;
            break :list sdk.result(output, id, userscripts.list(&items));
        },
        .@"lua.scripts.install" => install: {
            const value = decode(sdk.ScriptSource, allocator, params) catch return sdk.failure(output, id, .InvalidParams);
            const decoder = std.base64.standard.Decoder;
            const count = decoder.calcSizeForSlice(value.sourceBase64) catch return sdk.failure(output, id, .InvalidParams);
            if (count > sdk.lua_source_limit + 3) return sdk.failure(output, id, .LimitExceeded);
            const source = try allocator.alloc(u8, count);
            decoder.decode(source, value.sourceBase64) catch return sdk.failure(output, id, .InvalidParams);
            const script = userscripts.register(source, false) catch |err| return serviceFailure(output, id, err);
            break :install sdk.result(output, id, script);
        },
        .@"lua.scripts.setEnabled" => enabled: {
            const value = decode(sdk.ScriptSwitch, allocator, params) catch return sdk.failure(output, id, .InvalidParams);
            if (!validScriptId(value.id)) return sdk.failure(output, id, .InvalidParams);
            userscripts.setEnabled(value.id, value.enabled, context.consent) catch |err| return serviceFailure(output, id, err);
            break :enabled sdk.result(output, id, null);
        },
        .@"lua.scripts.remove" => remove: {
            const value = decode(sdk.ScriptId, allocator, params) catch return sdk.failure(output, id, .InvalidParams);
            if (!validScriptId(value.id)) return sdk.failure(output, id, .InvalidParams);
            userscripts.unregister(value.id) catch |err| return serviceFailure(output, id, err);
            break :remove sdk.result(output, id, null);
        },
    };
}

fn validScriptId(id: []const u8) bool {
    if (id.len != 64) return false;
    for (id) |ch| if (!std.ascii.isDigit(ch) and (ch < 'a' or ch > 'f')) return false;
    return true;
}
