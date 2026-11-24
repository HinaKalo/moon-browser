const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");
const updater = @import("updater.zig");
const userscripts = @import("userscripts.zig");
const settings = @import("extension_settings.zig");
const history = @import("history.zig");

pub const Permissions = std.EnumSet(sdk.Permission);
pub const Snapshot = struct { id: u64, title: [512:0]u8, url: [4096:0]u8 };
pub const Context = struct {
    grants: Permissions,
    plugin_id: []const u8,
    target_tab_id: u64,
    tab: ?*const Snapshot,
    consent: userscripts.Consent,
    from_page: bool = false,
    user_command: bool = false,
};

pub fn permissionFor(method: sdk.Method) ?sdk.Permission {
    return switch (method) {
        .@"host.getInfo", .@"settings.read", .@"settings.write", .@"ui.openPage" => null,
        .@"tabs.getActive" => .@"tabs.read",
        .@"lua.scripts.list", .@"lua.scripts.install", .@"lua.scripts.setEnabled", .@"lua.scripts.remove" => .@"lua.scripts.manage",
        .@"lua.scripts.getSource", .@"lua.scripts.update", .@"lua.scripts.reloadActive" => .@"lua.scripts.manage",
        .@"devtools.open" => .@"page.inspect",
        .@"history.list", .@"history.remove", .@"history.clear" => .@"history.manage",
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

fn decodeSource(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    const decoder = std.base64.standard.Decoder;
    const count = try decoder.calcSizeForSlice(encoded);
    if (count > sdk.lua_source_limit + 3) return error.LimitExceeded;
    const source = try allocator.alloc(u8,count);
    try decoder.decode(source,encoded);
    return source;
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
    if (context.from_page) switch (method) {
        .@"history.list", .@"history.remove", .@"history.clear" => {},
        else => return sdk.failure(output,id,.MethodNotFound),
    };
    if (!context.consent.valid(context.consent.context)) return sdk.failure(output, id, .Cancelled);
    if (permissionFor(method)) |permission| {
        if (!context.grants.contains(permission)) return sdk.failure(output, id, .PermissionDenied);
    }
    const params = object.get("params");
    switch (method) {
        .@"host.getInfo", .@"tabs.getActive", .@"lua.scripts.list", .@"settings.read", .@"ui.openPage", .@"history.clear" => {
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
            const source = decodeSource(allocator,value.sourceBase64) catch |err|
                return sdk.failure(output,id,if (err == error.LimitExceeded) .LimitExceeded else .InvalidParams);
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
        .@"lua.scripts.getSource" => get_source: {
            const value = decode(sdk.ScriptId,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            if (!validScriptId(value.id)) return sdk.failure(output,id,.InvalidParams);
            const source = userscripts.getSource(value.id) catch |err| return serviceFailure(output,id,err);
            const encoder = std.base64.standard.Encoder;
            const buffer = try allocator.alloc(u8,encoder.calcSize(source.len));
            break :get_source sdk.result(output,id,sdk.ScriptSource{ .sourceBase64 = encoder.encode(buffer,source) });
        },
        .@"lua.scripts.update" => update: {
            const value = decode(sdk.ScriptUpdate,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            if (!validScriptId(value.id)) return sdk.failure(output,id,.InvalidParams);
            const source = decodeSource(allocator,value.sourceBase64) catch |err|
                return sdk.failure(output,id,if (err == error.LimitExceeded) .LimitExceeded else .InvalidParams);
            const changed = userscripts.replace(value.id,source) catch |err| return serviceFailure(output,id,err);
            break :update sdk.result(output,id,changed);
        },
        .@"lua.scripts.reloadActive" => reload: {
            const value = decode(sdk.ScriptId,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            if (!validScriptId(value.id)) return sdk.failure(output,id,.InvalidParams);
            _ = userscripts.getSource(value.id) catch |err| return serviceFailure(output,id,err);
            var script: [64:0]u8 = @splat(0);
            @memcpy(script[0..64],value.id);
            const status: sdk.ReloadResult = switch (native.moon_userscript_reload_active(&script)) {
                native.MOON_RELOAD_OK => .reloaded,
                native.MOON_RELOAD_PROTECTED => .protectedPage,
                else => .noMatchingPage,
            };
            break :reload sdk.result(output,id,status);
        },
        .@"settings.read" => read: {
            const value = settings.read(allocator,context.plugin_id) catch return sdk.failure(output,id,.InternalError);
            break :read sdk.result(output,id,value);
        },
        .@"settings.write" => write: {
            const value = decode(struct { value: std.json.Value },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            settings.write(allocator,context.plugin_id,value.value) catch |err|
                return sdk.failure(output,id,if (err == error.InvalidObject) .InvalidParams else if (err == error.TooLarge) .LimitExceeded else .InternalError);
            break :write sdk.result(output,id,null);
        },
        .@"devtools.open" => inspect: {
            const value = decode(struct { panel: sdk.InspectorPanel },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            break :inspect sdk.result(output,id,native.moon_devtools_open(@intCast(@intFromEnum(value.panel)),context.target_tab_id));
        },
        .@"ui.openPage" => open: {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            break :open sdk.result(output,id,native.moon_plugin_open_page(owner.ptr));
        },
        .@"history.list" => list: {
            const options = decode(sdk.HistoryQuery,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            var rows: [30]sdk.HistoryVisit = undefined;
            const page = history.list(allocator,options,&rows) catch |err| return sdk.failure(output,id,if (err == error.InvalidParams) .InvalidParams else .InternalError);
            break :list sdk.result(output,id,page);
        },
        .@"history.remove" => remove: {
            const value = decode(struct { id: u32 },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            history.remove(value.id) catch |err| return sdk.failure(output,id,if (err == error.NotFound) .NotFound else .InternalError);
            break :remove sdk.result(output,id,null);
        },
        .@"history.clear" => clear: {
            history.clear() catch return sdk.failure(output,id,.InternalError);
            break :clear sdk.result(output,id,null);
        },
    };
}

fn validScriptId(id: []const u8) bool {
    if (id.len != 64) return false;
    for (id) |ch| if (!std.ascii.isDigit(ch) and (ch < 'a' or ch > 'f')) return false;
    return true;
}
