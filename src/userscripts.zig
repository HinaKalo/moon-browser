const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");

const allocator = std.heap.page_allocator;
const max_source = sdk.lua_source_limit;
pub const max_scripts = 16;
const Stored = struct { source: []const u8, enabled: bool, approved: bool = true };
pub const ServiceError = error{ InvalidScript, AlreadyExists, LimitExceeded, NotFound, Cancelled, InternalError };
pub const Consent = struct {
    context: *const anyopaque,
    valid: *const fn (?*const anyopaque) callconv(.c) bool,
};

const Rule = struct {
    origin: []const u8,
    path: []const u8,
    prefix: bool,
    excluded: bool,
};

const Script = struct {
    source: [:0]u8,
    id: [64]u8 = undefined,
    name: [96:0]u8 = @splat(0),
    rules: [8]Rule = undefined,
    rule_count: usize = 0,
    enabled: bool,
    approved: bool = false,
    last_error: [160:0]u8 = @splat(0),
};

var scripts: [max_scripts]Script = undefined;
var count: usize = 0;
var store: [4096:0]u8 = @splat(0);

fn text(value: anytype) []const u8 {
    return std.mem.sliceTo(value, 0);
}

fn parseRule(raw: []const u8, excluded: bool) ?Rule {
    const start: usize = if (std.mem.startsWith(u8, raw, "https://")) 8 else if (std.mem.startsWith(u8, raw, "http://")) 7 else return null;
    const slash = start + (std.mem.indexOfScalar(u8, raw[start..], '/') orelse return null);
    const authority = raw[start..slash];
    if (authority.len == 0 or raw.len > 160) return null;
    const colon = std.mem.indexOfScalar(u8, authority, ':');
    const host = authority[0 .. colon orelse authority.len];
    if (host.len == 0) return null;
    for (host) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '.') return null;
    if (colon) |index| {
        const port = std.fmt.parseUnsigned(u16, authority[index + 1 ..], 10) catch return null;
        if (port == 0) return null;
    }
    const prefix = raw[raw.len - 1] == '*';
    const path = raw[slash .. raw.len - @intFromBool(prefix)];
    for (path) |ch| if (ch <= 0x20 or ch >= 0x7f or ch == '?' or ch == '#' or ch == '*' or ch == '\\') return null;
    return .{ .origin = raw[0..slash], .path = path, .prefix = prefix, .excluded = excluded };
}

fn parse(raw: []const u8, enabled: bool) !Script {
    const source = if (std.mem.startsWith(u8, raw, "\xef\xbb\xbf")) raw[3..] else raw;
    if (source.len > max_source or std.mem.indexOfScalar(u8, source, 0) != null or !std.unicode.utf8ValidateSlice(source))
        return error.InvalidScript;
    var script: Script = .{ .source = try allocator.dupeSentinel(u8, source, 0), .enabled = enabled };
    errdefer allocator.free(script.source);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &hash, .{});
    script.id = std.fmt.bytesToHex(hash, .lower);
    var lines = std.mem.splitScalar(u8, script.source, '\n');
    const first = lines.next() orelse return error.InvalidMetadata;
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " \t\r"), "-- ==MoonUserScript==")) return error.InvalidMetadata;
    var compatible = false;
    var includes = false;
    while (lines.next()) |line| {
        const item = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, item, "-- ==/MoonUserScript==")) {
            if (!compatible or !includes or script.name[0] == 0) return error.InvalidMetadata;
            return script;
        }
        if (std.mem.startsWith(u8, item, "-- @name ")) {
            const label = std.mem.trim(u8, item[9..], " \t");
            if (script.name[0] != 0 or label.len == 0 or label.len >= script.name.len) return error.InvalidMetadata;
            for (label) |ch| if (ch < 0x20 or ch == 0x7f) return error.InvalidMetadata;
            @memcpy(script.name[0..label.len], label);
        } else if (std.mem.eql(u8, item, "-- @api 1") and !compatible) {
            compatible = true;
        } else if (std.mem.startsWith(u8, item, "-- @match ") or std.mem.startsWith(u8, item, "-- @exclude ")) {
            const excluded = item[4] == 'e';
            if (script.rule_count == script.rules.len) return error.InvalidMetadata;
            const raw_rule = std.mem.trim(u8, item[if (excluded) 12 else 10 ..], " \t");
            script.rules[script.rule_count] = parseRule(raw_rule, excluded) orelse return error.InvalidMatch;
            script.rule_count += 1;
            includes = includes or !excluded;
        } else if (item.len != 0 and !std.mem.eql(u8, item, "--")) return error.InvalidMetadata;
    }
    return error.InvalidMetadata;
}

