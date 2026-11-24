const std = @import("std");

pub const api_version = 2;
pub const frame_limit = 32 * 1024;
pub const command_limit = 12;
pub const request_limit = 24;
pub const lua_source_limit = 16 * 1024;
pub const rpc_version = "2.0";

pub const Permission = enum {
    @"tabs.read",
    @"lua.scripts.manage",
    @"page.inspect",
    @"history.manage",
    @"network.filter",
    @"bookmarks.manage",
    @"downloads.manage",
    @"siteData.read",
    @"page.reading",
    @"tabs.closed.manage",
    @"privacy.clear",
    @"taskManager.manage",
    @"ui.commands",
    @"tabs.organize",
    @"privacy.privateWindow",
    @"tabs.manage",
    @"search.manage",
    @"siteData.write",
    @"siteData.cookieDetails",
    @"siteSettings.autoplay",
    @"tabs.session.manage",
    @"bookmarks.transfer",
    @"page.source",
    @"popups.manage",
    @"window.fullscreen",
    @"page.save",
    @"tabs.groups",
    @"browser.defaultApp",
};
pub const Event = enum { @"tabs.changed" };
pub const Shortcut = enum {
    @"Ctrl+H", F12, @"Ctrl+Shift+J", @"Ctrl+D", @"Ctrl+Shift+O", @"Ctrl+J",
    @"Ctrl+F", @"Ctrl++", @"Ctrl+-", @"Ctrl+0",
    @"Ctrl+Shift+T",
    @"Ctrl+Shift+Delete",
    @"Ctrl+Shift+M",
    @"Ctrl+Shift+N",
    @"Ctrl+U",
    F11,
    @"Ctrl+Shift+C",
    @"Ctrl+S",
    @"Ctrl+Shift+B",
};
pub const MenuGroup = enum { page, library, privacy, developer, extensions };
pub const LinkMenuAction = enum(c_uint) { open = 1, copy, bookmark };
pub const LinkResult = enum { opened, copied, clipboardBusy, limitReached, saved, alreadySaved, unavailable };
pub const Command = struct {
    id: []const u8,
    label: []const u8,
    interactive: bool = false,
    shortcut: ?Shortcut = null,
    menu: ?MenuGroup = null,
    siteMenu: bool = false,
    linkMenu: ?LinkMenuAction = null,
    inspectElementMenu: ?[]const u8 = null,
    tabDrop: bool = false,
};
pub const ShortcutScope = enum { browser, global };
pub const RegisteredShortcut = struct { id: []const u8, shortcut: []const u8, scope: ShortcutScope = .browser };
pub const UiRegistration = enum(c_uint) { saved, notFound, conflict, reserved, invalidShortcut, limitReached, cancelled, unavailable };
pub const Manifest = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    apiVersion: u32,
    runtime: enum { native },
    entry: []const u8,
    settingsPage: ?[]const u8 = null,
    networkRules: ?[]const u8 = null,
    contributes: struct { commands: []const Command },
    permissions: []const Permission = &.{},
    events: []const Event = &.{},
};

