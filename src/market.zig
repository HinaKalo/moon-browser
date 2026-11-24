const std = @import("std");
const native = @import("native");

pub const address = "moon://market/";
const State = enum(u8) { idle, loading, ready, failed };
var state: std.atomic.Value(State) = .init(.idle);
var notified: State = .idle;
var buffer: [32 * 1024]u8 = undefined;
var used: usize = 0;

const Entry = struct { id: []const u8, name: []const u8, description: []const u8, permission: []const u8, url: []const u8 };
const Catalog = struct { version: u32, entries: []const Entry };

pub fn start() void {
    if (state.load(.acquire) == .loading) return;
    notified = .loading;
    state.store(.loading,.release);
    if (!native.moon_market_thread()) state.store(.failed,.release);
}

export fn moon_market_worker() void {
    var size: usize = 0;
    if (!native.moon_market_read(&buffer,buffer.len,&size)) {
        state.store(.failed,.release);
        return;
    }
    used = size;
    state.store(.ready,.release);
}

pub fn changed() bool {
    const current = state.load(.acquire);
    if (current == notified) return false;
    notified = current;
    return true;
}

fn escape(writer: *std.Io.Writer,text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(ch),
        }
    }
}

fn entries(allocator: std.mem.Allocator,writer: *std.Io.Writer) !void {
    const catalog = std.json.parseFromSlice(Catalog,allocator,buffer[0..used],.{}) catch {
        try writer.writeAll("<p role=status>目录格式无效。请按 F5 重试。</p>");
        return;
    };
    defer catalog.deinit();
    if (catalog.value.version != 1 or catalog.value.entries.len > 32) {
        try writer.writeAll("<p role=status>暂时无法读取此版本的插件目录。</p>");
        return;
    }
    try writer.writeAll("<label for=search>搜索插件</label><input id=search type=search placeholder='输入名称或插件 ID'><section id=cards>");
    for (catalog.value.entries) |entry| {
        if (entry.id.len > 96 or entry.name.len > 128 or entry.description.len > 600 or entry.permission.len > 128) continue;
        try writer.writeAll("<article><h2>");
        try escape(writer,entry.name);
        try writer.writeAll("</h2><p>");
        try escape(writer,entry.description);
        try writer.writeAll("</p><small>");
        try escape(writer,entry.id);
        try writer.writeAll(" · ");
        try escape(writer,entry.permission);
        try writer.writeAll("</small>");
        if (std.mem.startsWith(u8,entry.url,"https://docs.browser.moonl.cloud/")) {
            try writer.writeAll("<p><a href=\"");
            try escape(writer,entry.url);
            try writer.writeAll("\">查看说明</a></p>");
        }
        try writer.writeAll("</article>");
    }
    try writer.writeAll(
        \\</section><p id=empty hidden role=status>没有匹配的插件。</p><script>
        \\const search=document.querySelector('#search'), cards=[...document.querySelectorAll('#cards article')];
        \\search.addEventListener('input',()=>{ const q=search.value.trim().toLowerCase();
        \\ for(const card of cards)card.hidden=!card.textContent.toLowerCase().includes(q);
        \\ document.querySelector('#empty').hidden=cards.some(card=>!card.hidden);
        \\});
        \\</script>
    );
}

pub fn document(allocator: std.mem.Allocator) ![:0]u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const out = &body.writer;
    try out.writeAll(
        \\<html lang=zh-CN><meta charset=utf-8><meta name=viewport content="width=device-width, initial-scale=1">
        \\<title>插件市场 · Moon Browser</title><style>
        \\:root{color-scheme:light dark;color:#14161d;background:#f5f6f9;font:15px/1.55 system-ui,sans-serif}
        \\main{max-width:62rem;margin:auto;padding:46px 24px;color:inherit}h1{font-size:2rem;margin:0}
        \\label{display:block;font-weight:600;margin-top:24px}input{box-sizing:border-box;width:min(100%,28rem);margin:6px 0 18px;padding:10px 12px;border:1px solid #d9dce6;border-radius:8px;font:inherit}
        \\section{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,16rem),1fr));gap:14px}
        \\article{background:#fff;border:1px solid #d9dce6;border-radius:12px;padding:18px}h2{font-size:1.13rem;margin:0}
        \\p{margin:8px 0}small,p.intro{color:#51586a}a{color:#344db4}
        \\@media(prefers-color-scheme:dark){:root{color:#e9ebf2;background:#191c23}article{background:#242630;border-color:#363b49}small,p.intro{color:#b9c1d4}a{color:#a7b4ff}}
        \\</style><main><h1>插件市场</h1><p class=intro>Moon 插件目录。随浏览器提供的插件可在工具栏菜单中启用和授权。</p>
    );
    switch (state.load(.acquire)) {
        .ready => try entries(allocator,out),
        .failed => try out.writeAll("<p role=status>暂时无法连接 Moon 插件市场。请按 F5 重试。</p>"),
        else => try out.writeAll("<p role=status>正在加载 Moon 插件目录…</p>"),
    }
    try out.writeAll("</main></html>");
    return allocator.dupeSentinel(u8,body.written(),0);
}
