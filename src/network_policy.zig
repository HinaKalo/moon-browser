const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");
const settings = @import("extension_settings.zig");

pub const Source = struct { id: []const u8, executable: []const u8, filename: []const u8 };
const Cosmetic = struct { host: []const u8, selector: []const u8 };
const Policy = struct { requests: [:0]const u8, script: [:0]const u8 };
const allocator = std.heap.page_allocator;
const policy_limit = 128 * 1024 - 1;
const exception_limit = 32;
var selected: ?Source = null;
var active = false;

fn validHost(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;
    var labels = std.mem.splitScalar(u8,host,'.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len-1] == '-') return false;
        for (label) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return false;
    }
    return true;
}

fn exceptions(alloc: std.mem.Allocator, value: std.json.Value) ![][]const u8 {
    const stored = value.object.get("pausedSites") orelse return try alloc.alloc([]const u8,0);
    if (stored != .array or stored.array.items.len > exception_limit) return error.InvalidRules;
    const hosts = try alloc.alloc([]const u8,stored.array.items.len);
    for (stored.array.items,hosts) |item,*host| {
        if (item != .string or !validHost(item.string)) return error.InvalidRules;
        host.* = item.string;
    }
    return hosts;
}

fn makePolicy(alloc: std.mem.Allocator, source: Source, paused: []const []const u8) !Policy {
    var path: [4096]u8 = undefined;
    const separator = std.mem.lastIndexOfScalar(u8,source.executable,'\\') orelse return error.InvalidRules;
    const filename = try std.fmt.bufPrintSentinel(&path,"{s}\\{s}",.{source.executable[0..separator],source.filename},0);
    const buffer = try alloc.alloc(u8,policy_limit+1);
    if (!native.moon_read_plain_text(filename.ptr,buffer.ptr,buffer.len)) return error.InvalidRules;
    var lines = std.mem.tokenizeAny(u8,std.mem.sliceTo(buffer,0),"\r\n");
    var output: std.ArrayList(u8) = .empty;
    var cosmetics: std.ArrayList(Cosmetic) = .empty;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8,raw_line," \t");
        if (line.len == 0 or line[0] == '#') continue;
        switch (line[0]) {
            '-' => if (!validHost(line[1..])) return error.InvalidRules,
            '@' => {
                const tab = std.mem.indexOfScalar(u8,line,'\t') orelse return error.InvalidRules;
                const prefix = line[tab+1..];
                if (!validHost(line[1..tab]) or prefix.len == 0 or prefix.len > 1024 or prefix[0] != '/') return error.InvalidRules;
                for (prefix) |ch| if (ch < 33 or ch >= 127 or ch == '#' or ch == '?') return error.InvalidRules;
            },
            '+' => {
                const tab = std.mem.indexOfScalar(u8,line,'\t') orelse return error.InvalidRules;
                const selector = line[tab+1..];
                if (!validHost(line[1..tab]) or selector.len == 0 or selector.len > 256 or cosmetics.items.len == 128)
                    return error.InvalidRules;
                for (selector) |ch| if (ch < 32 or ch >= 127 or ch == '{' or ch == '}' or ch == ';' or ch == '@' or ch == '\\')
                    return error.InvalidRules;
                try cosmetics.append(alloc,.{ .host=line[1..tab],.selector=selector });
                continue;
            },
            else => return error.InvalidRules,
        }
        try output.appendSlice(alloc,line);
        try output.append(alloc,'\n');
    }
    if (output.items.len == 0 and cosmetics.items.len == 0) return error.InvalidRules;
    for (paused) |host| {
        try output.append(alloc,'!');
        try output.appendSlice(alloc,host);
        try output.append(alloc,'\n');
    }
    if (output.items.len >= policy_limit) return error.InvalidRules;
    return .{
        .requests=try alloc.dupeSentinel(u8,output.items,0),
        .script=if (cosmetics.items.len == 0) "" else try cosmeticScript(alloc,cosmetics.items,paused),
    };
}

