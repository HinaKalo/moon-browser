const std = @import("std");
const native = @import("native");

const allocator = std.heap.page_allocator;
const max_source = 16 * 1024;
const max_scripts = 16;
const Stored = struct { source: []const u8, enabled: bool };

const Rule = struct {
    origin: []const u8,
    path: []const u8,
    prefix: bool,
    excluded: bool,
};

const Script = struct {
    source: [:0]u8,
    name: [96:0]u8 = @splat(0),
    rules: [8]Rule = undefined,
    rule_count: usize = 0,
    enabled: bool,
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
        scripts[count] = parse(entry.source, entry.enabled) catch continue;
        count += 1;
    }
}

fn save(excluded: ?usize) bool {
    var items: [max_scripts]Stored = undefined;
    var size: usize = 0;
    for (scripts[0..count], 0..) |*script, index| {
        if (excluded == index) continue;
        items[size] = .{ .source = script.source, .enabled = script.enabled };
        size += 1;
    }
    const json = std.json.Stringify.valueAlloc(allocator, items[0..size], .{}) catch return false;
    defer allocator.free(json);
    const terminated = allocator.dupeSentinel(u8, json, 0) catch return false;
    defer allocator.free(terminated);
    return native.moon_write_text(&store, terminated.ptr);
}

pub fn install(path: []const u8) void {
    if (count == scripts.len) {
        native.moon_shell_info("Lua 用户脚本", "已达到 16 个脚本上限。");
        return;
    }
    const file = allocator.dupeSentinel(u8, path, 0) catch return;
    defer allocator.free(file);
    var buffer: [max_source + 4]u8 = undefined;
    if (!native.moon_read_text(file.ptr, &buffer, buffer.len)) {
        native.moon_shell_info("Lua 用户脚本", "无法读取脚本。请选择不超过 16 KiB 的 UTF-8 Lua 文件。");
        return;
    }
    const entry = parse(text(&buffer), true) catch {
        native.moon_shell_info("Lua 用户脚本", "脚本格式无效。请检查 @name、@api 1 和 @match。");
        return;
    };
    var installed = false;
    defer if (!installed) allocator.free(entry.source);
    for (scripts[0..count]) |*existing| {
        if (std.mem.eql(u8, existing.source, entry.source)) {
            native.moon_shell_info("Lua 用户脚本", "此脚本已安装。");
            return;
        }
    }
    var message: [1800:0]u8 = @splat(0);
    if (!native.moon_lua_check(entry.source.ptr, &message, message.len)) {
        native.moon_shell_info("Lua 用户脚本语法错误", &message);
        return;
    }
    var writer: std.Io.Writer = .fixed(&message);
    writer.print("“{s}”可修改以下匹配网页的内容。安装并启用？\n\n", .{text(&entry.name)}) catch return;
    for (entry.rules[0..entry.rule_count]) |rule| {
        writer.print("{s} {s}{s}{s}\n", .{ if (rule.excluded) "排除" else "允许", rule.origin, rule.path, if (rule.prefix) "*" else "" }) catch return;
    }
    if (writer.end >= message.len) return;
    message[writer.end] = 0;
    if (!native.moon_shell_confirm("安装 Lua 用户脚本", &message)) return;
    if (count == scripts.len) return;
    scripts[count] = entry;
    count += 1;
    if (!save(null)) {
        count -= 1;
        native.moon_shell_info("Lua 用户脚本", "无法保存到浏览器配置。");
        return;
    }
    installed = true;
}

pub fn toggle(index: usize) void {
    if (index >= count) return;
    const script = &scripts[index];
    script.enabled = !script.enabled;
    if (save(null)) {
        script.last_error[0] = 0;
        return;
    }
    script.enabled = !script.enabled;
    native.moon_shell_info("Lua 用户脚本", "无法保存到浏览器配置。");
}

pub fn remove(index: usize) void {
    if (index >= count or !native.moon_shell_confirm("移除 Lua 用户脚本？", &scripts[index].name)) return;
    if (!save(index)) {
        native.moon_shell_info("Lua 用户脚本", "无法保存到浏览器配置。");
        return;
    }
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

pub fn apply(view: *native.MoonView) void {
    if (count == 0) return;
    var url: [4096:0]u8 = @splat(0);
    native.moon_engine_committed_url(view, &url, url.len);
    const href = text(&url);
    const start: usize = if (std.mem.startsWith(u8, href, "https://")) 8 else if (std.mem.startsWith(u8, href, "http://")) 7 else return;
    const slash = start + (std.mem.indexOfScalar(u8, href[start..], '/') orelse return);
    const relative = href[slash..];
    const path = relative[0 .. std.mem.indexOfAny(u8, relative, "?#") orelse relative.len];
    for (scripts[0..count]) |*script| {
        if (script.enabled and matches(script, href[0..slash], path)) execute(script, view, &url);
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
    const url_json = std.json.Stringify.valueAlloc(allocator, text(href), .{}) catch return;
    defer allocator.free(url_json);
    const ops_json = std.json.Stringify.valueAlloc(allocator, wire[0..len], .{}) catch return;
    defer allocator.free(ops_json);
    const apply_operations =
        \\for (const op of ops) {
        \\  try {
        \\    const nodes = document.querySelectorAll(op.selector);
        \\    for (let i = 0; i < nodes.length && i < 64; i++) {
        \\      const node = nodes[i];
        \\      if (op.kind === 1 && !node.matches('script,style,iframe,object,template')) node.textContent = op.value;
        \\      if (op.kind === 2) node.hidden = true;
        \\      if (op.kind === 3) node.classList.add(op.value);
        \\    }
        \\  } catch {}
        \\}
    ;
    const javascript = std.fmt.allocPrintSentinel(allocator,
        "if (location.href !== {s} || document.contentType !== 'text/html') return;\nconst ops = {s};\n{s}",
        .{ url_json, ops_json, apply_operations }, 0) catch return;
    defer allocator.free(javascript);
    native.moon_engine_apply_dom(view, javascript.ptr);
}

export fn moon_userscript_count() usize {
    return count;
}
export fn moon_userscript_label(index: usize) [*:0]const u8 {
    return if (index < count) &scripts[index].name else "";
}
export fn moon_userscript_error(index: usize) [*:0]const u8 {
    return if (index < count) &scripts[index].last_error else "";
}
export fn moon_userscript_enabled(index: usize) bool {
    return index < count and scripts[index].enabled;
}
