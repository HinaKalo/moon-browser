const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");
const updater = @import("updater.zig");
const userscripts = @import("userscripts.zig");
const settings = @import("extension_settings.zig");
const history = @import("history.zig");
const network = @import("network_policy.zig");
const bookmarks = @import("bookmarks.zig");
const downloads = @import("downloads.zig");
const site_data = @import("site_data.zig");
const recent_tabs = @import("recent_tabs.zig");
const privacy = @import("privacy.zig");

pub const Permissions = std.EnumSet(sdk.Permission);
pub const Snapshot = struct { id: u64, title: [512:0]u8, url: [4096:0]u8, bookmarkable: bool = false };
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
        .@"network.filter.status", .@"network.filter.setSite" => .@"network.filter",
        .@"bookmarks.list", .@"bookmarks.save", .@"bookmarks.saveActive", .@"bookmarks.update", .@"bookmarks.remove" => .@"bookmarks.manage",
        .@"downloads.list", .@"downloads.cancel", .@"downloads.remove", .@"downloads.reveal" => .@"downloads.manage",
        .@"siteData.open", .@"siteData.status", .@"siteData.list", .@"siteData.value",
        .@"siteData.refresh", .@"siteData.openInspector" => .@"siteData.read",
        .@"reading.find", .@"reading.zoom" => .@"page.reading",
        .@"tabs.closed.list", .@"tabs.closed.reopen", .@"tabs.closed.clear" => .@"tabs.closed.manage",
        .@"tabs.togglePinned", .@"tabs.toggleMuted" => .@"tabs.organize",
        .@"privacy.clear", .@"privacy.status" => .@"privacy.clear",
        .@"taskManager.snapshot", .@"taskManager.focus", .@"taskManager.discard" => .@"taskManager.manage",
        .@"ui.menu.add", .@"ui.menu.remove", .@"ui.shortcuts.register", .@"ui.shortcuts.unregister" => .@"ui.commands",
    };
}

