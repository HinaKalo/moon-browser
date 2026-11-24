const std = @import("std");
const sdk = @import("moon_plugin");
const db_api = @import("profile_db.zig");
const history = @import("history.zig");
const html = @import("bookmark_html.zig");
const native = @import("native");
const userscripts = @import("userscripts.zig");

const sqlite = &db_api.sqlite;
var database: ?*db_api.Database = null;
var path: [4096:0]u8 = @splat(0);
var transferring = false;

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

fn importFile(allocator: std.mem.Allocator, file: [:0]const u8) !sdk.BookmarkTransfer {
    const input = try allocator.alloc(u8,html.byte_limit+1);
    defer allocator.free(input);
    if (!native.moon_read_plain_text(file.ptr,input.ptr,input.len)) return error.InvalidFile;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const bookmarks = try html.parse(arena.allocator(),std.mem.sliceTo(input,0));
    const db = try connection();
    if (sqlite.sqlite3_exec(db,"BEGIN IMMEDIATE",null,null,null)!=db_api.ok) return error.IOError;
    errdefer _ = sqlite.sqlite3_exec(db,"ROLLBACK",null,null,null);
    const statement = try db_api.prepare(db,"INSERT OR IGNORE INTO bookmarks(title,url,folder) VALUES (?1,?2,?3)");
    defer _ = sqlite.sqlite3_finalize(statement);
    var result: sdk.BookmarkTransfer = .{ .state=.done,.skipped=bookmarks.skipped };
    for (bookmarks.entries) |entry| {
        try bindBookmark(statement,entry.title,entry.url,entry.folder);
        if (sqlite.sqlite3_step(statement)!=db_api.done) return error.IOError;
        if (sqlite.sqlite3_changes(db)==0) result.skipped += 1 else result.count += 1;
        if (sqlite.sqlite3_reset(statement)!=db_api.ok) return error.IOError;
    }
    if (sqlite.sqlite3_exec(db,"COMMIT",null,null,null)!=db_api.ok) return error.IOError;
    return result;
}

fn splitFolder(value: []const u8, parts: *[html.depth_limit-1][]const u8) [][]const u8 {
    var it = std.mem.splitSequence(u8,value,html.separator);
    var len: usize = 0;
    while (it.next()) |part| {
        if (part.len==0 or len==parts.len) {
            if (value.len==0) return parts[0..0];
            parts[0] = value;
            return parts[0..1];
        }
        parts[len] = part;
        len += 1;
    }
    return parts[0..len];
}

fn exportFile(allocator: std.mem.Allocator, file: [:0]const u8) !sdk.BookmarkTransfer {
    const db = try connection();
    const statement = try db_api.prepare(db,"SELECT title,url,folder FROM bookmarks ORDER BY folder,id");
    defer _ = sqlite.sqlite3_finalize(statement);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try html.begin(writer);
    var previous: [160]u8 = undefined;
    var prior_len: usize = 0;
    var result: sdk.BookmarkTransfer = .{ .state=.done };
    while (true) {
        const status = sqlite.sqlite3_step(statement);
        if (status==db_api.done) break;
        if (status!=db_api.row) return error.IOError;
        const title = try db_api.columnText(statement,0);
        const url = try db_api.columnText(statement,1);
        const folder = try db_api.columnText(statement,2);
        if (!history.validURL(url) or !validLabel(title,511) or !validLabel(folder,160)) {
            result.skipped += 1;
            continue;
        }
        if (result.count==html.entry_limit) return error.LimitExceeded;
        var prior_parts: [html.depth_limit-1][]const u8 = undefined;
        var new_parts: [html.depth_limit-1][]const u8 = undefined;
        const prior = splitFolder(previous[0..prior_len],&prior_parts);
        const next = splitFolder(folder,&new_parts);
        var common: usize = 0;
        while (common<@min(prior.len,next.len) and std.mem.eql(u8,prior[common],next[common])) common += 1;
        for (common..prior.len) |_| try html.closeFolder(writer);
        for (next[common..]) |part| try html.openFolder(writer,part);
        try html.writeBookmark(writer,title,url);
        @memcpy(previous[0..folder.len],folder);
        prior_len = folder.len;
        result.count += 1;
        if (output.written().len>html.byte_limit) return error.LimitExceeded;
    }
    var prior_parts: [html.depth_limit-1][]const u8 = undefined;
    for (splitFolder(previous[0..prior_len],&prior_parts)) |_| try html.closeFolder(writer);
    try html.closeFolder(writer);
    if (output.written().len>html.byte_limit) return error.LimitExceeded;
    const bytes = try allocator.dupeSentinel(u8,output.written(),0);
    defer allocator.free(bytes);
    if (!native.moon_write_text(file.ptr,bytes.ptr)) return error.IOError;
    return result;
}

pub fn transfer(allocator: std.mem.Allocator, owner: [:0]const u8, source: u64, exporting: bool,
    consent: userscripts.Consent) sdk.BookmarkTransfer
{
    if (transferring or !native.moon_bookmark_transfer_allowed(source,owner.ptr)) return .{ .state=.unavailable };
    transferring = true;
    defer transferring = false;
    var storage: [4096:0]u8 = undefined;
    const selection = native.moon_shell_pick_bookmarks(exporting,&storage,storage.len);
    if (selection==0) return .{ .state=.cancelled };
    if (selection<0 or !consent.valid(consent.context) or !native.moon_bookmark_transfer_allowed(source,owner.ptr))
        return .{ .state=.unavailable };
    const selected = std.mem.sliceTo(&storage,0);
    return (if (exporting) exportFile(allocator,selected) else importFile(allocator,selected)) catch |err|
        .{ .state=switch (err) {
            error.InvalidFile, error.InvalidParams => .invalidFile,
            error.LimitExceeded => .limitExceeded,
            else => .unavailable,
        } };
}
