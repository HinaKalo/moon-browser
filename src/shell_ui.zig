//! MoonBrowser native shell chrome renderer powered by MoonUI (`moon-win32-modern`).
//! Renders the sidebar, top toolbar, address bar frame, bookmark bar, New Tab / Home page,
//! and window chrome. The shell updates the retained draw list when its state changes.
//! WM_PAINT presents that list through DirectComposition.
const std = @import("std");
const moonui = @import("moonui");
const native = @import("native");

const Renderer = moonui.renderer.Renderer;
const DrawList = moonui.drawlist.DrawList;
const TextStyle = moonui.drawlist.TextStyle;
const Color = moonui.Color;
const Theme = moonui.Theme;
const Palette = moonui.Palette;
const Rect = moonui.Rect;
const Vec2 = moonui.Vec2;
const v2 = moonui.v2;
const Icon = moonui.Icon;

const PAD: f32 = 8;
const SIDEBAR: f32 = 264;
const TOP: f32 = 48;
const ROW: f32 = 37;
const TAB_START: f32 = 134;
const FOOTER: f32 = 48;
const BOOKMARK_HEIGHT: f32 = 32;
const ADDRESS_TOP: f32 = 8;
const ADDRESS_HEIGHT: f32 = 32;
const HOME_FIELD_HEIGHT: f32 = 44;

const BOOKMARK_OVERFLOW: usize = native.MOON_BOOKMARK_BAR_PAGE;
const BOOKMARK_MANAGE: usize = native.MOON_BOOKMARK_BAR_PAGE + 1;

const DWMWA_USE_IMMERSIVE_DARK_MODE: u32 = 20;
const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
const DWMWCP_DONOTROUND: u32 = 1;
const DWMWCP_ROUND: u32 = 2;

extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: *anyopaque,
    dwAttribute: u32,
    pvAttribute: *const anyopaque,
    cbAttribute: u32,
) callconv(.winapi) i32;

const ShellRendererState = struct {
    hwnd: ?*anyopaque = null,
    renderer: ?Renderer = null,
    main_dl: DrawList = DrawList.init(std.heap.page_allocator),
    background: Color = undefined,
    dwm_applied: bool = false,
    dwm_dark: bool = false,
    dwm_square: bool = false,
};

var g_state: ShellRendererState = .{};
const empty_overlay = DrawList.init(std.heap.page_allocator);

fn syncWindowDwm(hwnd: *anyopaque, dark: bool, square: bool) void {
    if (g_state.dwm_applied and g_state.dwm_dark == dark and g_state.dwm_square == square) return;
    const use_dark: i32 = if (dark) 1 else 0;
    _ = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &use_dark, @sizeOf(i32));
    const corner: u32 = if (square) DWMWCP_DONOTROUND else DWMWCP_ROUND;
    _ = DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, @sizeOf(u32));
    g_state.dwm_applied = true;
    g_state.dwm_dark = dark;
    g_state.dwm_square = square;
}

pub export fn moon_shell_ui_release() void {
    if (g_state.renderer) |*r| r.deinit();
    g_state.main_dl.deinit();
    g_state = .{};
}

fn ensureRenderer(hwnd: *anyopaque, pixel_w: u32, pixel_h: u32, dpi: u32) ?*Renderer {
    if (pixel_w == 0 or pixel_h == 0) return null;
    const dpi_f: f32 = @floatFromInt(@max(dpi, 96));

    if (g_state.renderer != null and g_state.hwnd != hwnd) {
        moon_shell_ui_release();
    }
    if (g_state.renderer == null) {
        const r = Renderer.init(
            std.heap.page_allocator,
            @ptrCast(hwnd),
            pixel_w,
            pixel_h,
            dpi_f,
        ) catch return null;
        g_state.renderer = r;
        g_state.hwnd = hwnd;
    } else if (g_state.renderer) |*r| {
        r.resize(pixel_w, pixel_h, dpi_f);
    }
    return if (g_state.renderer) |*r| r else null;
}

fn cSlice(ptr: [*c]const u8) []const u8 {
    if (ptr == null) return "";
    return std.mem.span(ptr);
}

