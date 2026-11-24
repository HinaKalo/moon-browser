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
const page_source = @import("page_source.zig");
const popups = @import("popup_policy.zig");
const autoplay = @import("autoplay_policy.zig");
const site_sound = @import("site_sound.zig");
const recent_tabs = @import("recent_tabs.zig");
const privacy = @import("privacy.zig");
const search = @import("search.zig");
const session = @import("session.zig");

pub const Permissions = std.EnumSet(sdk.Permission);
pub const Snapshot = struct { id: u64, title: [512:0]u8, url: [4096:0]u8, bookmarkable: bool = false, navigation: u64 = 0 };
pub const LinkInvocation = struct { context: native.MoonLinkContext, operation: sdk.LinkMenuAction, consumed: bool = false };
pub const TabDropInvocation = struct { context: native.MoonTabDrop, consumed: bool = false };
pub const Context = struct {
    grants: Permissions,
    plugin_id: []const u8,
    target_tab_id: u64,
    target_navigation: u64 = 0,
    tab: ?*const Snapshot,
    consent: userscripts.Consent,
    from_page: bool = false,
    user_command: bool = false,
    link: ?*LinkInvocation = null,
    drop: ?*TabDropInvocation = null,
};

fn applyLink(link: *LinkInvocation) sdk.LinkResult {
    if (link.consumed or !native.moon_link_current(&link.context)) return .unavailable;
    link.consumed = true;
    switch (link.operation) {
        .open => return std.enums.fromInt(sdk.LinkResult,native.moon_link_open(&link.context)) orelse .unavailable,
        .copy => return if (native.moon_shell_copy_text(&link.context.url)) .copied else .clipboardBusy,
        .bookmark => {
            if (native.moon_shell_private()) return .unavailable;
            const url = std.mem.sliceTo(&link.context.url,0);
            const label = std.mem.sliceTo(&link.context.label,0);
            const title = if (std.unicode.utf8ValidateSlice(label) and std.mem.indexOfAny(u8,label,"\r\n\t") == null) label else "";
            const outcome = bookmarks.save(.{ .title=title,.url=url }) catch return .unavailable;
            return switch (outcome) { .saved => .saved, .alreadySaved => .alreadySaved, .noPage => .unavailable };
        },
    }
}

