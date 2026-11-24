const std = @import("std");
const db_api = @import("profile_db.zig");
const history = @import("history.zig");
const sdk = @import("moon_plugin");

const sqlite = &db_api.sqlite;
pub const levels = [_]u16{ 50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300 };
pub const zoom_page_size = 16;
var database: ?*db_api.Database = null;
var path: [4096:0]u8 = @splat(0);

pub fn init(profile: []const u8) void {
    _ = std.fmt.bufPrintSentinel(&path, "{s}\\page-zoom.sqlite3", .{profile}, 0) catch return;
}

fn connection() !*db_api.Database {
    if (database) |db| return db;
    const db = try db_api.open(std.mem.sliceTo(&path, 0));
    errdefer db_api.close(db);
    if (sqlite.sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS zoom (origin TEXT PRIMARY KEY, percent INTEGER NOT NULL);", null, null, null) != db_api.ok) return error.IOError;
    database = db;
    return db;
}

pub fn close() void {
    if (database) |db| db_api.close(db);
    database = null;
}

pub fn origin(url: []const u8) ?[]const u8 {
    if (!history.validURL(url)) return null;
    const scheme: usize = if (url[4] == ':') 7 else 8;
    const rest = url[scheme..];
    return url[0 .. scheme + (std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len)];
}

pub fn next(current: u16, action: sdk.ZoomAction) u16 {
    switch (action) {
        .reset => return 100,
        .increase => {
            for (levels) |level| if (level > current) return level;
            return levels[levels.len - 1];
        },
        .decrease => {
            var index = levels.len;
            while (index > 0) {
                index -= 1;
                if (levels[index] < current) return levels[index];
            }
            return levels[0];
        },
    }
}

pub fn load(key: []const u8) u16 {
    const db = connection() catch return 100;
    const statement = db_api.prepare(db, "SELECT percent FROM zoom WHERE origin=?1") catch return 100;
    defer _ = sqlite.sqlite3_finalize(statement);
    db_api.bindText(statement, 1, key) catch return 100;
    if (sqlite.sqlite3_step(statement) != db_api.row) return 100;
    const percent = std.math.cast(u16, sqlite.sqlite3_column_int64(statement, 0)) orelse return 100;
    return if (validLevel(percent)) percent else 100;
}

pub fn validLevel(percent: u16) bool {
    return std.mem.indexOfScalar(u16,&levels,percent)!=null;
}

pub fn listZoom(allocator: std.mem.Allocator, query: sdk.SiteZoomQuery, current: ?[]const u8,
    buffer: *[zoom_page_size]sdk.SiteZoomRule) !sdk.SiteZoomPage
{
    if (query.query.len>320 or std.mem.indexOfScalar(u8,query.query,0)!=null) return error.InvalidParams;
    const db = try connection();
    const statement = try db_api.prepare(db,
        "SELECT origin, percent FROM zoom WHERE length(CAST(origin AS BLOB)) < 320 " ++
        "AND instr(lower(origin), lower(?1)) > 0 ORDER BY origin LIMIT ?2 OFFSET ?3");
    defer _ = sqlite.sqlite3_finalize(statement);
    try db_api.bindText(statement,1,query.query);
    if (sqlite.sqlite3_bind_int64(statement,2,zoom_page_size+1)!=db_api.ok or
        sqlite.sqlite3_bind_int64(statement,3,query.offset)!=db_api.ok) return error.IOError;
    var used: usize = 0;
    var more: ?u32 = null;
    while (true) switch (sqlite.sqlite3_step(statement)) {
        db_api.done => break,
        db_api.row => {
            if (used==buffer.len) {
                more = query.offset +| zoom_page_size;
                break;
            }
            const key = try db_api.columnText(statement,0);
            const percent = std.math.cast(u16,sqlite.sqlite3_column_int64(statement,1)) orelse return error.IOError;
            buffer[used] = .{ .origin=try allocator.dupe(u8,key), .percent=percent };
            used += 1;
        },
        else => return error.IOError,
    };
    return .{ .currentOrigin=current, .currentPercent=if (current) |key| load(key) else 100,
        .levels=&levels,.rules=buffer[0..used],.previous=if (query.offset>0) query.offset -| zoom_page_size else null,
        .next=more };
}

pub fn save(key: []const u8, percent: u16) !void {
    const db = try connection();
    const statement = try db_api.prepare(db, if (percent == 100) "DELETE FROM zoom WHERE origin=?1" else "INSERT OR REPLACE INTO zoom(origin,percent) VALUES (?1,?2)");
    defer _ = sqlite.sqlite3_finalize(statement);
    try db_api.bindText(statement, 1, key);
    if (percent != 100 and sqlite.sqlite3_bind_int64(statement, 2, percent) != db_api.ok) return error.IOError;
    if (sqlite.sqlite3_step(statement) != db_api.done) return error.IOError;
}