fn fixedSlice(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

fn activeTheme(dark: bool) *const Theme {
    return if (dark) &moonui.themes.midnight else &moonui.themes.daylight;
}

fn frameBg(theme: *const Theme) Color {
    return if (theme.dark) theme.palette.bg else theme.palette.bg_subtle;
}

fn hoverBg(theme: *const Theme) Color {
    return if (theme.dark) Color.hex(0x252934) else Color.hex(0xE8EBF0);
}

fn softAccent(theme: *const Theme) Color {
    return if (theme.dark) theme.palette.accent.fade(0.20) else theme.palette.accent.fade(0.12);
}

fn groupColor(id: c_uint, dark: bool) Color {
    const light_tones = [_]Color{
        Color.hex(0x5B4DF0),
        Color.hex(0x0F766E),
        Color.hex(0xB45309),
        Color.hex(0xBE123C),
        Color.hex(0x7E22CE),
        Color.hex(0x475569),
    };
    const dark_tones = [_]Color{
        Color.hex(0x8B7CFF),
        Color.hex(0x2DD4BF),
        Color.hex(0xFBBF24),
        Color.hex(0xFB7185),
        Color.hex(0xC084FC),
        Color.hex(0x94A3B8),
    };
    const idx: usize = @intCast(id % light_tones.len);
    return if (dark) dark_tones[idx] else light_tones[idx];
}

fn pointed(f: *const native.MoonShellFrame, x: f32, y: f32, w: f32, h: f32) bool {
    const hx: f32 = @floatFromInt(f.hover_x);
    const hy: f32 = @floatFromInt(f.hover_y);
    return hx >= x and hx < x + w and hy >= y and hy < y + h;
}

fn paneLeft(f: *const native.MoonShellFrame) f32 {
    return if (f.focus_mode) PAD else PAD + SIDEBAR + PAD;
}

fn bookmarkBarDrawn(f: *const native.MoonShellFrame) bool {
    return f.bookmark_visible and !f.fullscreen;
}

fn paneTop(f: *const native.MoonShellFrame) f32 {
    return TOP + (if (bookmarkBarDrawn(f)) BOOKMARK_HEIGHT else 0);
}

fn addressLeft(f: *const native.MoonShellFrame) f32 {
    return paneLeft(f) + 106;
}

fn addressRight(width: f32) f32 {
    return width - 222;
}

fn homeLeft(f: *const native.MoonShellFrame, width: f32) f32 {
    const left = paneLeft(f);
    const available = width - left - PAD;
    return left + (if (available > 768) @floor((available - 720) * 0.5) else @as(f32, 24));
}

fn homeWidth(f: *const native.MoonShellFrame, width: f32) f32 {
    const available = width - PAD - homeLeft(f, width) - 24;
    return @max(@min(available, 720), 120);
}

fn homeTop(f: *const native.MoonShellFrame, height: f32) f32 {
    return paneTop(f) + (if (height > 520) @as(f32, 70) else @as(f32, 32));
}

fn tabCapacity(height: f32) usize {
    const avail = height - TAB_START - FOOTER - 6;
    if (avail < ROW) return 1;
    return @intFromFloat(@floor(avail / ROW));
}

fn ellipsizeText(r: *Renderer, buf: []u8, str: []const u8, style: TextStyle, max_w: f32) []const u8 {
    if (str.len == 0 or max_w <= 6) return "";
    if (r.measureText(str, style, 0).x <= max_w) return str;
    const dots = "…";
    const dots_w = r.measureText(dots, style, 0).x;
    if (dots_w >= max_w) return dots;
    const limit = max_w - dots_w;

    // Binary search on UTF-8 byte boundary
    var lo: usize = 0;
    var hi: usize = str.len;
    while (lo < hi) {
        var mid = lo + (hi - lo + 1) / 2;
        while (mid > lo and (str[mid] & 0xC0) == 0x80) : (mid -= 1) {}
        if (mid == lo) {
            var next = lo + 1;
            while (next < hi and (str[next] & 0xC0) == 0x80) : (next += 1) {}
            if (r.measureText(str[0..next], style, 0).x <= limit) {
                lo = next;
            } else break;
        } else if (r.measureText(str[0..mid], style, 0).x <= limit) {
            lo = mid;
        } else {
            hi = mid - 1;
            while (hi > lo and (str[hi] & 0xC0) == 0x80) : (hi -= 1) {}
        }
    }
    const copy_len = @min(lo, buf.len -| dots.len);
    @memcpy(buf[0..copy_len], str[0..copy_len]);
    @memcpy(buf[copy_len .. copy_len + dots.len], dots);
    return buf[0 .. copy_len + dots.len];
}

fn drawTextBox(
    r: *Renderer,
    dl: *DrawList,
    str: []const u8,
    rect: Rect,
    col: Color,
    style: TextStyle,
    center: bool,
) void {
    if (str.len == 0 or rect.w() <= 2 or rect.h() <= 2) return;
    var scratch: [512]u8 = undefined;
    const display = ellipsizeText(r, &scratch, str, style, rect.w());
    if (display.len == 0) return;
    const m = r.measureText(display, style, 0);
    const ty = rect.min.y + (rect.h() - m.y) * 0.5;
    const tx = if (center) rect.min.x + (rect.w() - m.x) * 0.5 else rect.min.x;
    dl.pushClip(rect);
    dl.text(v2(tx, ty), col, display, style, 0);
    dl.popClip();
}

fn drawMoonMark(dl: *DrawList, x: f32, y: f32, size: f32, bg: Color, accent: Color) void {
    const rad = size * 0.5;
    const cx = x + rad;
    const cy = y + rad;
    dl.circleFilled(v2(cx, cy), rad, accent);
    const cut_r = size * 0.405;
    dl.circleFilled(v2(x + size * 0.37 + cut_r, y - size * 0.10 + cut_r), cut_r, bg);
    const star_r = size * 0.08 + 0.6;
    dl.circleFilled(v2(x + size * 0.76 + star_r, y + size * 0.12 + star_r), star_r, accent);
}

fn drawIconBtn(
    f: *const native.MoonShellFrame,
    dl: *DrawList,
    theme: *const Theme,
    icon_kind: Icon,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    icon_size: f32,
    enabled: bool,
) void {
    const hot = enabled and pointed(f, x, y, w, h);
    if (hot) {
        dl.rectFilled(Rect.xywh(x, y, w, h), hoverBg(theme), theme.radius.sm);
    }
    const col = if (!enabled) theme.palette.text_faint else if (hot) theme.palette.text else theme.palette.text_muted;
    moonui.icons.draw(dl, icon_kind, v2(x + w * 0.5, y + h * 0.5), icon_size, col);
}

fn drawMutedSpeakerIcon(dl: *DrawList, cx: f32, cy: f32, col: Color) void {
    // Crisp vector muted speaker icon on a 14x14 footprint
    const pts = [_]Vec2{
        v2(cx - 5.0, cy - 2.0),
        v2(cx - 2.5, cy - 2.0),
        v2(cx + 0.5, cy - 4.5),
        v2(cx + 0.5, cy + 4.5),
        v2(cx - 2.5, cy + 2.0),
        v2(cx - 5.0, cy + 2.0),
    };
    dl.polyline(&pts, true, col, 1.3);
    dl.line(v2(cx + 2.5, cy - 2.2), v2(cx + 6.0, cy + 2.2), col, 1.4);
    dl.line(v2(cx + 6.0, cy - 2.2), v2(cx + 2.5, cy + 2.2), col, 1.4);
}

fn drawPinIcon(dl: *DrawList, cx: f32, cy: f32, col: Color) void {
    dl.line(v2(cx - 3.5, cy - 3.5), v2(cx + 3.5, cy - 3.5), col, 1.6);
    dl.line(v2(cx, cy - 3.5), v2(cx, cy + 4.5), col, 1.6);
    dl.line(v2(cx - 4.0, cy + 0.5), v2(cx + 4.0, cy + 0.5), col, 1.6);
}

fn drawSiteSlidersIcon(dl: *DrawList, cx: f32, cy: f32, col: Color, bg: Color) void {
    dl.line(v2(cx - 6.0, cy - 3.2), v2(cx + 6.0, cy - 3.2), col, 1.4);
    dl.line(v2(cx - 6.0, cy + 3.2), v2(cx + 6.0, cy + 3.2), col, 1.4);
    dl.circleFilled(v2(cx - 2.0, cy - 3.2), 2.3, bg);
    dl.circleStroke(v2(cx - 2.0, cy - 3.2), 2.2, col, 1.4);
    dl.circleFilled(v2(cx + 2.5, cy + 3.2), 2.3, bg);
    dl.circleStroke(v2(cx + 2.5, cy + 3.2), 2.2, col, 1.4);
}

fn drawMaximizeGlyph(dl: *DrawList, cx: f32, cy: f32, zoomed: bool, col: Color) void {
    if (zoomed) {
        // Restore overlapping squares
        dl.rectStroke(Rect.xywh(cx - 3.5, cy - 5.0, 8.5, 8.5), col, 1.5, 1.3);
        dl.rectStroke(Rect.xywh(cx - 5.5, cy - 3.0, 8.5, 8.5), col, 1.5, 1.3);
    } else {
        dl.rectStroke(Rect.xywh(cx - 5.0, cy - 5.0, 10.0, 10.0), col, 1.5, 1.35);
    }
}

fn drawSidebarToggleIcon(dl: *DrawList, cx: f32, cy: f32, open: bool, col: Color) void {
    const x = cx - 7.5;
    const y = cy - 6.5;
    if (open) {
        dl.rectFilled(Rect.xywh(x + 1.0, y + 1.0, 4.0, 11.0), col.fade(0.28), 1.0);
    }
    dl.rectStroke(Rect.xywh(x, y, 15.0, 13.0), col, 2.5, 1.4);
    dl.line(v2(x + 5.0, y + 0.5), v2(x + 5.0, y + 12.5), col, 1.4);
}

fn paintSidebar(r: *Renderer, dl: *DrawList, f: *const native.MoonShellFrame, theme: *const Theme, height: f32) void {
    const p = &theme.palette;
    const bg = frameBg(theme);
    const x: f32 = 12;
    const w: f32 = SIDEBAR - 8;

    // Brand header
    drawMoonMark(dl, 17, 15, 20, bg, p.accent);
    drawTextBox(r, dl, "MoonBrowser", Rect.xywh(45, 0, 150, TOP), p.text, .{
        .size = 14.5,
        .weight = .semibold,
    }, false);
    if (f.private_window) {
        const badge_rect = Rect.xywh(x + w - 50, 14, 48, 20);
        dl.rectFilled(badge_rect, softAccent(theme), theme.radius.full);
        drawTextBox(r, dl, "隐私", badge_rect, p.accent, .{ .size = 11, .weight = .medium }, true);
    }

    // Command / Search trigger pill
    const search_rect = Rect.xywh(x, 50, w, 34);
    const search_hot = pointed(f, x, 50, w, 34);
    dl.rectFilled(search_rect, if (search_hot) p.surface else p.surface_raised, theme.radius.md);
    dl.rectStroke(search_rect, if (search_hot) p.border_strong else p.border, theme.radius.md, 1.0);
    moonui.icons.draw(dl, .search, v2(x + 18, 50 + 17), 14, p.text_muted);
    drawTextBox(r, dl, "搜索或输入网址", Rect.xywh(x + 33, 50, 147, 34), p.text_muted, .{
        .size = 13,
        .weight = .regular,
    }, false);
    const kbd_rect = Rect.xywh(x + w - 57, 57, 49, 20);
    dl.rectFilled(kbd_rect, bg, theme.radius.sm - 1);
    dl.rectStroke(kbd_rect, p.border, theme.radius.sm - 1, 1.0);
    drawTextBox(r, dl, "Ctrl K", kbd_rect, p.text_faint, .{ .size = 11, .weight = .medium, .mono = true }, true);

    // Section header ("标签页" / selection count) + New tab button
    const selection_count = native.moon_tab_selection_count();
    var sel_buf: [48]u8 = undefined;
    const header_text = if (selection_count > 0)
        std.fmt.bufPrint(&sel_buf, "已选择 {d} 个标签", .{selection_count}) catch "标签页"
    else
        "标签页";
    drawTextBox(
        r,
        dl,
        header_text,
        Rect.xywh(x + 8, 92, 160, 30),
        if (selection_count > 0) p.accent else p.text_muted,
        .{ .size = 12, .weight = .semibold },
        false,
    );
    drawIconBtn(f, dl, theme, .plus, x + w - 32, 92, 30, 29, 15, true);

    // Subtle divider
    dl.rectFilled(Rect.xywh(x, 125, w, 1), p.border, 0);

    // Tab strip rows
    const count = f.sidebar_count;
    const capacity = tabCapacity(height);
    if (f.sidebar_rows != null) {
        var i: usize = 0;
        while (i < capacity and f.first_tab + i < count) : (i += 1) {
            const row = &f.sidebar_rows[f.first_tab + i];
            const tab = row.tab;
            const y = TAB_START + @as(f32, @floatFromInt(i)) * ROW;
            const row_h = ROW - 3;
            const selected = row.active;
            const hot = pointed(f, x, y, w, row_h);

            if (row.header) {
                const tone = groupColor(row.color, theme.dark);
                const receiving = f.drag_into_group and f.drag_anchor == native.moon_tab_id(tab);
                const row_rect = Rect.xywh(x, y, w, row_h);
                const fill_col = if (receiving) softAccent(theme) else if (selected) p.surface else if (hot) hoverBg(theme) else p.surface_raised;
                dl.rectFilled(row_rect, fill_col, theme.radius.md);
                if (selected or receiving) {
                    dl.rectStroke(row_rect, if (receiving) p.accent else p.border, theme.radius.md, 1.0);
                }
                dl.rectFilled(Rect.xywh(x + 1, y + 6, 3, row_h - 12), tone, 1.5);
                moonui.icons.draw(
                    dl,
                    if (row.collapsed) .chevron_right else .chevron_down,
                    v2(x + 19, y + row_h * 0.5),
                    13,
                    tone,
                );
                const gname = cSlice(native.moon_group_name(row.group));
                drawTextBox(r, dl, gname, Rect.xywh(x + 34, y, w - 79, row_h), p.text, .{
                    .size = 13,
                    .weight = .medium,
                }, false);
                var count_buf: [16]u8 = undefined;
                const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{row.members}) catch "";
                const pill = Rect.xywh(x + w - 34, y + 7, 26, row_h - 14);
                dl.rectFilled(pill, bg, theme.radius.full);
                drawTextBox(r, dl, count_str, pill, p.text_muted, .{ .size = 11, .weight = .medium }, true);
                continue;
            }

            const flags = native.moon_tab_flags(tab);
            const multi_selected = (flags & native.MOON_TAB_SELECTED) != 0;
            const dragged = f.drag_active and native.moon_tab_id(tab) == f.drag_source;
            const indent: f32 = if (row.group != 0) 12 else 0;
            const item_rect = Rect.xywh(x + indent, y, w - indent, row_h);

            if (selected or hot or dragged or multi_selected) {
                const bg_col = if (dragged or multi_selected)
                    softAccent(theme)
                else if (selected)
                    p.surface
                else
                    hoverBg(theme);
                if (selected and !dragged and !multi_selected) {
                    dl.shadow(item_rect, theme.radius.md, p.shadow.fade(0.35), 4, 1);
                }
                dl.rectFilled(item_rect, bg_col, theme.radius.md);
                if (selected) {
                    dl.rectStroke(item_rect, p.border, theme.radius.md, 1.0);
                }
            }
            if (row.group != 0) {
                dl.rectFilled(Rect.xywh(x + 5, y, 2, ROW - 2), groupColor(row.color, theme.dark), 1);
            }
            if (selected) {
                dl.rectFilled(Rect.xywh(x + indent + 1, y + 7, 3, row_h - 14), p.accent, 1.5);
            }
            if (multi_selected) {
                dl.rectFilled(Rect.xywh(x + w - 5, y + 8, 2, row_h - 16), p.accent, 1);
            }

            const is_failed = (flags & native.MOON_TAB_FAILED) != 0;
            const is_dormant = (flags & native.MOON_TAB_DORMANT) != 0;
            const is_loading = (flags & native.MOON_TAB_LOADING) != 0;
            const is_pinned = (flags & native.MOON_TAB_PINNED) != 0;
            const tone = if (is_failed) p.danger else if (is_dormant) p.text_faint else if (is_loading) p.warning else p.accent;

            const icon_box = Rect.xywh(x + indent + 11, y + 8, 18, 18);
            dl.rectFilled(icon_box, if (selected) softAccent(theme) else p.surface_raised, 5);
            if (is_pinned) {
                drawPinIcon(dl, icon_box.center().x, icon_box.center().y, tone);
            } else {
                dl.circleFilled(icon_box.center(), 3.2, tone);
            }

            const raw_label = cSlice(native.moon_tab_label(tab));
            const label = if (raw_label.len > 0) raw_label else "标签页";
            const audio_muted = (flags & (native.MOON_TAB_MUTED | native.MOON_TAB_SITE_MUTED)) != 0;
            const text_w = w - indent - 71 - (if (audio_muted) @as(f32, 20) else 0);
            drawTextBox(
                r,
                dl,
                label,
                Rect.xywh(x + indent + 38, y, text_w, row_h),
                if (selected or multi_selected) p.text else p.text_muted,
                .{ .size = 13, .weight = if (selected) .medium else .regular },
                false,
            );

            if (audio_muted) {
                drawMutedSpeakerIcon(dl, x + w - 41, y + row_h * 0.5, p.text_muted);
            }
            if ((selected or hot) and !is_pinned) {
                drawIconBtn(f, dl, theme, .x, x + w - 29, y + 3, 25, row_h - 6, 12, true);
            }
        }
    }

    // Drag reorder guide line
    if (f.drag_anchor != 0 and !f.drag_into_group) {
        const gy: f32 = @floatFromInt(f.drag_guide);
        dl.rectFilled(Rect.xywh(x + 4, gy, w - 8, 3), p.accent, 1.5);
    }

    // Slim scrollbar
    if (count > capacity) {
        const track = height - TAB_START - FOOTER - 6;
        if (track > 0) {
            const thumb = @max(track * @as(f32, @floatFromInt(capacity)) / @as(f32, @floatFromInt(count)), 16);
            const thumb_y = TAB_START + track * @as(f32, @floatFromInt(f.first_tab)) / @as(f32, @floatFromInt(count));
            dl.rectFilled(Rect.xywh(SIDEBAR + 3, thumb_y, 3, thumb), p.border_strong, 1.5);
        }
    }

    // Sidebar footer
    const footer_y = height - FOOTER;
    dl.rectFilled(Rect.xywh(x, footer_y, w, 1), p.border, 0);
    drawIconBtn(f, dl, theme, .grid, x + 2, footer_y + 7, 32, 31, 15, true);
    drawIconBtn(f, dl, theme, .layers, x + 39, footer_y + 7, 32, 31, 15, true);
    drawIconBtn(f, dl, theme, .more, x + 76, footer_y + 7, 32, 31, 15, true);
}