fn cosmeticScript(alloc: std.mem.Allocator, rules: []const Cosmetic, paused: []const []const u8) ![:0]u8 {
    const rule_data = try std.json.Stringify.valueAlloc(alloc,rules,.{});
    const paused_data = try std.json.Stringify.valueAlloc(alloc,paused,.{});
    const script =
        \\((rules, paused) => {
        \\  const host = location.hostname.toLowerCase().replace(/\.$/, '');
        \\  if (paused.some(value => host === value || host.endsWith('.' + value))) return;
        \\  const css = rules.filter(rule => host === rule.host).map(rule => rule.selector + '{display:none!important}').join('\n');
        \\  if (!css) return;
        \\  const sheet = new CSSStyleSheet();
        \\  sheet.replaceSync(css);
        \\  document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        \\})
    ;
    return std.fmt.allocPrintSentinel(alloc,"{s}({s},{s});",.{ script,rule_data,paused_data },0);
}

pub fn select(source: ?Source) void {
    if (source == null and selected == null) return;
    selected = source;
    active = false;
    const config = source orelse {
        _ = native.moon_engine_set_request_policy("","");
        return;
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();
    const value = settings.read(temp,config.id) catch return;
    const paused = exceptions(temp,value) catch return;
    const policy = makePolicy(temp,config,paused) catch return;
    active = native.moon_engine_set_request_policy(policy.requests.ptr,policy.script.ptr);
}

pub fn mayNavigate() bool {
    return selected == null or active;
}

fn isOwner(id: []const u8) bool {
    return if (selected) |source| std.mem.eql(u8,source.id,id) else false;
}

pub fn status(alloc: std.mem.Allocator, id: []const u8) !sdk.NetworkFilterStatus {
    const owner = isOwner(id);
    return .{
        .preferred=owner,.active=owner and active,
        .exceptions=try exceptions(alloc,try settings.read(alloc,id)),
    };
}

pub fn boundSite(alloc: std.mem.Allocator, origin: []const u8) !?struct { owner: []const u8, info: sdk.SiteFiltering } {
    const source = selected orelse return null;
    if (!active) return null;
    const uri = std.Uri.parse(origin) catch return null;
    const component = uri.host orelse return null;
    const raw = try component.toRawMaybeAlloc(alloc);
    const hostname = if (std.mem.endsWith(u8,raw,".")) raw[0..raw.len-1] else raw;
    const host = try alloc.dupe(u8,hostname);
    _ = std.ascii.lowerString(host,host);
    if (!validHost(host)) return null;
    const value = try settings.read(alloc,source.id);
    const paused = try exceptions(alloc,value);
    var exact = false;
    var ancestor: ?[]const u8 = null;
    for (paused) |candidate| {
        if (std.mem.eql(u8,host,candidate)) exact=true;
        if (host.len<=candidate.len or !std.mem.endsWith(u8,host,candidate)) continue;
        if (host[host.len-candidate.len-1]!='.') continue;
        if (ancestor==null or candidate.len>ancestor.?.len) ancestor=candidate;
    }
    return .{
        .owner=try alloc.dupe(u8,source.id),
        .info=.{
            .host=host,
            .state=if (ancestor!=null) .inherited else if (exact) .paused else .filtering,
            .pausedBy=ancestor,
        },
    };
}

pub fn setSite(alloc: std.mem.Allocator, id: []const u8, site: sdk.NetworkFilterSite) !void {
    if (!isOwner(id)) return error.NotSelected;
    const host = try alloc.dupe(u8,std.mem.trim(u8,site.host," \t"));
    _ = std.ascii.lowerString(host,host);
    if (!validHost(host)) return error.InvalidHost;
    var value = try settings.read(alloc,id);
    const before = try exceptions(alloc,value);
    var next: std.ArrayList([]const u8) = .empty;
    var present = false;
    for (before) |candidate| {
        if (std.mem.eql(u8,host,candidate)) {
            present = true;
            if (site.enabled) continue;
        }
        try next.append(alloc,candidate);
    }
    if (!site.enabled and !present) {
        if (next.items.len == exception_limit) return error.LimitExceeded;
        try next.append(alloc,host);
    }
    const source = selected.?;
    const policy = try makePolicy(alloc,source,next.items);
    var list: std.array_list.Managed(std.json.Value) = .init(alloc);
    for (next.items) |candidate| try list.append(.{ .string=candidate });
    try value.object.put(alloc,"pausedSites",.{ .array=list });
    if (!native.moon_engine_set_request_policy(policy.requests.ptr,policy.script.ptr)) return error.IOError;
    settings.write(alloc,id,value) catch |err| {
        const previous = makePolicy(alloc,source,before) catch return err;
        _ = native.moon_engine_set_request_policy(previous.requests.ptr,previous.script.ptr);
        return err;
    };
    active = true;
}
