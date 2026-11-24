const std = @import("std");
const sdk = @import("moon_plugin");
const native = @import("native");
const history = @import("history.zig");
const settings = @import("extension_settings.zig");

pub const owner = "moon.session";
pub const limit = 128;
pub const Entry = struct { url: []const u8, title: []const u8 };
pub const Snapshot = struct { version: u32 = 1, tabs: []const Entry, selected: ?usize = null };

const allocator = std.heap.page_allocator;
var file: [4096:0]u8 = @splat(0);
var preferences: sdk.SessionPreferences = .{};
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
    preferences = std.json.parseFromValueLeaky(sdk.SessionPreferences,arena.allocator(),value,.{}) catch .{};
}

pub fn automatic() bool {
    return preferences.autoRestore;
}

pub fn configure(alloc: std.mem.Allocator, input: sdk.SessionPreferences, value: std.json.Value) bool {
    if (file[0]==0) return false;
    settings.write(alloc,owner,value) catch return false;
    preferences = input;
    return true;
}

pub fn read() ?std.json.Parsed(Snapshot) {
    if (file[0]==0 or restored) return null;
    // A stored URL and title can grow after JSON escaping.
    const data = allocator.alloc(u8,limit*(4096*2+512*6+64)+256) catch return null;
    defer allocator.free(data);
    if (!native.moon_read_text(&file,data.ptr,data.len)) return null;
    const parsed = std.json.parseFromSlice(Snapshot,allocator,std.mem.sliceTo(data,0),.{ .allocate=.alloc_always }) catch return null;
    const snapshot = parsed.value;
    if (snapshot.version!=1 or snapshot.tabs.len>limit) {
        parsed.deinit();
        return null;
    }
    if (snapshot.selected) |selected| {
        if (selected>=snapshot.tabs.len) {
            parsed.deinit();
            return null;
        }
    }
    for (snapshot.tabs) |tab| {
        if (!history.validURL(tab.url) or tab.title.len>=512 or !std.unicode.utf8ValidateSlice(tab.title) or
            std.mem.indexOfScalar(u8,tab.title,0)!=null)
        {
            parsed.deinit();
            return null;
        }
    }
    return parsed;
}

pub fn status() sdk.SessionStatus {
    const snapshot = read() orelse return .{ .autoRestore=preferences.autoRestore,.tabs=0,.alreadyRestored=restored };
    defer snapshot.deinit();
    return .{ .autoRestore=preferences.autoRestore,.tabs=snapshot.value.tabs.len,.alreadyRestored=false };
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
