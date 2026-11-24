#define COBJMACROS
#define INITGUID
#include "win_internal.h"
#include <d2d1.h>
#include <dwrite.h>
#include <gdiplus.h>
#include <commctrl.h>
#include <commdlg.h>
#include <imm.h>
#include <psapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

static HWND frame, content, address, home_edit, diagnostics, palette, palette_input, palette_list;
static HBRUSH address_brush;
static HFONT edit_font, hero_font;
static UINT dpi = 96;
static HANDLE low_memory;
static char profile_dir[4096], app_dir[4096];
static wchar_t content_status[512];
static size_t first_tab;
static ID2D1Factory *drawing;
static IDWriteFactory *writing;
static IDWriteTextFormat *font_left, *font_center, *font_hero;
static ID2D1HwndRenderTarget *target;
static ID2D1SolidColorBrush *brush;
static ULONG_PTR gdiplus;
static bool force_fallback, quitting;
static bool show_home, focus_mode, tracking_mouse;
static POINT hover = {-1,-1};

typedef struct Theme {
    unsigned frame, panel, field, hover, line, outline, text, muted, accent, soft, danger, loading;
} Theme;
static const Theme light = {
    0xe6e8ee, 0xffffff, 0xf5f6f9, 0xf0f1f6, 0xd9dce6, 0xb5bbcd,
    0x14161d, 0x51586a, 0x4359c5, 0xe8ecff, 0xc13f46, 0xa26721
};
static const Theme dark = {
    0x14161b, 0x191c23, 0x20232c, 0x292d38, 0x363b49, 0x5e687f,
    0xe9ebf2, 0xa3a9bb, 0xa6b6ff, 0x2b365e, 0xf47c82, 0xf0bf73
};
static const Theme *theme = &light;

enum { PAD = 8, SIDEBAR = 264, TOP = 48, ROW = 37, TAB_START = 134, FOOTER = 48 };
enum { MENU_DIAG = 10, MENU_ADD, MENU_THEME, MENU_FOCUS, MENU_PALETTE, MENU_UPDATES, MENU_PLUGIN_BASE = 100, MENU_PLUGIN_STRIDE = 11,
       MENU_SCRIPTS_PICK = 300, MENU_SCRIPTS_BASE = 310 };
enum { ADDRESS_CONTROL = 1001, HOME_CONTROL = 1002, PALETTE_INPUT = 1003, PALETTE_LIST = 1004,
       PALETTE_TAB_OFFSET = 1000 };

typedef struct Canvas {
    ID2D1RenderTarget *d2d;
    GpGraphics *gplus;
    HDC hdc;
} Canvas;

bool moon_utf16(const char *text, wchar_t *out, size_t capacity) {
    if (!text || !capacity) return false;
    out[0] = 0;
    return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, out, (int)capacity) > 0;
}
bool moon_utf8(const wchar_t *text, char *out, size_t capacity) {
    if (!text || !capacity) return false;
    out[0] = 0;
    return WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1, out, (int)capacity, NULL, NULL) > 0;
}
bool moon_path(wchar_t *out, size_t capacity, const wchar_t *directory, const wchar_t *name) {
    int written = swprintf(out, capacity, L"%ls\\%ls", directory, name);
    return written >= 0 && (size_t)written < capacity;
}
static bool init_paths(void) {
    wchar_t executable[2048], local[2048], location[2048];
    DWORD length = GetModuleFileNameW(NULL, executable, ARRAYSIZE(executable));
    if (!length || length >= ARRAYSIZE(executable)) return false;
    wchar_t *slash = wcsrchr(executable, L'\\');
    if (!slash) return false;
    *slash = 0;
    if (!moon_utf8(executable, app_dir, sizeof(app_dir))) return false;
    length = GetEnvironmentVariableW(L"MOON_BROWSER_PROFILE_DIR", location, ARRAYSIZE(location));
    if (length >= ARRAYSIZE(location)) return false;
    if (!length) {
        wchar_t marker[2048];
        if (!moon_path(marker, ARRAYSIZE(marker), executable, L"portable.flag")) return false;
        DWORD attributes = GetFileAttributesW(marker);
        if (attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
            if (!moon_path(location, ARRAYSIZE(location), executable, L"profile")) return false;
        } else {
            length = GetEnvironmentVariableW(L"LOCALAPPDATA", local, ARRAYSIZE(local));
            if (!length || length >= ARRAYSIZE(local) || !moon_path(location, ARRAYSIZE(location), local, L"MoonBrowser\\profile")) return false;
        }
    }
    int error = SHCreateDirectoryExW(NULL, location, NULL);
    if (error != ERROR_SUCCESS && error != ERROR_ALREADY_EXISTS && error != ERROR_FILE_EXISTS) return false;
    return moon_utf8(location, profile_dir, sizeof(profile_dir));
}
const char *moon_profile_dir(void) { return profile_dir; }
const char *moon_app_dir(void) { return app_dir; }
HWND moon_shell_window(void) { return frame; }
HWND moon_shell_content(void) { return content; }
uint64_t moon_clock(void) { return GetTickCount64(); }
uint64_t moon_perf_us(void) {
    LARGE_INTEGER now, frequency;
    QueryPerformanceCounter(&now);
    QueryPerformanceFrequency(&frequency);
    uint64_t cycles = now.QuadPart, rate = frequency.QuadPart;
    return (cycles / rate) * 1000000 + ((cycles % rate) * 1000000) / rate;
}

