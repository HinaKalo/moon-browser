const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");

const db_api = @import("profile_db.zig");
const sqlite = &db_api.sqlite;
const prepare = db_api.prepare;
const bindText = db_api.bindText;
const columnText = db_api.columnText;
const ok = db_api.ok;
const row = db_api.row;
const done = db_api.done;
var database: ?*db_api.Database = null;
var path: [4096:0]u8 = @splat(0);

pub fn init(profile: []const u8) void {
    _ = std.fmt.bufPrintSentinel(&path,"{s}\\history.sqlite3",.{profile},0) catch return;
}

fn connection() !*db_api.Database {
    if (database) |db| return db;
    const db = try db_api.open(std.mem.sliceTo(&path,0));
    errdefer db_api.close(db);
    const schema =
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
    if (database) |db| db_api.close(db);
    database = null;
}

pub fn validURL(url: []const u8) bool {
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

pub fn list(allocator: std.mem.Allocator, options: sdk.HistorySearch, buffer: *[30]sdk.HistoryVisit) !sdk.HistoryPage {
    if (options.query.len > 256) return error.InvalidParams;
    const from = if (options.from) |time| std.math.cast(i64,time) orelse return error.InvalidParams else std.math.minInt(i64);
    const until = if (options.until) |time| std.math.cast(i64,time) orelse return error.InvalidParams else -1;
    if (until>=0 and from>=until) return error.InvalidParams;
    const db = try connection();
    const statement = try prepare(db,
        \\SELECT id,title,url,visited_at FROM visits
        \\WHERE id > 0 AND id < ?1 AND (instr(lower(title),lower(?2)) OR instr(lower(url),lower(?2)))
        \\  AND visited_at >= ?3 AND (?4 < 0 OR visited_at < ?4)
        \\ORDER BY id DESC LIMIT 31
    );
    defer _ = sqlite.sqlite3_finalize(statement);
    const end: i64 = if (options.before) |visit| visit else @as(i64,std.math.maxInt(u32))+1;
    if (sqlite.sqlite3_bind_int64(statement,1,end) != ok or sqlite.sqlite3_bind_int64(statement,3,from)!=ok or
        sqlite.sqlite3_bind_int64(statement,4,until)!=ok) return error.IOError;
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

pub fn removeMany(ids: []const u32) !u32 {
    if (ids.len==0 or ids.len>sdk.history_selection_limit or std.mem.indexOfScalar(u32,ids,0)!=null) return error.InvalidParams;
    const db = try connection();
    const sql = "DELETE FROM visits WHERE id IN (" ++ (comptime db_api.parameterList(sdk.history_selection_limit)) ++ ")";
    const statement = try prepare(db,sql);
    defer _ = sqlite.sqlite3_finalize(statement);
    for (ids,1..) |id,index| {
        if (sqlite.sqlite3_bind_int64(statement,@intCast(index),id)!=ok) return error.IOError;
    }
    if (sqlite.sqlite3_step(statement)!=done) return error.IOError;
    return @intCast(sqlite.sqlite3_changes(db));
}

pub fn clear() !void {
    const db = try connection();
    if (sqlite.sqlite3_exec(db,"DELETE FROM visits",null,null,null) != ok) return error.IOError;
}

pub fn suggest(allocator: std.mem.Allocator, query: []const u8, output: []db_api.Link) ![]db_api.Link {
    const db=try connection();
    return db_api.findLinks(allocator,db,
        \\SELECT title,url,MAX(id) FROM visits
        \\WHERE instr(lower(title),lower(?1)) OR instr(lower(url),lower(?1))
        \\GROUP BY url ORDER BY (instr(lower(title),lower(?1))=1) DESC, MAX(id) DESC LIMIT ?2
    ,query,output);
}
