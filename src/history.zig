const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");

const Database = opaque {};
const Statement = opaque {};
const Sqlite = struct {
    sqlite3_open: *const fn ([*:0]const u8,*?*Database) callconv(.c) c_int,
    sqlite3_close: *const fn (*Database) callconv(.c) c_int,
    sqlite3_busy_timeout: *const fn (*Database,c_int) callconv(.c) c_int,
    sqlite3_exec: *const fn (*Database,[*:0]const u8,?*anyopaque,?*anyopaque,?*anyopaque) callconv(.c) c_int,
    sqlite3_prepare_v2: *const fn (*Database,[*:0]const u8,c_int,*?*Statement,?*anyopaque) callconv(.c) c_int,
    sqlite3_finalize: *const fn (*Statement) callconv(.c) c_int,
    sqlite3_bind_int64: *const fn (*Statement,c_int,i64) callconv(.c) c_int,
    sqlite3_bind_text: *const fn (*Statement,c_int,[*]const u8,c_int,?*anyopaque) callconv(.c) c_int,
    sqlite3_step: *const fn (*Statement) callconv(.c) c_int,
    sqlite3_column_int64: *const fn (*Statement,c_int) callconv(.c) i64,
    sqlite3_column_text: *const fn (*Statement,c_int) callconv(.c) ?[*:0]const u8,
    sqlite3_column_bytes: *const fn (*Statement,c_int) callconv(.c) c_int,
    sqlite3_changes: *const fn (*Database) callconv(.c) c_int,
    sqlite3_last_insert_rowid: *const fn (*Database) callconv(.c) i64,
};

