const std = @import("std");
const sdk = @import("moon_plugin");
const native = @import("native");

const Entry = struct { name: []const u8, value: []const u8, shortened: bool };
const Group = struct { entries: []Entry, more: bool };
const Snapshot = struct { cookies: ?Group, local: ?Group, session: ?Group };
const allocator = std.heap.page_allocator;
var captured: ?std.json.Parsed(Snapshot) = null;
var source: u64 = 0;
var panel: u64 = 0;
var sequence: u64 = 0;
var received: sdk.SiteDataState = .idle;
var failure: ?sdk.SiteDataFailure = null;
var deadline: u64 = 0;
var owner: [96]u8 = undefined;
var owner_len: usize = 0;
var origin: [4096]u8 = undefined;
var origin_len: usize = 0;

fn dropValues() void {
    if (captured) |result| result.deinit();
    captured = null;
}

pub fn reset() void {
    dropValues();
    source=0;
    panel=0;
    owner_len=0;
    origin_len=0;
    received=.idle;
    failure=null;
}

pub fn invalidate(tab: u64) void {
    if (source != tab) return;
    dropValues();
    source=0;
    received=.stale;
    failure=null;
}

pub fn closed(tab: u64) void {
    if (panel == tab) reset() else invalidate(tab);
}

pub fn owns(tab: u64, id: []const u8) bool {
    return tab != 0 and tab == panel and std.mem.eql(u8,id,owner[0..owner_len]);
}
pub fn ownerId() ?[]const u8 {
    return if (owner_len == 0) null else owner[0..owner_len];
}

pub fn selected(tab: u64, id: []const u8) ?u64 {
    if (!owns(tab,id) or source == 0) return null;
    return source;
}

pub fn protected(tab: u64, active: u64) bool {
    return source==tab and (received == .pending or (received == .ready and active==panel));
}

pub fn begin(id: []const u8, target: u64, address_origin: []const u8, view: *native.MoonView) void {
    reset();
    @memcpy(owner[0..id.len],id);
    owner_len=id.len;
    @memcpy(origin[0..address_origin.len],address_origin);
    origin_len=address_origin.len;
    source=target;
    _ = request(view);
}

pub fn bindPanel(tab: u64) void {
    panel=tab;
}

pub fn request(view: *native.MoonView) bool {
    dropValues();
    sequence+=1;
    deadline=native.moon_clock()+5000;
    received=.pending;
    failure=null;
    if (!native.moon_engine_inspect_site(view,sequence)) {
        received=.unavailable;
        failure=.engineUnavailable;
    }
    return received == .pending;
}

pub fn complete(tab: u64, token: u64, json: []const u8) void {
    if (tab != source or token != sequence or received != .pending) return;
    received=.unavailable;
    failure=.invalidResult;
    if (json.len > 2 and json[0] == '"' and json[json.len-1] == '"') {
        failure=std.meta.stringToEnum(sdk.SiteDataFailure,json[1..json.len-1]) orelse .invalidResult;
        return;
    }
    const result = std.json.parseFromSlice(Snapshot,allocator,json,.{ .allocate=.alloc_always }) catch return;
    inline for (.{ result.value.cookies,result.value.local,result.value.session }) |maybe| {
        if (maybe) |group| {
            if (group.entries.len > 32) {
                result.deinit();
                return;
            }
            for (group.entries) |item| {
                if (item.name.len > 512 or item.value.len > 2048) {
                    result.deinit();
                    return;
                }
            }
        }
    }
    captured=result;
    received=.ready;
    failure=null;
    deadline=native.moon_clock()+5*60*1000;
}

pub fn tick(now: u64) void {
    if (received == .pending and now >= deadline) {
        received=.unavailable;
        failure=.timedOut;
    } else if (received == .ready and now >= deadline) {
        dropValues();
        received=.expired;
    }
}

fn resolve(kind: sdk.SiteDataGroup) ?Group {
    const result=captured orelse return null;
    return switch (kind) {
        .cookies => result.value.cookies,
        .local => result.value.local,
        .session => result.value.session,
    };
}

pub fn status(tab: u64, id: []const u8) sdk.SiteDataStatus {
    if (!owns(tab,id)) return .{ .state=.idle,.origin="",.generation=0 };
    return .{ .state=received,.origin=origin[0..origin_len],.generation=sequence,.failure=failure };
}

pub fn list(tab: u64, id: []const u8, kind: sdk.SiteDataGroup, buffer: *[32]sdk.SiteDataEntry) ?sdk.SiteDataPage {
    if (!owns(tab,id) or received != .ready) return null;
    const group=resolve(kind) orelse return .{ .available=false,.entries=&.{},.more=false,.generation=sequence };
    for (group.entries,0..) |item,index| buffer[index]=.{
        .id=@intCast(index),.name=item.name,.length=item.value.len,.shortened=item.shortened,
    };
    return .{ .available=true,.entries=buffer[0..group.entries.len],.more=group.more,.generation=sequence };
}

pub fn value(tab: u64, id: []const u8, target: sdk.SiteDataItem) ?[]const u8 {
    if (!owns(tab,id) or received != .ready or target.generation != sequence) return null;
    const group=resolve(target.group) orelse return null;
    if (target.id >= group.entries.len) return null;
    return group.entries[target.id].value;
}