bool moon_low_memory(void) {
    BOOL low = FALSE;
    return low_memory && QueryMemoryResourceNotification(low_memory, &low) && low;
}
void *moon_process_watch(uint32_t pid) { return OpenProcess(SYNCHRONIZE,FALSE,pid); }
bool moon_process_exited(void *watch) { return WaitForSingleObject(watch,0) == WAIT_OBJECT_0; }
void moon_process_unwatch(void *watch) { CloseHandle(watch); }
size_t moon_memory_samples(MoonSample *samples, size_t cap) {
    // A process snapshot can include stale or reused PIDs. Keep only descendants
    // whose handles still open, and count each snapshot entry once.
    DWORD pids[4096], parents[4096];
    size_t count = 1, found = 0;
    pids[0] = GetCurrentProcessId();
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot != INVALID_HANDLE_VALUE) {
        PROCESSENTRY32W item = { .dwSize = sizeof(item) };
        if (Process32FirstW(snapshot, &item)) do {
            if (item.th32ProcessID != pids[0] && found + 1 < ARRAYSIZE(pids)) {
                ++found;
                pids[found] = item.th32ProcessID;
                parents[found] = item.th32ParentProcessID;
            }
        } while (Process32NextW(snapshot, &item));
        CloseHandle(snapshot);
    }
    for (size_t parent = 0; parent < count; ++parent) {
        for (size_t candidate = count; candidate <= found; ++candidate) {
            if (parents[candidate] != pids[parent]) continue;
            DWORD pid = pids[candidate], ancestor = parents[candidate];
            pids[candidate] = pids[count];
            parents[candidate] = parents[count];
            pids[count] = pid;
            parents[count++] = ancestor;
        }
    }
    size_t written = 0;
    for (size_t index = 0; index < count && written < cap; ++index) {
        HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pids[index]);
        if (!process) continue;
        PROCESS_MEMORY_COUNTERS_EX info = { .cb = sizeof(info) };
        if (K32GetProcessMemoryInfo(process, (PROCESS_MEMORY_COUNTERS *)&info, sizeof(info))) {
            samples[written++] = (MoonSample){pids[index], info.PrivateUsage};
        }
        CloseHandle(process);
    }
    return written;
}
static bool write_file(const char *path, const char *data, DWORD mode) {
    wchar_t buffer[2048];
    if (!moon_utf16(path, buffer, ARRAYSIZE(buffer))) return false;
    HANDLE file = CreateFileW(buffer, mode == OPEN_ALWAYS ? FILE_APPEND_DATA : GENERIC_WRITE,
        FILE_SHARE_READ, NULL, mode, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD wrote = 0, length = (DWORD)strlen(data);
    bool ok = WriteFile(file, data, length, &wrote, NULL) && wrote == length;
    CloseHandle(file);
    return ok;
}
void moon_log(const char *path, const char *line) { write_file(path, line, OPEN_ALWAYS); }
bool moon_read_text(const char *path, char *output, size_t cap) {
    wchar_t buffer[2048];
    if (cap < 2 || !moon_utf16(path, buffer, ARRAYSIZE(buffer))) return false;
    HANDLE file = CreateFileW(buffer, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER length;
    DWORD got = 0;
    bool ok = GetFileSizeEx(file, &length) && length.QuadPart >= 0 && (uint64_t)length.QuadPart < cap &&
        ReadFile(file, output, (DWORD)length.QuadPart, &got, NULL) && got == (DWORD)length.QuadPart;
    CloseHandle(file);
    if (ok) {
        output[got] = 0;
        ok = memchr(output, 0, got) == NULL;
    }
    return ok;
}
bool moon_write_text(const char *path, const char *data) {
    char temporary[4096];
    wchar_t from[2048], to[2048];
    int written = snprintf(temporary, sizeof(temporary), "%s.%lu.tmp", path, GetCurrentProcessId());
    if (written < 0 || written >= (int)sizeof(temporary) || !moon_utf16(path, to, ARRAYSIZE(to)) ||
        !moon_utf16(temporary, from, ARRAYSIZE(from)) || !write_file(temporary, data, CREATE_ALWAYS)) return false;
    if (MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) return true;
    DeleteFileW(from);
    return false;
}
size_t moon_plugin_directories(const char *parent, char *names, size_t stride, size_t cap) {
    wchar_t directory[2048], glob[2048];
    WIN32_FIND_DATAW data;
    if (!moon_utf16(parent, directory, ARRAYSIZE(directory)) ||
        !moon_path(glob, ARRAYSIZE(glob), directory, L"*")) return 0;
    HANDLE find = FindFirstFileW(glob, &data);
    if (find == INVALID_HANDLE_VALUE) return 0;
    size_t used = 0;
    do {
        if ((data.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != FILE_ATTRIBUTE_DIRECTORY ||
            data.cFileName[0] == L'.') continue;
        if (moon_utf8(data.cFileName, names + used * stride, stride)) ++used;
    } while (used < cap && FindNextFileW(find, &data));
    FindClose(find);
    return used;
}

static int px(int value) { return MulDiv(value, dpi, 96); }
static COLORREF rgb(unsigned color) { return RGB(color >> 16, color >> 8, color); }
static D2D1_COLOR_F color_value(unsigned color) {
    return (D2D1_COLOR_F){ (float)((color >> 16) & 255) / 255, (float)((color >> 8) & 255) / 255,
        (float)(color & 255) / 255, 1 };
}
static RECT rectangle(int x, int y, int w, int h) {
    return (RECT){px(x), px(y), px(x + w), px(y + h)};
}
static void fill(Canvas c, int x, int y, int w, int h, unsigned color, float radius) {
    if (w <= 0 || h <= 0) return;
    if (c.d2d) {
        D2D1_COLOR_F tone = color_value(color);
        D2D1_RECT_F shape = { (float)x, (float)y, (float)(x+w), (float)(y+h) };
        ID2D1SolidColorBrush_SetColor(brush, &tone);
        if (radius > 0) {
            D2D1_ROUNDED_RECT rounded = { shape, radius, radius };
            ID2D1RenderTarget_FillRoundedRectangle(c.d2d, &rounded, (ID2D1Brush *)brush);
        } else ID2D1RenderTarget_FillRectangle(c.d2d, &shape, (ID2D1Brush *)brush);
    } else if (c.gplus) {
        GpSolidFill *paint = NULL;
        if (GdipCreateSolidFill(0xff000000u | color, &paint) == Ok) {
            RECT r = rectangle(x,y,w,h);
            GdipFillRectangleI(c.gplus, (GpBrush *)paint, r.left, r.top, r.right-r.left, r.bottom-r.top);
            GdipDeleteBrush((GpBrush *)paint);
        }
    } else {
        RECT r = rectangle(x,y,w,h);
        HBRUSH solid = CreateSolidBrush(rgb(color));
        if (solid) { FillRect(c.hdc, &r, solid); DeleteObject(solid); }
    }
}
static void text_at(Canvas c, const wchar_t *text, int x, int y, int w, int h, unsigned color, bool center) {
    if (!text || !*text || w <= 0) return;
    if (c.d2d) {
        D2D1_COLOR_F tone = color_value(color);
        D2D1_RECT_F shape = { (float)x, (float)y, (float)(x+w), (float)(y+h) };
        ID2D1SolidColorBrush_SetColor(brush, &tone);
        ID2D1RenderTarget_DrawText(c.d2d, text, (UINT32)wcslen(text), center ? font_center : font_left,
            &shape, (ID2D1Brush *)brush, D2D1_DRAW_TEXT_OPTIONS_CLIP, DWRITE_MEASURING_MODE_NATURAL);
    } else {
        RECT r = rectangle(x,y,w,h);
        SetTextColor(c.hdc, rgb(color));
        SetBkMode(c.hdc, TRANSPARENT);
        HFONT old = SelectObject(c.hdc, edit_font);
        DrawTextW(c.hdc, text, -1, &r, DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS |
            DT_NOPREFIX | (center ? DT_CENTER : DT_LEFT));
        SelectObject(c.hdc, old);
    }
}

static int client_width(void) {
    RECT r;
    GetClientRect(frame,&r);
    return MulDiv(r.right,96,dpi);
}
static int client_height(void) {
    RECT r;
    GetClientRect(frame,&r);
    return MulDiv(r.bottom,96,dpi);
}
static int pane_left(void) { return focus_mode ? PAD : PAD + SIDEBAR + PAD; }
static int home_left(int width) {
    int available = width - pane_left() - PAD;
    return pane_left() + (available > 768 ? (available-720)/2 : 24);
}
static int home_width(int width) {
    int available = width - PAD - home_left(width) - 24;
    return available > 720 ? 720 : available;
}
static int home_top(int height) { return TOP + (height > 520 ? 70 : 32); }
static int address_left(void) { return pane_left()+106; }
static int address_right(int width) { return width-222; }
static bool pointed(int x,int y,int w,int h) {
    return hover.x>=x && hover.x<x+w && hover.y>=y && hover.y<y+h;
}
static size_t tab_capacity(void) {
    int room = client_height()-TAB_START-FOOTER-6;
    return room > ROW ? (size_t)(room/ROW) : 1;
}
static void clamp_tab_strip(bool reveal_active) {
    size_t count=moon_tab_count(), capacity=tab_capacity(), active=moon_active_index();
    size_t last=count>capacity ? count-capacity : 0;
    if (first_tab>last) first_tab=last;
    if (reveal_active && active<count) {
        if (active<first_tab) first_tab=active;
        if (active>=first_tab+capacity) first_tab=active-capacity+1;
    }
}
static void ellipse(Canvas c,int x,int y,int w,int h,unsigned color) {
    if (c.d2d) {
        D2D1_COLOR_F tint=color_value(color);
        D2D1_ELLIPSE shape={{x+w*.5f,y+h*.5f},w*.5f,h*.5f};
        ID2D1SolidColorBrush_SetColor(brush,&tint);
        ID2D1RenderTarget_FillEllipse(c.d2d,&shape,(ID2D1Brush *)brush);
    } else if (c.gplus) {
        GpSolidFill *paint=NULL;
        if (GdipCreateSolidFill(0xff000000u|color,&paint)==Ok) {
            GdipFillEllipseI(c.gplus,(GpBrush *)paint,px(x),px(y),px(w),px(h));
            GdipDeleteBrush((GpBrush *)paint);
        }
    } else {
        HBRUSH solid=CreateSolidBrush(rgb(color));
        HBRUSH old=SelectObject(c.hdc,solid);
        HPEN pen=SelectObject(c.hdc,GetStockObject(NULL_PEN));
        Ellipse(c.hdc,px(x),px(y),px(x+w),px(y+h));
        SelectObject(c.hdc,pen);
        SelectObject(c.hdc,old);
        DeleteObject(solid);
    }
}
static void moon_mark(Canvas c,int x,int y,int size,unsigned background) {
    ellipse(c,x,y,size,size,theme->accent);
    ellipse(c,x+size*37/100,y-size/10,size*81/100,size*81/100,background);
    ellipse(c,x+size*76/100,y+size/8,size/7+1,size/7+1,theme->accent);
}
static void icon_button(Canvas c,const wchar_t *glyph,int x,int y,int w,int h,bool enabled) {
    if (enabled && pointed(x,y,w,h)) fill(c,x,y,w,h,theme->hover,7);
    text_at(c,glyph,x,y,w,h,enabled?theme->text:theme->outline,true);
}
static void heading_at(Canvas c,const wchar_t *text,int x,int y,int w,int h) {
    if (c.d2d && font_hero) {
        D2D1_COLOR_F tone=color_value(theme->text);
        D2D1_RECT_F shape={(float)x,(float)y,(float)(x+w),(float)(y+h)};
        ID2D1SolidColorBrush_SetColor(brush,&tone);
        ID2D1RenderTarget_DrawText(c.d2d,text,(UINT32)wcslen(text),font_hero,&shape,
            (ID2D1Brush *)brush,D2D1_DRAW_TEXT_OPTIONS_CLIP,DWRITE_MEASURING_MODE_NATURAL);
    } else {
        RECT r=rectangle(x,y,w,h);
        HFONT old=SelectObject(c.hdc,hero_font);
        SetTextColor(c.hdc,rgb(theme->text));
        SetBkMode(c.hdc,TRANSPARENT);
        DrawTextW(c.hdc,text,-1,&r,DT_VCENTER|DT_SINGLELINE|DT_END_ELLIPSIS|DT_NOPREFIX);
        SelectObject(c.hdc,old);
    }
}
static void paint_sidebar(Canvas c,int height) {
    const int x=12, w=SIDEBAR-8;
    moon_mark(c,17,15,20,theme->frame);
    text_at(c,L"MoonBrowser",45,0,150,TOP,theme->text,false);
    fill(c,x,50,w,34,pointed(x,50,w,34)?theme->panel:theme->field,8);
    text_at(c,L"\x2315",x+6,50,25,34,theme->muted,true);
    text_at(c,L"\u641c\u7d22\u6216\u8f93\u5165\u7f51\u5740",x+33,50,147,34,theme->text,false);
    fill(c,x+w-57,57,49,20,theme->frame,4);
    text_at(c,L"Ctrl K",x+w-57,57,49,20,theme->muted,true);
    text_at(c,L"\u6807\u7b7e\u9875",x+8,92,130,30,theme->muted,false);
    icon_button(c,L"+",x+w-32,92,30,29,true);
    fill(c,x,125,w,1,theme->line,0);
    size_t active=moon_active_index(), count=moon_tab_count(), capacity=tab_capacity();
    for(size_t i=0;i<capacity && first_tab+i<count;++i) {
        size_t tab=first_tab+i;
        int y=TAB_START+(int)i*ROW;
        bool selected=tab==active, hot=pointed(x,y,w,ROW-3);
        unsigned flags=moon_tab_flags(tab);
        if (selected || hot) fill(c,x,y,w,ROW-3,selected?theme->panel:theme->hover,7);
        if (selected) fill(c,x,y+6,3,ROW-15,theme->accent,2);
        unsigned tone=(flags&2)?theme->danger:(flags&1)?theme->muted:(flags&4)?theme->loading:theme->accent;
        fill(c,x+11,y+8,18,18,selected?theme->soft:theme->field,5);
        ellipse(c,x+17,y+14,6,6,tone);
        wchar_t label[512];
        if (!moon_utf16(moon_tab_label(tab),label,ARRAYSIZE(label))) wcscpy(label,L"\u6807\u7b7e\u9875");
        text_at(c,label,x+38,y,w-71,ROW-3,selected?theme->text:theme->muted,false);
        if (selected || hot) icon_button(c,L"\xd7",x+w-29,y+3,25,ROW-9,true);
    }
    if (count>capacity) {
        const int track=height-TAB_START-FOOTER-9, thumb=track*(int)capacity/(int)count;
        if (track>0) fill(c,SIDEBAR+3,TAB_START+track*(int)first_tab/(int)count,2,thumb>12?thumb:12,theme->outline,1);
    }
    int footer=height-FOOTER;
    fill(c,x,footer,w,1,theme->line,0);
    icon_button(c,L"\x229e",x+2,footer+7,32,31,true);
    icon_button(c,L"\x25f7",x+39,footer+7,32,31,true);
    icon_button(c,L"\x2026",x+76,footer+7,32,31,true);
}
static int tile_width(int width) {
    int w=(home_width(width)-20)/3;
    return w>176?176:w;
}
static void paint_home(Canvas c,int width,int height) {
    int x=home_left(width), y=home_top(height), w=home_width(width);
    moon_mark(c,x,y+7,65,theme->panel);
    heading_at(c,L"MoonBrowser",x+87,y,w-87,52);
    text_at(c,L"\u65b0\u6807\u7b7e\u9875",x+88,y+48,w-88,25,theme->muted,false);
    int search=y+98;
    fill(c,x,search,w,44,GetFocus()==home_edit?theme->accent:theme->line,9);
    fill(c,x+1,search+1,w-2,42,theme->field,8);
    text_at(c,L"\x2315",x+5,search,34,44,theme->muted,true);
    if (height-search<145) return;
    text_at(c,L"\u5feb\u6377\u529f\u80fd",x,search+61,w,26,theme->muted,false);
    int tile=tile_width(width);
    for(size_t i=0;i<3 && i<moon_action_count(true);++i) {
        int left=x+(int)i*(tile+10), top=search+94;
        fill(c,left,top,tile,61,pointed(left,top,tile,61)?theme->hover:theme->field,9);
        fill(c,left+10,top+16,28,28,theme->soft,8);
        text_at(c,i==0?L"\x25f7":L"\x229e",left+10,top+16,28,28,theme->accent,true);
        wchar_t title[256];
        if (moon_utf16(moon_action_label(i,true),title,ARRAYSIZE(title)))
            text_at(c,title,left+47,top,tile-52,61,theme->text,false);
    }
}
static void paint_chrome(Canvas c,int width,int height) {
    fill(c,0,0,width,height,theme->frame,0);
    int left=pane_left();
    if (!focus_mode) paint_sidebar(c,height);
    fill(c,left,TOP,width-left-PAD,height-TOP-PAD,theme->line,12);
    fill(c,left+1,TOP+1,width-left-PAD-2,height-TOP-PAD-2,theme->panel,11);
    unsigned controls=moon_controls();
    icon_button(c,L"\x2190",left,8,31,32,controls&1);
    icon_button(c,L"\x2192",left+34,8,31,32,controls&2);
    icon_button(c,L"\x21bb",left+68,8,31,32,true);
    int address_x=address_left(), address_w=address_right(width)-address_x;
    fill(c,address_x,8,address_w,32,GetFocus()==address?theme->accent:theme->line,8);
    fill(c,address_x+1,9,address_w-2,30,theme->field,7);
    text_at(c,L"\x2315",address_x+3,8,24,32,theme->muted,true);
    icon_button(c,L"\x25e7",width-213,8,32,32,true);
    icon_button(c,L"\x2026",width-175,8,32,32,true);
    icon_button(c,L"\x2212",width-138,0,44,TOP,true);
    icon_button(c,IsZoomed(frame)?L"\x29c9":L"\x25a1",width-94,0,44,TOP,true);
    if (pointed(width-50,0,44,TOP)) fill(c,width-50,1,44,TOP-2,theme->danger,7);
    text_at(c,L"\xd7",width-50,0,44,TOP,pointed(width-50,0,44,TOP)?0xffffff:theme->text,true);
    if (show_home) paint_home(c,width,height);
    else if (moon_tab_count() && (moon_tab_flags(moon_active_index())&4))
        fill(c,left+8,TOP+1,74,2,theme->accent,1);
}

static void release_target(void) {
    if (brush) ID2D1SolidColorBrush_Release(brush);
    if (target) ID2D1HwndRenderTarget_Release(target);
    brush = NULL;
    target = NULL;
}
static bool create_target(HWND hwnd) {
    if (force_fallback || !drawing || !font_left || !font_center) return false;
    if (target) return true;
    RECT r;
    GetClientRect(hwnd,&r);
    if (!r.right || !r.bottom) return false;
    D2D1_RENDER_TARGET_PROPERTIES description = { .dpiX = (float)dpi, .dpiY = (float)dpi };
    D2D1_HWND_RENDER_TARGET_PROPERTIES window = {hwnd, {(UINT32)r.right,(UINT32)r.bottom}, D2D1_PRESENT_OPTIONS_NONE};
    if (FAILED(ID2D1Factory_CreateHwndRenderTarget(drawing, &description, &window, &target))) return false;
    D2D1_COLOR_F white = {1,1,1,1};
    if (SUCCEEDED(ID2D1RenderTarget_CreateSolidColorBrush((ID2D1RenderTarget *)target,&white,NULL,&brush))) return true;
    release_target();
    return false;
}
static void chrome_frame(HWND hwnd) {
    PAINTSTRUCT paint;
    HDC dc = BeginPaint(hwnd,&paint);
    RECT r;
    GetClientRect(hwnd,&r);
    int w = MulDiv(r.right,96,dpi);
    int h = MulDiv(r.bottom,96,dpi);
    if (create_target(hwnd)) {
        ID2D1RenderTarget *render = (ID2D1RenderTarget *)target;
        ID2D1RenderTarget_BeginDraw(render);
        paint_chrome((Canvas){.d2d=render,.hdc=dc},w,h);
        if (FAILED(ID2D1RenderTarget_EndDraw(render,NULL,NULL))) {
            release_target();
            InvalidateRect(hwnd,NULL,FALSE);
        }
    } else {
        GpGraphics *graphics = NULL;
        if (gdiplus) GdipCreateFromHDC(dc,&graphics);
        paint_chrome((Canvas){.gplus=graphics,.hdc=dc},w,h);
        if (graphics) GdipDeleteGraphics(graphics);
    }
    EndPaint(hwnd,&paint);
}
static void layout(void) {
    RECT r;
    GetClientRect(frame,&r);
    int width=client_width(), height=client_height();
    int left=px(pane_left()+1), top=px(TOP+1), margin=px(PAD+1);
    int pane_width=r.right-left-margin, pane_height=r.bottom-top-margin;
    MoveWindow(content,left,top,pane_width>0?pane_width:0,pane_height>0?pane_height:0,TRUE);
    if (pane_width>0 && pane_height>0) {
        HRGN corners=CreateRoundRectRgn(0,0,pane_width+1,pane_height+1,px(20),px(20));
        if (corners && !SetWindowRgn(content,corners,TRUE)) DeleteObject(corners);
    }
    int address_width=address_right(width)-address_left()-34;
    MoveWindow(address,px(address_left()+29),px(14),px(address_width>10?address_width:10),px(21),TRUE);
    if (home_edit) {
        int field_width=home_width(width)-48;
        MoveWindow(home_edit,px(home_left(width)+40),px(home_top(height)+110),
            px(field_width>10?field_width:10),px(23),TRUE);
    }
    if (target) {
        D2D1_SIZE_U size = {(UINT32)r.right,(UINT32)r.bottom};
        if (FAILED(ID2D1HwndRenderTarget_Resize(target,&size))) release_target();
    }
    clamp_tab_strip(true);
    InvalidateRect(frame,NULL,FALSE);
}
static void set_font(void) {
    HFONT old = edit_font;
    HFONT old_hero = hero_font;
    edit_font = CreateFontW(-px(14),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
    hero_font = CreateFontW(-px(32),0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
    SendMessageW(address,WM_SETFONT,(WPARAM)edit_font,TRUE);
    if (home_edit) SendMessageW(home_edit,WM_SETFONT,(WPARAM)edit_font,TRUE);
    if (old) DeleteObject(old);
    if (old_hero) DeleteObject(old_hero);
}
unsigned moon_shell_test_dpi(void) {
    RECT outer, parent, child;
    if (!GetWindowRect(frame,&outer)) return 0;
    const UINT original = dpi;
    const UINT requested = original == 144 ? 192 : 144;
    SendMessageW(frame,WM_DPICHANGED,MAKELONG(requested,requested),(LPARAM)&outer);
    bool correct = dpi == requested && GetClientRect(frame,&parent) && GetClientRect(content,&child) &&
        parent.right-child.right == px(pane_left()+1)+px(PAD+1) &&
        parent.bottom-child.bottom == px(TOP+1)+px(PAD+1);
    SendMessageW(frame,WM_DPICHANGED,MAKELONG(original,original),(LPARAM)&outer);
    return correct ? requested : 0;
}
void moon_shell_focus_address(void) { SetFocus(address); SendMessageW(address, EM_SETSEL, 0, -1); }
void moon_shell_address(const char *value, bool force) {
    if (GetFocus() == address && !force) return;
    wchar_t wide[4096];
    if (moon_utf16(value,wide,ARRAYSIZE(wide))) SetWindowTextW(address,wide);
}
void moon_shell_status(const char *value) {
    moon_utf16(value,content_status,ARRAYSIZE(content_status));
    InvalidateRect(content,NULL,FALSE);
}
void moon_shell_show_home(bool visible) {
    if (show_home==visible) return;
    show_home=visible;
    if (visible) SetWindowTextW(home_edit,L"");
    ShowWindow(content,visible?SW_HIDE:SW_SHOWNA);
    ShowWindow(home_edit,visible?SW_SHOWNA:SW_HIDE);
    InvalidateRect(frame,NULL,FALSE);
}
void moon_shell_toggle_sidebar(void) {
    focus_mode=!focus_mode;
    layout();
}
static void refresh_theme(void) {
    HBRUSH old=address_brush;
    address_brush=CreateSolidBrush(rgb(theme->field));
    if (old) DeleteObject(old);
    InvalidateRect(frame,NULL,TRUE);
    InvalidateRect(address,NULL,TRUE);
    InvalidateRect(home_edit,NULL,TRUE);
    InvalidateRect(content,NULL,TRUE);
}
static bool theme_path(char *path,size_t size) {
    int written=snprintf(path,size,"%s\\chrome-theme",moon_profile_dir());
    return written>0 && (size_t)written<size;
}
void moon_shell_toggle_theme(void) {
    theme=theme==&light?&dark:&light;
    char path[4096];
    if (theme_path(path,sizeof(path))) moon_write_text(path,theme==&dark?"dark":"light");
    refresh_theme();
}
void moon_shell_refresh(void) { clamp_tab_strip(true); InvalidateRect(frame,NULL,FALSE); }
void moon_shell_info(const char *title, const char *body) {
    wchar_t heading[125], message[8192];
    if (!moon_utf16(title,heading,ARRAYSIZE(heading)) || !moon_utf16(body,message,ARRAYSIZE(message))) return;
    if (diagnostics && IsWindow(diagnostics)) DestroyWindow(diagnostics);
    diagnostics = CreateWindowExW(WS_EX_TOOLWINDOW,L"MoonInfo",heading,WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT,CW_USEDEFAULT,px(650),px(440),frame,NULL,GetModuleHandleW(NULL),NULL);
    if (!diagnostics) return;
    HWND edit = CreateWindowExW(0,L"EDIT",message,WS_CHILD | WS_VISIBLE | WS_VSCROLL |
        ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY,0,0,0,0,diagnostics,(HMENU)1,GetModuleHandleW(NULL),NULL);
    SendMessageW(edit,WM_SETFONT,(WPARAM)GetStockObject(DEFAULT_GUI_FONT),TRUE);
    SendMessageW(diagnostics,WM_SIZE,0,0);
}
bool moon_shell_confirm(const char *title, const char *body) {
    wchar_t heading[125], message[2048];
    if (!moon_utf16(title,heading,ARRAYSIZE(heading)) || !moon_utf16(body,message,ARRAYSIZE(message))) return false;
    return MessageBoxW(frame,message,heading,MB_YESNO | MB_DEFBUTTON2 | MB_ICONQUESTION) == IDYES;
}
void moon_shell_error(const char *body) {
    wchar_t message[2048];
    if (moon_utf16(body,message,ARRAYSIZE(message)))
        MessageBoxW(frame,message,L"Moon Browser",MB_OK | MB_ICONERROR);
}
void moon_quit(int status) {
    if (quitting) return;
    quitting = true;
    moon_command(MOON_SHUTDOWN,0,NULL);
    if (frame) DestroyWindow(frame);
    PostQuitMessage(status);
}
void moon_engine_test_fallback(bool value) {
    force_fallback = value;
    if (value) release_target();
    if (frame) InvalidateRect(frame,NULL,FALSE);
}

static void open_palette(void);
static void pick_userscript(void) {
    wchar_t file[2048] = {0};
    char path[4096];
    OPENFILENAMEW dialog = {.lStructSize = sizeof(dialog), .hwndOwner = frame,
        .lpstrFilter = L"Lua 脚本 (*.lua)\0*.lua\0\0", .lpstrFile = file, .nMaxFile = ARRAYSIZE(file),
        .lpstrTitle = L"安装 Lua 用户脚本",
        .Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER};
    if (GetOpenFileNameW(&dialog) && moon_utf8(file, path, ARRAYSIZE(path)))
        moon_command(MOON_SCRIPTS_INSTALL, 0, path);
}
static void userscript_menu(HMENU popup) {
    HMENU scripts = CreatePopupMenu();
    if (!scripts) return;
    AppendMenuW(scripts, MF_STRING, MENU_SCRIPTS_PICK, L"安装 Lua 脚本…");
    const size_t count = moon_userscript_count();
    if (count) AppendMenuW(scripts, MF_SEPARATOR, 0, NULL);
    for (size_t i = 0; i < count; ++i) {
        wchar_t name[96], error[200];
        if (!moon_utf16(moon_userscript_label(i), name, ARRAYSIZE(name))) continue;
        HMENU item = CreatePopupMenu();
        if (!item) continue;
        const UINT id = MENU_SCRIPTS_BASE + (UINT)i * 2;
        const bool enabled = moon_userscript_enabled(i);
        AppendMenuW(item, MF_STRING | (enabled ? MF_CHECKED : 0), id, L"启用");
        AppendMenuW(item, MF_STRING, id + 1, L"移除…");
        if (moon_utf16(moon_userscript_error(i), error, ARRAYSIZE(error)) && *error)
            AppendMenuW(item, MF_STRING | MF_GRAYED, 0, error);
        AppendMenuW(scripts, MF_POPUP, (UINT_PTR)item, name);
    }
    AppendMenuW(popup, MF_POPUP, (UINT_PTR)scripts, L"Lua 用户脚本");
}
static void menu(HWND hwnd, RECT button, bool above, bool right_aligned) {
    HMENU popup=CreatePopupMenu();
    if (!popup) return;
    AppendMenuW(popup,MF_STRING,MENU_ADD,L"\u65b0\u5efa\u6807\u7b7e\u9875\tCtrl+T");
    AppendMenuW(popup,MF_STRING,MENU_PALETTE,L"\u547d\u4ee4\u9762\u677f\tCtrl+K");
    AppendMenuW(popup,MF_STRING,MENU_DIAG,L"\u5185\u5b58\u8bca\u65ad\tCtrl+Shift+M");
    AppendMenuW(popup,MF_STRING,MENU_UPDATES,L"\u7248\u672c\u4e0e\u66f4\u65b0");
    AppendMenuW(popup,MF_STRING|(theme==&dark?MF_CHECKED:0),MENU_THEME,L"\u6df1\u8272\u4e3b\u9898\tCtrl+Shift+L");
    AppendMenuW(popup,MF_STRING|(focus_mode?MF_CHECKED:0),MENU_FOCUS,L"\u4e13\u6ce8\u6a21\u5f0f\tCtrl+B");
    userscript_menu(popup);
    size_t count=moon_plugin_count();
    if (count) AppendMenuW(popup,MF_SEPARATOR,0,NULL);
    for(size_t i=0;i<count;++i) {
        wchar_t name[256],action[256];
        if (!moon_utf16(moon_plugin_label(i),name,ARRAYSIZE(name))) continue;
        HMENU sub=CreatePopupMenu();
        if (!sub) continue;
        unsigned flags=moon_plugin_flags(i), id=MENU_PLUGIN_BASE+(unsigned)i*MENU_PLUGIN_STRIDE;
        AppendMenuW(sub,MF_STRING|(flags&1?MF_CHECKED:0),id,L"\u542f\u7528\u672c\u5730\u63d2\u4ef6");
        AppendMenuW(sub,MF_STRING|(flags&2?MF_CHECKED:0),id+1,L"\u5141\u8bb8\u8bfb\u53d6\u6807\u9898\u548c\u7f51\u5740");
        if (flags&8) AppendMenuW(sub,MF_STRING|(flags&4?MF_CHECKED:0),id+2,L"允许管理 Lua 用户脚本");
        for(size_t j=0;j<moon_plugin_action_count(i);++j) {
            if (moon_utf16(moon_plugin_action(i,j),action,ARRAYSIZE(action)))
                AppendMenuW(sub,MF_STRING|(flags&1?0:MF_GRAYED),id+3+j,action);
        }
        AppendMenuW(popup,MF_POPUP,(UINT_PTR)sub,name);
    }
    MapWindowPoints(hwnd,NULL,(POINT *)&button,2);
    TPMPARAMS placement={.cbSize=sizeof(placement),.rcExclude=button};
    UINT flags=TPM_RETURNCMD|TPM_NONOTIFY|
        (above ? TPM_BOTTOMALIGN|TPM_VERTICAL : TPM_TOPALIGN)|
        (right_aligned ? TPM_RIGHTALIGN : TPM_LEFTALIGN);
    UINT command=TrackPopupMenuEx(popup,flags,right_aligned?button.right:button.left,
        above?button.top:button.bottom,hwnd,&placement);
    DestroyMenu(popup);
    if (command==MENU_DIAG) moon_command(MOON_DIAGNOSTICS,0,NULL);
    else if (command==MENU_ADD) moon_command(MOON_NEW,0,NULL);
    else if (command==MENU_THEME) moon_shell_toggle_theme();
    else if (command==MENU_FOCUS) moon_shell_toggle_sidebar();
    else if (command==MENU_PALETTE) open_palette();
    else if (command==MENU_UPDATES) moon_command(MOON_UPDATES,0,NULL);
    else if (command==MENU_SCRIPTS_PICK) pick_userscript();
    else if (command>=MENU_SCRIPTS_BASE) {
        const unsigned value=command-MENU_SCRIPTS_BASE;
        moon_command(value%2?MOON_SCRIPTS_REMOVE:MOON_SCRIPTS_TOGGLE,value/2,NULL);
    }
    else if (command>=MENU_PLUGIN_BASE) {
        unsigned value=command-MENU_PLUGIN_BASE;
        const unsigned offset=value%MENU_PLUGIN_STRIDE, plugin=value/MENU_PLUGIN_STRIDE;
        const int grants[]={MOON_PLUGIN_ENABLE,MOON_PLUGIN_GRANT,MOON_PLUGIN_GRANT_LUA};
        if (offset<ARRAYSIZE(grants)) moon_command(grants[offset],plugin,NULL);
        else moon_command(MOON_PLUGIN_COMMAND,((uint64_t)plugin<<32)|(offset-3),NULL);
        moon_shell_refresh();
    }
}
void moon_shell_open_plugins(void) {
    const int width=client_width(), height=client_height(), search=home_top(height)+98;
    if (show_home && height-search>=145) {
        const int tile=tile_width(width);
        menu(frame,rectangle(home_left(width)+tile+10,search+94,tile,61),false,false);
    } else {
        menu(frame,rectangle(width-175,8,32,32),false,true);
    }
}

static void palette_row(const wchar_t *name,LPARAM data) {
    LRESULT row=SendMessageW(palette_list,LB_ADDSTRING,0,(LPARAM)name);
    if (row>=0) SendMessageW(palette_list,LB_SETITEMDATA,(WPARAM)row,data);
}
static void filter_palette(void) {
    if (!palette_list || !palette_input) return;
    wchar_t query[4096], name[512];
    GetWindowTextW(palette_input,query,ARRAYSIZE(query));
    bool url_like=wcspbrk(query,L"./:")!=NULL;
    SendMessageW(palette_list,WM_SETREDRAW,FALSE,0);
    SendMessageW(palette_list,LB_RESETCONTENT,0,0);
    if (url_like) palette_row(L"\u6253\u5f00\u6216\u641c\u7d22\u8f93\u5165\u5185\u5bb9",-2);
    for(size_t i=0;i<moon_action_count(false);++i) {
        if (moon_utf16(moon_action_label(i,false),name,ARRAYSIZE(name)) && (!*query || StrStrIW(name,query)))
            palette_row(name,(LPARAM)i);
    }
    for(size_t i=0;i<moon_tab_count();++i) {
        if (moon_utf16(moon_tab_label(i),name,ARRAYSIZE(name)) && (!*query || StrStrIW(name,query)))
            palette_row(name,PALETTE_TAB_OFFSET+(LPARAM)i);
    }
    if (*query && !url_like) palette_row(L"\u6253\u5f00\u6216\u641c\u7d22\u8f93\u5165\u5185\u5bb9",-2);
    SendMessageW(palette_list,LB_SETCURSEL,0,0);
    SendMessageW(palette_list,WM_SETREDRAW,TRUE,0);
    InvalidateRect(palette_list,NULL,TRUE);
}
static void run_palette(void) {
    LRESULT row=SendMessageW(palette_list,LB_GETCURSEL,0,0);
    if (row==LB_ERR) return;
    LRESULT action=SendMessageW(palette_list,LB_GETITEMDATA,(WPARAM)row,0);
    wchar_t query[4096];
    char value[16384];
    GetWindowTextW(palette_input,query,ARRAYSIZE(query));
    DestroyWindow(palette);
    if (action==-2 && moon_utf8(query,value,sizeof(value))) moon_command(MOON_ADDRESS,0,value);
    else if (action>=PALETTE_TAB_OFFSET) moon_command(MOON_SELECT,(uint64_t)(action-PALETTE_TAB_OFFSET),NULL);
    else if (action>=0) moon_action_run((size_t)action,false);
}
static LRESULT CALLBACK palette_message(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp) {
    if (msg==WM_COMMAND) {
        if (LOWORD(wp)==PALETTE_INPUT && HIWORD(wp)==EN_CHANGE) filter_palette();
        if (LOWORD(wp)==PALETTE_LIST && HIWORD(wp)==LBN_DBLCLK) run_palette();
        return 0;
    }
    if (msg==WM_SIZE) {
        RECT r;
        GetClientRect(hwnd,&r);
        if (palette_input) MoveWindow(palette_input,px(12),px(12),r.right-px(24),px(27),TRUE);
        if (palette_list) MoveWindow(palette_list,px(12),px(47),r.right-px(24),r.bottom-px(59),TRUE);
        return 0;
    }
    if (msg==WM_DESTROY) {
        palette=NULL; palette_input=NULL; palette_list=NULL;
        return 0;
    }
    if (msg==WM_CTLCOLOREDIT || msg==WM_CTLCOLORLISTBOX) {
        SetBkColor((HDC)wp,rgb(theme->field));
        SetTextColor((HDC)wp,rgb(theme->text));
        return (LRESULT)address_brush;
    }
    return DefWindowProcW(hwnd,msg,wp,lp);
}
static void open_palette(void) {
    if (palette) { SetFocus(palette_input); return; }
    RECT owner;
    GetWindowRect(frame,&owner);
    int width=px(client_width()<740?450:540);
    HINSTANCE instance=GetModuleHandleW(NULL);
    palette=CreateWindowExW(WS_EX_TOOLWINDOW,L"MoonPalette",L"\u547d\u4ee4\u9762\u677f",
        WS_POPUP|WS_CAPTION|WS_SYSMENU|WS_CLIPCHILDREN,
        owner.left+(owner.right-owner.left-width)/2,owner.top+px(62),width,px(312),frame,NULL,instance,NULL);
    if (!palette) return;
    palette_input=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",NULL,WS_CHILD|WS_VISIBLE|WS_TABSTOP|ES_AUTOHSCROLL,
        0,0,0,0,palette,(HMENU)PALETTE_INPUT,instance,NULL);
    palette_list=CreateWindowExW(WS_EX_CLIENTEDGE,L"LISTBOX",NULL,
        WS_CHILD|WS_VISIBLE|WS_VSCROLL|WS_TABSTOP|LBS_NOTIFY|LBS_NOINTEGRALHEIGHT,
        0,0,0,0,palette,(HMENU)PALETTE_LIST,instance,NULL);
    if (!palette_input || !palette_list) { DestroyWindow(palette); return; }
    SendMessageW(palette_input,WM_SETFONT,(WPARAM)edit_font,TRUE);
    SendMessageW(palette_list,WM_SETFONT,(WPARAM)edit_font,TRUE);
    SendMessageW(palette_input,EM_SETLIMITTEXT,4095,0);
    SendMessageW(palette_input,EM_SETCUEBANNER,TRUE,(LPARAM)L"\u641c\u7d22\u6807\u7b7e\u9875\u3001\u547d\u4ee4\uff0c\u6216\u8f93\u5165\u7f51\u5740");
    SendMessageW(palette,WM_SIZE,0,0);
    filter_palette();
    ShowWindow(palette,SW_SHOW);
    SetFocus(palette_input);
}
static bool palette_key(const MSG *msg) {
    switch(msg->wParam) {
        case VK_ESCAPE: DestroyWindow(palette); return true;
        case VK_RETURN: run_palette(); return true;
        case VK_UP: case VK_DOWN: {
            LRESULT selected=SendMessageW(palette_list,LB_GETCURSEL,0,0);
            LRESULT count=SendMessageW(palette_list,LB_GETCOUNT,0,0);
            if (count>0) {
                selected += msg->wParam==VK_UP?-1:1;
                if (selected<0) selected=count-1;
                if (selected>=count) selected=0;
                SendMessageW(palette_list,LB_SETCURSEL,(WPARAM)selected,0);
            }
            return true;
        }
        default: return false;
    }
}
static bool within(int x,int y,int left,int top,int w,int h) {
    return x>=left && x<left+w && y>=top && y<top+h;
}
static void click(HWND hwnd,int psx,int psy) {
    int x=MulDiv(psx,96,dpi), y=MulDiv(psy,96,dpi);
    int width=client_width(), height=client_height(), left=pane_left();
    if (y<TOP) {
        if (x>=width-50) { PostMessageW(hwnd,WM_SYSCOMMAND,SC_CLOSE,0); return; }
        if (x>=width-94) { ShowWindow(hwnd,IsZoomed(hwnd)?SW_RESTORE:SW_MAXIMIZE); return; }
        if (x>=width-138) { ShowWindow(hwnd,SW_MINIMIZE); return; }
        if (x>=width-175) { menu(hwnd,rectangle(width-175,8,32,32),false,true); return; }
        if (x>=width-213) {
            moon_shell_toggle_sidebar();
            return;
        }
        if (x>=left && x<left+31) moon_command(MOON_BACK,0,NULL);
        else if (x>=left+34 && x<left+65) moon_command(MOON_FORWARD,0,NULL);
        else if (x>=left+68 && x<left+99) moon_command(MOON_RELOAD,0,NULL);
        else if (x>=address_left() && x<address_right(width)) moon_shell_focus_address();
        return;
    }
    if (!focus_mode && x<left) {
        if (within(x,y,12,50,SIDEBAR-8,34)) open_palette();
        else if (within(x,y,SIDEBAR-28,92,40,29)) moon_command(MOON_NEW,0,NULL);
        else if (y>=TAB_START && y<height-FOOTER) {
            size_t slot=(size_t)(y-TAB_START)/ROW, index=first_tab+slot;
            if (slot<tab_capacity() && index<moon_tab_count()) {
                moon_command(x>=SIDEBAR-26 ? MOON_CLOSE : MOON_SELECT,index,NULL);
            }
        } else if (y>=height-FOOTER) {
            if (x<49) menu(hwnd,rectangle(14,height-FOOTER+7,32,31),true,false);
            else if (x<86) moon_command(MOON_DIAGNOSTICS,0,NULL);
            else if (x<125) menu(hwnd,rectangle(88,height-FOOTER+7,32,31),true,false);
        }
        return;
    }
    if (show_home) {
        int home_x=home_left(width), search=home_top(height)+98;
        if (within(x,y,home_x,search,home_width(width),44)) { SetFocus(home_edit); return; }
        int tile=tile_width(width), top=search+94;
        for(size_t i=0;i<3 && i<moon_action_count(true);++i) {
            if (within(x,y,home_x+(int)i*(tile+10),top,tile,61) && height-search>=145) {
                moon_action_run(i,true);
                return;
            }
        }
    }
}

static LRESULT CALLBACK content_message(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp) {
    if (msg == WM_SIZE) {
        HWND view = GetWindow(hwnd,GW_CHILD);
        RECT r;
        GetClientRect(hwnd,&r);
        while (view) {
            MoveWindow(view,0,0,r.right,r.bottom,TRUE);
            view = GetWindow(view,GW_HWNDNEXT);
        }
        return 0;
    }
    if (msg == WM_PAINT) {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(hwnd,&paint);
        RECT r;
        GetClientRect(hwnd,&r);
        HBRUSH background = CreateSolidBrush(rgb(theme->panel));
        FillRect(dc,&paint.rcPaint,background);
        DeleteObject(background);
        SetBkMode(dc,TRANSPARENT);
        SetTextColor(dc,rgb(theme->muted));
        HFONT old = SelectObject(dc,edit_font);
        DrawTextW(dc,content_status,-1,&r,DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        SelectObject(dc,old);
        EndPaint(hwnd,&paint);
        return 0;
    }
    return DefWindowProcW(hwnd,msg,wp,lp);
}
static LRESULT CALLBACK info_message(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp) {
    if (msg == WM_SIZE) {
        RECT r;
        GetClientRect(hwnd,&r);
        HWND edit = GetDlgItem(hwnd,1);
        if (edit) MoveWindow(edit,0,0,r.right,r.bottom,TRUE);
        return 0;
    }
    return DefWindowProcW(hwnd,msg,wp,lp);
}
static LRESULT CALLBACK frame_message(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp) {
    switch (msg) {
        case WM_NCCALCSIZE:
            if (wp) {
                if (IsZoomed(hwnd)) {
                    MONITORINFO area={.cbSize=sizeof(area)};
                    NCCALCSIZE_PARAMS *client=(NCCALCSIZE_PARAMS *)lp;
                    if (GetMonitorInfoW(MonitorFromRect(&client->rgrc[0],MONITOR_DEFAULTTONEAREST),&area))
                        client->rgrc[0]=area.rcWork;
                }
                return 0;
            }
            break;
        case WM_NCHITTEST: {
            POINT point={(short)LOWORD(lp),(short)HIWORD(lp)};
            RECT bounds;
            GetWindowRect(hwnd,&bounds);
            if (!IsZoomed(hwnd)) {
                int edge=px(6);
                bool left=point.x<bounds.left+edge, right=point.x>=bounds.right-edge;
                bool top=point.y<bounds.top+edge, bottom=point.y>=bounds.bottom-edge;
                if (top) return left?HTTOPLEFT:right?HTTOPRIGHT:HTTOP;
                if (bottom) return left?HTBOTTOMLEFT:right?HTBOTTOMRIGHT:HTBOTTOM;
                if (left || right) return left?HTLEFT:HTRIGHT;
            }
            ScreenToClient(hwnd,&point);
            if ((!focus_mode && point.y<px(TOP) && point.x<px(pane_left())) ||
                (point.y>=px(TOP-6) && point.y<px(TOP) && point.x<px(client_width()-140))) return HTCAPTION;
            return HTCLIENT;
        }
        case WM_SIZE: if (content && address) layout(); return 0;
        case WM_DPICHANGED: {
            dpi = LOWORD(wp);
            const RECT *r = (RECT *)lp;
            release_target();
            SetWindowPos(hwnd,NULL,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER | SWP_NOACTIVATE);
            if (address && content) {
                set_font();
                layout();
            }
            return 0;
        }
        case WM_GETMINMAXINFO: {
            MINMAXINFO *bounds = (MINMAXINFO *)lp;
            bounds->ptMinTrackSize = (POINT){px(690),px(360)};
            return 0;
        }
        case WM_ERASEBKGND: return 1;
        case WM_PAINT: chrome_frame(hwnd); return 0;
        case WM_CTLCOLOREDIT:
            SetBkColor((HDC)wp,rgb(theme->field));
            SetTextColor((HDC)wp,rgb(theme->text));
            return (LRESULT)address_brush;
        case WM_COMMAND:
            if (HIWORD(wp)==EN_SETFOCUS || HIWORD(wp)==EN_KILLFOCUS) InvalidateRect(hwnd,NULL,FALSE);
            return 0;
        case WM_MOUSEMOVE:
            hover=(POINT){MulDiv((short)LOWORD(lp),96,dpi),MulDiv((short)HIWORD(lp),96,dpi)};
            if (!tracking_mouse) {
                TRACKMOUSEEVENT tracking={sizeof(tracking),TME_LEAVE,hwnd,0};
                tracking_mouse=TrackMouseEvent(&tracking);
            }
            InvalidateRect(hwnd,NULL,FALSE);
            return 0;
        case WM_MOUSELEAVE:
            hover=(POINT){-1,-1};
            tracking_mouse=false;
            InvalidateRect(hwnd,NULL,FALSE);
            return 0;
        case WM_LBUTTONUP: click(hwnd,(short)LOWORD(lp),(short)HIWORD(lp)); return 0;
        case WM_MOUSEWHEEL:
            if (!focus_mode && moon_tab_count() > tab_capacity()) {
                if (GET_WHEEL_DELTA_WPARAM(wp) < 0) ++first_tab;
                else if (first_tab) --first_tab;
                clamp_tab_strip(false);
                InvalidateRect(hwnd,NULL,FALSE);
            }
            return 0;
        case WM_TIMER: moon_command(MOON_TICK,0,NULL); return 0;
        case WM_CLOSE: moon_quit(0); return 0;
    }
    return DefWindowProcW(hwnd,msg,wp,lp);
}
static bool composing(HWND input) {
    HIMC context=ImmGetContext(input);
    if (!context) return false;
    bool active=ImmGetCompositionStringW(context,GCS_COMPSTR,NULL,0)>0;
    ImmReleaseContext(input,context);
    return active;
}
static bool keyboard(MSG *msg) {
    bool ctrl = GetKeyState(VK_CONTROL) < 0, shift = GetKeyState(VK_SHIFT) < 0;
    bool alt = (msg->lParam & (1L<<29)) != 0;
    if ((msg->hwnd==address || msg->hwnd==home_edit) && msg->wParam==VK_RETURN && !ctrl && !alt && !composing(msg->hwnd)) {
        wchar_t wide[4096];
        char value[16384];
        GetWindowTextW(msg->hwnd,wide,ARRAYSIZE(wide));
        if (moon_utf8(wide,value,sizeof(value))) moon_command(MOON_ADDRESS,0,value);
        return true;
    }
    if (ctrl && shift && msg->wParam == 'L') { moon_shell_toggle_theme(); return true; }
    if ((ctrl && msg->wParam == 'L') || msg->wParam == VK_F6) { moon_shell_focus_address(); return true; }
    if (ctrl && msg->wParam == 'K') { open_palette(); return true; }
    if (ctrl && msg->wParam == 'B') { moon_shell_toggle_sidebar(); return true; }
    if (ctrl && msg->wParam == 'T') { moon_command(MOON_NEW,0,NULL); return true; }
    if (ctrl && msg->wParam == 'W') { moon_command(MOON_CLOSE,moon_active_index(),NULL); return true; }
    if (ctrl && msg->wParam == VK_TAB) { moon_command(shift ? MOON_KEY_PREV : MOON_KEY_NEXT,0,NULL); return true; }
    if (ctrl && shift && msg->wParam == 'M') { moon_command(MOON_DIAGNOSTICS,0,NULL); return true; }
    if (msg->wParam == VK_F5 || (ctrl && msg->wParam == 'R')) { moon_command(MOON_RELOAD,0,NULL); return true; }
    if (alt && msg->wParam == VK_LEFT) { moon_command(MOON_BACK,0,NULL); return true; }
    if (alt && msg->wParam == VK_RIGHT) { moon_command(MOON_FORWARD,0,NULL); return true; }
    return false;
}
static bool page_input(UINT message, WPARAM key) {
    switch (message) {
        case WM_KEYDOWN: case WM_SYSKEYDOWN:
            return key != VK_SHIFT && key != VK_CONTROL && key != VK_MENU && key != VK_ESCAPE;
        case WM_CHAR: case WM_IME_STARTCOMPOSITION: case WM_PASTE:
        case WM_LBUTTONDOWN: case WM_RBUTTONDOWN: case WM_MBUTTONDOWN: case WM_POINTERDOWN:
            return true;
        default: return false;
    }
}
static void init_graphics(void) {
    GdiplusStartupInput startup = { .GdiplusVersion = 1 };
    GdiplusStartup(&gdiplus,&startup,NULL);
    D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,&IID_ID2D1Factory,NULL,(void **)&drawing);
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,&IID_IDWriteFactory,(IUnknown **)&writing))) return;
    IDWriteFactory_CreateTextFormat(writing,L"Segoe UI",NULL,DWRITE_FONT_WEIGHT_NORMAL,DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL,13.0f,L"zh-CN",&font_left);
    IDWriteFactory_CreateTextFormat(writing,L"Segoe UI",NULL,DWRITE_FONT_WEIGHT_MEDIUM,DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL,16.0f,L"zh-CN",&font_center);
    IDWriteFactory_CreateTextFormat(writing,L"Segoe UI",NULL,DWRITE_FONT_WEIGHT_SEMI_BOLD,DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL,32.0f,L"zh-CN",&font_hero);
    if (font_left) {
        IDWriteTextFormat_SetParagraphAlignment(font_left,DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        IDWriteTextFormat_SetWordWrapping(font_left,DWRITE_WORD_WRAPPING_NO_WRAP);
    }
    if (font_center) {
        IDWriteTextFormat_SetParagraphAlignment(font_center,DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        IDWriteTextFormat_SetTextAlignment(font_center,DWRITE_TEXT_ALIGNMENT_CENTER);
        IDWriteTextFormat_SetWordWrapping(font_center,DWRITE_WORD_WRAPPING_NO_WRAP);
    }
    if (font_hero) {
        IDWriteTextFormat_SetParagraphAlignment(font_hero,DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        IDWriteTextFormat_SetWordWrapping(font_hero,DWRITE_WORD_WRAPPING_NO_WRAP);
    }
}
int moon_shell_run(void) {
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_USER_DIRS);
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (!init_paths()) {
        MessageBoxW(NULL,L"Cannot open the Moon Browser profile.",L"Moon Browser",MB_ICONERROR);
        return 1;
    }
    char appearance[4096], preference[8];
    if (theme_path(appearance,sizeof(appearance)) && moon_read_text(appearance,preference,sizeof(preference)) &&
        strcmp(preference,"dark")==0) theme=&dark;
    OleInitialize(NULL);
    INITCOMMONCONTROLSEX controls={sizeof(controls),ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&controls);
    init_graphics();
    low_memory = CreateMemoryResourceNotification(LowMemoryResourceNotification);
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW class = { .hInstance=instance,.hCursor=LoadCursorW(NULL,IDC_ARROW),.lpfnWndProc=frame_message,
        .lpszClassName=L"MoonBrowserWindow",.hIcon=LoadIconW(NULL,IDI_APPLICATION) };
    if (!RegisterClassW(&class)) return 1;
    class.lpfnWndProc = content_message;
    class.lpszClassName = L"MoonContent";
    if (!RegisterClassW(&class)) return 1;
    class.lpfnWndProc = info_message;
    class.lpszClassName = L"MoonInfo";
    if (!RegisterClassW(&class)) return 1;
    class.lpfnWndProc = palette_message;
    class.lpszClassName = L"MoonPalette";
    class.hbrBackground=(HBRUSH)(COLOR_WINDOW+1);
    if (!RegisterClassW(&class)) return 1;
    frame = CreateWindowExW(0,L"MoonBrowserWindow",L"Moon Browser",WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
        CW_USEDEFAULT,CW_USEDEFAULT,1120,760,NULL,NULL,instance,NULL);
    if (!frame) return 1;
    SetWindowLongPtrW(frame,GWL_STYLE,GetWindowLongPtrW(frame,GWL_STYLE) & ~(LONG_PTR)WS_CAPTION);
    SetWindowPos(frame,NULL,0,0,0,0,SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    dpi = GetDpiForWindow(frame);
    address_brush = CreateSolidBrush(rgb(theme->field));
    content = CreateWindowExW(0,L"MoonContent",NULL,WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN,
        0,0,0,0,frame,NULL,instance,NULL);
    address = CreateWindowExW(0,L"EDIT",NULL,WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL,
        0,0,0,0,frame,(HMENU)ADDRESS_CONTROL,instance,NULL);
    home_edit = CreateWindowExW(0,L"EDIT",NULL,WS_CHILD | WS_TABSTOP | ES_AUTOHSCROLL,
        0,0,0,0,frame,(HMENU)HOME_CONTROL,instance,NULL);
    if (!address || !home_edit || !content) return 1;
    SendMessageW(address,EM_SETLIMITTEXT,4095,0);
    SendMessageW(address,EM_SETCUEBANNER,TRUE,(LPARAM)L"搜索或输入网址");
    SendMessageW(home_edit,EM_SETLIMITTEXT,4095,0);
    SendMessageW(home_edit,EM_SETCUEBANNER,TRUE,(LPARAM)L"搜索或输入网址");
    set_font();
    layout();
    ShowWindow(frame,SW_SHOW);
    UpdateWindow(frame);
    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(),&argc);
    bool ready = moon_start(argc,(const uint16_t *const *)argv);
    LocalFree(argv);
    if (!ready && !quitting) moon_quit(1);
    if (!quitting) SetTimer(frame,1,100,NULL);
    MSG msg = {0};
    BOOL next;
    while ((next=GetMessageW(&msg,NULL,0,0)) > 0) {
        if (palette && (msg.hwnd==palette || IsChild(palette,msg.hwnd)) && msg.message==WM_KEYDOWN &&
            !composing(msg.hwnd) && palette_key(&msg)) continue;
        if ((msg.hwnd==frame || IsChild(frame,msg.hwnd)) &&
            (msg.message==WM_KEYDOWN || msg.message==WM_SYSKEYDOWN) && keyboard(&msg)) continue;
        if (IsChild(content,msg.hwnd) && page_input(msg.message,msg.wParam))
            moon_command(MOON_INPUT,0,NULL);
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    release_target();
    if (font_left) IDWriteTextFormat_Release(font_left);
    if (font_center) IDWriteTextFormat_Release(font_center);
    if (font_hero) IDWriteTextFormat_Release(font_hero);
    if (drawing) ID2D1Factory_Release(drawing);
    if (writing) IDWriteFactory_Release(writing);
    if (address_brush) DeleteObject(address_brush);
    if (edit_font) DeleteObject(edit_font);
    if (hero_font) DeleteObject(hero_font);
    if (low_memory) CloseHandle(low_memory);
    if (gdiplus) GdiplusShutdown(gdiplus);
    OleUninitialize();
    return next < 0 ? 1 : (int)msg.wParam;
}