fn paintBookmarkBar(r: *Renderer, dl: *DrawList, f: *const native.MoonShellFrame, theme: *const Theme, width: f32) void {
    const p = &theme.palette;
    const right = width - PAD - 4;
    var x = paneLeft(f) + 4;
    const top = TOP + 1;
    const h = BOOKMARK_HEIGHT - 5;

    if (f.bookmark_count == 0) {
        const btn = Rect.xywh(x, top, 104, h);
        if (pointed(f, btn.min.x, btn.min.y, btn.w(), btn.h())) {
            dl.rectFilled(btn, hoverBg(theme), theme.radius.sm);
        }
        moonui.icons.draw(dl, .star, v2(x + 13, top + h * 0.5), 13, p.accent);
        drawTextBox(r, dl, "管理书签", Rect.xywh(x + 25, top, 74, h), p.text, .{ .size = 12.5, .weight = .regular }, false);
        return;
    }

    var shown: usize = 0;
    if (f.bookmark_roots != null) {
        while (shown < f.bookmark_count) : (shown += 1) {
            const entry = &f.bookmark_roots[shown];
            const label = fixedSlice(&entry.text);
            const char_count = std.unicode.calcUtf16LeLen(label) catch label.len;
            const raw_w: f32 = 32 + @as(f32, @floatFromInt(char_count)) * 8;
            const item_w = std.math.clamp(raw_w, 62, 182);
            if (x + item_w > right - 35) break;

            const btn = Rect.xywh(x, top, item_w, h);
            if (pointed(f, x, top, item_w, h)) {
                dl.rectFilled(btn, hoverBg(theme), theme.radius.sm);
            }
            const is_folder = entry.id == 0;
            moonui.icons.draw(dl, if (is_folder) .folder else .star, v2(x + 13, top + h * 0.5), 13, p.accent);
            drawTextBox(r, dl, label, Rect.xywh(x + 25, top, item_w - 30, h), p.text, .{
                .size = 12.5,
                .weight = .regular,
            }, false);
            x += item_w + 3;
        }
    }

    if (shown < f.bookmark_count or f.bookmark_more) {
        const ov_x = right - 30;
        drawIconBtn(f, dl, theme, .chevron_right, ov_x, top, 30, h, 14, true);
    }
    _ = BOOKMARK_OVERFLOW;
    _ = BOOKMARK_MANAGE;
}

