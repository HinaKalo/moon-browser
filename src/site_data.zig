const std = @import("std");
const sdk = @import("moon_plugin");
const native = @import("native");
const cookie_store = @import("cookie_store.zig");

const Entry = struct { name: []const u8, value: []const u8, shortened: bool };
const Group = struct { entries: []Entry, more: bool };
const Snapshot = struct { cookies: ?Group, local: ?Group, session: ?Group, mutation: ?sdk.SiteDataMutation = null };
const Catalog = struct {
    indexedDB: @FieldType(sdk.SiteStorageCatalog,"indexedDB"),
    cacheStorage: @FieldType(sdk.SiteStorageCatalog,"cacheStorage"),
};
const allocator = std.heap.page_allocator;
var captured: ?std.json.Parsed(Snapshot) = null;
var cookies: ?cookie_store.Snapshot = null;
var catalog: ?std.json.Parsed(Catalog) = null;
var catalog_deadline: ?u64 = null;
var catalog_requested = false;
var source: u64 = 0;
var panel: u64 = 0;
var sequence: u64 = 0;
var received: sdk.SiteDataState = .idle;
var failure: ?sdk.SiteDataFailure = null;
var mutation: ?sdk.SiteDataMutation = null;
var deadline: u64 = 0;
var owner: [96]u8 = undefined;
var owner_len: usize = 0;
var origin: [4096]u8 = undefined;
var origin_len: usize = 0;

fn dropValues() void {
    if (captured) |result| result.deinit();
    captured = null;
    dropCookies();
    if (catalog) |result| result.deinit();
    catalog = null;
    catalog_deadline = null;
    catalog_requested = false;
}

pub fn dropCookies() void {
    if (cookies) |*snapshot| snapshot.deinit();
    cookies = null;
}

pub fn reset() void {
    dropValues();
    source=0;
    panel=0;
    owner_len=0;
    origin_len=0;
    received=.idle;
    failure=null;
    mutation=null;
}