fn libraryReason(err: anyerror) sdk.Reason {
    return switch (err) {
        error.InvalidParams => .InvalidParams,
        error.AlreadyExists => .AlreadyExists,
        error.NotFound => .NotFound,
        else => .InternalError,
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

fn taskSnapshot(allocator: std.mem.Allocator, id: []const u8, query: sdk.TaskQuery) ![]u8 {
    const page_size = 24;
    var info: native.MoonTaskOverview = undefined;
    native.moon_tasks_overview(&info);
    var result: sdk.TaskSnapshot = .{
        .overview = .{
            .privateBytes=info.private_bytes,.peakBytes=info.peak_bytes,.highBytes=info.high_bytes,
            .targetBytes=info.target_bytes,.pressure=info.pressure,.warmLimit=info.warm_limit,.idleSeconds=info.idle_seconds,
            .open=info.open,.live=info.live,.dormant=info.dormant,.protected=info.protected_tabs,
            .processes=info.processes,.evictions=info.evictions,.retiring=info.retiring,
            .beforeBytes=if (info.has_sweep) info.before_bytes else null,
            .afterBytes=if (info.has_sweep and !info.sweep_pending) info.after_bytes else null,
        },
        .next = null,
    };
    switch (query.view) {
        .tabs => {
            var rows: [page_size]native.MoonTaskTab = undefined;
            const len = native.moon_tasks_tabs(query.offset,&rows,rows.len);
            var ids: [page_size][24]u8 = undefined;
            var items: [page_size]sdk.TaskTab = undefined;
            for (rows[0..len],items[0..len],ids[0..len]) |*row,*item,*tab_id| {
                item.* = .{
                    .id=tabId(row.id,tab_id),.title=std.mem.sliceTo(&row.title,0),.phase=@enumFromInt(row.phase),
                    .pid=if (row.pid!=0) row.pid else null,.protection=std.enums.fromInt(sdk.TaskProtection,row.protection),
                };
            }
            result.tabs = items[0..len];
            result.next = if (info.open -| query.offset > len) query.offset+@as(u32,@intCast(len)) else null;
            return sdk.result(allocator,id,result);
        },
        .processes => {
            var rows: [page_size]native.MoonTaskProcess = undefined;
            const len = native.moon_tasks_processes(query.offset,&rows,rows.len);
            var items: [page_size]sdk.TaskProcess = undefined;
            for (rows[0..len],items[0..len]) |row,*item|
                item.* = .{ .pid=row.pid,.privateBytes=row.private_bytes,.tabs=row.tabs,.browser=row.browser };
            result.processes = items[0..len];
            result.next = if (info.processes -| query.offset > len) query.offset+@as(u32,@intCast(len)) else null;
            return sdk.result(allocator,id,result);
        },
    }
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
        .@"history.list", .@"history.remove", .@"history.clear", .@"network.filter.status", .@"network.filter.setSite" => {},
        .@"bookmarks.list", .@"bookmarks.save", .@"bookmarks.update", .@"bookmarks.remove",
        .@"downloads.list", .@"downloads.cancel", .@"downloads.remove", .@"downloads.reveal" => {},
        .@"siteData.status", .@"siteData.list", .@"siteData.value", .@"siteData.refresh", .@"siteData.openInspector" => {},
        .@"tabs.closed.list", .@"tabs.closed.reopen", .@"tabs.closed.clear" => {},
        .@"privacy.clear", .@"privacy.status" => {},
        .@"taskManager.snapshot", .@"taskManager.focus", .@"taskManager.discard" => {},
        .@"ui.menu.add", .@"ui.menu.remove", .@"ui.shortcuts.register", .@"ui.shortcuts.unregister" => {},
        else => return sdk.failure(output,id,.MethodNotFound),
    };
    if (!context.consent.valid(context.consent.context)) return sdk.failure(output, id, .Cancelled);
    if (permissionFor(method)) |permission| {
        if (!context.grants.contains(permission)) return sdk.failure(output, id, .PermissionDenied);
    }
    const params = object.get("params");
    switch (method) {
        .@"host.getInfo", .@"tabs.getActive", .@"lua.scripts.list", .@"settings.read", .@"ui.openPage", .@"history.clear",
        .@"network.filter.status", .@"bookmarks.saveActive", .@"siteData.open",
        .@"siteData.status", .@"siteData.refresh", .@"siteData.openInspector", .@"reading.find",
        .@"tabs.closed.list", .@"tabs.closed.clear", .@"privacy.status", .@"tabs.togglePinned", .@"tabs.toggleMuted" => {
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
        .@"network.filter.status" => check: {
            const status = network.status(allocator,context.plugin_id) catch return sdk.failure(output,id,.InternalError);
            break :check sdk.result(output,id,status);
        },
        .@"network.filter.setSite" => site: {
            const value = decode(sdk.NetworkFilterSite,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            network.setSite(allocator,context.plugin_id,value) catch |err| {
                return sdk.failure(output,id,switch (err) {
                    error.InvalidHost => .InvalidParams,
                    error.NotSelected => .PermissionDenied,
                    error.LimitExceeded,error.TooLarge => .LimitExceeded,
                    else => .InternalError,
                });
            };
            break :site sdk.result(output,id,null);
        },
        .@"bookmarks.list" => list: {
            const options = decode(sdk.HistoryQuery,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            var rows: [24]sdk.Bookmark = undefined;
            const page = bookmarks.list(allocator,options,&rows) catch |err| return sdk.failure(output,id,libraryReason(err));
            break :list sdk.result(output,id,page);
        },
        .@"bookmarks.saveActive" => save: {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const tab = context.tab orelse break :save sdk.result(output,id,sdk.BookmarkSave.noPage);
            const url = std.mem.sliceTo(&tab.url,0);
            if (!tab.bookmarkable or !history.validURL(url)) break :save sdk.result(output,id,sdk.BookmarkSave.noPage);
            const outcome = bookmarks.save(.{ .title=std.mem.sliceTo(&tab.title,0),.url=url }) catch |err|
                return sdk.failure(output,id,libraryReason(err));
            break :save sdk.result(output,id,outcome);
        },
        .@"bookmarks.save" => save: {
            const value = decode(sdk.BookmarkInput,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            const outcome = bookmarks.save(value) catch |err| return sdk.failure(output,id,libraryReason(err));
            break :save sdk.result(output,id,outcome);
        },
        .@"bookmarks.update" => update: {
            const value = decode(sdk.BookmarkEdit,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            bookmarks.update(value) catch |err| return sdk.failure(output,id,libraryReason(err));
            break :update sdk.result(output,id,null);
        },
        .@"bookmarks.remove" => remove: {
            const value = decode(struct { id: u32 },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            bookmarks.remove(value.id) catch |err| return sdk.failure(output,id,libraryReason(err));
            break :remove sdk.result(output,id,null);
        },
        .@"downloads.list" => list: {
            const options = decode(sdk.HistoryQuery,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            var rows: [24]sdk.Download = undefined;
            const page = downloads.list(allocator,options,&rows) catch |err| return sdk.failure(output,id,libraryReason(err));
            break :list sdk.result(output,id,page);
        },
        .@"downloads.cancel", .@"downloads.remove", .@"downloads.reveal" => change: {
            const value = decode(struct { id: u32 },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            const action = switch (method) {
                .@"downloads.cancel" => downloads.cancel(value.id),
                .@"downloads.remove" => downloads.remove(value.id),
                .@"downloads.reveal" => downloads.reveal(allocator,value.id),
                else => unreachable,
            };
            action catch |err| return sdk.failure(output,id,libraryReason(err));
            break :change sdk.result(output,id,null);
        },
        .@"siteData.open" => open: {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const tab = context.tab orelse break :open sdk.result(output,id,false);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            break :open sdk.result(output,id,native.moon_site_data_open(owner.ptr,tab.id,&tab.url));
        },
        .@"siteData.status" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            return sdk.result(output,id,site_data.status(context.target_tab_id,context.plugin_id));
        },
        .@"siteData.list" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const options = decode(struct { group: sdk.SiteDataGroup },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            var entries: [32]sdk.SiteDataEntry = undefined;
            const result = site_data.list(context.target_tab_id,context.plugin_id,options.group,&entries) orelse
                return sdk.failure(output,id,.NotFound);
            return sdk.result(output,id,result);
        },
        .@"siteData.value" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const options = decode(sdk.SiteDataItem,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            const result = site_data.value(context.target_tab_id,context.plugin_id,options) orelse return sdk.failure(output,id,.NotFound);
            return sdk.result(output,id,result);
        },
        .@"siteData.refresh", .@"siteData.openInspector" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            return sdk.result(output,id,native.moon_site_data_action(context.target_tab_id,owner.ptr,method == .@"siteData.openInspector"));
        },
        .@"reading.find" => {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            return sdk.result(output,id,native.moon_reading_find(context.target_tab_id,owner.ptr));
        },
        .@"reading.zoom" => {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const value = decode(struct { action: sdk.ZoomAction },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            const percent = native.moon_reading_zoom(context.target_tab_id,@intFromEnum(value.action));
            const result: ?c_uint = if (percent == 0) null else percent;
            return sdk.result(output,id,result);
        },
        .@"tabs.togglePinned", .@"tabs.toggleMuted" => {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const outcome = native.moon_tabs_organize(context.target_tab_id,method==.@"tabs.toggleMuted");
            return sdk.result(output,id,@as(sdk.TabOrganization,@enumFromInt(outcome)));
        },
        .@"tabs.closed.list" => {
            var items: [recent_tabs.limit]sdk.ClosedTab = undefined;
            return sdk.result(output,id,recent_tabs.list(&items));
        },
        .@"tabs.closed.reopen" => {
            if (!context.user_command and !context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const options = decode(struct { id: ?u32 = null },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            const reopened = native.moon_recent_reopen(context.target_tab_id,options.id!=null,options.id orelse 0);
            return sdk.result(output,id,@as(sdk.ReopenClosedTab,@enumFromInt(reopened)));
        },
        .@"tabs.closed.clear" => {
            if (!context.user_command and !context.from_page) return sdk.failure(output,id,.PermissionDenied);
            recent_tabs.clear();
            return sdk.result(output,id,null);
        },
        .@"privacy.clear" => {
            if (!context.user_command and !context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const selection = decode(sdk.PrivacySelection,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            if (!selection.history and !selection.siteData and !selection.cache) return sdk.failure(output,id,.InvalidParams);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            return sdk.result(output,id,privacy.start(selection,context.target_tab_id,owner,context.consent));
        },
        .@"privacy.status" => sdk.result(output,id,privacy.status(context.plugin_id)),
        .@"taskManager.snapshot" => {
            const query = decode(sdk.TaskQuery,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            return taskSnapshot(output,id,query);
        },
        .@"taskManager.focus", .@"taskManager.discard" => {
            if (!context.user_command and !context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const options = decode(struct { id: []const u8 },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            if (!std.mem.startsWith(u8,options.id,"t-")) return sdk.failure(output,id,.InvalidParams);
            const target = std.fmt.parseInt(u64,options.id[2..],10) catch return sdk.failure(output,id,.InvalidParams);
            const result = native.moon_tasks_action(context.target_tab_id,target,method==.@"taskManager.discard");
            return sdk.result(output,id,@as(sdk.TaskAction,@enumFromInt(result)));
        },
        .@"ui.menu.add", .@"ui.menu.remove", .@"ui.shortcuts.register", .@"ui.shortcuts.unregister" => {
            if (!context.user_command and !context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            const result = if (method==.@"ui.shortcuts.register") entry: {
                const value = decode(sdk.RegisteredShortcut,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
                if (value.shortcut.len==0 or std.mem.indexOfScalar(u8,value.shortcut,0)!=null)
                    return sdk.failure(output,id,.InvalidParams);
                const command = commandName(allocator,value.id) catch return sdk.failure(output,id,.InvalidParams);
                const shortcut = try allocator.dupeSentinel(u8,value.shortcut,0);
                break :entry native.moon_plugin_ui_shortcut(owner.ptr,command.ptr,shortcut.ptr,value.scope==.global,
                    context.consent.context,context.consent.valid);
            } else entry: {
                const value = decode(struct { id: []const u8 },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
                const command = commandName(allocator,value.id) catch return sdk.failure(output,id,.InvalidParams);
                if (method==.@"ui.shortcuts.unregister")
                    break :entry native.moon_plugin_ui_shortcut(owner.ptr,command.ptr,null,false,context.consent.context,context.consent.valid);
                break :entry native.moon_plugin_ui_menu(owner.ptr,command.ptr,method==.@"ui.menu.add");
            };
            return sdk.result(output,id,@as(sdk.UiRegistration,@enumFromInt(result)));
        },
    };
}

fn commandName(allocator: std.mem.Allocator, value: []const u8) ![:0]u8 {
    if (value.len==0 or value.len>=64 or std.mem.indexOfScalar(u8,value,0)!=null) return error.InvalidParams;
    return allocator.dupeSentinel(u8,value,0);
}

fn validScriptId(id: []const u8) bool {
    if (id.len != 64) return false;
    for (id) |ch| if (!std.ascii.isDigit(ch) and (ch < 'a' or ch > 'f')) return false;
    return true;
}