pub fn init(profile: []const u8) void {
    _ = std.fmt.bufPrintSentinel(&store, "{s}\\lua-userscripts.json", .{profile}, 0) catch return;
    const buffer = allocator.alloc(u8, max_scripts * max_source * 6 + 8192) catch return;
    defer allocator.free(buffer);
    if (!native.moon_read_text(&store, buffer.ptr, buffer.len)) return;
    const entries = std.json.parseFromSlice([]Stored, allocator, text(buffer), .{}) catch return;
    defer entries.deinit();
    for (entries.value[0..@min(entries.value.len, max_scripts)]) |entry| {
        scripts[count] = parse(entry.source, entry.enabled and entry.approved) catch continue;
        scripts[count].approved = entry.approved;
        count += 1;
    }
}

fn save(excluded: ?usize) bool {
    var items: [max_scripts]Stored = undefined;
    var size: usize = 0;
    for (scripts[0..count], 0..) |*script, index| {
        if (excluded == index) continue;
        items[size] = .{ .source = script.source, .enabled = script.enabled, .approved = script.approved };
        size += 1;
    }
    const json = std.json.Stringify.valueAlloc(allocator, items[0..size], .{}) catch return false;
    defer allocator.free(json);
    const terminated = allocator.dupeSentinel(u8, json, 0) catch return false;
    defer allocator.free(terminated);
    return native.moon_write_text(&store, terminated.ptr);
}

fn find(id: []const u8) ?usize {
    for (scripts[0..count], 0..) |*script, index| if (std.mem.eql(u8, &script.id, id)) return index;
    return null;
}

fn describe(script: *const Script) sdk.Script {
    return .{ .id = &script.id, .name = text(&script.name), .enabled = script.enabled };
}

pub fn list(output: *[max_scripts]sdk.Script) []const sdk.Script {
    for (scripts[0..count], output[0..count]) |*script, *entry| entry.* = describe(script);
    return output[0..count];
}

pub fn getSource(id: []const u8) ServiceError![]const u8 {
    return scripts[find(id) orelse return error.NotFound].source;
}

pub fn runtimeError(id: []const u8) ServiceError!?[]const u8 {
    const message = text(&scripts[find(id) orelse return error.NotFound].last_error);
    if (message.len == 0) return null;
    return if (std.unicode.utf8ValidateSlice(message)) message else "Lua reported an error with invalid UTF-8.";
}

fn sameRules(old: []const Rule, replacement: []const Rule) bool {
    if (old.len != replacement.len) return false;
    for (old,replacement) |a,b| {
        if (a.prefix != b.prefix or a.excluded != b.excluded or
            !std.mem.eql(u8,a.origin,b.origin) or !std.mem.eql(u8,a.path,b.path)) return false;
    }
    return true;
}

pub fn replace(id: []const u8, source: []const u8) ServiceError!sdk.Script {
    const index = find(id) orelse return error.NotFound;
    var entry = parse(source,false) catch |err| switch (err) {
        error.OutOfMemory => return error.InternalError,
        else => return error.InvalidScript,
    };
    var transferred = false;
    defer if (!transferred) allocator.free(entry.source);
    if (find(&entry.id)) |existing| {
        if (existing != index) return error.AlreadyExists;
        return describe(&scripts[index]);
    }
    var message: [160]u8 = undefined;
    if (!native.moon_lua_check(entry.source.ptr,&message,message.len)) return error.InvalidScript;
    const original = scripts[index];
    if (sameRules(original.rules[0..original.rule_count],entry.rules[0..entry.rule_count])) {
        entry.approved = original.approved;
        entry.enabled = original.enabled;
    }
    scripts[index] = entry;
    if (!save(null)) {
        scripts[index] = original;
        return error.InternalError;
    }
    allocator.free(original.source);
    transferred = true;
    return describe(&scripts[index]);
}

fn confirmScope(entry: *const Script) bool {
    var message: [1800:0]u8 = @splat(0);
    var writer: std.Io.Writer = .fixed(&message);
    writer.print("“{s}”可修改以下匹配网页的内容。允许启用？\n\n", .{text(&entry.name)}) catch return false;
    for (entry.rules[0..entry.rule_count]) |rule| {
        writer.print("{s} {s}{s}{s}\n", .{ if (rule.excluded) "排除" else "允许", rule.origin, rule.path, if (rule.prefix) "*" else "" }) catch return false;
    }
    if (writer.end >= message.len) return false;
    message[writer.end] = 0;
    return native.moon_shell_confirm("启用 Lua 用户脚本", &message);
}

pub fn register(source: []const u8) ServiceError!sdk.Script {
    if (count == scripts.len) return error.LimitExceeded;
    const entry = parse(source, false) catch |err| switch (err) {
        error.OutOfMemory => return error.InternalError,
        else => return error.InvalidScript,
    };
    errdefer allocator.free(entry.source);
    if (find(&entry.id) != null) return error.AlreadyExists;
    var message: [160]u8 = undefined;
    if (!native.moon_lua_check(entry.source.ptr, &message, message.len)) return error.InvalidScript;
    scripts[count] = entry;
    count += 1;
    if (!save(null)) {
        count -= 1;
        return error.InternalError;
    }
    return describe(&scripts[count - 1]);
}