pub fn permissionFor(method: sdk.Method) ?sdk.Permission {
    return switch (method) {
        .@"host.getInfo", .@"settings.read", .@"settings.write", .@"ui.openPage" => null,
        .@"browser.openDefaultApps" => .@"browser.defaultApp",
        .@"tabs.getActive" => .@"tabs.read",
        .@"lua.scripts.list", .@"lua.scripts.install", .@"lua.scripts.setEnabled", .@"lua.scripts.remove" => .@"lua.scripts.manage",
        .@"lua.scripts.getSource", .@"lua.scripts.update", .@"lua.scripts.reloadActive" => .@"lua.scripts.manage",
        .@"devtools.open", .@"devtools.toggle" => .@"page.inspect",
        .@"pageSource.open", .@"pageSource.status", .@"pageSource.read" => .@"page.source",
        .@"page.saveHtml" => .@"page.save",
        .@"popups.open", .@"popups.status", .@"popups.setRule", .@"popups.openBlocked" => .@"popups.manage",
        .@"siteSettings.autoplay.get", .@"siteSettings.autoplay.set" => .@"siteSettings.autoplay",
        .@"siteSettings.sound.get", .@"siteSettings.sound.set", .@"siteSettings.sound.toggle" => .@"siteSettings.sound",
        .@"history.list", .@"history.remove", .@"history.clear" => .@"history.manage",
        .@"network.filter.status", .@"network.filter.setSite" => .@"network.filter",
        .@"bookmarks.list", .@"bookmarks.save", .@"bookmarks.saveActive", .@"bookmarks.saveLink", .@"bookmarks.update", .@"bookmarks.remove",
        .@"bookmarks.bar.toggle" => .@"bookmarks.manage",
        .@"bookmarks.importHtml", .@"bookmarks.exportHtml" => .@"bookmarks.transfer",
        .@"downloads.list", .@"downloads.cancel", .@"downloads.remove", .@"downloads.reveal", .@"downloads.clearCompleted" => .@"downloads.manage",
        .@"siteData.open", .@"siteData.status", .@"siteData.list", .@"siteData.catalog", .@"siteData.value",
        .@"siteData.refresh", .@"siteData.openInspector" => .@"siteData.read",
        .@"siteData.cookieDetails", .@"siteData.cookieValue" => .@"siteData.cookieDetails",
        .@"siteData.update", .@"siteData.create", .@"siteData.clear" => .@"siteData.write",
        .@"reading.find", .@"reading.zoom" => .@"page.reading",
        .@"window.toggleFullscreen" => .@"window.fullscreen",
        .@"tabs.closed.list", .@"tabs.closed.reopen", .@"tabs.closed.clear" => .@"tabs.closed.manage",
        .@"tabs.togglePinned", .@"tabs.toggleMuted", .@"tabs.reorder" => .@"tabs.organize",
        .@"tabs.groups.open", .@"tabs.groups.create", .@"tabs.groups.removeTab", .@"tabs.groups.list",
        .@"tabs.groups.assign", .@"tabs.groups.update", .@"tabs.groups.dissolve" => .@"tabs.groups",
        .@"tabs.duplicate", .@"tabs.copyAddress", .@"tabs.openLink", .@"tabs.copyLink", .@"tabs.closeGroup" => .@"tabs.manage",
        .@"privacy.clear", .@"privacy.status" => .@"privacy.clear",
        .@"privacy.openPrivateWindow" => .@"privacy.privateWindow",
        .@"search.getConfig", .@"search.setConfig" => .@"search.manage",
        .@"tabs.session.status", .@"tabs.session.setPreferences", .@"tabs.session.restore", .@"tabs.session.forget" => .@"tabs.session.manage",
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
        .@"bookmarks.importHtml", .@"bookmarks.exportHtml",
        .@"downloads.list", .@"downloads.cancel", .@"downloads.remove", .@"downloads.reveal", .@"downloads.clearCompleted" => {},
        .@"siteData.status", .@"siteData.list", .@"siteData.catalog", .@"siteData.value", .@"siteData.refresh", .@"siteData.openInspector", .@"siteData.update" => {},
        .@"siteData.create", .@"siteData.clear", .@"siteData.cookieDetails", .@"siteData.cookieValue" => {},
        .@"pageSource.status", .@"pageSource.read" => {},
        .@"popups.status", .@"popups.setRule", .@"popups.openBlocked", .@"siteSettings.autoplay.get", .@"siteSettings.autoplay.set" => {},
        .@"siteSettings.sound.get", .@"siteSettings.sound.set" => {},
        .@"tabs.closed.list", .@"tabs.closed.reopen", .@"tabs.closed.clear" => {},
        .@"tabs.groups.list", .@"tabs.groups.assign", .@"tabs.groups.update", .@"tabs.groups.dissolve" => {},
        .@"privacy.clear", .@"privacy.status" => {},
        .@"search.getConfig", .@"search.setConfig" => {},
        .@"tabs.session.status", .@"tabs.session.setPreferences", .@"tabs.session.restore", .@"tabs.session.forget" => {},
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
        .@"host.getInfo", .@"browser.openDefaultApps", .@"tabs.getActive", .@"lua.scripts.list", .@"settings.read", .@"ui.openPage", .@"history.clear",
        .@"network.filter.status", .@"bookmarks.saveActive", .@"bookmarks.bar.toggle", .@"bookmarks.importHtml", .@"bookmarks.exportHtml", .@"siteData.open",
        .@"siteData.status", .@"siteData.refresh", .@"siteData.openInspector", .@"reading.find", .@"pageSource.open", .@"pageSource.status",
        .@"popups.open", .@"popups.status", .@"siteSettings.autoplay.get", .@"downloads.clearCompleted", .@"tabs.openLink", .@"tabs.copyLink", .@"bookmarks.saveLink",
        .@"siteSettings.sound.get", .@"siteSettings.sound.toggle",
        .@"tabs.closed.list", .@"tabs.closed.clear", .@"privacy.status", .@"privacy.openPrivateWindow",
        .@"tabs.togglePinned", .@"tabs.toggleMuted", .@"tabs.duplicate", .@"tabs.copyAddress", .@"search.getConfig",
        .@"tabs.session.status", .@"tabs.session.restore", .@"tabs.session.forget" => {
            if (!noParams(params)) return sdk.failure(output, id, .InvalidParams);
        },
        else => {},
    }
    return switch (method) {
        .@"tabs.openLink", .@"tabs.copyLink", .@"bookmarks.saveLink" => {
            const link = context.link orelse return sdk.failure(output,id,.PermissionDenied);
            const operation: sdk.LinkMenuAction = switch (method) {
                .@"tabs.openLink" => .open,
                .@"tabs.copyLink" => .copy,
                .@"bookmarks.saveLink" => .bookmark,
                else => unreachable,
            };
            if (!context.user_command or link.operation!=operation) return sdk.failure(output,id,.PermissionDenied);
            return sdk.result(output,id,applyLink(link));
        },
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
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const value = decode(struct { panel: sdk.InspectorPanel, placement: sdk.InspectorPlacement = .docked },allocator,params) catch
                return sdk.failure(output,id,.InvalidParams);
            break :inspect sdk.result(output,id,native.moon_devtools_open(@intFromEnum(value.panel),value.placement==.window,context.target_tab_id,context.target_navigation));
        },
        .@"devtools.toggle" => {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            if (!noParams(params)) return sdk.failure(output,id,.InvalidParams);
            const state = native.moon_devtools_toggle(context.target_tab_id,context.target_navigation);
            const result: ?bool = if (state<0) null else state==1;
            return sdk.result(output,id,result);
        },
        .@"pageSource.open" => open: {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const tab = context.tab orelse break :open sdk.result(output,id,false);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            break :open sdk.result(output,id,native.moon_page_source_open(owner.ptr,tab.id,&tab.url));
        },
        .@"page.saveHtml" => {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            if (!noParams(params)) return sdk.failure(output,id,.InvalidParams);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            const result = native.moon_page_save(owner.ptr,context.target_tab_id,context.target_navigation,
                context.consent.context,context.consent.valid);
            return sdk.result(output,id,std.enums.fromInt(sdk.PageSaveStart,result) orelse .failed);
        },
        .@"pageSource.status" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            return sdk.result(output,id,page_source.status(context.target_tab_id,context.plugin_id));
        },
        .@"pageSource.read" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const query = decode(sdk.PageSourceQuery,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            const chunk = page_source.read(context.target_tab_id,context.plugin_id,query) orelse
                return sdk.failure(output,id,.NotFound);
            const encoder = std.base64.standard.Encoder;
            const buffer = try allocator.alloc(u8,encoder.calcSize(chunk.bytes.len));
            return sdk.result(output,id,sdk.PageSourceChunk{ .sourceBase64=encoder.encode(buffer,chunk.bytes), .next=chunk.next });
        },
        .@"popups.open" => {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            return sdk.result(output,id,native.moon_popups_open(owner.ptr,context.target_tab_id));
        },
        .@"popups.status" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            var rules: popups.RuleBuffer = undefined;
            var target: popups.Origin = undefined;
            return sdk.result(output,id,popups.status(context.target_tab_id,context.plugin_id,&rules,&target));
        },
        .@"popups.setRule" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const rule = decode(sdk.PopupRule,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            const key = popups.origin(rule.origin) orelse return sdk.failure(output,id,.InvalidParams);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            if (!native.moon_popups_change_allowed(owner.ptr,context.target_tab_id,&key,
                rule.mode == .allow and popups.mode(std.mem.sliceTo(&key,0)) != .allow))
                return sdk.failure(output,id,.Cancelled);
            popups.save(allocator,rule) catch |err| return sdk.failure(output,id,switch (err) {
                error.InvalidParams => .InvalidParams,
                error.LimitExceeded => .LimitExceeded,
                else => .InternalError,
            });
            return sdk.result(output,id,true);
        },
        .@"popups.openBlocked" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const request = decode(struct { id: u64 },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            return sdk.result(output,id,native.moon_popups_open_blocked(owner.ptr,context.target_tab_id,request.id));
        },
        .@"siteSettings.autoplay.get" => {
            if (!context.from_page or native.moon_shell_private()) return sdk.failure(output,id,.PermissionDenied);
            var buffer: autoplay.Buffer = undefined;
            return sdk.result(output,id,autoplay.status(context.target_tab_id,context.plugin_id,&buffer));
        },
        .@"siteSettings.autoplay.set" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const rule = decode(sdk.AutoplayRule,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            const key = popups.origin(rule.origin) orelse return sdk.failure(output,id,.InvalidParams);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            if (!native.moon_autoplay_change_allowed(owner.ptr,context.target_tab_id,&key,
                rule.mode==.allow and autoplay.mode(std.mem.sliceTo(&key,0))!=.allow))
                return sdk.failure(output,id,.Cancelled);
            autoplay.save(allocator,key,rule.mode) catch |err| return sdk.failure(output,id,switch (err) {
                error.LimitExceeded => .LimitExceeded,
                else => .InternalError,
            });
            return sdk.result(output,id,true);
        },
        .@"siteSettings.sound.get" => {
            if (!context.from_page or native.moon_shell_private()) return sdk.failure(output,id,.PermissionDenied);
            var buffer: site_sound.Buffer = undefined;
            return sdk.result(output,id,site_sound.status(context.target_tab_id,context.plugin_id,&buffer));
        },
        .@"siteSettings.sound.set" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const rule = decode(sdk.SiteSoundRule,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            const key = popups.origin(rule.origin) orelse return sdk.failure(output,id,.InvalidParams);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            if (!native.moon_site_sound_panel_allowed(owner.ptr,context.target_tab_id)) return sdk.failure(output,id,.PermissionDenied);
            site_sound.save(allocator,key,rule.muted) catch |err| return sdk.failure(output,id,switch (err) {
                error.LimitExceeded => .LimitExceeded,
                else => .InternalError,
            });
            native.moon_site_sound_update();
            return sdk.result(output,id,true);
        },
        .@"siteSettings.sound.toggle" => {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            const changed = native.moon_site_sound_toggle(owner.ptr,context.target_tab_id,context.target_navigation);
            return sdk.result(output,id,std.enums.fromInt(sdk.SiteSoundResult,changed) orelse .unavailable);
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
        .@"bookmarks.bar.toggle" => {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const change: sdk.BookmarksBarChange = @enumFromInt(native.moon_bookmark_bar_toggle());
            return sdk.result(output,id,change);
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
        .@"bookmarks.importHtml", .@"bookmarks.exportHtml" => {
            if ((!context.user_command and !context.from_page) or !context.grants.contains(.@"bookmarks.manage"))
                return sdk.failure(output,id,.PermissionDenied);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            const result = bookmarks.transfer(allocator,owner,context.target_tab_id,method==.@"bookmarks.exportHtml",context.consent);
            return sdk.result(output,id,result);
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
        .@"downloads.clearCompleted" => clear: {
            const count = downloads.clearCompleted() catch |err| return sdk.failure(output,id,libraryReason(err));
            break :clear sdk.result(output,id,.{ .removed=count });
        },
        .@"siteData.open" => open: {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const tab = context.tab orelse break :open sdk.result(output,id,false);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            break :open sdk.result(output,id,native.moon_site_data_open(owner.ptr,tab.id,&tab.url));
        },
        .@"siteData.status" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            return sdk.result(output,id,site_data.status(context.target_tab_id,context.plugin_id,
                context.grants.contains(.@"siteData.write"),
                !native.moon_shell_private() and context.grants.contains(.@"siteData.cookieDetails")));
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
        .@"siteData.cookieDetails", .@"siteData.cookieValue" => {
            if (!context.from_page or !context.grants.contains(.@"siteData.read")) return sdk.failure(output,id,.PermissionDenied);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            var url: [4096:0]u8 = @splat(0);
            if (!native.moon_site_data_cookie_url(context.target_tab_id,owner.ptr,&url,url.len))
                return sdk.failure(output,id,.NotFound);
            if (method == .@"siteData.cookieDetails") {
                const options = decode(struct { generation: u64 },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
                const result = site_data.cookieDetails(context.target_tab_id,context.plugin_id,options.generation,std.mem.span(@as([*:0]const u8,&url))) orelse
                    return sdk.failure(output,id,.NotFound);
                return sdk.result(output,id,result);
            }
            const options = decode(sdk.SiteCookieItem,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            const result = site_data.cookieValue(allocator,context.target_tab_id,context.plugin_id,options,std.mem.span(@as([*:0]const u8,&url))) orelse
                return sdk.failure(output,id,.NotFound);
            return sdk.result(output,id,result);
        },
        .@"siteData.catalog" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const options = decode(struct { group: sdk.SiteCatalogGroup },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            _ = native.moon_site_data_action(context.target_tab_id,owner.ptr,native.MOON_SITE_CATALOG);
            const result = site_data.catalogStatus(context.target_tab_id,context.plugin_id,options.group) orelse return sdk.failure(output,id,.NotFound);
            return sdk.result(output,id,result);
        },
        .@"siteData.update" => {
            if (!context.from_page or !context.grants.contains(.@"siteData.read")) return sdk.failure(output,id,.PermissionDenied);
            const options = decode(sdk.SiteDataUpdate,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            if (options.group==.cookies) return sdk.failure(output,id,.InvalidParams);
            if (options.value) |raw| if (raw.len>sdk.site_data_value_limit) return sdk.failure(output,id,.LimitExceeded);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            const value = options.value orelse "";
            const ok = native.moon_site_data_update(context.target_tab_id,owner.ptr,options.group==.session,
                options.id,options.generation,if (options.value!=null) value.ptr else null,value.len);
            if (!ok) return sdk.failure(output,id,.NotFound);
            return sdk.result(output,id,true);
        },
        .@"siteData.create" => {
            if (!context.from_page or !context.grants.contains(.@"siteData.read")) return sdk.failure(output,id,.PermissionDenied);
            const options = decode(sdk.SiteDataCreate,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            if (options.group==.cookies) return sdk.failure(output,id,.InvalidParams);
            if (options.key.len>sdk.site_data_key_limit or options.value.len>sdk.site_data_value_limit)
                return sdk.failure(output,id,.LimitExceeded);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            if (!native.moon_site_data_create(context.target_tab_id,owner.ptr,options.group==.session,
                options.generation,options.key.ptr,options.key.len,options.value.ptr,options.value.len))
                return sdk.failure(output,id,.NotFound);
            return sdk.result(output,id,true);
        },
        .@"siteData.clear" => {
            if (!context.from_page or !context.grants.contains(.@"siteData.read")) return sdk.failure(output,id,.PermissionDenied);
            const options = decode(sdk.SiteDataClear,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            if (options.group==.cookies) return sdk.failure(output,id,.InvalidParams);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            const outcome = native.moon_site_data_clear(context.target_tab_id,owner.ptr,options.group==.session,options.generation);
            return sdk.result(output,id,std.enums.fromInt(sdk.SiteDataClearStart,outcome) orelse .unavailable);
        },
        .@"siteData.refresh", .@"siteData.openInspector" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            const action = if (method == .@"siteData.openInspector") native.MOON_SITE_INSPECTOR else native.MOON_SITE_REFRESH;
            return sdk.result(output,id,native.moon_site_data_action(context.target_tab_id,owner.ptr,action));
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
        .@"window.toggleFullscreen" => {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            if (!noParams(params)) return sdk.failure(output,id,.InvalidParams);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            const state = native.moon_window_fullscreen(context.target_tab_id,context.target_navigation,owner.ptr);
            const result: ?bool = if (state < 0) null else state != 0;
            return sdk.result(output,id,result);
        },
        .@"tabs.togglePinned", .@"tabs.toggleMuted", .@"tabs.duplicate", .@"tabs.copyAddress" => {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const operation: sdk.TabOperation = switch (method) {
                .@"tabs.togglePinned" => .pin,
                .@"tabs.toggleMuted" => .mute,
                .@"tabs.duplicate" => .duplicate,
                .@"tabs.copyAddress" => .copyAddress,
                else => unreachable,
            };
            const outcome = native.moon_tabs_organize(context.target_tab_id,@intFromEnum(operation));
            return sdk.result(output,id,@as(sdk.TabOrganization,@enumFromInt(outcome)));
        },
        .@"tabs.reorder" => {
            const drop = context.drop orelse return sdk.failure(output,id,.PermissionDenied);
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            if (!noParams(params)) return sdk.failure(output,id,.InvalidParams);
            if (drop.consumed) return sdk.result(output,id,sdk.TabReorder.unavailable);
            if (drop.context.into_group and !context.grants.contains(.@"tabs.groups"))
                return sdk.failure(output,id,.PermissionDenied);
            drop.consumed = true;
            const outcome = native.moon_tabs_reorder(&drop.context);
            return sdk.result(output,id,std.enums.fromInt(sdk.TabReorder,outcome) orelse .unavailable);
        },
        .@"tabs.closeGroup" => {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            const options = decode(struct { scope: sdk.TabCloseScope },allocator,params) catch
                return sdk.failure(output,id,.InvalidParams);
            var counts: native.MoonTabCloseResult = undefined;
            if (!native.moon_tabs_close_group(context.target_tab_id,options.scope==.below,&counts))
                return sdk.result(output,id,null);
            return sdk.result(output,id,sdk.TabCloseResult{ .closed=counts.closed,.kept=counts.kept });
        },
        .@"tabs.groups.open", .@"tabs.groups.create", .@"tabs.groups.removeTab" => {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            if (!noParams(params)) return sdk.failure(output,id,.InvalidParams);
            if (method==.@"tabs.groups.open") {
                const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
                return sdk.result(output,id,native.moon_group_panel(owner.ptr,context.target_tab_id));
            }
            const outcome=if (method==.@"tabs.groups.create") native.moon_group_create(context.target_tab_id)
                else native.moon_group_remove_tab(context.target_tab_id);
            return sdk.result(output,id,std.enums.fromInt(sdk.TabGroupResult,outcome) orelse .unavailable);
        },
        .@"tabs.groups.list" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            if (!noParams(params)) return sdk.failure(output,id,.InvalidParams);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            var rows: [native.MOON_MAX_GROUPS]native.MoonTabGroup=undefined;
            var count: usize=0;
            var assigned: u32=0;
            var assignable: bool=false;
            if (!native.moon_group_list(context.target_tab_id,owner.ptr,&rows,rows.len,&count,&assigned,&assignable))
                return sdk.failure(output,id,.PermissionDenied);
            var groups: [rows.len]struct {
                id: u32, name: []const u8, color: sdk.TabGroupColor, members: u32, collapsed: bool,
            }=undefined;
            for (groups[0..count],rows[0..count]) |*group,*row| group.*=.{ .id=row.id,.name=std.mem.sliceTo(&row.name,0),
                .color=@enumFromInt(row.color),.members=row.members,.collapsed=row.collapsed };
            return sdk.result(output,id,.{ .groups=groups[0..count],.assigned=assigned,.assignable=assignable });
        },
        .@"tabs.groups.assign", .@"tabs.groups.update", .@"tabs.groups.dissolve" => {
            if (!context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const owner = try allocator.dupeSentinel(u8,context.plugin_id,0);
            const panel=context.target_tab_id;
            const result=if (method==.@"tabs.groups.update") update: {
                const group=decode(sdk.TabGroup,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
                if (group.name.len>96 or std.mem.indexOfScalar(u8,group.name,0)!=null)
                    return sdk.result(output,id,sdk.TabGroupResult.invalidName);
                const name=try allocator.dupeSentinel(u8,group.name,0);
                break :update native.moon_group_update(panel,owner.ptr,group.id,name.ptr,@intFromEnum(group.color),group.collapsed);
            } else action: {
                const options=decode(struct { id: u32 },allocator,params) catch return sdk.failure(output,id,.InvalidParams);
                break :action if (method==.@"tabs.groups.assign") native.moon_group_assign(panel,owner.ptr,options.id)
                    else native.moon_group_dissolve(panel,owner.ptr,options.id);
            };
            return sdk.result(output,id,std.enums.fromInt(sdk.TabGroupResult,result) orelse .unavailable);
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
        .@"privacy.openPrivateWindow" => {
            if (!context.user_command) return sdk.failure(output,id,.PermissionDenied);
            return sdk.result(output,id,native.moon_shell_open_private());
        },
        .@"browser.openDefaultApps" => {
            if (!context.user_command or native.moon_shell_private()) return sdk.failure(output,id,.PermissionDenied);
            const outcome: sdk.DefaultAppsResult = @enumFromInt(native.moon_shell_open_default_apps());
            return sdk.result(output,id,outcome);
        },
        .@"search.getConfig" => {
            var engines: [sdk.search_custom_limit]sdk.SearchEngine = undefined;
            const state: sdk.SearchState = .{ .config=search.get(&engines), .builtins=&search.builtins, .customLimit=sdk.search_custom_limit };
            return sdk.result(output,id,state);
        },
        .@"search.setConfig" => {
            if (!context.user_command and !context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const config = decode(sdk.SearchConfig,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            return sdk.result(output,id,search.save(allocator,config,params.?));
        },
        .@"tabs.session.status" => sdk.result(output,id,session.status()),
        .@"tabs.session.setPreferences" => {
            if (!context.user_command and !context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const preferences = decode(sdk.SessionPreferences,allocator,params) catch return sdk.failure(output,id,.InvalidParams);
            return sdk.result(output,id,session.configure(allocator,preferences,params.?));
        },
        .@"tabs.session.restore" => {
            if (!context.user_command and !context.from_page) return sdk.failure(output,id,.PermissionDenied);
            const result = native.moon_session_restore(context.target_tab_id);
            return sdk.result(output,id,@as(sdk.SessionRestore,@enumFromInt(result)));
        },
        .@"tabs.session.forget" => {
            if (!context.user_command and !context.from_page) return sdk.failure(output,id,.PermissionDenied);
            return sdk.result(output,id,session.forget());
        },
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
