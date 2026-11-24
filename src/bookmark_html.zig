const std = @import("std");
const sdk = @import("moon_plugin");
const history = @import("history.zig");

pub const byte_limit = 8*1024*1024;
pub const entry_limit = 20_000;
pub const separator = " / ";
const header = "<!DOCTYPE NETSCAPE-Bookmark-file-1>";
pub const depth_limit = 16;
pub const Parsed = struct { entries: []const sdk.BookmarkInput, skipped: usize };

const Tag = struct {
    name: []const u8, attrs: []const u8, closing: bool, start: usize,

    fn is(tag: Tag,name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(tag.name,name);
    }
};

fn nextTag(html: []const u8, cursor: *usize) ?Tag {
    while (std.mem.indexOfScalarPos(u8,html,cursor.*,'<')) |start| {
        const body = html[start+1..];
        if (std.mem.startsWith(u8,body,"!--")) {
            const end = std.mem.indexOf(u8,body,"-->") orelse return null;
            cursor.* = start+1+end+3;
            continue;
        }
        var quote: u8 = 0;
        for (body,0..) |ch,i| {
            if (quote!=0) {
                if (ch==quote) quote = 0;
            } else if (ch=='"' or ch=='\'') {
                quote = ch;
            } else if (ch=='>') {
                cursor.* = start+2+i;
                const tag = std.mem.trim(u8,body[0..i]," \t\r\n");
                if (tag.len==0) break;
                const closing = tag[0]=='/';
                const content = if (closing) tag[1..] else tag;
                const end = std.mem.indexOfAny(u8,content," \t\r\n/") orelse content.len;
                return .{ .name=content[0..end], .attrs=content[end..], .closing=closing, .start=start };
            }
        } else return null;
    }
    return null;
}

fn href(attrs: []const u8) ?[]const u8 {
    const space = " \t\r\n";
    var remaining = std.mem.trimStart(u8,attrs,space);
    while (remaining.len>0) {
        const name_end = std.mem.indexOfAny(u8,remaining,space++"=") orelse break;
        const key = remaining[0..name_end];
        remaining = std.mem.trimStart(u8,remaining[name_end..],space);
        if (remaining.len==0) break;
        if (remaining[0]!='=') {
            // Attribute without a value, such as PERSONAL_TOOLBAR_FOLDER.
            if (key.len==0) break;
            continue;
        }
        remaining = std.mem.trimStart(u8,remaining[1..],space);
        if (remaining.len==0) break;
        const quoted = remaining[0]=='"' or remaining[0]=='\'';
        const val_start: usize = if (quoted) 1 else 0;
        const val_end = if (quoted) std.mem.indexOfScalarPos(u8,remaining,1,remaining[0]) orelse break
            else std.mem.indexOfAny(u8,remaining,space) orelse remaining.len;
        if (std.ascii.eqlIgnoreCase(key,"href")) return remaining[val_start..val_end];
        remaining = std.mem.trimStart(u8,remaining[val_end+@intFromBool(quoted)..],space);
    }
    return null;
}

fn entity(text: []const u8) ?u21 {
    const named = .{ .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "apos", '\'' }, .{ "nbsp", 160 } };
    inline for (named) |item| if (std.ascii.eqlIgnoreCase(text,item[0])) return item[1];
    if (text.len<2 or text[0]!='#') return null;
    const hex = text[1]=='x' or text[1]=='X';
    return std.fmt.parseInt(u21,text[if (hex) 2 else 1 ..],if (hex) 16 else 10) catch null;
}

fn decode(allocator: std.mem.Allocator, raw: []const u8, label_limit: ?usize) ![]const u8 {
    const bytes = try allocator.alloc(u8,raw.len);
    var input: usize = 0;
    var output: usize = 0;
    while (input<raw.len) {
        if (raw[input]=='&') {
            if (std.mem.indexOfScalar(u8,raw[input+1..@min(input+17,raw.len)],';')) |relative| {
                const end = input+1+relative;
                if (entity(raw[input+1..end])) |point| {
                    if (std.unicode.utf8Encode(point,bytes[output..])) |length| {
                        output += length;
                        input = end+1;
                        continue;
                    } else |_| {}
                }
            }
        }
        bytes[output] = raw[input];
        output += 1;
        input += 1;
    }
    const limit = label_limit orelse return std.mem.trim(u8,bytes[0..output]," \t\r\n");
    for (bytes[0..output]) |*ch| if (std.ascii.isControl(ch.*)) { ch.* = ' '; };
    const trimmed = std.mem.trim(u8,bytes[0..output]," ");
    var end = @min(limit,trimmed.len);
    while (end<trimmed.len and trimmed[end]&0xc0==0x80) end -= 1;
    return trimmed[0..end];
}

pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !Parsed {
    if (raw.len>byte_limit) return error.LimitExceeded;
    const body = if (std.mem.startsWith(u8,raw,"\xef\xbb\xbf")) raw[3..] else raw;
    const html = std.mem.trimStart(u8,body," \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(html,header) or !std.unicode.utf8ValidateSlice(html)) return error.InvalidFile;

    var entries: std.ArrayList(sdk.BookmarkInput) = .empty;
    var seen: usize = 0;
    var cursor: usize = 0;
    var depth: usize = 0;
    var folder: [depth_limit+1][]const u8 = @splat("");
    var child: []const u8 = "";
    var capture: enum { none, title, folder } = .none;
    var content_start: usize = 0;
    var address: ?[]const u8 = null;
    while (nextTag(html,&cursor)) |tag| {
        if (!tag.closing and (tag.is("script") or tag.is("style"))) {
            const end = if (tag.is("script")) "</script" else "</style";
            cursor += std.ascii.findIgnoreCase(html[cursor..],end) orelse break;
            continue;
        }
        if (tag.is("dl")) {
            capture = .none;
            if (tag.closing) {
                depth -|= 1;
            } else {
                if (depth==depth_limit) return error.LimitExceeded;
                folder[depth+1] = child;
                depth += 1;
            }
            child = "";
        } else if (depth>0 and tag.is("h3")) {
            if (!tag.closing) {
                capture = .folder;
                content_start = cursor;
            } else if (capture==.folder) {
                child = try decode(allocator,html[content_start..tag.start],160);
                capture = .none;
            }
        } else if (depth>0 and tag.is("a")) {
            if (!tag.closing) {
                seen += 1;
                if (seen>entry_limit) return error.LimitExceeded;
                capture = .title;
                content_start = cursor;
                address = href(tag.attrs);
                child = "";
            } else if (capture==.title) {
                capture = .none;
                const url = if (address) |value| try decode(allocator,value,null) else "";
                var path_buffer: [160]u8 = undefined;
                const path = folderPath(folder[1..depth+1],&path_buffer);
                if (!history.validURL(url) or path==null) continue;
                const title = try decode(allocator,html[content_start..tag.start],511);
                try entries.append(allocator,.{ .url=url,.title=title,.folder=try allocator.dupe(u8,path.?) });
            }
        }
    }
    const skipped = seen-entries.items.len;
    return .{ .entries=try entries.toOwnedSlice(allocator), .skipped=skipped };
}

fn folderPath(parts: []const []const u8, buffer: []u8) ?[]const u8 {
    var used: usize = 0;
    for (parts) |part| {
        if (part.len==0) continue;
        const lead: []const u8 = if (used==0) "" else separator;
        const written = std.fmt.bufPrint(buffer[used..],"{s}{s}",.{lead,part}) catch return null;
        used += written.len;
    }
    return buffer[0..used];
}

fn escape(writer: *std.Io.Writer,text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        else => try writer.writeByte(ch),
    };
}

pub fn begin(writer: *std.Io.Writer) !void {
    try writer.writeAll(header ++ "\r\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\r\n" ++
        "<TITLE>Bookmarks</TITLE>\r\n<H1>Bookmarks</H1>\r\n<DL><p>\r\n");
}

pub fn openFolder(writer: *std.Io.Writer,title: []const u8) !void {
    try writer.writeAll("<DT><H3>");
    try escape(writer,title);
    try writer.writeAll("</H3>\r\n<DL><p>\r\n");
}

pub fn closeFolder(writer: *std.Io.Writer) !void {
    try writer.writeAll("</DL><p>\r\n");
}

pub fn writeBookmark(writer: *std.Io.Writer,title: []const u8,url: []const u8) !void {
    try writer.writeAll("<DT><A HREF=\"");
    try escape(writer,url);
    try writer.writeAll("\">");
    try escape(writer,title);
    try writer.writeAll("</A>\r\n");
}
