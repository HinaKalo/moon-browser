const std = @import("std");
const sdk = @import("moon_plugin");
const settings = @import("extension_settings.zig");

pub const owner = "moon.search";
pub const builtins = [_]sdk.SearchEngine{
    .{ .alias="g", .name="Google", .template="https://www.google.com/search?q={query}" },
    .{ .alias="b", .name="Bing", .template="https://www.bing.com/search?q={query}" },
    .{ .alias="ddg", .name="DuckDuckGo", .template="https://duckduckgo.com/?q={query}" },
    .{ .alias="bd", .name="百度", .template="https://www.baidu.com/s?wd={query}" },
};
const marker = "{query}";
const StoredEngine = struct {
    alias: [17:0]u8 = @splat(0),
    name: [65:0]u8 = @splat(0),
    template: [481:0]u8 = @splat(0),
};
const State = struct {
    preferred: [17:0]u8 = @splat(0),
    custom: [sdk.search_custom_limit]StoredEngine = @splat(.{}),
    count: usize = 0,
    suggest_history: bool = true,
    suggest_bookmarks: bool = true,
};
var active: State = .{};

fn text(bytes: anytype) []const u8 {
    return std.mem.sliceTo(bytes,0);
}

fn store(buffer: []u8, value: []const u8) void {
    @memcpy(buffer[0..value.len],value);
    buffer[value.len] = 0;
}

fn validAlias(alias: []const u8) bool {
    if (alias.len==0 or alias.len>16 or !std.ascii.isAlphanumeric(alias[0])) return false;
    for (alias) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch!='-') return false;
    return true;
}

fn validTemplate(template: []const u8) bool {
    if (template.len>480 or !std.ascii.startsWithIgnoreCase(template,"https://")) return false;
    for (template) |ch| if (ch<=0x20 or ch>=0x7f or std.mem.indexOfScalar(u8,"\\\"<>",ch)!=null) return false;
    const at = std.mem.indexOf(u8,template,marker) orelse return false;
    if (std.mem.indexOf(u8,template[at+marker.len..],marker)!=null) return false;
    const start = std.mem.indexOfScalar(u8,template,'?') orelse return false;
    if (start>=at or std.mem.indexOfScalar(u8,template,'#')!=null) return false;
    const parameter = std.mem.lastIndexOfScalar(u8,template[start..at],'&') orelse 0;
    const key = template[start+parameter+1..at];
    const assign = std.mem.indexOfScalar(u8,key,'=') orelse return false;
    if (assign==0) return false;
    var check: [481]u8 = undefined;
    const candidate = std.fmt.bufPrint(&check,"{s}x{s}",.{template[0..at],template[at+marker.len..]}) catch return false;
    const uri = std.Uri.parse(candidate) catch return false;
    const host = uri.host orelse return false;
    return !host.isEmpty() and uri.user==null and uri.password==null and uri.port!=@as(?u16,0);
}

fn templateFor(state: *const State, alias: []const u8) ?[]const u8 {
    for (builtins) |engine| if (std.ascii.eqlIgnoreCase(alias,engine.alias)) return engine.template;
    for (state.custom[0..state.count]) |*engine| {
        if (std.ascii.eqlIgnoreCase(alias,text(&engine.alias))) return text(&engine.template);
    }
    return null;
}

fn validated(config: sdk.SearchConfig, next: *State) sdk.SearchSave {
    if (config.custom.len>sdk.search_custom_limit) return .tooMany;
    for (config.custom) |engine| {
        if (!validAlias(engine.alias)) return .invalidAlias;
        if (templateFor(next,engine.alias)!=null) return .duplicateAlias;
        if (engine.name.len==0 or engine.name.len>64 or std.mem.trim(u8,engine.name," ").len==0 or
            !std.unicode.utf8ValidateSlice(engine.name)) return .invalidName;
        for (engine.name) |ch| if (std.ascii.isControl(ch)) return .invalidName;
        if (!validTemplate(engine.template)) return .invalidTemplate;
        const slot = &next.custom[next.count];
        store(&slot.alias,engine.alias);
        store(&slot.name,engine.name);
        store(&slot.template,engine.template);
        next.count += 1;
    }
    if (!validAlias(config.preferred) or templateFor(next,config.preferred)==null) return .invalidDefault;
    store(&next.preferred,config.preferred);
    next.suggest_history = config.suggestHistory orelse active.suggest_history;
    next.suggest_bookmarks = config.suggestBookmarks orelse active.suggest_bookmarks;
    return .saved;
}

pub fn init() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value = settings.read(allocator,owner) catch return;
    const config = std.json.parseFromValueLeaky(sdk.SearchConfig,allocator,value,.{}) catch return;
    var next: State = .{};
    if (validated(config,&next)==.saved) active = next;
}

pub fn get(buffer: *[sdk.search_custom_limit]sdk.SearchEngine) sdk.SearchConfig {
    for (active.custom[0..active.count],buffer[0..active.count]) |*engine,*slot| {
        slot.* = .{ .alias=text(&engine.alias), .name=text(&engine.name), .template=text(&engine.template) };
    }
    const preferred = text(&active.preferred);
    return .{ .preferred=if (preferred.len!=0) preferred else "g", .custom=buffer[0..active.count],
        .suggestHistory=active.suggest_history,.suggestBookmarks=active.suggest_bookmarks };
}

pub fn suggestionSources() struct { history: bool, bookmarks: bool } {
    return .{ .history=active.suggest_history,.bookmarks=active.suggest_bookmarks };
}

pub fn save(allocator: std.mem.Allocator, config: sdk.SearchConfig, value: std.json.Value) sdk.SearchSave {
    var next: State = .{};
    const status = validated(config,&next);
    if (status!=.saved) return status;
    var saved=value;
    saved.object.put(allocator,"suggestHistory",.{ .bool=next.suggest_history }) catch return .unavailable;
    saved.object.put(allocator,"suggestBookmarks",.{ .bool=next.suggest_bookmarks }) catch return .unavailable;
    settings.write(allocator,owner,saved) catch return .unavailable;
    active = next;
    return .saved;
}

pub fn resolve(input: []const u8, buffer: []u8, enabled: bool) ?[:0]const u8 {
    var template = if (enabled) templateFor(&active,text(&active.preferred)) orelse builtins[0].template else builtins[0].template;
    var query = input;
    if (enabled and input[0]=='@') {
        if (std.mem.indexOfScalar(u8,input,' ')) |space| {
            if (templateFor(&active,input[1..space])) |engine| {
                query = std.mem.trim(u8,input[space+1..]," ");
                if (query.len==0) return null;
                template = engine;
            }
        }
    }
    const at = std.mem.indexOf(u8,template,marker).?;
    const tail = template[at+marker.len..];
    if (buffer.len<=at+tail.len) return null;
    @memcpy(buffer[0..at],template[0..at]);
    var len = at;
    const end = buffer.len-tail.len-1;
    const hex = "0123456789ABCDEF";
    for (query) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8,"-._~",ch)!=null) {
            if (len==end) return null;
            buffer[len] = ch;
            len += 1;
        } else {
            if (end-len<3) return null;
            buffer[len..][0..3].* = .{ '%', hex[ch>>4], hex[ch&15] };
            len += 3;
        }
    }
    @memcpy(buffer[len..][0..tail.len],tail);
    len += tail.len;
    buffer[len] = 0;
    return buffer[0..len :0];
}
