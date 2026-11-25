const std = @import("std");
const sdk = @import("moon_plugin");
const native = @import("native");
const cookie_store = @import("cookie_store.zig");

const Entry = struct { name: []const u8, value: []const u8, shortened: bool };
const Group = struct { entries: []Entry, more: bool };
const Snapshot = struct { cookies: ?Group, local: ?Group, session: ?Group, mutation: ?sdk.SiteDataMutation = null };
const StorageSnapshot = struct { entries: []Entry, total: u32, storageCount: u32 };
const StorageRequest = struct {
    group: sdk.SiteDataGroup,
    offset: u32,
    token: u64,
    term: [sdk.site_storage_query_limit]u8 = undefined,
    term_len: usize,
    deadline: ?u64,
    result: ?std.json.Parsed(StorageSnapshot) = null,
};
const Catalog = struct {
    indexedDB: @FieldType(sdk.SiteStorageCatalog,"indexedDB"),
    cacheStorage: @FieldType(sdk.SiteStorageCatalog,"cacheStorage"),
};
const DatabaseSnapshot = struct {
    state: sdk.SiteDatabaseDetailsState,
    stores: []const sdk.SiteObjectStore = &.{},
    more: bool = false,
};
const DatabaseRequest = struct {
    index: u32,
    token: u64,
    deadline: ?u64 = null,
    result: ?std.json.Parsed(DatabaseSnapshot) = null,
};
const RecordsSnapshot = struct {
    state: sdk.SiteDatabaseDetailsState,
    records: []const sdk.SiteRecord = &.{},
    next: ?u16 = null,
    capped: bool = false,
};
const RecordsRequest = struct {
    store: u32,
    offset: u16,
    token: u64,
    deadline: ?u64 = null,
    result: ?std.json.Parsed(RecordsSnapshot) = null,
};
const AsyncMutation = union(enum) { cache, cookies, database: u64 };
const allocator = std.heap.page_allocator;
var captured: ?std.json.Parsed(Snapshot) = null;
var storage_page: ?StorageRequest = null;
var storage_serial: u64 = 0;
var cookies: ?cookie_store.Snapshot = null;
var cookie_page: ?cookie_store.Snapshot = null;
var cookie_serial: u64 = 0;
var cookie_removal: ?struct { snapshot: cookie_store.Snapshot, id: u32 } = null;
var catalog: ?std.json.Parsed(Catalog) = null;
var catalog_deadline: ?u64 = null;
var catalog_requested = false;
var database: ?DatabaseRequest = null;
var record_page: ?RecordsRequest = null;
var database_serial: u64 = 0;
var source: u64 = 0;
var panel: u64 = 0;
var sequence: u64 = 0;
var received: sdk.SiteDataState = .idle;
var failure: ?sdk.SiteDataFailure = null;
var mutation: ?sdk.SiteDataMutation = null;
var async_mutation: ?AsyncMutation = null;
var deadline: u64 = 0;
var owner: [96]u8 = undefined;
var owner_len: usize = 0;
var origin: [4096]u8 = undefined;
var origin_len: usize = 0;

fn dropValues() void {
    async_mutation = null;
    if (captured) |result| result.deinit();
    captured = null;
    dropCookies();
    dropCookieRemoval();
    dropStoragePage();
    if (catalog) |result| result.deinit();
    catalog = null;
    catalog_deadline = null;
    catalog_requested = false;
    dropDatabase();
}

pub fn dropStoragePage() void {
    if (storage_page) |page| if (page.result) |result| result.deinit();
    storage_page = null;
}

fn dropDatabase() void {
    if (database) |inspection| if (inspection.result) |result| result.deinit();
    database = null;
    dropRecordPreview();
}

pub fn dropRecordPreview() void {
    if (record_page) |preview| if (preview.result) |result| result.deinit();
    record_page = null;
}

pub fn dropCookies() void {
    if (cookies) |*snapshot| snapshot.deinit();
    cookies = null;
    dropCookiePage();
}

fn dropCookieRemoval() void {
    if (cookie_removal) |*removal| removal.snapshot.deinit();
    cookie_removal = null;
}