pub const Initialization = struct {
    apiVersion: u32,
    pluginId: []const u8,
    permissions: []const Permission,
    browserWindow: u64 = 0,
    darkMode: bool = false,
};
pub const HostInfo = struct { apiVersion: u32, browserVersion: []const u8, luaVersion: []const u8 };
pub const PageSourceState = enum { idle, pending, ready, stale, unavailable };
pub const PageSourceStatus = struct {
    state: PageSourceState = .idle,
    generation: u64 = 0,
    url: []const u8 = "",
    bytes: usize = 0,
    truncated: bool = false,
};
pub const PageSourceQuery = struct { generation: u64, offset: usize };
pub const PageSourceChunk = struct { sourceBase64: []const u8, next: ?usize };
pub const PageSaveStart = enum(c_int) { started, cancelled, unavailable, unsupported, invalidFilename, busy, failed };
pub const PopupMode = enum { automatic, allow, block };
pub const PopupRule = struct { origin: []const u8, mode: PopupMode };
pub const AutoplayMode = enum(c_uint) { automatic, allow, muted, block };
pub const AutoplayRule = struct { origin: []const u8, mode: AutoplayMode };
pub const AutoplaySettings = struct { currentOrigin: ?[]const u8, rules: []const AutoplayRule };
pub const PopupNotice = struct { id: u64, count: u32, targetOrigin: []const u8 };
pub const Tab = struct { id: []const u8, title: []const u8, url: []const u8 };
pub const TabChange = struct { tabId: ?[]const u8 };
pub const ClosedTab = struct { id: u32, title: []const u8, origin: []const u8 };
pub const ReopenClosedTab = enum(c_int) { reopened, notFound, tabLimit, unavailable };
pub const SessionPreferences = struct { autoRestore: bool = false };
pub const SessionStatus = struct { autoRestore: bool, tabs: usize, alreadyRestored: bool };
pub const SessionRestore = enum(c_int) { restored, empty, tabLimit, unavailable };
pub const TabOperation = enum(c_int) { pin, mute, duplicate, copyAddress };
pub const TabOrganization = enum(c_int) {
    pinned, unpinned, muted, unmuted, unavailable, limitReached, saveFailed, duplicated, copied, clipboardBusy,
};
pub const TabCloseScope = enum { others, below };
pub const TabCloseResult = struct { closed: u32, kept: u32 };
pub const TabReorder = enum(c_int) { moved, unavailable, saveFailed };
pub const TabGroupColor = enum(c_uint) { indigo, teal, amber, rose, slate };
pub const TabGroup = struct { id: u32, name: []const u8, color: TabGroupColor, collapsed: bool = false };
pub const TabGroupResult = enum(c_int) { saved, unavailable, limitReached, invalidName };
pub const DefaultAppsResult = enum(c_int) { opened, installRequired, unavailable };
pub const search_custom_limit = 5;
pub const SearchEngine = struct { alias: []const u8, name: []const u8, template: []const u8 };
pub const SearchConfig = struct {
    preferred: []const u8 = "g",
    custom: []const SearchEngine = &.{},
    suggestHistory: ?bool = null,
    suggestBookmarks: ?bool = null,
};
pub const SearchState = struct { config: SearchConfig, builtins: []const SearchEngine, customLimit: usize };
pub const SearchSave = enum { saved, invalidAlias, duplicateAlias, invalidName, invalidTemplate, invalidDefault, tooMany, unavailable };
pub const PrivacySelection = struct { history: bool = false, siteData: bool = false, cache: bool = false };
pub const PrivacyStart = enum { started, cancelled, busy, unavailable };
pub const PrivacyState = enum { idle, running, waitingForEngine, complete, incomplete };
pub const PrivacyStatus = struct { state: PrivacyState, failed: PrivacySelection = .{} };
pub const TaskTabPhase = enum(u32) { blank, live, dormant, crashed, restoring, failed };
pub const TaskProtection = enum(u32) { current, loading, input, nonGet, download, media, siteInspection, internal, developerTools };
pub const TaskTab = struct { id: []const u8, title: []const u8, phase: TaskTabPhase, pid: ?u32, protection: ?TaskProtection };
pub const TaskProcess = struct { pid: u32, privateBytes: u64, tabs: u32, browser: bool };
pub const TaskOverview = struct {
    privateBytes: u64, peakBytes: u64, highBytes: u64, targetBytes: u64, pressure: bool, warmLimit: u32, idleSeconds: u32,
    open: u32, live: u32, dormant: u32, protected: u32, processes: u32, evictions: u32, retiring: u32,
    beforeBytes: ?u64, afterBytes: ?u64,
};
pub const TaskQuery = struct { view: enum { tabs, processes }, offset: u32 = 0 };
pub const TaskSnapshot = struct {
    overview: TaskOverview,
    tabs: ?[]const TaskTab = null,
    processes: ?[]const TaskProcess = null,
    next: ?u32,
};
pub const TaskAction = enum(c_uint) { done, notFound, protected, unavailable };
pub const Script = struct { id: []const u8, name: []const u8, enabled: bool };
pub const ScriptId = struct { id: []const u8 };
pub const ScriptSwitch = struct { id: []const u8, enabled: bool };
pub const ScriptSource = struct { sourceBase64: []const u8 };
pub const ScriptUpdate = struct { id: []const u8, sourceBase64: []const u8 };
pub const ReloadResult = enum { reloaded, noMatchingPage, protectedPage };
pub const InspectorPanel = enum(c_int) { inspector, console, resources, elements };
pub const InspectorPlacement = enum { docked, window };
pub const HistoryVisit = struct { id: u32, title: []const u8, url: []const u8, visitedAt: u64 };
pub const HistoryQuery = struct { query: []const u8 = "", before: ?u32 = null };
pub const HistoryPage = struct { visits: []const HistoryVisit, next: ?u32 };
pub const BookmarkInput = struct { title: []const u8, url: []const u8, folder: []const u8 = "" };
pub const BookmarkEdit = struct { id: u32, title: []const u8, url: []const u8, folder: []const u8 = "" };
pub const Bookmark = struct { id: u32, title: []const u8, url: []const u8, folder: []const u8 };
pub const BookmarksBarChange = enum(c_int) { shown, hidden, unavailable };
pub const BookmarkPage = struct { bookmarks: []const Bookmark, next: ?u32 };
pub const BookmarkTransferState = enum { done, cancelled, invalidFile, limitExceeded, unavailable };
pub const BookmarkTransfer = struct { state: BookmarkTransferState, count: usize = 0, skipped: usize = 0 };
pub const BookmarkSave = enum { saved, alreadySaved, noPage };
pub const DownloadState = enum { choosing, transferring, complete, failed, cancelled, interrupted };
pub const Download = struct {
    id: u32,
    name: []const u8,
    state: DownloadState,
    received: u64,
    total: ?u64,
    cancellable: bool,
    startedAt: u64,
};
pub const DownloadPage = struct { downloads: []const Download, next: ?u32 };
pub const SiteDataGroup = enum { cookies, local, session };
pub const SiteDataState = enum { idle, pending, ready, stale, unavailable, expired };
pub const SiteDataFailure = enum {
    engineUnavailable, frameUnavailable, sourceChanged, worldUnavailable, contextUnavailable,
    evaluationFailed, conversionFailed, invalidResult, timedOut,
};
pub const SiteDataMutation = enum { saved, removed, cleared, conflict, failed };
pub const SiteDataClearStart = enum(c_int) { started, cancelled, unavailable };
pub const SiteDataStatus = struct {
    state: SiteDataState, origin: []const u8, generation: u64,
    failure: ?SiteDataFailure = null, mutation: ?SiteDataMutation = null, writable: bool = false,
    cookieDetails: bool = false,
};
pub const SiteDataEntry = struct { id: u32, name: []const u8, length: usize, shortened: bool };
pub const SiteDataPage = struct { available: bool, entries: []const SiteDataEntry, more: bool, generation: u64 };
pub const SiteDataItem = struct { group: SiteDataGroup, id: u32, generation: u64 };
pub const SiteCookieEntry = struct {
    id: u32,
    name: []const u8,
    domain: []const u8,
    path: []const u8,
    expiresAt: ?i64,
    httpOnly: bool,
    secure: bool,
    length: usize,
    shortened: bool,
    metadataShortened: bool,
};
pub const SiteCookiePage = struct { available: bool, entries: []const SiteCookieEntry, more: bool, generation: u64 };
pub const SiteCookieItem = struct { id: u32, generation: u64 };
pub const SiteDatabase = struct { name: []const u8, version: ?u64, shortened: bool };
pub const SiteCache = struct { name: []const u8, shortened: bool };
pub const SiteCatalogGroup = enum { indexedDB, cacheStorage };
pub const SiteStorageCatalog = struct {
    state: enum { pending, ready, unavailable },
    generation: u64,
    indexedDB: ?struct { entries: []const SiteDatabase, more: bool } = null,
    cacheStorage: ?struct { entries: []const SiteCache, more: bool } = null,
};
pub const site_data_value_limit = 1024;
pub const site_data_key_limit = 512;
pub const SiteDataUpdate = struct { group: SiteDataGroup, id: u32, generation: u64, value: ?[]const u8 };
pub const SiteDataCreate = struct { group: SiteDataGroup, generation: u64, key: []const u8, value: []const u8 };
pub const SiteDataClear = struct { group: SiteDataGroup, generation: u64 };
pub const ZoomAction = enum { increase, decrease, reset };
pub const NetworkFilterStatus = struct { preferred: bool, active: bool, exceptions: []const []const u8 };
pub const NetworkFilterSite = struct { host: []const u8, enabled: bool };
pub const CommandResult = struct {
    message: ?[]const u8 = null,
    toast: bool = false,

    pub fn jsonStringify(self: CommandResult, writer: anytype) !void {
        if (self.toast) {
            try writer.write(.{ .message=self.message,.toast=true });
        } else {
            try writer.write(.{ .message=self.message });
        }
    }
};