pub fn setEnabled(id: []const u8, enabled: bool, consent: ?Consent) ServiceError!void {
    const initial = find(id) orelse return error.NotFound;
    if (scripts[initial].enabled == enabled) return;
    if (enabled and !scripts[initial].approved) {
        if (!confirmScope(&scripts[initial])) return error.Cancelled;
        if (consent) |check| if (!check.valid(check.context)) return error.Cancelled;
    }
    const index = find(id) orelse return error.NotFound;
    const script = &scripts[index];
    const old_enabled = script.enabled;
    const old_approved = script.approved;
    script.enabled = enabled;
    script.approved = script.approved or enabled;
    if (save(null)) {
        script.last_error[0] = 0;
        return;
    }
    script.enabled = old_enabled;
    script.approved = old_approved;
    return error.InternalError;
}

pub fn unregister(id: []const u8, consent: ?Consent) ServiceError!void {
    if (consent) |check| {
        const script = &scripts[find(id) orelse return error.NotFound];
        var message: [384:0]u8 = undefined;
        _ = std.fmt.bufPrintSentinel(&message,"移除“{s}”？这会删除源码和站点授权，并丢弃未保存的改动。",.{text(&script.name)},0) catch
            return error.InternalError;
        if (!native.moon_shell_confirm("移除 Lua 用户脚本？",&message) or !check.valid(check.context))
            return error.Cancelled;
    }
    const index = find(id) orelse return error.NotFound;
    if (!save(index)) return error.InternalError;
    allocator.free(scripts[index].source);
    for (index..count - 1) |i| scripts[i] = scripts[i + 1];
    count -= 1;
}

fn matches(script: *const Script, origin: []const u8, path: []const u8) bool {
    var allowed = false;
    for (script.rules[0..script.rule_count]) |rule| {
        if (!std.ascii.eqlIgnoreCase(rule.origin, origin)) continue;
        const hit = if (rule.prefix) std.mem.startsWith(u8, path, rule.path) else std.mem.eql(u8, rule.path, path);
        if (!hit) continue;
        if (rule.excluded) return false;
        allowed = true;
    }
    return allowed;
}

fn addressParts(href: []const u8) ?struct { origin: []const u8, path: []const u8 } {
    const start: usize = if (std.mem.startsWith(u8, href, "https://")) 8 else if (std.mem.startsWith(u8, href, "http://")) 7 else return null;
    const slash = start + (std.mem.indexOfScalar(u8, href[start..], '/') orelse return null);
    const relative = href[slash..];
    return .{ .origin = href[0..slash], .path = relative[0 .. std.mem.indexOfAny(u8,relative,"?#") orelse relative.len] };
}

pub fn matchesEnabled(id: []const u8, href: []const u8) bool {
    const script = &scripts[find(id) orelse return false];
    const parts = addressParts(href) orelse return false;
    return script.enabled and matches(script,parts.origin,parts.path);
}

pub fn apply(view: *native.MoonView) void {
    if (count == 0) return;
    var url: [4096:0]u8 = @splat(0);
    native.moon_engine_committed_url(view, &url, url.len);
    const parts = addressParts(text(&url)) orelse return;
    for (scripts[0..count]) |*script| {
        if (script.enabled and matches(script,parts.origin,parts.path)) execute(script, view, &url);
    }
}

const Operation = struct { kind: c_uint, selector: []const u8, value: []const u8 };
fn execute(script: *Script, view: *native.MoonView, href: [*:0]const u8) void {
    var operations: [native.MOON_DOM_MAX_OPS]native.MoonDomOp = undefined;
    const size = native.moon_lua_userscript(script.source.ptr, href, &operations, &script.last_error, script.last_error.len);
    if (size <= 0) return;
    var wire: [native.MOON_DOM_MAX_OPS]Operation = undefined;
    const len: usize = @intCast(size);
    for (operations[0..len], wire[0..len]) |*item, *output| {
        const selector = text(&item.selector);
        const value = text(&item.value);
        if (!std.unicode.utf8ValidateSlice(selector) or !std.unicode.utf8ValidateSlice(value)) {
            const message = "DOM arguments must be UTF-8";
            @memcpy(script.last_error[0..message.len], message);
            script.last_error[message.len] = 0;
            return;
        }
        output.* = .{ .kind = item.kind, .selector = selector, .value = value };
    }
    const ops_json = std.json.Stringify.valueAlloc(allocator, wire[0..len], .{}) catch return;
    defer allocator.free(ops_json);
    const payload = allocator.dupeSentinel(u8, ops_json, 0) catch return;
    defer allocator.free(payload);
    if (!native.moon_engine_apply_lua_dom(view,payload.ptr)) {
        const message = "WebKit DOM bridge unavailable";
        @memcpy(script.last_error[0..message.len],message);
        script.last_error[message.len] = 0;
    }
}