fn paintHome(r: *Renderer, dl: *DrawList, f: *const native.MoonShellFrame, theme: *const Theme, width: f32, height: f32) void {
    const p = &theme.palette;
    const x = homeLeft(f, width);
    const y = homeTop(f, height);
    const w = homeWidth(f, width);

    // Hero emblem + title
    drawMoonMark(dl, x, y + 7, 65, p.surface, p.accent);
    drawTextBox(
        r,
        dl,
        if (f.private_window) "隐私浏览" else "MoonBrowser",
        Rect.xywh(x + 87, y, w - 87, 48),
        p.text,
        .{ .size = 28, .weight = .bold },
        false,
    );
    drawTextBox(
        r,
        dl,
        if (f.private_window) "此窗口的网页数据在关闭后清除。" else "新标签页",
        Rect.xywh(x + 88, y + 48, w - 88, 25),
        p.text_muted,
        .{ .size = 13.5, .weight = .regular },
        false,
    );

    // Modern search bar card
    const search_y = y + 98;
    const search_rect = Rect.xywh(x, search_y, w, HOME_FIELD_HEIGHT);
    dl.shadow(search_rect, theme.radius.lg, p.shadow.fade(0.45), 10, 3);
    if (f.home_focused) {
        dl.focusRing(search_rect, theme.radius.lg, p.accent, 0.35);
    }
    dl.rectFilled(search_rect, p.surface_raised, theme.radius.lg);
    dl.rectStroke(search_rect, if (f.home_focused) p.accent else p.border, theme.radius.lg, if (f.home_focused) 1.5 else 1.0);
    moonui.icons.draw(dl, .search, v2(x + 22, search_y + HOME_FIELD_HEIGHT * 0.5), 16, if (f.home_focused) p.accent else p.text_muted);

    if (f.private_window) {
        drawTextBox(r, dl, "手动保存的文件会保留。", Rect.xywh(x, search_y + 56, w, 28), p.text_muted, .{
            .size = 13,
            .weight = .regular,
        }, false);
        return;
    }

    if (height - search_y < 145) return;

    drawTextBox(r, dl, "快捷功能", Rect.xywh(x, search_y + 61, w, 26), p.text_muted, .{
        .size = 12.5,
        .weight = .semibold,
    }, false);

    const tile = @max(@min((w - 20) / 3.0, 176), 80);
    const action_count = @min(native.moon_action_count(true), 3);
    const tile_icons = [_]Icon{ .layers, .grid, .sparkles };

    var i: usize = 0;
    while (i < action_count) : (i += 1) {
        const left = x + @as(f32, @floatFromInt(i)) * (tile + 10);
        const top = search_y + 94;
        const card_rect = Rect.xywh(left, top, tile, 61);
        const hot = pointed(f, left, top, tile, 61);

        dl.shadow(card_rect, theme.radius.lg, p.shadow.fade(if (hot) 0.55 else 0.30), if (hot) 8 else 4, 2);
        dl.rectFilled(card_rect, if (hot) hoverBg(theme) else p.surface_raised, theme.radius.lg);
        dl.rectStroke(card_rect, if (hot) p.border_strong else p.border, theme.radius.lg, 1.0);

        const icon_rect = Rect.xywh(left + 12, top + 16, 28, 28);
        dl.rectFilled(icon_rect, softAccent(theme), theme.radius.md);
        moonui.icons.draw(dl, tile_icons[i], icon_rect.center(), 15, p.accent);

        const title = cSlice(native.moon_action_label(i, true));
        drawTextBox(r, dl, title, Rect.xywh(left + 48, top, tile - 56, 61), p.text, .{
            .size = 13,
            .weight = .medium,
        }, false);
    }
}