fn dropCookiePage() void {
    if (cookie_page) |*snapshot| snapshot.deinit();
    cookie_page = null;
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
    if (async_mutation != null or cookie_removal != null) return false;
    startRequest();
    if (!native.moon_engine_inspect_site(view,sequence)) failedRequest();
    return received == .pending;
}

pub fn update(view: *native.MoonView, tab: u64, id: []const u8, target: sdk.SiteDataItem, replacement: ?[]const u8) bool {
    if (!canMutate(tab,id,target.group,target.generation)) return false;
    if (replacement) |bytes| {
        if (bytes.len>sdk.site_data_value_limit or !std.unicode.utf8ValidateSlice(bytes)) return false;
    }
    const entry = storageEntry(target) orelse return false;
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

pub fn cacheName(tab: u64, id: []const u8, target: sdk.SiteCacheRemove) ?[]const u8 {
    if (!owns(tab,id) or received != .ready or target.generation != sequence) return null;
    const result = catalog orelse return null;
    const section = result.value.cacheStorage orelse return null;
    if (target.index >= section.entries.len) return null;
    const entry = section.entries[target.index];
    return if (entry.shortened) null else entry.name;
}

pub fn removeCache(view: *native.MoonView, tab: u64, id: []const u8, target: sdk.SiteCacheRemove) bool {
    const name = cacheName(tab,id,target) orelse return false;
    var number: [24]u8 = undefined;
    const previous = std.fmt.bufPrint(&number,"{d}",.{sequence}) catch unreachable;
    const bytes = std.json.Stringify.valueAlloc(allocator,.{ .name=name,.previous=previous },.{}) catch return false;
    defer allocator.free(bytes);
    const payload = allocator.dupeSentinel(u8,bytes,0) catch return false;
    defer allocator.free(payload);
    startRequest();
    if (!native.moon_engine_remove_site_cache(view,sequence,payload.ptr)) {
        failedRequest();
        return false;
    }
    async_mutation = .cache;
    return true;
}

pub fn completeCache(view: *native.MoonView, tab: u64, token: u64, json: []const u8) void {
    const pending = async_mutation orelse return;
    if (std.meta.activeTag(pending)!=.cache or tab!=source or token!=sequence) return;
    completeAsyncMutation(view,json);
}

pub fn canClearCookies(tab: u64, id: []const u8, generation: u64) bool {
    return owns(tab,id) and received==.ready and generation==sequence;
}

pub fn clearCookies(url: [*:0]const u8) bool {
    startRequest();
    async_mutation = .cookies;
    if (native.moon_engine_clear_site_cookies(url,sequence)) return true;
    async_mutation = null;
    failedRequest();
    return false;
}

pub fn cookieClearSource(token: u64) ?u64 {
    const pending = async_mutation orelse return null;
    return if (std.meta.activeTag(pending)==.cookies and token==sequence) source else null;
}

pub fn completeCookieClear(view: *native.MoonView) void {
    finishMutation(view,.cleared);
}

fn completeAsyncMutation(view: *native.MoonView, json: []const u8) void {
    async_mutation = null;
    const result = std.json.parseFromSlice(struct { mutation: sdk.SiteDataMutation },allocator,json,.{}) catch {
        failedRequest();
        return;
    };
    defer result.deinit();
    finishMutation(view,result.value.mutation);
}

fn finishMutation(view: *native.MoonView, result: sdk.SiteDataMutation) void {
    async_mutation = null;
    mutation = result;
    deadline = native.moon_clock()+5000;
    if (!native.moon_engine_inspect_site(view,sequence)) failedRequest();
}

const Mutation = struct {
    revision: []const u8 = "",
    group: sdk.SiteDataGroup,
    key: []const u8 = "",
    previous: ?[]const u8 = null,
    replacement: ?[]const u8 = null,
    clear: bool = false,
    expire_cookie: ?[]const u8 = null,
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
    defer dropCookieRemoval();
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
    mutation=result.value.mutation orelse mutation;
    if (cookie_removal) |*removal| {
        if (mutation==.removed and !cookie_store.removed(&removal.snapshot,removal.id)) mutation=.failed;
    }
    deadline=native.moon_clock()+5*60*1000;
}

pub fn tick(now: u64) void {
    if (storage_page) |*page| {
        if (page.deadline) |expires| {
            if (now >= expires) page.deadline = null;
        }
    }
    if (catalog_deadline) |expires| {
        if (now >= expires) catalog_deadline = null;
    }
    if (database) |*inspection| {
        if (inspection.deadline) |expires| {
            if (now >= expires) inspection.deadline = null;
        }
    }
    if (record_page) |*preview| {
        if (preview.deadline) |expires| {
            if (now >= expires) preview.deadline = null;
        }
    }
    if (received == .pending and now >= deadline) {
        async_mutation = null;
        dropCookieRemoval();
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

fn selectedDatabase(tab: u64, id: []const u8, query: sdk.SiteDatabaseQuery) ?sdk.SiteDatabase {
    if (!owns(tab,id) or received!=.ready or query.generation!=sequence) return null;
    const result = catalog orelse return null;
    const section = result.value.indexedDB orelse return null;
    if (query.index>=section.entries.len) return null;
    const entry = section.entries[query.index];
    if (entry.shortened or (entry.version orelse 0)==0) return null;
    return entry;
}

pub fn requestDatabase(view: *native.MoonView, tab: u64, id: []const u8, query: sdk.SiteDatabaseQuery) bool {
    const entry = selectedDatabase(tab,id,query) orelse return false;
    if (database) |inspection| {
        if (inspection.deadline!=null or (inspection.index==query.index and !query.refresh)) return true;
    }
    dropDatabase();
    database_serial += 1;
    database = .{ .index=query.index,.token=database_serial };
    if (inspectDatabase(view,.{ .name=entry.name,.version=entry.version.?,.revision=sequence }))
        database.?.deadline = native.moon_clock()+5000;
    return true;
}

fn databasePayload(query: anytype) ![:0]u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator,query,.{});
    defer allocator.free(bytes);
    return std.fmt.allocPrintSentinel(allocator,"{s}\n{s}",.{bytes,@embedFile("site_database.js")},0);
}

fn inspectDatabase(view: *native.MoonView, query: anytype) bool {
    const payload = databasePayload(query) catch return false;
    defer allocator.free(payload);
    return native.moon_engine_inspect_database(view,database_serial,payload.ptr);
}

pub fn completeDatabase(view: *native.MoonView, tab: u64, token: u64, json: []const u8) void {
    if (async_mutation) |pending| switch (pending) {
        .database => |request_id| if (tab==source and request_id==token) {
            completeAsyncMutation(view,json);
            return;
        },
        .cache, .cookies => {},
    };
    if (tab!=source or received!=.ready or json.len>20*1024) return;
    if (record_page) |*preview| {
        if (preview.token==token and preview.deadline!=null) {
            preview.deadline = null;
            const parsed = std.json.parseFromSlice(RecordsSnapshot,allocator,json,.{ .allocate=.alloc_always }) catch return;
            if (parsed.value.records.len>sdk.site_record_page_size or
                (parsed.value.next!=null and (parsed.value.next.?!=preview.offset+sdk.site_record_page_size or
                    parsed.value.next.?>=sdk.site_record_preview_limit))) {
                parsed.deinit();
                return;
            }
            preview.result = parsed;
            return;
        }
    }
    if (database) |*inspection| {
        if (inspection.token!=token or inspection.deadline==null) return;
        inspection.deadline = null;
        inspection.result = std.json.parseFromSlice(DatabaseSnapshot,allocator,json,.{ .allocate=.alloc_always }) catch return;
    }
}

pub fn databaseDetails(tab: u64, id: []const u8, query: sdk.SiteDatabaseQuery) ?sdk.SiteDatabaseDetails {
    _ = selectedDatabase(tab,id,query) orelse return null;
    const inspection = database orelse return null;
    var result: sdk.SiteDatabaseDetails = .{ .index=query.index,.generation=sequence,.state=.pending };
    if (inspection.index!=query.index or inspection.deadline!=null) return result;
    result.revision = inspection.token;
    result.state = .unavailable;
    if (inspection.result) |parsed| {
        result.state = parsed.value.state;
        result.stores = parsed.value.stores;
        result.more = parsed.value.more;
    }
    return result;
}

const ObjectStore = struct { database: sdk.SiteDatabase, name: []const u8 };

pub fn objectStore(tab: u64, id: []const u8, target: sdk.SiteDatabaseStoreTarget) ?ObjectStore {
    const entry = selectedDatabase(tab,id,.{ .index=target.index,.generation=target.generation }) orelse return null;
    const inspection = database orelse return null;
    if (inspection.index!=target.index or inspection.token!=target.revision) return null;
    const parsed = inspection.result orelse return null;
    if (parsed.value.state!=.ready or target.store>=parsed.value.stores.len) return null;
    const store = parsed.value.stores[target.store];
    if (store.shortened) return null;
    return .{ .database=entry,.name=store.name };
}

pub fn clearObjectStore(view: *native.MoonView, tab: u64, id: []const u8, target: sdk.SiteDatabaseStoreTarget) bool {
    const store = objectStore(tab,id,target) orelse return false;
    return startDatabaseMutation(view,.{
        .name=store.database.name,.version=store.database.version.?,.revision=sequence,
        .clear=.{ .store=store.name,.expires=native.moon_wall_ms()+3500 },
    });
}

const Record = struct { store: ObjectStore, key: []const u8 };

pub fn record(tab: u64, id: []const u8, target: sdk.SiteDatabaseRecordTarget) ?Record {
    const store = objectStore(tab,id,.{
        .index=target.index,.generation=target.generation,.revision=target.revision,.store=target.store,
    }) orelse return null;
    const page = record_page orelse return null;
    if (page.store!=target.store or page.token!=target.pageRevision) return null;
    const result = page.result orelse return null;
    if (result.value.state!=.ready or target.row>=result.value.records.len) return null;
    const key = result.value.records[target.row].key;
    return if (key.shortened) null else .{ .store=store,.key=key.text };
}

pub fn removeRecord(view: *native.MoonView, tab: u64, id: []const u8, target: sdk.SiteDatabaseRecordTarget) bool {
    const entry = record(tab,id,target) orelse return false;
    const store = entry.store;
    return startDatabaseMutation(view,.{
        .name=store.database.name,.version=store.database.version.?,.revision=sequence,
        .remove=.{ .store=store.name,.pageRevision=target.pageRevision,.row=target.row,.expires=native.moon_wall_ms()+3500 },
    });
}

fn startDatabaseMutation(view: *native.MoonView, query: anytype) bool {
    const payload = databasePayload(query) catch return false;
    defer allocator.free(payload);
    database_serial += 1;
    startRequest();
    if (!native.moon_engine_inspect_database(view,database_serial,payload.ptr)) {
        failedRequest();
        return false;
    }
    async_mutation = .{ .database=database_serial };
    return true;
}

pub fn requestRecords(view: *native.MoonView, tab: u64, id: []const u8, query: sdk.SiteDatabaseRecordsQuery) bool {
    if (query.offset>=sdk.site_record_preview_limit or query.offset%sdk.site_record_page_size!=0) return false;
    const store = objectStore(tab,id,.{ .index=query.index,.generation=query.generation,.revision=query.revision,.store=query.store }) orelse return false;
    if (record_page) |preview| {
        if (preview.deadline!=null or (preview.store==query.store and preview.offset==query.offset and !query.refresh)) return true;
    }
    dropRecordPreview();
    database_serial += 1;
    record_page = .{ .store=query.store,.offset=query.offset,.token=database_serial };
    if (inspectDatabase(view,.{
        .name=store.database.name,.version=store.database.version.?,.revision=sequence,
        .records=.{ .store=store.name,.offset=query.offset,.size=sdk.site_record_page_size,.limit=sdk.site_record_preview_limit },
    })) record_page.?.deadline = native.moon_clock()+5000;
    return true;
}

pub fn databaseRecords(query: sdk.SiteDatabaseRecordsQuery) sdk.SiteDatabaseRecords {
    const preview = record_page orelse return .{ .offset=query.offset,.state=.unavailable };
    if (preview.store!=query.store or preview.offset!=query.offset or preview.deadline!=null)
        return .{ .offset=query.offset,.state=.pending };
    const result = preview.result orelse return .{ .offset=query.offset,.state=.unavailable };
    return .{ .offset=query.offset,.state=result.value.state,.records=result.value.records,.pageRevision=preview.token,
        .next=result.value.next,.capped=result.value.capped };
}

fn resolve(kind: sdk.SiteDataGroup) ?Group {
    const result=captured orelse return null;
    return switch (kind) {
        .cookies => result.value.cookies,
        .local => result.value.local,
        .session => result.value.session,
    };
}

pub fn status(tab: u64, id: []const u8, writable: bool, cookie_details: bool, cache_writable: bool, record_preview: bool) sdk.SiteDataStatus {
    if (!owns(tab,id)) return .{ .state=.idle,.origin="",.generation=0 };
    return .{ .state=received,.origin=origin[0..origin_len],.generation=sequence,.failure=failure,
        .mutation=mutation,.writable=writable,.cookieDetails=cookie_details,.cacheWritable=cache_writable,.recordPreview=record_preview };
}

pub fn cookieDetails(tab: u64, id: []const u8, generation: u64, url: []const u8) ?sdk.SiteCookiePage {
    if (!owns(tab,id) or received != .ready or generation != sequence) return null;
    if (cookies == null) cookies = cookie_store.list(url,.{ .generation=generation }) catch
        return .{ .available=false,.entries=&.{},.more=false,.generation=sequence };
    if (cookies) |*snapshot| return .{
        .available=true,.entries=snapshot.entries[0..snapshot.len],.more=snapshot.more,.generation=sequence,
    };
    unreachable;
}

pub fn cookiePage(tab: u64, id: []const u8, target: sdk.SiteCookieQuery, url: []const u8) ?sdk.SiteCookieSearchPage {
    if (!owns(tab,id) or received != .ready or target.generation != sequence) return null;
    dropCookiePage();
    var response: sdk.SiteCookieSearchPage = .{ .available=false,.generation=sequence,.offset=target.offset };
    cookie_page = cookie_store.list(url,target) catch return response;
    cookie_serial+=1;
    const snapshot = &cookie_page.?;
    response.available=true;
    response.pageRevision=cookie_serial;
    response.entries=snapshot.entries[0..snapshot.len];
    if (snapshot.more) response.next=target.offset+|@as(u32,@intCast(snapshot.len));
    return response;
}

pub fn removableCookie(tab: u64, owner_id: []const u8, target: sdk.SiteCookieRemoval) ?sdk.SiteCookieEntry {
    if (!canClearCookies(tab,owner_id,target.generation) or target.pageRevision!=cookie_serial) return null;
    const snapshot=if (cookie_page) |*page| page else return null;
    if (target.id>=snapshot.len or !snapshot.entries[target.id].removable) return null;
    return snapshot.entries[target.id];
}

pub fn removeCookie(view: *native.MoonView, tab: u64, id: []const u8, target: sdk.SiteCookieRemoval, url: []const u8) bool {
    _=removableCookie(tab,id,target) orelse return false;
    var buffer: [1024]u8 = undefined;
    const header=cookie_store.deletionHeader(&cookie_page.?,url,target.id,&buffer) catch return false;
    // Move ownership of the inspected page past the ordinary snapshot reset.
    var snapshot=cookie_page.?;
    cookie_page=null;
    if (!mutate(view,.{ .group=.cookies,.expire_cookie=header })) {
        snapshot.deinit();
        return false;
    }
    cookie_removal=.{ .snapshot=snapshot,.id=target.id };
    return true;
}

pub fn cookieValue(alloc: std.mem.Allocator, tab: u64, id: []const u8, target: sdk.SiteCookieItem, url: []const u8) ?[]const u8 {
    if (!owns(tab,id) or received != .ready or target.generation != sequence) return null;
    if (target.pageRevision) |revision| {
        if (revision!=cookie_serial) return null;
        if (cookie_page) |*snapshot| return cookie_store.value(snapshot,alloc,url,target.id) catch null;
        return null;
    }
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

pub fn requestStoragePage(view: *native.MoonView, tab: u64, id: []const u8, query: sdk.SiteStorageQuery) bool {
    if (!canMutate(tab,id,query.group,query.generation) or query.query.len>sdk.site_storage_query_limit) return false;
    if (!query.refresh) {
        if (storage_page) |*page| {
            if (page.group==query.group and page.offset==query.offset and
                std.mem.eql(u8,page.term[0..page.term_len],query.query)) return true;
        }
    }
    var generation: [20]u8 = undefined;
    const bytes = std.json.Stringify.valueAlloc(allocator,.{
        .generation=std.fmt.bufPrint(&generation,"{d}",.{sequence}) catch unreachable,
        .group=query.group,.query=query.query,.offset=query.offset,
    },.{}) catch return false;
    defer allocator.free(bytes);
    const payload = allocator.dupeSentinel(u8,bytes,0) catch return false;
    defer allocator.free(payload);
    dropStoragePage();
    storage_serial+=1;
    storage_page=.{ .group=query.group,.offset=query.offset,.token=storage_serial,
        .term_len=query.query.len,.deadline=native.moon_clock()+5000 };
    @memcpy(storage_page.?.term[0..query.query.len],query.query);
    if (!native.moon_engine_inspect_storage_page(view,storage_serial,payload.ptr))
        storage_page.?.deadline=null;
    return true;
}

pub fn completeStoragePage(tab: u64, token: u64, json: []const u8) void {
    const page = if (storage_page) |*current| current else return;
    if (tab!=source or page.token!=token or page.deadline==null) return;
    page.deadline=null;
    const result = std.json.parseFromSlice(StorageSnapshot,allocator,json,.{ .allocate=.alloc_always }) catch return;
    const expected = @min(sdk.site_storage_page_size,result.value.total -| page.offset);
    if (result.value.total>result.value.storageCount or result.value.entries.len!=expected) {
        result.deinit();
        return;
    }
    for (result.value.entries) |entry| {
        if (entry.name.len>512 or entry.value.len>2048) {
            result.deinit();
            return;
        }
    }
    page.result=result;
}

pub fn storagePage(query: sdk.SiteStorageQuery, buffer: *[sdk.site_storage_page_size]sdk.SiteDataEntry) sdk.SiteStoragePage {
    const page = storage_page.?;
    var response: sdk.SiteStoragePage = .{
        .generation=query.generation,.pageRevision=page.token,.offset=query.offset,
        .state=if (page.deadline!=null) .pending else .unavailable,
    };
    if (page.result) |result| {
        const entries = result.value.entries;
        for (entries,0..) |item,index| buffer[index]=.{
            .id=@intCast(index),.name=item.name,.length=item.value.len,.shortened=item.shortened,
        };
        response.state=.ready;
        response.entries=buffer[0..entries.len];
        response.total=result.value.total;
        response.storageCount=result.value.storageCount;
    }
    return response;
}

fn storageEntry(target: sdk.SiteDataItem) ?Entry {
    const entries = if (target.pageRevision) |revision| blk: {
        const page = storage_page orelse return null;
        if (page.token!=revision or page.group!=target.group) return null;
        const result = page.result orelse return null;
        break :blk result.value.entries;
    } else (resolve(target.group) orelse return null).entries;
    if (target.id>=entries.len) return null;
    return entries[target.id];
}

pub fn value(tab: u64, id: []const u8, target: sdk.SiteDataItem) ?[]const u8 {
    if (!owns(tab,id) or received != .ready or target.generation != sequence) return null;
    const entry=storageEntry(target) orelse return null;
    return entry.value;
}
