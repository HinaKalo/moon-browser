#define COBJMACROS
#define INITGUID
#include "win_internal.h"
#include <d2d1.h>
#include <dwrite.h>
#include <gdiplus.h>
#include <commctrl.h>
#include <psapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

static HWND frame, content, address, diagnostics;
static HBRUSH address_brush;
static HFONT edit_font;
static UINT dpi = 96;
static HANDLE low_memory;
static char profile_dir[4096], app_dir[4096];
static wchar_t content_status[512];
static size_t first_tab;
static ID2D1Factory *drawing;
static IDWriteFactory *writing;
static IDWriteTextFormat *font_left, *font_center;
static ID2D1HwndRenderTarget *target;
static ID2D1SolidColorBrush *brush;
static ULONG_PTR gdiplus;
static bool force_fallback, quitting;

enum { CHROME_HEIGHT = 89, TAB_Y = 8, TAB_HEIGHT = 34, TOOL_Y = 50, TOOL_HEIGHT = 31 };
enum { MENU_DIAG = 10, MENU_ADD = 11, MENU_PLUGIN_BASE = 100 };

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
        length = GetEnvironmentVariableW(L"LOCALAPPDATA", local, ARRAYSIZE(local));
        if (!length || length >= ARRAYSIZE(local) || !moon_path(location, ARRAYSIZE(location), local, L"MoonBrowser\\profile")) return false;
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
    GetClientRect(frame, &r);
    return MulDiv(r.right, 96, dpi);
}
static int tab_span(void) {
    int width = client_width() - 110;
    size_t count = moon_tab_count();
    int ideal = count ? width / (int)count : 160;
    return ideal < 116 ? 116 : ideal > 210 ? 210 : ideal;
}
static size_t tab_capacity(void) {
    int width = client_width() - 110;
    size_t count = moon_tab_count();
    if (width <= tab_span()) return 1;
    size_t capacity = (size_t)(width / tab_span());
    return capacity < count ? capacity : count;
}
static void clamp_tab_strip(bool reveal_active) {
    size_t count = moon_tab_count(), capacity = tab_capacity(), active = moon_active_index();
    size_t last = count > capacity ? count - capacity : 0;
    if (first_tab > last) first_tab = last;
    if (reveal_active && active < count) {
        if (active < first_tab) first_tab = active;
        if (capacity && active >= first_tab + capacity) first_tab = active - capacity + 1;
    }
}
static int add_position(void) { return 15 + (int)tab_capacity() * tab_span(); }
static void paint_chrome(Canvas c, int width, int height, bool full) {
    if (full) fill(c, 0, 0, width, height, 0x101218, 0);
    fill(c, 0, 0, width, CHROME_HEIGHT, 0x111319, 0);
    fill(c, 0, 44, width, 45, 0x171a23, 0);
    fill(c, 0, 88, width, 1, 0x2d3444, 0);

    size_t active = moon_active_index(), count = moon_tab_count();
    int span = tab_span();
    for (size_t i = 0; i < tab_capacity() && first_tab+i < count; ++i) {
        size_t tab = first_tab+i;
        int x = 12 + (int)i * span;
        bool chosen = tab == active;
        unsigned flags = moon_tab_flags(tab);
        fill(c, x, TAB_Y, span-4, TAB_HEIGHT, chosen ? 0x292f3f : 0x1a1e27, 7);
        if (chosen) fill(c, x+11, TAB_Y+3, 16, 2, 0x91afff, 0);
        fill(c, x+12, TAB_Y+15, 6, 6, (flags & 2) ? 0xf38983 :
            (flags & 1) ? 0x65718a : (flags & 4) ? 0xf1ba82 : 0x91afff, 3);
        wchar_t name[512];
        if (!moon_utf16(moon_tab_label(tab), name, ARRAYSIZE(name))) wcscpy(name,L"Tab");
        text_at(c, name, x+26, TAB_Y, span-56, TAB_HEIGHT, chosen ? 0xf0f3ff : 0xc0c9db, false);
        text_at(c, L"\x00d7", x+span-28, TAB_Y, 21, TAB_HEIGHT, 0xaab5c9, true);
    }
    int add = add_position();
    fill(c, add, TAB_Y+3, 30, 28, 0x222735, 6);
    text_at(c, L"+", add, TAB_Y+3, 30, 28, 0xe1e9fb, true);
    if (count > tab_capacity()) {
        text_at(c, L"\x2039", width-66, TAB_Y, 27, TAB_HEIGHT, 0xadb9cf, true);
        text_at(c, L"\x203a", width-39, TAB_Y, 27, TAB_HEIGHT, 0xadb9cf, true);
    }
    unsigned controls = moon_controls();
    text_at(c, L"\x2190", 9, TOOL_Y, 29, TOOL_HEIGHT, controls & 1 ? 0xe1e9fb : 0x738098, true);
    text_at(c, L"\x2192", 40, TOOL_Y, 29, TOOL_HEIGHT, controls & 2 ? 0xe1e9fb : 0x738098, true);
    text_at(c, L"\x21bb", 70, TOOL_Y, 29, TOOL_HEIGHT, 0xe1e9fb, true);
    fill(c, 107, TOOL_Y, width-162, TOOL_HEIGHT, 0x242b3a, 6);
    fill(c, width-45, TOOL_Y, 32, TOOL_HEIGHT, 0x242b3a, 6);
    text_at(c, L"\x2026", width-45, TOOL_Y-1, 32, TOOL_HEIGHT, 0xe1e9fb, true);
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
        paint_chrome((Canvas){.d2d=render},w,h,false);
        if (FAILED(ID2D1RenderTarget_EndDraw(render,NULL,NULL))) {
            release_target();
            InvalidateRect(hwnd,NULL,FALSE);
        }
    } else {
        GpGraphics *graphics = NULL;
        if (gdiplus) GdipCreateFromHDC(dc,&graphics);
        paint_chrome((Canvas){.gplus=graphics,.hdc=dc},w,h,false);
        if (graphics) GdipDeleteGraphics(graphics);
    }
    EndPaint(hwnd,&paint);
}
static void layout(void) {
    RECT r;
    GetClientRect(frame,&r);
    int y = px(CHROME_HEIGHT);
    MoveWindow(content,0,y,r.right,r.bottom > y ? r.bottom-y : 0,TRUE);
    int width = r.right-px(181);
    MoveWindow(address,px(117),px(TOOL_Y+6),width > 10 ? width : 10,px(TOOL_HEIGHT-11),TRUE);
    if (target) {
        D2D1_SIZE_U size = {(UINT32)r.right,(UINT32)r.bottom};
        if (FAILED(ID2D1HwndRenderTarget_Resize(target,&size))) release_target();
    }
    clamp_tab_strip(true);
    InvalidateRect(frame,NULL,FALSE);
}
static void set_font(void) {
    HFONT old = edit_font;
    edit_font = CreateFontW(-px(14),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
    SendMessageW(address,WM_SETFONT,(WPARAM)edit_font,TRUE);
    if (old) DeleteObject(old);
}
unsigned moon_shell_test_dpi(void) {
    RECT outer, parent, child;
    if (!GetWindowRect(frame,&outer)) return 0;
    const UINT original = dpi;
    const UINT requested = original == 144 ? 192 : 144;
    SendMessageW(frame,WM_DPICHANGED,MAKELONG(requested,requested),(LPARAM)&outer);
    bool correct = dpi == requested && GetClientRect(frame,&parent) && GetClientRect(content,&child) &&
        parent.right == child.right && parent.bottom - child.bottom == MulDiv(CHROME_HEIGHT,requested,96);
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
static void menu(HWND hwnd) {
    HMENU popup = CreatePopupMenu();
    if (!popup) return;
    AppendMenuW(popup,MF_STRING,MENU_ADD,L"New tab\tCtrl+T");
    AppendMenuW(popup,MF_STRING,MENU_DIAG,L"Memory & diagnostics\tCtrl+Shift+M");
    size_t count = moon_plugin_count();
    if (count) AppendMenuW(popup,MF_SEPARATOR,0,NULL);
    for (size_t i=0;i<count;++i) {
        wchar_t name[256], action[256];
        if (!moon_utf16(moon_plugin_label(i),name,ARRAYSIZE(name))) continue;
        if (!moon_utf16(moon_plugin_action(i),action,ARRAYSIZE(action))) continue;
        HMENU sub = CreatePopupMenu();
        unsigned flags = moon_plugin_flags(i), id = MENU_PLUGIN_BASE + (unsigned)i*3;
        AppendMenuW(sub,MF_STRING | (flags & 1 ? MF_CHECKED : 0),id,L"Enable local executable");
        AppendMenuW(sub,MF_STRING | (flags & 2 ? MF_CHECKED : 0),id+1,L"Share active tab title and URL");
        AppendMenuW(sub,MF_STRING | (flags & 1 ? 0 : MF_GRAYED),id+2,action);
        AppendMenuW(popup,MF_POPUP,(UINT_PTR)sub,name);
    }
    RECT r;
    GetClientRect(hwnd,&r);
    POINT anchor = {r.right-px(13),px(83)};
    ClientToScreen(hwnd,&anchor);
    UINT command = TrackPopupMenu(popup,TPM_RETURNCMD | TPM_RIGHTALIGN | TPM_NONOTIFY,
        anchor.x,anchor.y,0,hwnd,NULL);
    DestroyMenu(popup);
    if (command == MENU_DIAG) moon_command(MOON_DIAGNOSTICS,0,NULL);
    else if (command == MENU_ADD) moon_command(MOON_NEW,0,NULL);
    else if (command >= MENU_PLUGIN_BASE) {
        unsigned value = command - MENU_PLUGIN_BASE;
        const int actions[] = {MOON_PLUGIN_ENABLE, MOON_PLUGIN_GRANT, MOON_PLUGIN_COMMAND};
        moon_command(actions[value % 3],value / 3,NULL);
    }
}
static void click(HWND hwnd,int x,int y) {
    if (y >= px(TAB_Y) && y < px(TAB_Y+TAB_HEIGHT)) {
        if (x >= px(add_position()) && x < px(add_position()+30)) {
            moon_command(MOON_NEW,0,NULL);
            return;
        }
        int width = client_width();
        if (moon_tab_count() > tab_capacity() && x >= px(width-66)) {
            if (x < px(width-39)) { if (first_tab) --first_tab; }
            else ++first_tab;
            clamp_tab_strip(false);
            InvalidateRect(hwnd,NULL,FALSE);
            return;
        }
        if (x >= px(12)) {
            int local = MulDiv(x,96,dpi)-12, span = tab_span();
            if ((size_t)(local/span) < tab_capacity()) {
                size_t index = first_tab + (size_t)(local/span);
                if (index < moon_tab_count())
                    moon_command(local%span >= span-28 ? MOON_CLOSE : MOON_SELECT,index,NULL);
            }
        }
    }
    if (y >= px(TOOL_Y) && y < px(TOOL_Y+TOOL_HEIGHT)) {
        if (x > px(client_width()-47)) menu(hwnd);
        else if (x < px(39)) moon_command(MOON_BACK,0,NULL);
        else if (x < px(70)) moon_command(MOON_FORWARD,0,NULL);
        else if (x < px(104)) moon_command(MOON_RELOAD,0,NULL);
        else moon_shell_focus_address();
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
        HBRUSH background = CreateSolidBrush(rgb(0x101218));
        FillRect(dc,&paint.rcPaint,background);
        DeleteObject(background);
        SetBkMode(dc,TRANSPARENT);
        SetTextColor(dc,rgb(0xc7d3e9));
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
            bounds->ptMinTrackSize = (POINT){px(570),px(270)};
            return 0;
        }
        case WM_ERASEBKGND: return 1;
        case WM_PAINT: chrome_frame(hwnd); return 0;
        case WM_CTLCOLOREDIT:
            SetBkColor((HDC)wp,rgb(0x242b3a));
            SetTextColor((HDC)wp,rgb(0xf0f3ff));
            return (LRESULT)address_brush;
        case WM_LBUTTONUP: click(hwnd,(short)LOWORD(lp),(short)HIWORD(lp)); return 0;
        case WM_MOUSEWHEEL:
            if (moon_tab_count() > tab_capacity()) {
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
static bool keyboard(MSG *msg) {
    bool ctrl = GetKeyState(VK_CONTROL) < 0, shift = GetKeyState(VK_SHIFT) < 0;
    bool alt = (msg->lParam & (1L<<29)) != 0;
    if (msg->hwnd == address && msg->wParam == VK_RETURN && !ctrl && !alt) {
        wchar_t wide[4096];
        char value[16384];
        GetWindowTextW(address,wide,ARRAYSIZE(wide));
        if (moon_utf8(wide,value,sizeof(value))) moon_command(MOON_ADDRESS,0,value);
        return true;
    }
    if ((ctrl && msg->wParam == 'L') || msg->wParam == VK_F6) { moon_shell_focus_address(); return true; }
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
    if (font_left) {
        IDWriteTextFormat_SetParagraphAlignment(font_left,DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        IDWriteTextFormat_SetWordWrapping(font_left,DWRITE_WORD_WRAPPING_NO_WRAP);
    }
    if (font_center) {
        IDWriteTextFormat_SetParagraphAlignment(font_center,DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        IDWriteTextFormat_SetTextAlignment(font_center,DWRITE_TEXT_ALIGNMENT_CENTER);
        IDWriteTextFormat_SetWordWrapping(font_center,DWRITE_WORD_WRAPPING_NO_WRAP);
    }
}
int moon_shell_run(void) {
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_USER_DIRS);
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (!init_paths()) {
        MessageBoxW(NULL,L"Cannot open the Moon Browser profile.",L"Moon Browser",MB_ICONERROR);
        return 1;
    }
    OleInitialize(NULL);
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
    frame = CreateWindowExW(0,L"MoonBrowserWindow",L"Moon Browser",WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
        CW_USEDEFAULT,CW_USEDEFAULT,1120,760,NULL,NULL,instance,NULL);
    if (!frame) return 1;
    dpi = GetDpiForWindow(frame);
    address_brush = CreateSolidBrush(rgb(0x242b3a));
    content = CreateWindowExW(0,L"MoonContent",NULL,WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN,
        0,0,0,0,frame,NULL,instance,NULL);
    address = CreateWindowExW(0,L"EDIT",NULL,WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL,
        0,0,0,0,frame,NULL,instance,NULL);
    if (!address || !content) return 1;
    SendMessageW(address,EM_SETLIMITTEXT,4095,0);
    SendMessageW(address,EM_SETCUEBANNER,TRUE,(LPARAM)L"Search or enter an address");
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
    if (drawing) ID2D1Factory_Release(drawing);
    if (writing) IDWriteFactory_Release(writing);
    if (address_brush) DeleteObject(address_brush);
    if (edit_font) DeleteObject(edit_font);
    if (low_memory) CloseHandle(low_memory);
    if (gdiplus) GdiplusShutdown(gdiplus);
    OleUninitialize();
    return next < 0 ? 1 : (int)msg.wParam;
}