pub const Method = enum {
    @"host.getInfo",
    @"browser.openDefaultApps",
    @"tabs.getActive",
    @"lua.scripts.list",
    @"lua.scripts.install",
    @"lua.scripts.setEnabled",
    @"lua.scripts.remove",
    @"lua.scripts.getSource",
    @"lua.scripts.update",
    @"lua.scripts.reloadActive",
    @"settings.read",
    @"settings.write",
    @"devtools.open",
    @"devtools.toggle",
    @"pageSource.open",
    @"pageSource.status",
    @"pageSource.read",
    @"page.saveHtml",
    @"popups.open",
    @"popups.status",
    @"popups.setRule",
    @"popups.openBlocked",
    @"siteSettings.autoplay.get",
    @"siteSettings.autoplay.set",
    @"ui.openPage",
    @"history.list",
    @"history.remove",
    @"history.clear",
    @"network.filter.status",
    @"network.filter.setSite",
    @"bookmarks.list",
    @"bookmarks.save",
    @"bookmarks.saveActive",
    @"bookmarks.bar.toggle",
    @"bookmarks.saveLink",
    @"bookmarks.update",
    @"bookmarks.remove",
    @"bookmarks.importHtml",
    @"bookmarks.exportHtml",
    @"downloads.list",
    @"downloads.cancel",
    @"downloads.remove",
    @"downloads.clearCompleted",
    @"downloads.reveal",
    @"siteData.open",
    @"siteData.status",
    @"siteData.list",
    @"siteData.catalog",
    @"siteData.value",
    @"siteData.cookieDetails",
    @"siteData.cookieValue",
    @"siteData.refresh",
    @"siteData.openInspector",
    @"siteData.update",
    @"siteData.create",
    @"siteData.clear",
    @"reading.find",
    @"reading.zoom",
    @"window.toggleFullscreen",
    @"tabs.closed.list",
    @"tabs.closed.reopen",
    @"tabs.closed.clear",
    @"tabs.session.status",
    @"tabs.session.setPreferences",
    @"tabs.session.restore",
    @"tabs.session.forget",
    @"tabs.togglePinned",
    @"tabs.toggleMuted",
    @"tabs.duplicate",
    @"tabs.copyAddress",
    @"tabs.openLink",
    @"tabs.copyLink",
    @"tabs.closeGroup",
    @"tabs.reorder",
    @"tabs.groups.open",
    @"tabs.groups.create",
    @"tabs.groups.removeTab",
    @"tabs.groups.list",
    @"tabs.groups.assign",
    @"tabs.groups.update",
    @"tabs.groups.dissolve",
    @"privacy.clear",
    @"privacy.status",
    @"privacy.openPrivateWindow",
    @"search.getConfig",
    @"search.setConfig",
    @"taskManager.snapshot",
    @"taskManager.focus",
    @"taskManager.discard",
    @"ui.menu.add",
    @"ui.menu.remove",
    @"ui.shortcuts.register",
    @"ui.shortcuts.unregister",
};
pub const Reason = enum(i32) {
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603,
    PermissionDenied = -32001,
    Cancelled = -32002,
    LimitExceeded = -32003,
    NotFound = -32004,
    AlreadyExists = -32005,
    InvalidScript = -32006,

    pub fn code(self: Reason) []const u8 {
        return switch (self) {
            .ParseError => "PARSE_ERROR",
            .InvalidRequest => "INVALID_REQUEST",
            .MethodNotFound => "METHOD_NOT_FOUND",
            .InvalidParams => "INVALID_PARAMS",
            .InternalError => "INTERNAL_ERROR",
            .PermissionDenied => "PERMISSION_DENIED",
            .Cancelled => "CANCELLED",
            .LimitExceeded => "LIMIT_EXCEEDED",
            .NotFound => "NOT_FOUND",
            .AlreadyExists => "ALREADY_EXISTS",
            .InvalidScript => "INVALID_SCRIPT",
        };
    }
};