pub fn invalidate(tab: u64) void {
    if (source != tab) return;
    dropValues();
    source=0;
    received=.stale;
    failure=null;
    mutation=null;
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

fn startRequest() void {
    dropValues();
    sequence+=1;
    deadline=native.moon_clock()+5000;
    received=.pending;
    failure=null;
    mutation=null;
}

fn failedRequest() void {
    received=.unavailable;
    failure=.engineUnavailable;
}

pub fn request(view: *native.MoonView) bool {
    startRequest();
    if (!native.moon_engine_inspect_site(view,sequence)) failedRequest();
    return received == .pending;
}

pub fn update(view: *native.MoonView, tab: u64, id: []const u8, target: sdk.SiteDataItem, replacement: ?[]const u8) bool {
    if (!canMutate(tab,id,target.group,target.generation)) return false;
    if (replacement) |bytes| {
        if (bytes.len>sdk.site_data_value_limit or !std.unicode.utf8ValidateSlice(bytes)) return false;
    }
    const group = resolve(target.group) orelse return false;
    if (target.id>=group.entries.len) return false;
    const entry = group.entries[target.id];
    if (entry.shortened) return false;
    return mutate(view,.{ .group=target.group,.key=entry.name,.previous=entry.value,.replacement=replacement });
}

pub fn canMutate(tab: u64, id: []const u8, group: sdk.SiteDataGroup, generation: u64) bool {
    return owns(tab,id) and received==.ready and generation==sequence and group!=.cookies and resolve(group)!=null;
}

pub fn create(view: *native.MoonView, tab: u64, id: []const u8, target: sdk.SiteDataCreate) bool {
    if (!canMutate(tab,id,target.group,target.generation)) return false;
    if (target.key.len>sdk.site_data_key_limit or target.value.len>sdk.site_data_value_limit or
        !std.unicode.utf8ValidateSlice(target.key) or !std.unicode.utf8ValidateSlice(target.value)) return false;
    return mutate(view,.{ .group=target.group,.key=target.key,.replacement=target.value });
}

pub fn clear(view: *native.MoonView, tab: u64, id: []const u8, group: sdk.SiteDataGroup, generation: u64) bool {
    if (!canMutate(tab,id,group,generation)) return false;
    return mutate(view,.{ .group=group,.clear=true });
}

const Mutation = struct {
    revision: []const u8 = "",
    group: sdk.SiteDataGroup,
    key: []const u8 = "",
    previous: ?[]const u8 = null,
    replacement: ?[]const u8 = null,
    clear: bool = false,
};

fn mutate(view: *native.MoonView, change: Mutation) bool {
    var number: [24]u8 = undefined;
    var payload_data = change;
    payload_data.revision = std.fmt.bufPrint(&number,"{d}",.{sequence}) catch unreachable;
    const bytes = std.json.Stringify.valueAlloc(allocator,payload_data,.{}) catch return false;
    defer allocator.free(bytes);
    const payload = allocator.dupeSentinel(u8,bytes,0) catch return false;
    defer allocator.free(payload);
    startRequest();
    if (!native.moon_engine_update_site(view,sequence,payload.ptr)) failedRequest();
    return received==.pending;
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
    mutation=result.value.mutation;
    deadline=native.moon_clock()+5*60*1000;
}

pub fn tick(now: u64) void {
    if (catalog_deadline) |expires| {
        if (now >= expires) catalog_deadline = null;
    }
    if (received == .pending and now >= deadline) {
        received=.unavailable;
        failure=.timedOut;
    } else if (received == .ready and now >= deadline) {
        dropValues();
        received=.expired;
    }
}

pub fn requestCatalog(view: *native.MoonView) void {
    if (received!=.ready or catalog_requested) return;
    catalog_requested = true;
    catalog_deadline = native.moon_clock()+5000;
    if (!native.moon_engine_inspect_catalog(view,sequence)) catalog_deadline = null;
}

pub fn completeCatalog(tab: u64, token: u64, json: []const u8) void {
    if (tab != source or token != sequence or received != .ready or catalog_deadline == null) return;
    catalog_deadline = null;
    const parsed = std.json.parseFromSlice(Catalog,allocator,json,.{ .allocate=.alloc_always }) catch return;
    inline for (.{ parsed.value.indexedDB,parsed.value.cacheStorage }) |maybe| {
        if (maybe) |section| {
            if (section.entries.len>32) {
                parsed.deinit();
                return;
            }
            for (section.entries) |entry| {
                if (entry.name.len>512) {
                    parsed.deinit();
                    return;
                }
            }
        }
    }
    catalog = parsed;
}

pub fn catalogStatus(tab: u64, id: []const u8, group: sdk.SiteCatalogGroup) ?sdk.SiteStorageCatalog {
    if (!owns(tab,id) or received != .ready or !catalog_requested) return null;
    if (catalog) |result| return .{ .state=.ready,.generation=sequence,
        .indexedDB=if (group==.indexedDB) result.value.indexedDB else null,
        .cacheStorage=if (group==.cacheStorage) result.value.cacheStorage else null };
    return .{ .state=if (catalog_deadline!=null) .pending else .unavailable,.generation=sequence };
}

fn resolve(kind: sdk.SiteDataGroup) ?Group {
    const result=captured orelse return null;
    return switch (kind) {
        .cookies => result.value.cookies,
        .local => result.value.local,
        .session => result.value.session,
    };
}

pub fn status(tab: u64, id: []const u8, writable: bool, cookie_details: bool) sdk.SiteDataStatus {
    if (!owns(tab,id)) return .{ .state=.idle,.origin="",.generation=0 };
    return .{ .state=received,.origin=origin[0..origin_len],.generation=sequence,.failure=failure,
        .mutation=mutation,.writable=writable,.cookieDetails=cookie_details };
}

pub fn cookieDetails(tab: u64, id: []const u8, generation: u64, url: []const u8) ?sdk.SiteCookiePage {
    if (!owns(tab,id) or received != .ready or generation != sequence) return null;
    if (cookies == null) cookies = cookie_store.list(url) catch
        return .{ .available=false,.entries=&.{},.more=false,.generation=sequence };
    if (cookies) |*snapshot| return .{
        .available=true,.entries=snapshot.entries[0..snapshot.len],.more=snapshot.more,.generation=sequence,
    };
    unreachable;
}

pub fn cookieValue(alloc: std.mem.Allocator, tab: u64, id: []const u8, target: sdk.SiteCookieItem, url: []const u8) ?[]const u8 {
    if (!owns(tab,id) or received != .ready or target.generation != sequence) return null;
    if (cookies) |*snapshot| return cookie_store.value(snapshot,alloc,url,target.id) catch null;
    return null;
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