extern "kernel32" fn LoadLibraryExW([*:0]const u16,?*anyopaque,u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque,[*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(*anyopaque) callconv(.winapi) c_int;

const ok = 0;
const row = 100;
const done = 101;
var sqlite: Sqlite = undefined;
var library: ?*anyopaque = null;
var database: ?*Database = null;
var path: [4096:0]u8 = @splat(0);

pub fn init(profile: []const u8) void {
    _ = std.fmt.bufPrintSentinel(&path,"{s}\\history.sqlite3",.{profile},0) catch return;
}

fn connection() !*Database {
    if (database) |db| return db;
    if (path[0] == 0) return error.IOError;
    if (library == null) {
        const system32 = 0x00000800;
        const module = LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("winsqlite3.dll"),null,system32) orelse return error.IOError;
        errdefer _ = FreeLibrary(module);
        inline for (@typeInfo(Sqlite).@"struct".field_names) |name| {
            @field(sqlite,name) = @ptrCast(GetProcAddress(module,name) orelse return error.IOError);
        }
        library = module;
    }
    var handle: ?*Database = null;
    const opened = sqlite.sqlite3_open(&path,&handle);
    const db = handle orelse return error.IOError;
    errdefer _ = sqlite.sqlite3_close(db);
    if (opened != ok or sqlite.sqlite3_busy_timeout(db,25) != ok) return error.IOError;
    const schema =
        \\PRAGMA secure_delete=ON;
        \\PRAGMA cache_size=-256;
        \\CREATE TABLE IF NOT EXISTS visits (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  title TEXT NOT NULL,
        \\  url TEXT NOT NULL,
        \\  visited_at INTEGER NOT NULL
        \\);
        \\CREATE TRIGGER IF NOT EXISTS limit_visits AFTER INSERT ON visits BEGIN
        \\  DELETE FROM visits WHERE id < (SELECT id FROM visits ORDER BY id DESC LIMIT 1 OFFSET 999);
        \\END;
    ;
    if (sqlite.sqlite3_exec(db,schema,null,null,null) != ok) return error.IOError;
    database = db;
    return db;
}

pub fn close() void {
    if (database) |db| _ = sqlite.sqlite3_close(db);
    if (library) |module| _ = FreeLibrary(module);
    database = null;
    library = null;
}

fn prepare(db: *Database, sql: [:0]const u8) !*Statement {
    var statement: ?*Statement = null;
    if (sqlite.sqlite3_prepare_v2(db,sql.ptr,-1,&statement,null) != ok) return error.IOError;
    return statement orelse error.IOError;
}

fn bindText(statement: *Statement, index: c_int, value: []const u8) !void {
    const address = if (value.len == 0) "".ptr else value.ptr;
    if (sqlite.sqlite3_bind_text(statement,index,address,@intCast(value.len),null) != ok) return error.IOError;
}

fn validURL(url: []const u8) bool {
    if (url.len > 4095 or !std.unicode.utf8ValidateSlice(url)) return false;
    const start: usize = if (std.ascii.startsWithIgnoreCase(url,"https://")) 8
        else if (std.ascii.startsWithIgnoreCase(url,"http://")) 7 else return false;
    for (url) |ch| if (std.ascii.isControl(ch)) return false;
    const rest = url[start..];
    const authority = rest[0..std.mem.indexOfAny(u8,rest,"/?#") orelse rest.len];
    return authority.len != 0 and std.mem.indexOfAny(u8,authority," @\\") == null;
}

pub fn record(url: []const u8, title: []const u8) ?u32 {
    if (!validURL(url) or title.len > 511 or !std.unicode.utf8ValidateSlice(title)) return null;
    const db = connection() catch return null;
    const statement = prepare(db,"INSERT INTO visits(title,url,visited_at) VALUES (?1,?2,?3)") catch return null;
    defer _ = sqlite.sqlite3_finalize(statement);
    bindText(statement,1,title) catch return null;
    bindText(statement,2,url) catch return null;
    if (sqlite.sqlite3_bind_int64(statement,3,@intCast(native.moon_wall_ms())) != ok or
        sqlite.sqlite3_step(statement) != done) return null;
    return std.math.cast(u32,sqlite.sqlite3_last_insert_rowid(db));
}

pub fn updateTitle(id: u32, url: []const u8, title: []const u8) void {
    if (title.len == 0 or title.len > 511 or !std.unicode.utf8ValidateSlice(title)) return;
    const db = connection() catch return;
    const statement = prepare(db,"UPDATE visits SET title=?1 WHERE id=?2 AND url=?3") catch return;
    defer _ = sqlite.sqlite3_finalize(statement);
    bindText(statement,1,title) catch return;
    if (sqlite.sqlite3_bind_int64(statement,2,id) != ok) return;
    bindText(statement,3,url) catch return;
    _ = sqlite.sqlite3_step(statement);
}

fn columnText(statement: *Statement, index: c_int) ![]const u8 {
    const value = sqlite.sqlite3_column_text(statement,index) orelse return error.IOError;
    const length = sqlite.sqlite3_column_bytes(statement,index);
    return value[0..@intCast(length)];
}

pub fn list(allocator: std.mem.Allocator, options: sdk.HistoryQuery, buffer: *[30]sdk.HistoryVisit) !sdk.HistoryPage {
    if (options.query.len > 256) return error.InvalidParams;
    const db = try connection();
    const statement = try prepare(db,
        \\SELECT id,title,url,visited_at FROM visits
        \\WHERE id > 0 AND id < ?1 AND (instr(lower(title),lower(?2)) OR instr(lower(url),lower(?2)))
        \\ORDER BY id DESC LIMIT 31
    );
    defer _ = sqlite.sqlite3_finalize(statement);
    const end: i64 = if (options.before) |visit| visit else @as(i64,std.math.maxInt(u32))+1;
    if (sqlite.sqlite3_bind_int64(statement,1,end) != ok) return error.IOError;
    try bindText(statement,2,options.query);
    var remaining: usize = 24*1024;
    var length: usize = 0;
    var before: ?u32 = null;
    while (true) {
        const status = sqlite.sqlite3_step(statement);
        if (status == done) break;
        if (status != row) return error.IOError;
        const title = try columnText(statement,1);
        const url = try columnText(statement,2);
        if (title.len > 511 or !validURL(url)) continue;
        const max_bytes = 2*url.len + 6*title.len + 100;
        if (length == buffer.len or max_bytes > remaining) {
            before = buffer[length-1].id;
            break;
        }
        buffer[length] = .{
            .id=@intCast(sqlite.sqlite3_column_int64(statement,0)),
            .title=try allocator.dupe(u8,title),
            .url=try allocator.dupe(u8,url),
            .visitedAt=@intCast(@max(0,sqlite.sqlite3_column_int64(statement,3))),
        };
        length += 1;
        remaining -= max_bytes;
    }
    return .{ .visits=buffer[0..length],.next=before };
}

pub fn remove(id: u32) !void {
    const db = try connection();
    const statement = try prepare(db,"DELETE FROM visits WHERE id=?1");
    defer _ = sqlite.sqlite3_finalize(statement);
    if (sqlite.sqlite3_bind_int64(statement,1,id) != ok or sqlite.sqlite3_step(statement) != done) return error.IOError;
    if (sqlite.sqlite3_changes(db) == 0) return error.NotFound;
}

pub fn clear() !void {
    const db = try connection();
    if (sqlite.sqlite3_exec(db,"DELETE FROM visits",null,null,null) != ok) return error.IOError;
}
