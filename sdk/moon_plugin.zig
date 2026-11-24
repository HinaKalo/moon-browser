const std = @import("std");

pub const api_version = 2;
pub const frame_limit = 32 * 1024;
pub const command_limit = 8;
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
};
pub const Event = enum { @"tabs.changed" };
pub const Shortcut = enum {
    @"Ctrl+H", F12, @"Ctrl+Shift+J", @"Ctrl+D", @"Ctrl+Shift+O", @"Ctrl+J",
    @"Ctrl+F", @"Ctrl++", @"Ctrl+-", @"Ctrl+0",
    @"Ctrl+Shift+T",
};
pub const Command = struct { id: []const u8, label: []const u8, interactive: bool = false, shortcut: ?Shortcut = null };
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
pub const Tab = struct { id: []const u8, title: []const u8, url: []const u8 };
pub const TabChange = struct { tabId: ?[]const u8 };
pub const ClosedTab = struct { id: u32, title: []const u8, origin: []const u8 };
pub const ReopenClosedTab = enum(c_int) { reopened, notFound, tabLimit, unavailable };
pub const Script = struct { id: []const u8, name: []const u8, enabled: bool };
pub const ScriptId = struct { id: []const u8 };
pub const ScriptSwitch = struct { id: []const u8, enabled: bool };
pub const ScriptSource = struct { sourceBase64: []const u8 };
pub const ScriptUpdate = struct { id: []const u8, sourceBase64: []const u8 };
pub const ReloadResult = enum { reloaded, noMatchingPage, protectedPage };
pub const InspectorPanel = enum { inspector, console, resources };
pub const HistoryVisit = struct { id: u32, title: []const u8, url: []const u8, visitedAt: u64 };
pub const HistoryQuery = struct { query: []const u8 = "", before: ?u32 = null };
pub const HistoryPage = struct { visits: []const HistoryVisit, next: ?u32 };
pub const BookmarkInput = struct { title: []const u8, url: []const u8, folder: []const u8 = "" };
pub const BookmarkEdit = struct { id: u32, title: []const u8, url: []const u8, folder: []const u8 = "" };
pub const Bookmark = struct { id: u32, title: []const u8, url: []const u8, folder: []const u8 };
pub const BookmarkPage = struct { bookmarks: []const Bookmark, next: ?u32 };
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
pub const SiteDataStatus = struct { state: SiteDataState, origin: []const u8, generation: u64, failure: ?SiteDataFailure = null };
pub const SiteDataEntry = struct { id: u32, name: []const u8, length: usize, shortened: bool };
pub const SiteDataPage = struct { available: bool, entries: []const SiteDataEntry, more: bool, generation: u64 };
pub const SiteDataItem = struct { group: SiteDataGroup, id: u32, generation: u64 };
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
    @"ui.openPage",
    @"history.list",
    @"history.remove",
    @"history.clear",
    @"network.filter.status",
    @"network.filter.setSite",
    @"bookmarks.list",
    @"bookmarks.save",
    @"bookmarks.saveActive",
    @"bookmarks.update",
    @"bookmarks.remove",
    @"downloads.list",
    @"downloads.cancel",
    @"downloads.remove",
    @"downloads.reveal",
    @"siteData.open",
    @"siteData.status",
    @"siteData.list",
    @"siteData.value",
    @"siteData.refresh",
    @"siteData.openInspector",
    @"reading.find",
    @"reading.zoom",
    @"tabs.closed.list",
    @"tabs.closed.reopen",
    @"tabs.closed.clear",
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
