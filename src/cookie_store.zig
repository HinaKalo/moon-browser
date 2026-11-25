const std = @import("std");
const db = @import("profile_db.zig");
const sdk = @import("moon_plugin");
const native = @import("native");

const limit = 32;
const value_limit = 2048;
const metadata_limit = 256;
const metadata_budget = 3900;
// Match the curl port's domain, path and expiry rules for the committed URL.
const scope = " FROM Cookie WHERE (domain=?1 COLLATE NOCASE OR " ++
    "(substr(domain,1,1)='.' AND (domain=('.'||?1) COLLATE NOCASE OR " ++
    "substr(?1,-length(domain))=domain COLLATE NOCASE))) AND " ++
    "(path=?2 OR (length(path)>0 AND substr(?2,1,length(path))=path AND " ++
    "(substr(path,-1)='/' OR substr(?2,length(path)+1,1)='/'))) AND " ++
    "(session=1 OR expires>?3) AND (?4=1 OR secure=0)";

const Key = struct {
    rowid: i64,
    name: []const u8,
    domain: []const u8,
    path: []const u8,
    updated: []const u8,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    keys: [limit]Key = undefined,
    entries: [limit]sdk.SiteCookieEntry = undefined,
    len: usize = 0,
    more: bool = false,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }
};

fn open() !*db.Database {
    const path = native.moon_profile_dir();
    if (path == null or path[0] == 0) return error.IOError;
    var file: [4096:0]u8 = undefined;
    return db.openReadOnly(try std.fmt.bufPrintSentinel(&file,"{s}\\Cookies.db",.{std.mem.span(path)},0));
}

fn bindInt(statement: *db.Statement, index: c_int, number: i64) !void {
    if (db.sqlite.sqlite3_bind_int64(statement,index,number) != db.ok) return error.IOError;
}

fn bindScope(statement: *db.Statement, url: []const u8) !void {
    const uri = try std.Uri.parse(url);
    const secure = std.mem.eql(u8,uri.scheme,"https");
    if (!secure and !std.mem.eql(u8,uri.scheme,"http")) return error.InvalidURL;
    const host = (uri.host orelse return error.InvalidURL).percent_encoded;
    if (host.len == 0 or std.mem.indexOfScalar(u8,host,'%') != null) return error.InvalidURL;
    const path = uri.path.percent_encoded;
    try db.bindText(statement,1,host);
    try db.bindText(statement,2,if (path.len == 0) "/" else path);
    try bindInt(statement,3,@intCast(native.moon_wall_ms()));
    try bindInt(statement,4,@intFromBool(secure));
}

fn textPrefix(bytes: []const u8, cap: usize) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidText;
    var len = @min(bytes.len,cap);
    while (len < bytes.len and (bytes[len] & 0xc0) == 0x80) len -= 1;
    return bytes[0..len];
}

pub fn list(url: []const u8, term: []const u8, offset: u32) !Snapshot {
    const conn = try open();
    defer db.close(conn);
    const query = try db.prepare(conn,"SELECT rowid,name,domain,path,expires,session,httponly,secure," ++
        "length(CAST(value AS BLOB)),CAST(lastupdated AS TEXT)" ++ scope ++
        " AND (?5='' OR instr(lower(name),lower(?5))>0 OR instr(lower(domain),lower(?5))>0 OR instr(lower(path),lower(?5))>0)" ++
        " ORDER BY name,domain,path LIMIT 33 OFFSET ?6");
    defer _ = db.sqlite.sqlite3_finalize(query);
    try bindScope(query,url);
    try db.bindText(query,5,term);
    try bindInt(query,6,offset);
    var snapshot: Snapshot = .{ .arena=std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    errdefer snapshot.deinit();
    const allocator = snapshot.arena.allocator();
    const colInt = db.sqlite.sqlite3_column_int64;
    var budget: usize = metadata_budget;
    while (true) {
        switch (db.sqlite.sqlite3_step(query)) {
            db.done => break,
            db.row => {},
            else => return error.IOError,
        }
        if (snapshot.len == limit) {
            snapshot.more = true;
            break;
        }
        const name = try db.columnText(query,1);
        const domain = try db.columnText(query,2);
        const path = try db.columnText(query,3);
        const visible_name = try textPrefix(name,metadata_limit);
        const visible_domain = try textPrefix(domain,metadata_limit);
        const visible_path = try textPrefix(path,metadata_limit);
        const display_size = visible_name.len+visible_domain.len+visible_path.len;
        if (display_size > budget) {
            snapshot.more = true;
            break;
        }
        budget -= display_size;
        const key: Key = .{
            .rowid=colInt(query,0),.name=try allocator.dupe(u8,name),.domain=try allocator.dupe(u8,domain),
            .path=try allocator.dupe(u8,path),.updated=try allocator.dupe(u8,try db.columnText(query,9)),
        };
        const length: usize = @intCast(@max(0,colInt(query,8)));
        snapshot.keys[snapshot.len] = key;
        snapshot.entries[snapshot.len] = .{
            .id=@intCast(snapshot.len),.name=key.name[0..visible_name.len],.domain=key.domain[0..visible_domain.len],
            .path=key.path[0..visible_path.len],.metadataShortened=display_size < name.len+domain.len+path.len,
            .expiresAt=if (colInt(query,5) == 1) null else colInt(query,4),
            .httpOnly=colInt(query,6) == 1,.secure=colInt(query,7) == 1,.length=length,.shortened=length>value_limit,
        };
        snapshot.len += 1;
    }
    return snapshot;
}

pub fn value(snapshot: *const Snapshot, allocator: std.mem.Allocator, url: []const u8, id: u32) ![]const u8 {
    if (id >= snapshot.len) return error.NotFound;
    const key = snapshot.keys[id];
    const conn = try open();
    defer db.close(conn);
    const query = try db.prepare(conn,"SELECT value" ++ scope ++
        " AND rowid=?5 AND name=?6 AND domain=?7 AND path=?8 AND CAST(lastupdated AS TEXT)=?9");
    defer _ = db.sqlite.sqlite3_finalize(query);
    try bindScope(query,url);
    try bindInt(query,5,key.rowid);
    try db.bindText(query,6,key.name);
    try db.bindText(query,7,key.domain);
    try db.bindText(query,8,key.path);
    try db.bindText(query,9,key.updated);
    if (db.sqlite.sqlite3_step(query) != db.row) return error.NotFound;
    return allocator.dupe(u8,try textPrefix(try db.columnText(query,0),value_limit));
}