pub fn serialize(allocator: std.mem.Allocator, message: anytype) ![]u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, message, .{});
    errdefer allocator.free(bytes);
    if (bytes.len + 1 >= frame_limit) return error.FrameTooLarge;
    return bytes;
}

pub fn request(allocator: std.mem.Allocator, id: []const u8, method: []const u8, params: anytype) ![]u8 {
    if (@TypeOf(params) == @TypeOf(.{}))
        return serialize(allocator, .{ .jsonrpc = rpc_version, .id = id, .method = method, .params = std.json.Value{ .object = .empty } });
    return serialize(allocator, .{ .jsonrpc = rpc_version, .id = id, .method = method, .params = params });
}

pub fn result(allocator: std.mem.Allocator, id: []const u8, value: anytype) ![]u8 {
    return serialize(allocator, .{ .jsonrpc = rpc_version, .id = id, .result = value });
}

pub fn failure(allocator: std.mem.Allocator, id: ?[]const u8, reason: Reason) ![]u8 {
    return serialize(allocator, .{ .jsonrpc = rpc_version, .id = id, .@"error" = .{
        .code = @intFromEnum(reason), .message = reason.code(), .data = .{ .reason = reason.code() },
    } });
}

pub fn string(value: ?std.json.Value) ?[]const u8 {
    const item = value orelse return null;
    return if (item == .string) item.string else null;
}

