const std = @import("std");
const sdk = @import("moon_plugin");
const native = @import("native");
const history = @import("history.zig");
const settings = @import("extension_settings.zig");
const tab_groups = @import("tab_groups.zig");

pub const owner = "moon.session";
pub const limit = 128;
pub const Entry = struct { url: []const u8, title: []const u8, group: u32 = 0 };
pub const Snapshot = struct {
    version: u32 = 1, tabs: []const Entry, selected: ?usize = null,
    groups: []const sdk.TabGroup = &.{},
};

const allocator = std.heap.page_allocator;
var file: [4096:0]u8 = @splat(0);
const page_limit = 1024;
const pages_budget = 3072;
pub const PageViews = [sdk.session_startup_limit][]const u8;
var startup_mode: sdk.SessionStartupMode = .newTab;
var startup_pages: [sdk.session_startup_limit][page_limit]u8 = undefined;
var startup_lengths: [sdk.session_startup_limit]usize = @splat(0);
var startup_count: usize = 0;
var restored = false;

pub fn init(profile: []const u8) void {
    if (profile.len==0) return;
    _ = std.fmt.bufPrintSentinel(&file,"{s}\\last-session.json",.{profile},0) catch {
        file[0] = 0;
        return;
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = settings.read(arena.allocator(),owner) catch return;
    const input = std.json.parseFromValueLeaky(sdk.SessionPreferences,arena.allocator(),value,.{}) catch return;
    if (validPreferences(input)) applyPreferences(input);
}

fn requestedMode(input: sdk.SessionPreferences) sdk.SessionStartupMode {
    return input.startupMode orelse if (input.autoRestore) .restore else .newTab;
}

pub fn configure(alloc: std.mem.Allocator, input: sdk.SessionPreferences, value: std.json.Value) bool {
    if (file[0]==0) return false;
    settings.write(alloc,owner,value) catch return false;
    applyPreferences(input);
    return true;
}

pub fn validPreferences(input: sdk.SessionPreferences) bool {
    if (input.startupPages.len>sdk.session_startup_limit or
        (requestedMode(input)==.pages and input.startupPages.len==0)) return false;
    var remaining: usize = pages_budget;
    for (input.startupPages,0..) |url,index| {
        if (url.len>page_limit or url.len>remaining or !history.validURL(url) or
            std.mem.indexOfAny(u8,url," \"\\")!=null) return false;
        const uri = std.Uri.parse(url) catch return false;
        const host = uri.host orelse return false;
        if (host.percent_encoded.len==0) return false;
        for (input.startupPages[0..index]) |prior| if (std.mem.eql(u8,prior,url)) return false;
        remaining -= url.len;
    }
    return true;
}

fn applyPreferences(input: sdk.SessionPreferences) void {
    startup_mode = requestedMode(input);
    startup_count = input.startupPages.len;
    for (input.startupPages,0..) |url,index| {
        @memcpy(startup_pages[index][0..url.len],url);
        startup_lengths[index] = url.len;
    }
}

pub fn mode() sdk.SessionStartupMode {
    return startup_mode;
}

pub fn pages(buffer: *PageViews) []const []const u8 {
    for (buffer[0..startup_count],0..) |*url,index|
        url.* = startup_pages[index][0..startup_lengths[index]];
    return buffer[0..startup_count];
}

pub fn read() ?std.json.Parsed(Snapshot) {
    if (file[0]==0 or restored) return null;
    // A stored URL and title can grow after JSON escaping.
    const data = allocator.alloc(u8,limit*(4096*2+512*6+80)+tab_groups.limit*(6*tab_groups.name_limit+96)+256) catch return null;
    defer allocator.free(data);
    if (!native.moon_read_text(&file,data.ptr,data.len)) return null;
    const parsed = std.json.parseFromSlice(Snapshot,allocator,std.mem.sliceTo(data,0),.{ .allocate=.alloc_always }) catch return null;
    const snapshot = parsed.value;
    if (snapshot.version!=1 or snapshot.tabs.len>limit or snapshot.groups.len>tab_groups.limit) {
        parsed.deinit();
        return null;
    }
    for (snapshot.groups,0..) |group,index| {
        if (group.id==0 or !tab_groups.validName(group.name)) {
            parsed.deinit();
            return null;
        }
        for (snapshot.groups[0..index]) |prior| if (prior.id==group.id) {
            parsed.deinit();
            return null;
        };
    }
    if (snapshot.selected) |selected| {
        if (selected>=snapshot.tabs.len) {
            parsed.deinit();
            return null;
        }
    }
    var seen_groups: [tab_groups.limit]bool = @splat(false);
    var previous_group: u32 = 0;
    for (snapshot.tabs) |tab| {
        if (!history.validURL(tab.url) or tab.title.len>=512 or !std.unicode.utf8ValidateSlice(tab.title) or
            std.mem.indexOfScalar(u8,tab.title,0)!=null)
        {
            parsed.deinit();
            return null;
        }
        if (tab.group!=0 and tab.group!=previous_group) {
            for (snapshot.groups,0..) |group,index| {
                if (group.id!=tab.group) continue;
                if (seen_groups[index]) {
                    parsed.deinit();
                    return null;
                }
                seen_groups[index]=true;
                break;
            } else {
                parsed.deinit();
                return null;
            }
        }
        previous_group=tab.group;
    }
    return parsed;
}

pub fn status(buffer: *PageViews) sdk.SessionStatus {
    var state: sdk.SessionStatus = .{ .autoRestore=startup_mode==.restore,.tabs=0,.alreadyRestored=restored,
        .startupMode=startup_mode,.startupPages=pages(buffer) };
    const snapshot = read() orelse return state;
    defer snapshot.deinit();
    state.tabs = snapshot.value.tabs.len;
    return state;
}

pub fn markRestored() void {
    restored = true;
}

pub fn save(snapshot: Snapshot) bool {
    if (file[0]==0) return false;
    const bytes = std.json.Stringify.valueAlloc(allocator,snapshot,.{}) catch return false;
    defer allocator.free(bytes);
    const text = allocator.dupeSentinel(u8,bytes,0) catch return false;
    defer allocator.free(text);
    return native.moon_write_text(&file,text.ptr);
}

pub fn forget() bool {
    if (file[0]==0) return true;
    if (!save(.{ .tabs=&.{} })) return false;
    restored = false;
    return true;
}