fn paintChrome(r: *Renderer, dl: *DrawList, f: *const native.MoonShellFrame, theme: *const Theme) void {
    const p = &theme.palette;
    const width: f32 = @floatFromInt(f.width);
    const height: f32 = @floatFromInt(f.height);

    if (f.fullscreen) {
        dl.rectFilled(Rect.xywh(0, 0, width, height), p.surface, 0);
        return;
    }

    const left = paneLeft(f);
    const top = paneTop(f);

    if (!f.focus_mode) {
        paintSidebar(r, dl, f, theme, height);
    }
    if (bookmarkBarDrawn(f)) {
        paintBookmarkBar(r, dl, f, theme, width);
    }

    // Elevated main content viewport card
    const pane_rect = Rect.xywh(left, top, @max(width - left - PAD, 0), @max(height - top - PAD, 0));
    dl.shadow(pane_rect, theme.radius.lg, p.shadow.fade(0.30), 8, 2);
    dl.rectFilled(pane_rect, p.surface, theme.radius.lg);
    dl.rectStroke(pane_rect, p.border, theme.radius.lg, 1.0);

    // Top toolbar navigation buttons
    const controls = native.moon_controls();
    drawIconBtn(f, dl, theme, .arrow_left, left, 8, 31, 32, 15, (controls & 1) != 0);
    drawIconBtn(f, dl, theme, .arrow_right, left + 34, 8, 31, 32, 15, (controls & 2) != 0);
    drawIconBtn(f, dl, theme, .refresh, left + 68, 8, 31, 32, 14, true);

    // Address bar pill
    const addr_x = addressLeft(f);
    const addr_w = @max(addressRight(width) - addr_x, 40);
    const addr_rect = Rect.xywh(addr_x, ADDRESS_TOP, addr_w, ADDRESS_HEIGHT);
    if (f.address_focused) {
        dl.focusRing(addr_rect, theme.radius.md, p.accent, 0.30);
    }
    dl.rectFilled(addr_rect, p.surface_raised, theme.radius.md);
    dl.rectStroke(addr_rect, if (f.address_focused) p.accent else p.border, theme.radius.md, if (f.address_focused) 1.5 else 1.0);

    const active_flags = native.moon_tab_flags(native.moon_active_index());
    if ((active_flags & native.MOON_TAB_HAS_SITE) != 0) {
        const site_btn = Rect.xywh(addr_x + 3, ADDRESS_TOP + 4, 24, 24);
        if (pointed(f, site_btn.min.x, site_btn.min.y, site_btn.w(), site_btn.h())) {
            dl.rectFilled(site_btn, softAccent(theme), theme.radius.sm - 1);
        }
        drawSiteSlidersIcon(dl, site_btn.center().x, site_btn.center().y, p.text_muted, p.surface_raised);
    } else {
        moonui.icons.draw(dl, .search, v2(addr_x + 15, ADDRESS_TOP + ADDRESS_HEIGHT * 0.5), 14, p.text_muted);
    }

    if (f.private_window) {
        const badge_x = addressRight(width) - 67;
        const badge_rect = Rect.xywh(badge_x, ADDRESS_TOP + 4, 62, ADDRESS_HEIGHT - 8);
        dl.rectFilled(badge_rect, softAccent(theme), theme.radius.sm);
        drawTextBox(r, dl, "隐私浏览", badge_rect, p.accent, .{ .size = 11.5, .weight = .medium }, true);
    }

    // Right toolbar controls & window caption buttons
    const can_sidebar = native.moon_appearance_available() or f.focus_mode;
    const sb_x = width - 213;
    const sb_hot = can_sidebar and pointed(f, sb_x, 8, 32, 32);
    if (sb_hot) dl.rectFilled(Rect.xywh(sb_x, 8, 32, 32), hoverBg(theme), theme.radius.sm);
    const sb_col = if (!can_sidebar) p.text_faint else if (sb_hot) p.text else p.text_muted;
    drawSidebarToggleIcon(dl, sb_x + 16, 24, !f.focus_mode, sb_col);
    drawIconBtn(f, dl, theme, .more, width - 175, 8, 32, 32, 15, true);

    // Minimize
    drawIconBtn(f, dl, theme, .minus, width - 138, 0, 44, TOP, 14, true);

    // Maximize / Restore
    const max_x = width - 94;
    const max_hot = pointed(f, max_x, 0, 44, TOP);
    if (max_hot) dl.rectFilled(Rect.xywh(max_x, 1, 44, TOP - 2), hoverBg(theme), theme.radius.sm);
    drawMaximizeGlyph(dl, max_x + 22, TOP * 0.5, f.zoomed, if (max_hot) p.text else p.text_muted);

    // Close
    const close_x = width - 50;
    const close_hot = pointed(f, close_x, 0, 44, TOP);
    if (close_hot) {
        dl.rectFilled(Rect.xywh(close_x, 1, 44, TOP - 2), p.danger, theme.radius.sm);
    }
    moonui.icons.draw(dl, .x, v2(close_x + 22, TOP * 0.5), 14, if (close_hot) p.on_accent else p.text_muted);

    // New Tab / Home page OR loading bar
    if (f.show_home) {
        paintHome(r, dl, f, theme, width, height);
    } else if (native.moon_tab_count() > 0 and (active_flags & native.MOON_TAB_LOADING) != 0) {
        dl.rectFilled(Rect.xywh(left + 12, top + 1, 88, 2.5), p.accent, 1.25);
    }
}

pub export fn moon_shell_ui_update(frame_ptr: [*c]const native.MoonShellFrame) bool {
    if (frame_ptr == null) return false;
    const f: *const native.MoonShellFrame = @ptrCast(frame_ptr);
    const hwnd = f.hwnd orelse return false;
    const surface = f.surface orelse hwnd;
    const r = ensureRenderer(surface, f.pixel_w, f.pixel_h, f.dpi) orelse return false;
    syncWindowDwm(hwnd, f.dark, f.zoomed or f.fullscreen);

    const theme = activeTheme(f.dark);
    g_state.background = frameBg(theme);
    g_state.main_dl.clear();
    paintChrome(r, &g_state.main_dl, f, theme);
    return true;
}

pub export fn moon_shell_ui_present() void {
    if (g_state.renderer) |*r| {
        r.render(g_state.background, &g_state.main_dl, &empty_overlay, false);
    }
}