pub fn envelope(value: std.json.Value) ?std.json.ObjectMap {
    if (value != .object) return null;
    const version = string(value.object.get("jsonrpc")) orelse return null;
    return if (std.mem.eql(u8, version, rpc_version)) value.object else null;
}

extern "c" fn getchar() c_int;
extern "c" fn puts([*:0]const u8) c_int;
extern "c" fn fflush(?*anyopaque) c_int;

pub const Client = struct {
    allocator: std.mem.Allocator,
    sequence: u32 = 0,

    // Parsed messages use the supplied allocator. An arena scoped to one invocation is convenient.
    pub fn receive(self: Client) !std.json.ObjectMap {
        var buffer: [frame_limit]u8 = undefined;
        var used: usize = 0;
        while (used + 1 < buffer.len) {
            const ch = getchar();
            if (ch < 0) return error.EndOfStream;
            if (ch == '\n') {
                const json = try std.json.parseFromSliceLeaky(std.json.Value, self.allocator, buffer[0..used], .{ .allocate = .alloc_always });
                return envelope(json) orelse error.InvalidEnvelope;
            }
            if (ch == 0) return error.InvalidEnvelope;
            buffer[used] = @intCast(ch);
            used += 1;
        }
        return error.FrameTooLarge;
    }

    fn send(self: Client, bytes: []const u8) !void {
        const line = try self.allocator.dupeSentinel(u8, bytes, 0);
        defer self.allocator.free(line);
        if (puts(line.ptr) < 0 or fflush(null) != 0) return error.WriteFailed;
    }

    pub fn reply(self: Client, id: []const u8, value: anytype) !void {
        const bytes = try result(self.allocator, id, value);
        defer self.allocator.free(bytes);
        try self.send(bytes);
    }

    pub fn initialize(self: Client) !Initialization {
        const message = try self.receive();
        const method = string(message.get("method")) orelse return error.InvalidHandshake;
        const id = string(message.get("id")) orelse return error.InvalidHandshake;
        if (!std.mem.eql(u8, method, "plugin.initialize")) return error.InvalidHandshake;
        const params = message.get("params") orelse return error.InvalidHandshake;
        const init = try std.json.parseFromValueLeaky(Initialization, self.allocator, params, .{ .ignore_unknown_fields = true });
        if (init.apiVersion != api_version) return error.IncompatibleVersion;
        try self.reply(id, null);
        return init;
    }

    pub fn call(self: *Client, method: Method, params: anytype) !std.json.ObjectMap {
        if (self.sequence == request_limit) return error.RequestLimit;
        self.sequence += 1;
        var buffer: [20]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "p:{d}", .{self.sequence});
        const bytes = try request(self.allocator, id, @tagName(method), params);
        defer self.allocator.free(bytes);
        try self.send(bytes);
        const response = try self.receive();
        if (!std.mem.eql(u8, string(response.get("id")) orelse return error.InvalidResponse, id))
            return error.InvalidResponse;
        if (response.contains("result") == response.contains("error")) return error.InvalidResponse;
        return response;
    }

    pub fn installScript(self: *Client, source: []const u8) !std.json.ObjectMap {
        const encoder = std.base64.standard.Encoder;
        if (source.len > lua_source_limit + 3) return error.ScriptTooLarge;
        const encoded = try self.allocator.alloc(u8, encoder.calcSize(source.len));
        defer self.allocator.free(encoded);
        return self.call(.@"lua.scripts.install", ScriptSource{ .sourceBase64 = encoder.encode(encoded, source) });
    }
};
