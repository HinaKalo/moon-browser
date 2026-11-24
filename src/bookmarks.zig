const std = @import("std");
const sdk = @import("moon_plugin");
const db_api = @import("profile_db.zig");
const history = @import("history.zig");

const sqlite = &db_api.sqlite;
var database: ?*db_api.Database = null;
var path: [4096:0]u8 = @splat(0);

pub fn init(profile: []const u8) void {
    _ = std.fmt.bufPrintSentinel(&path,"{s}\\bookmarks.sqlite3",.{profile},0) catch return;
}

fn connection() !*db_api.Database {
    if (database) |db| return db;
    const db = try db_api.open(std.mem.sliceTo(&path,0));
    errdefer db_api.close(db);
    if (sqlite.sqlite3_exec(db,
        \\CREATE TABLE IF NOT EXISTS bookmarks (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  title TEXT NOT NULL,
        \\  url TEXT NOT NULL UNIQUE,
        \\  folder TEXT NOT NULL
        \\);
    ,null,null,null) != db_api.ok) return error.IOError;
    database = db;
    return db;
}

pub fn close() void {
    if (database) |db| db_api.close(db);
    database = null;
}

fn validLabel(value: []const u8, max: usize) bool {
    if (value.len > max or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |ch| if (std.ascii.isControl(ch)) return false;
    return true;
}

fn bindBookmark(statement: *db_api.Statement, title: []const u8, url: []const u8, folder: []const u8) !void {
    if (!history.validURL(url) or !validLabel(title,511) or !validLabel(folder,160)) return error.InvalidParams;
    try db_api.bindText(statement,1,title);
    try db_api.bindText(statement,2,url);
    try db_api.bindText(statement,3,folder);
}

pub fn save(input: sdk.BookmarkInput) !sdk.BookmarkSave {
    const db = try connection();
    const statement = try db_api.prepare(db,"INSERT OR IGNORE INTO bookmarks(title,url,folder) VALUES (?1,?2,?3)");
    defer _ = sqlite.sqlite3_finalize(statement);
    try bindBookmark(statement,input.title,input.url,input.folder);
    if (sqlite.sqlite3_step(statement) != db_api.done) return error.IOError;
    return if (sqlite.sqlite3_changes(db) == 0) .alreadySaved else .saved;
}

pub fn update(input: sdk.BookmarkEdit) !void {
    const db = try connection();
    const statement = try db_api.prepare(db,"UPDATE bookmarks SET title=?1,url=?2,folder=?3 WHERE id=?4");
    defer _ = sqlite.sqlite3_finalize(statement);
    try bindBookmark(statement,input.title,input.url,input.folder);
    if (sqlite.sqlite3_bind_int64(statement,4,input.id) != db_api.ok) return error.IOError;
    const status = sqlite.sqlite3_step(statement);
    if (status == 19) return error.AlreadyExists; // UNIQUE(url).
    if (status != db_api.done) return error.IOError;
    if (sqlite.sqlite3_changes(db) == 0) return error.NotFound;
}

pub fn remove(id: u32) !void {
    const db = try connection();
    const statement = try db_api.prepare(db,"DELETE FROM bookmarks WHERE id=?1");
    defer _ = sqlite.sqlite3_finalize(statement);
    if (sqlite.sqlite3_bind_int64(statement,1,id) != db_api.ok or sqlite.sqlite3_step(statement) != db_api.done)
        return error.IOError;
    if (sqlite.sqlite3_changes(db) == 0) return error.NotFound;
}

pub fn list(allocator: std.mem.Allocator, options: sdk.HistoryQuery, buffer: *[24]sdk.Bookmark) !sdk.BookmarkPage {
    if (options.query.len > 256) return error.InvalidParams;
    const db = try connection();
    const statement = try db_api.prepare(db,
        \\SELECT id,title,url,folder FROM bookmarks WHERE id>0 AND id<?1
        \\AND (instr(lower(title),lower(?2)) OR instr(lower(url),lower(?2)) OR instr(lower(folder),lower(?2)))
        \\ORDER BY id DESC LIMIT 25
    );
    defer _ = sqlite.sqlite3_finalize(statement);
    const end: i64 = if (options.before) |id| id else @as(i64,std.math.maxInt(u32))+1;
    if (sqlite.sqlite3_bind_int64(statement,1,end) != db_api.ok) return error.IOError;
    try db_api.bindText(statement,2,options.query);
    var remaining: usize = 24*1024;
    var length: usize = 0;
    while (true) {
        const status = sqlite.sqlite3_step(statement);
        if (status == db_api.done) return .{ .bookmarks=buffer[0..length],.next=null };
        if (status != db_api.row) return error.IOError;
        const title = try db_api.columnText(statement,1);
        const url = try db_api.columnText(statement,2);
        const folder = try db_api.columnText(statement,3);
        if (!history.validURL(url) or !validLabel(title,511) or !validLabel(folder,160)) continue;
        const max_bytes = 2*(title.len+url.len+folder.len)+128;
        if (length == buffer.len or max_bytes > remaining)
            return .{ .bookmarks=buffer[0..length],.next=buffer[length-1].id };
        buffer[length] = .{
            .id=@intCast(sqlite.sqlite3_column_int64(statement,0)),
            .title=try allocator.dupe(u8,title),
            .url=try allocator.dupe(u8,url),
            .folder=try allocator.dupe(u8,folder),
        };
        length += 1;
        remaining -= max_bytes;
    }
}
