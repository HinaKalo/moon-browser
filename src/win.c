#define COBJMACROS
#define INITGUID
#include "win_internal.h"
#include <d2d1.h>
#include <dwrite.h>
#include <gdiplus.h>
#include <commctrl.h>
#include <commdlg.h>
#include <imm.h>
#include <knownfolders.h>
#include <psapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static HWND frame, content, address, home_edit, palette, palette_input, palette_list;
static HWND palette_previous_focus;
static bool palette_tabs;
static HWND fullscreen_exit;
static WINDOWPLACEMENT fullscreen_placement;
static LONG_PTR fullscreen_style;
static bool fullscreen;
static HBRUSH address_brush;
static HFONT edit_font, hero_font;
static UINT dpi = 96;
static HANDLE low_memory;
static char profile_dir[4096], app_dir[4096];
static wchar_t content_status[512];
static size_t first_tab;
static MoonSidebarRow sidebar_rows[MOON_MAX_SIDEBAR_ROWS];
static size_t sidebar_count;
static MoonBookmarkBarEntry bookmark_roots[MOON_BOOKMARK_BAR_PAGE];
static wchar_t bookmark_labels[MOON_BOOKMARK_BAR_PAGE][512];
static size_t bookmark_count;
static bool bookmark_visible, bookmark_more;
static ID2D1Factory *drawing;
static IDWriteFactory *writing;
static IDWriteTextFormat *font_left, *font_center, *font_hero;
static ID2D1HwndRenderTarget *target;
static ID2D1SolidColorBrush *brush;
static ULONG_PTR gdiplus;
static bool force_fallback, quitting, private_window;
static bool show_home, focus_mode, tracking_mouse;
static bool syncing_address;
static POINT hover = {-1,-1};
static struct {
    uint64_t source;
    POINT start, pointer;
    MoonTabDrop target;
    int guide;
    bool active;
} tab_drag;
static bool ignore_tab_release;
static void cancel_tab_drag(void);
static void queue_presentation(HWND hwnd);

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

enum { PAD = 8, SIDEBAR = 264, TOP = 48, ROW = 37, TAB_START = 134, FOOTER = 48, BOOKMARK_HEIGHT = 32 };
enum { MAINTENANCE_TIMER = 1, PRESENTATION_TIMER = 2, FULLSCREEN_HINT_TIMER = 3, TAB_DRAG_TIMER = 4,
       ADDRESS_TOP = 8, ADDRESS_HEIGHT = 32, HOME_FIELD_HEIGHT = 44 };
enum { MENU_ADD = 11, MENU_PALETTE, MENU_UPDATES, MENU_MARKET, MENU_MANAGE_PLUGINS,
       MENU_PLUGIN_BASE = 100, MENU_PLUGIN_ACTIONS = 2 + MOON_PLUGIN_MENU_PERMISSION_LIMIT, MENU_PLUGIN_STRIDE = 64 };
_Static_assert(MENU_PLUGIN_ACTIONS + MOON_LINK_MENU_STRIDE <= MENU_PLUGIN_STRIDE,
    "Native menu plugin command and permission IDs must fit within the plugin slot");
enum { ADDRESS_CONTROL = 1001, HOME_CONTROL = 1002, PALETTE_INPUT = 1003, PALETTE_LIST = 1004,
       FULLSCREEN_EXIT_CONTROL = 1005,
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
    if (private_window) return true;
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
bool moon_shell_private(void) { return private_window; }
bool moon_shell_open_private(void) {
    wchar_t executable[2048], command[2100];
    DWORD length=GetModuleFileNameW(NULL,executable,ARRAYSIZE(executable));
    if (!length || length>=ARRAYSIZE(executable)) return false;
    int written=swprintf(command,ARRAYSIZE(command),L"\"%ls\" --private",executable);
    if (written<=0 || written>=ARRAYSIZE(command)) return false;
    STARTUPINFOW start={.cb=sizeof(start)};
    PROCESS_INFORMATION process;
    if (!CreateProcessW(executable,command,NULL,NULL,FALSE,0,NULL,NULL,&start,&process)) return false;
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return true;
}
const char *moon_app_dir(void) { return app_dir; }
HWND moon_shell_window(void) { return frame; }
HWND moon_shell_content(void) { return content; }
uint64_t moon_clock(void) { return GetTickCount64(); }
uint64_t moon_wall_ms(void) {
    FILETIME time;
    GetSystemTimeAsFileTime(&time);
    ULARGE_INTEGER ticks = { .LowPart=time.dwLowDateTime, .HighPart=time.dwHighDateTime };
    return ticks.QuadPart / 10000 - UINT64_C(11644473600000);
}
uint32_t moon_current_pid(void) { return GetCurrentProcessId(); }
uint64_t moon_process_birth(uint32_t pid) {
    FILETIME created,ended,kernel,user;
    HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,pid);
    if (!process) return 0;
    const bool live=WaitForSingleObject(process,0)==WAIT_TIMEOUT && GetProcessTimes(process,&created,&ended,&kernel,&user);
    CloseHandle(process);
    if (!live) return 0;
    return ((uint64_t)created.dwHighDateTime<<32)|created.dwLowDateTime;
}
bool moon_shell_reveal_file(const char *path) {
    wchar_t wide[4096];
    if (!moon_utf16(path,wide,ARRAYSIZE(wide)) || PathIsRelativeW(wide)) return false;
    const DWORD attrs=GetFileAttributesW(wide);
    if (attrs==INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_DIRECTORY)) return false;
    PIDLIST_ABSOLUTE item=ILCreateFromPathW(wide);
    if (!item) return false;
    const HRESULT result=SHOpenFolderAndSelectItems(item,0,NULL,0);
    CoTaskMemFree(item);
    return SUCCEEDED(result);
}
static int local_download_path(const char *path,wchar_t *wide,size_t capacity) {
    if (!moon_utf16(path,wide,capacity) || wcslen(wide)<4 ||
        !((wide[0]>=L'A' && wide[0]<=L'Z') || (wide[0]>=L'a' && wide[0]<=L'z')) ||
        wide[1]!=L':' || wide[2]!=L'\\' || wcschr(wide+2,L':')) return MOON_OPEN_DOWNLOAD_UNAVAILABLE;
    const wchar_t root[]={wide[0],L':',L'\\',0};
    if (GetDriveTypeW(root)==DRIVE_REMOTE) return MOON_OPEN_DOWNLOAD_UNAVAILABLE;
    for (const wchar_t *ch=wide+3;*ch;++ch) {
        if (*ch<32 || (*ch>=0x202a && *ch<=0x202e) || (*ch>=0x2066 && *ch<=0x2069))
            return MOON_OPEN_DOWNLOAD_UNAVAILABLE;
    }
    const DWORD attrs=GetFileAttributesW(wide);
    if (attrs==INVALID_FILE_ATTRIBUTES) {
        const DWORD error=GetLastError();
        return error==ERROR_FILE_NOT_FOUND || error==ERROR_PATH_NOT_FOUND ? MOON_OPEN_DOWNLOAD_MISSING : MOON_OPEN_DOWNLOAD_UNAVAILABLE;
    }
    if (attrs&FILE_ATTRIBUTE_DIRECTORY) return MOON_OPEN_DOWNLOAD_MISSING;
    if (attrs&FILE_ATTRIBUTE_REPARSE_POINT) return MOON_OPEN_DOWNLOAD_UNAVAILABLE;
    return MOON_OPEN_DOWNLOAD_DONE;
}
static int prepare_download_attachment(const char *path,IAttachmentExecute **attachment) {
    wchar_t wide[4096];
    const int status=local_download_path(path,wide,ARRAYSIZE(wide));
    if (status!=MOON_OPEN_DOWNLOAD_DONE) return status;
    HRESULT result=CoCreateInstance(&CLSID_AttachmentServices,NULL,CLSCTX_INPROC_SERVER,
        &IID_IAttachmentExecute,(void **)attachment);
    if (FAILED(result)) return MOON_OPEN_DOWNLOAD_UNAVAILABLE;
    IAttachmentExecute_SetClientTitle(*attachment,L"打开下载文件");
    result=IAttachmentExecute_SetLocalPath(*attachment,wide);
    // Without verified origin metadata, let Windows use its default Restricted Zone.
    if (FAILED(result)) return MOON_OPEN_DOWNLOAD_UNAVAILABLE;
    result=IAttachmentExecute_CheckPolicy(*attachment);
    if (result==S_OK) return MOON_OPEN_DOWNLOAD_DONE;
    if (result==S_FALSE) return MOON_OPEN_DOWNLOAD_SYSTEM_PROMPT;
    return MOON_OPEN_DOWNLOAD_BLOCKED;
}
int moon_shell_download_open_status(const char *path) {
    IAttachmentExecute *attachment=NULL;
    const int status=prepare_download_attachment(path,&attachment);
    if (attachment) IAttachmentExecute_Release(attachment);
    return status;
}
int moon_shell_open_download(const char *path,bool system_prompt) {
    IAttachmentExecute *attachment=NULL;
    const int status=prepare_download_attachment(path,&attachment);
    if (status!=MOON_OPEN_DOWNLOAD_SYSTEM_PROMPT && (status!=MOON_OPEN_DOWNLOAD_DONE || system_prompt)) {
        if (attachment) IAttachmentExecute_Release(attachment);
        return status==MOON_OPEN_DOWNLOAD_DONE ? MOON_OPEN_DOWNLOAD_UNAVAILABLE : status;
    }
    const HRESULT result=IAttachmentExecute_Execute(attachment,frame,NULL,NULL);
    IAttachmentExecute_Release(attachment);
    if (result==S_OK) return MOON_OPEN_DOWNLOAD_DONE;
    if (result==E_ABORT || result==HRESULT_FROM_WIN32(ERROR_CANCELLED)) return MOON_OPEN_DOWNLOAD_CANCELLED;
    if (result==E_ACCESSDENIED || result==HRESULT_FROM_WIN32(ERROR_ACCESS_DISABLED_BY_POLICY)) return MOON_OPEN_DOWNLOAD_BLOCKED;
    return MOON_OPEN_DOWNLOAD_UNAVAILABLE;
}
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
static bool read_text(const char *path, char *output, size_t cap, bool plain) {
    wchar_t buffer[2048];
    if (cap < 2 || !moon_utf16(path, buffer, ARRAYSIZE(buffer))) return false;
    if (plain) {
        wchar_t *slash = wcsrchr(buffer,L'\\');
        if (!slash) return false;
        *slash = 0;
        DWORD parent = GetFileAttributesW(buffer);
        *slash = L'\\';
        if (parent == INVALID_FILE_ATTRIBUTES || (parent & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
    }
    HANDLE file = CreateFileW(buffer, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | (plain ? FILE_FLAG_OPEN_REPARSE_POINT : 0), NULL);
    if (file == INVALID_HANDLE_VALUE) return false;
    if (plain) {
        BY_HANDLE_FILE_INFORMATION info;
        if (!GetFileInformationByHandle(file,&info) ||
            (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY))) {
            CloseHandle(file);
            return false;
        }
    }
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
bool moon_read_text(const char *path, char *output, size_t cap) { return read_text(path,output,cap,false); }
bool moon_read_plain_text(const char *path, char *output, size_t cap) { return read_text(path,output,cap,true); }
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
bool moon_shell_write_html(const char *path, const char *data, size_t length, bool replace) {
    if (!length || length>MOON_HTML_SAVE_LIMIT) return false;
    wchar_t target_path[2048], temporary[2048], token[40];
    if (!moon_utf16(path,target_path,ARRAYSIZE(target_path))) return false;
    wchar_t *filename=wcsrchr(target_path,L'\\');
    GUID id;
    if (!filename || FAILED(CoCreateGuid(&id)) || !StringFromGUID2(&id,token,ARRAYSIZE(token))) return false;
    size_t directory=(size_t)(filename-target_path)+1;
    if (directory+64>=ARRAYSIZE(temporary)) return false;
    wmemcpy(temporary,target_path,directory);
    swprintf(temporary+directory,ARRAYSIZE(temporary)-directory,L".moon-save-%ls.tmp",token);
    HANDLE file=CreateFileW(temporary,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if (file==INVALID_HANDLE_VALUE) return false;
    const unsigned char bom[]={0xef,0xbb,0xbf};
    DWORD written;
    bool ok=(length>=sizeof(bom) && memcmp(data,bom,sizeof(bom))==0) ||
        (WriteFile(file,bom,sizeof(bom),&written,NULL) && written==sizeof(bom));
    ok=ok && WriteFile(file,data,(DWORD)length,&written,NULL) && written==length && FlushFileBuffers(file);
    CloseHandle(file);
    if (ok && MoveFileExW(temporary,target_path,MOVEFILE_WRITE_THROUGH|(replace?MOVEFILE_REPLACE_EXISTING:0))) return true;
    DeleteFileW(temporary);
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
MoonDialogTheme moon_dialog_theme(void) {
    return (MoonDialogTheme){
        .panel=rgb(theme->panel), .field=rgb(theme->field), .border=rgb(theme->outline),
        .text=rgb(theme->text), .muted=rgb(theme->muted), .accent=rgb(theme->accent),
        .on_accent=rgb(theme==&dark ? 0x10152d : 0xffffff), .danger=rgb(theme->danger), .hover=rgb(theme->hover),
    };
}
uint64_t moon_shell_window_handle(void) { return (uintptr_t)frame; }
bool moon_shell_dark_mode(void) { return theme==&dark; }
bool moon_shell_focus_mode(void) { return focus_mode; }
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
static bool bookmark_bar_drawn(void) { return bookmark_visible && !fullscreen; }
static int pane_top(void) { return TOP+(bookmark_bar_drawn()?BOOKMARK_HEIGHT:0); }
static int home_left(int width) {
    int available = width - pane_left() - PAD;
    return pane_left() + (available > 768 ? (available-720)/2 : 24);
}
static int home_width(int width) {
    int available = width - PAD - home_left(width) - 24;
    return available > 720 ? 720 : available;
}
static int home_top(int height) { return pane_top() + (height > 520 ? 70 : 32); }
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
    size_t active=0, capacity=tab_capacity();
    const size_t count=moon_sidebar_rows(sidebar_rows,ARRAYSIZE(sidebar_rows),&active);
    sidebar_count=count;
    size_t last=count>capacity ? count-capacity : 0;
    if (first_tab>last) first_tab=last;
    if (reveal_active && active<count) {
        if (active<first_tab) first_tab=active;
        if (active>=first_tab+capacity) first_tab=active-capacity+1;
    }
}
static const MoonSidebarRow *sidebar_row_at(int y) {
    if (y<TAB_START) return NULL;
    size_t slot=(size_t)(y-TAB_START)/ROW;
    size_t index=first_tab+slot;
    return slot<tab_capacity() && index<sidebar_count?&sidebar_rows[index]:NULL;
}
static unsigned group_color(unsigned id) {
    static const unsigned colors[]={0x5269ca,0x237f72,0xa46025,0xa74878,0x66748b};
    static const unsigned dark_colors[]={0xa7b7ff,0x8bd7c7,0xe6b480,0xe7a8ca,0xb7c4de};
    return id<ARRAYSIZE(colors)?(theme==&dark?dark_colors[id]:colors[id]):theme->accent;
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
    const size_t selection_count=moon_tab_selection_count();
    wchar_t selection_label[32];
    if (selection_count) swprintf(selection_label,ARRAYSIZE(selection_label),L"已选择 %u 个标签",(unsigned)selection_count);
    text_at(c,selection_count?selection_label:L"\u6807\u7b7e\u9875",x+8,92,130,30,selection_count?theme->accent:theme->muted,false);
    icon_button(c,L"+",x+w-32,92,30,29,true);
    fill(c,x,125,w,1,theme->line,0);
    size_t count=sidebar_count, capacity=tab_capacity();
    for(size_t i=0;i<capacity && first_tab+i<count;++i) {
        const MoonSidebarRow *row=&sidebar_rows[first_tab+i];
        const size_t tab=row->tab;
        int y=TAB_START+(int)i*ROW;
        bool selected=row->active, hot=pointed(x,y,w,ROW-3);
        if (row->header) {
            const unsigned tone=group_color(row->color);
            const bool receiving=tab_drag.target.into_group && tab_drag.target.anchor==moon_tab_id(tab);
            fill(c,x,y,w,ROW-3,receiving?theme->soft:selected?theme->panel:hot?theme->hover:theme->field,7);
            fill(c,x,y+5,3,ROW-13,tone,2);
            text_at(c,row->collapsed?L"\x203a":L"\x02c5",x+8,y,22,ROW-3,tone,true);
            wchar_t label[128], members[16];
            if (moon_utf16(moon_group_name(row->group),label,ARRAYSIZE(label)))
                text_at(c,label,x+34,y,w-79,ROW-3,theme->text,false);
            swprintf(members,ARRAYSIZE(members),L"%u",row->members);
            text_at(c,members,x+w-38,y,32,ROW-3,theme->muted,true);
            continue;
        }
        unsigned flags=moon_tab_flags(tab);
        const bool multi_selected=(flags&MOON_TAB_SELECTED)!=0;
        const bool dragged=tab_drag.active && moon_tab_id(tab)==tab_drag.source;
        const int indent=row->group?12:0;
        if (selected || hot || dragged || multi_selected)
            fill(c,x+indent,y,w-indent,ROW-3,dragged||multi_selected?theme->soft:selected?theme->panel:theme->hover,7);
        if (row->group) fill(c,x+5,y,2,ROW-2,group_color(row->color),1);
        if (selected) fill(c,x+indent,y+6,3,ROW-15,theme->accent,2);
        if (multi_selected) fill(c,x+w-5,y+8,2,ROW-19,theme->accent,2);
        unsigned tone=(flags&MOON_TAB_FAILED)?theme->danger:(flags&MOON_TAB_DORMANT)?theme->muted:(flags&MOON_TAB_LOADING)?theme->loading:theme->accent;
        fill(c,x+indent+11,y+8,18,18,selected?theme->soft:theme->field,5);
        if (flags&MOON_TAB_PINNED) {
            fill(c,x+16,y+12,8,2,tone,1);
            fill(c,x+19,y+14,2,9,tone,1);
            fill(c,x+15,y+17,10,2,tone,1);
        } else {
            ellipse(c,x+indent+17,y+14,6,6,tone);
        }
        wchar_t label[512];
        if (!moon_utf16(moon_tab_label(tab),label,ARRAYSIZE(label))) wcscpy(label,L"\u6807\u7b7e\u9875");
        const bool audio_muted=flags&(MOON_TAB_MUTED|MOON_TAB_SITE_MUTED);
        text_at(c,label,x+indent+38,y,w-indent-71-(audio_muted?20:0),ROW-3,selected||multi_selected?theme->text:theme->muted,false);
        if (audio_muted)
            text_at(c,L"\xd83d\xdd07",x+w-51,y+3,20,ROW-9,theme->muted,true);
        if ((selected || hot) && !(flags&MOON_TAB_PINNED)) icon_button(c,L"\xd7",x+w-29,y+3,25,ROW-9,true);
    }
    if (tab_drag.target.anchor && !tab_drag.target.into_group) fill(c,x+4,tab_drag.guide,w-8,3,theme->accent,2);
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
    heading_at(c,private_window?L"隐私浏览":L"MoonBrowser",x+87,y,w-87,52);
    text_at(c,private_window?L"此窗口的网页数据在关闭后清除。":L"\u65b0\u6807\u7b7e\u9875",x+88,y+48,w-88,25,theme->muted,false);
    int search=y+98;
    fill(c,x,search,w,HOME_FIELD_HEIGHT,GetFocus()==home_edit?theme->accent:theme->line,9);
    fill(c,x+1,search+1,w-2,HOME_FIELD_HEIGHT-2,theme->field,8);
    text_at(c,L"\x2315",x+5,search,34,HOME_FIELD_HEIGHT,theme->muted,true);
    if (private_window) {
        text_at(c,L"手动保存的文件会保留。",x,search+56,w,28,theme->muted,false);
        return;
    }
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
typedef struct { int x, width; size_t index; } BookmarkButton;
enum { BOOKMARK_OVERFLOW=MOON_BOOKMARK_BAR_PAGE, BOOKMARK_MANAGE=MOON_BOOKMARK_BAR_PAGE+1 };

static size_t bookmark_buttons(int width, BookmarkButton *output, size_t *shown) {
    const int right=width-PAD-4;
    int x=pane_left()+4;
    *shown=0;
    if (!bookmark_count) {
        output[0]=(BookmarkButton){x,104,BOOKMARK_MANAGE};
        return 1;
    }
    while (*shown<bookmark_count) {
        const int item_width=min(182,max(62,32+(int)wcslen(bookmark_labels[*shown])*8));
        if (x+item_width>right-35) break;
        output[*shown]=(BookmarkButton){x,item_width,*shown};
        x+=item_width+3;
        ++*shown;
    }
    if (*shown<bookmark_count || bookmark_more) {
        output[*shown]=(BookmarkButton){right-30,30,BOOKMARK_OVERFLOW};
        return *shown+1;
    }
    return *shown;
}

static void paint_bookmark_bar(Canvas c,int width) {
    BookmarkButton buttons[MOON_BOOKMARK_BAR_PAGE+1];
    size_t shown;
    const size_t count=bookmark_buttons(width,buttons,&shown);
    for (size_t i=0;i<count;++i) {
        const BookmarkButton item=buttons[i];
        const int top=TOP+1,height=BOOKMARK_HEIGHT-5;
        if (pointed(item.x,top,item.width,height)) fill(c,item.x,top,item.width,height,theme->hover,6);
        if (item.index==BOOKMARK_OVERFLOW) {
            text_at(c,L"\xbb",item.x,top,item.width,height,theme->accent,true);
        } else {
            const bool folder=item.index!=BOOKMARK_MANAGE && bookmark_roots[item.index].id==0;
            const wchar_t *label=item.index==BOOKMARK_MANAGE?L"管理书签":bookmark_labels[item.index];
            text_at(c,folder?L"\x25b8":L"\x2606",item.x+4,top,18,height,theme->accent,true);
            text_at(c,label,item.x+25,top,item.width-30,height,theme->text,false);
        }
    }
}

static void paint_chrome(Canvas c,int width,int height) {
    if (fullscreen) {
        fill(c,0,0,width,height,theme->panel,0);
        return;
    }
    fill(c,0,0,width,height,theme->frame,0);
    int left=pane_left();
    const int top=pane_top();
    if (!focus_mode) paint_sidebar(c,height);
    if (bookmark_bar_drawn()) paint_bookmark_bar(c,width);
    fill(c,left,top,width-left-PAD,height-top-PAD,theme->line,12);
    fill(c,left+1,top+1,width-left-PAD-2,height-top-PAD-2,theme->panel,11);
    unsigned controls=moon_controls();
    icon_button(c,L"\x2190",left,8,31,32,controls&1);
    icon_button(c,L"\x2192",left+34,8,31,32,controls&2);
    icon_button(c,L"\x21bb",left+68,8,31,32,true);
    int address_x=address_left(), address_w=address_right(width)-address_x;
    fill(c,address_x,ADDRESS_TOP,address_w,ADDRESS_HEIGHT,GetFocus()==address?theme->accent:theme->line,8);
    fill(c,address_x+1,ADDRESS_TOP+1,address_w-2,ADDRESS_HEIGHT-2,theme->field,7);
    if (moon_tab_flags(moon_active_index()) & MOON_TAB_HAS_SITE) {
        if (pointed(address_x+3,ADDRESS_TOP+4,24,24))
            fill(c,address_x+3,ADDRESS_TOP+4,24,24,theme->soft,5);
        fill(c,address_x+8,ADDRESS_TOP+12,14,1,theme->text,0);
        fill(c,address_x+8,ADDRESS_TOP+19,14,1,theme->text,0);
        ellipse(c,address_x+11,ADDRESS_TOP+10,5,5,theme->text);
        ellipse(c,address_x+16,ADDRESS_TOP+17,5,5,theme->text);
    } else text_at(c,L"\x2315",address_x+3,ADDRESS_TOP,24,ADDRESS_HEIGHT,theme->muted,true);
    if (private_window) {
        const int badge=address_right(width)-67;
        fill(c,badge,ADDRESS_TOP+4,62,ADDRESS_HEIGHT-8,theme->soft,6);
        text_at(c,L"隐私浏览",badge,ADDRESS_TOP+3,62,ADDRESS_HEIGHT-6,theme->accent,true);
    }
    icon_button(c,L"\x25e7",width-213,8,32,32,moon_appearance_available() || focus_mode);
    icon_button(c,L"\x2026",width-175,8,32,32,true);
    icon_button(c,L"\x2212",width-138,0,44,TOP,true);
    icon_button(c,IsZoomed(frame)?L"\x29c9":L"\x25a1",width-94,0,44,TOP,true);
    if (pointed(width-50,0,44,TOP)) fill(c,width-50,1,44,TOP-2,theme->danger,7);
    text_at(c,L"\xd7",width-50,0,44,TOP,pointed(width-50,0,44,TOP)?0xffffff:theme->text,true);
    if (show_home) paint_home(c,width,height);
    else if (moon_tab_count() && (moon_tab_flags(moon_active_index())&MOON_TAB_LOADING))
        fill(c,left+8,top+1,74,2,theme->accent,1);
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
    moon_suggest_hide();
    RECT r;
    GetClientRect(frame,&r);
    int width=client_width(), height=client_height();
    int left=fullscreen?0:px(pane_left()+1), top=fullscreen?0:px(pane_top()+1), margin=fullscreen?0:px(PAD+1);
    int pane_width=r.right-left-margin, pane_height=r.bottom-top-margin;
    MoveWindow(content,left,top,pane_width>0?pane_width:0,pane_height>0?pane_height:0,TRUE);
    if (fullscreen) {
        SetWindowRgn(content,NULL,TRUE);
        if (fullscreen_exit)
            SetWindowPos(fullscreen_exit,HWND_TOP,(r.right-px(206))/2,px(8),px(206),px(38),SWP_NOACTIVATE);
    } else if (pane_width>0 && pane_height>0) {
        HRGN corners=CreateRoundRectRgn(0,0,pane_width+1,pane_height+1,px(20),px(20));
        if (corners && !SetWindowRgn(content,corners,TRUE)) DeleteObject(corners);
    }
    moon_find_layout();
    int address_width=address_right(width)-address_left()-34-(private_window?68:0);
    MoveWindow(address,px(address_left()+29),px(ADDRESS_TOP+3),px(address_width>10?address_width:10),
        px(ADDRESS_TOP+ADDRESS_HEIGHT-3)-px(ADDRESS_TOP+3),TRUE);
    if (home_edit) {
        int field_width=home_width(width)-48;
        int top=home_top(height)+98;
        MoveWindow(home_edit,px(home_left(width)+40),px(top+6),px(field_width>10?field_width:10),
            px(top+HOME_FIELD_HEIGHT-6)-px(top+6),TRUE);
    }
    if (target) {
        D2D1_SIZE_U size = {(UINT32)r.right,(UINT32)r.bottom};
        if (FAILED(ID2D1HwndRenderTarget_Resize(target,&size))) release_target();
    }
    clamp_tab_strip(!tab_drag.active);
    InvalidateRect(frame,NULL,FALSE);
}

void moon_shell_bookmarks_changed(void) {
    if (!frame || !content || quitting) return;
    moon_bookmark_menu_cancel();
    const bool before=bookmark_bar_drawn();
    bookmark_visible=moon_bookmark_bar_visible();
    bookmark_more=false;
    bookmark_count=bookmark_visible?moon_bookmark_bar_entries("",0,bookmark_roots,ARRAYSIZE(bookmark_roots),&bookmark_more):0;
    for (size_t i=0;i<bookmark_count;++i) {
        if (!moon_utf16(bookmark_roots[i].text,bookmark_labels[i],ARRAYSIZE(bookmark_labels[i]))) bookmark_labels[i][0]=0;
    }
    if (before!=bookmark_bar_drawn()) {
        layout();
        queue_presentation(frame);
    } else if (bookmark_bar_drawn()) {
        InvalidateRect(frame,NULL,FALSE);
    }
}
static bool fit_fullscreen(HMONITOR monitor) {
    MONITORINFO info={.cbSize=sizeof(info)};
    if (!GetMonitorInfoW(monitor,&info)) return false;
    const RECT r=info.rcMonitor;
    return SetWindowPos(frame,NULL,r.left,r.top,r.right-r.left,r.bottom-r.top,
        SWP_NOZORDER|SWP_NOACTIVATE|SWP_FRAMECHANGED);
}
static void show_fullscreen_exit(void) {
    if (!fullscreen_exit) return;
    ShowWindow(fullscreen_exit,SW_SHOWNA);
    if (!SetTimer(frame,FULLSCREEN_HINT_TIMER,3000,NULL)) ShowWindow(fullscreen_exit,SW_HIDE);
}
void moon_shell_leave_fullscreen(void) {
    if (!fullscreen) return;
    fullscreen=false;
    KillTimer(frame,FULLSCREEN_HINT_TIMER);
    if (GetFocus()==fullscreen_exit) SetFocus(content);
    ShowWindow(fullscreen_exit,SW_HIDE);
    SetWindowLongPtrW(frame,GWL_STYLE,fullscreen_style&~(LONG_PTR)(WS_MAXIMIZE|WS_MINIMIZE));
    SetWindowPlacement(frame,&fullscreen_placement);
    SetWindowPos(frame,NULL,0,0,0,0,SWP_NOZORDER|SWP_NOACTIVATE|SWP_NOMOVE|SWP_NOSIZE|SWP_FRAMECHANGED);
    ShowWindow(address,SW_SHOWNA);
    layout();
}
int moon_shell_toggle_fullscreen(void) {
    if (fullscreen) {
        moon_shell_leave_fullscreen();
        return 0;
    }
    if (!frame || show_home || IsIconic(frame)) return -1;
    cancel_tab_drag();
    fullscreen_placement=(WINDOWPLACEMENT){.length=sizeof(fullscreen_placement)};
    if (!GetWindowPlacement(frame,&fullscreen_placement)) return -1;
    HMONITOR monitor=MonitorFromWindow(frame,MONITOR_DEFAULTTONEAREST);
    fullscreen_style=GetWindowLongPtrW(frame,GWL_STYLE);
    fullscreen=true;
    ShowWindow(address,SW_HIDE);
    SetWindowLongPtrW(frame,GWL_STYLE,(fullscreen_style&~(LONG_PTR)(WS_CAPTION|WS_THICKFRAME|WS_MAXIMIZEBOX|WS_MAXIMIZE))|WS_POPUP);
    if (!fit_fullscreen(monitor)) {
        moon_shell_leave_fullscreen();
        return -1;
    }
    layout();
    show_fullscreen_exit();
    return 1;
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
        parent.bottom-child.bottom == px(pane_top()+1)+px(PAD+1);
    SendMessageW(frame,WM_DPICHANGED,MAKELONG(original,original),(LPARAM)&outer);
    return correct ? requested : 0;
}
void moon_shell_focus_address(void) {
    moon_shell_leave_fullscreen();
    SetFocus(address);
    SendMessageW(address,EM_SETSEL,0,-1);
}
void moon_shell_address(const char *value, bool force) {
    if (GetFocus() == address && !force) return;
    wchar_t wide[4096];
    if (!moon_utf16(value,wide,ARRAYSIZE(wide))) return;
    wchar_t current[4096];
    GetWindowTextW(address,current,ARRAYSIZE(current));
    if (force) moon_suggest_hide();
    if (wcscmp(current,wide)!=0) {
        syncing_address=true;
        SetWindowTextW(address,wide);
        syncing_address=false;
    }
}
void moon_shell_status(const char *value) {
    moon_utf16(value,content_status,ARRAYSIZE(content_status));
    InvalidateRect(content,NULL,FALSE);
}
void moon_shell_show_home(bool visible) {
    if (visible) moon_shell_leave_fullscreen();
    if (show_home==visible) return;
    show_home=visible;
    if (visible) SetWindowTextW(home_edit,L"");
    ShowWindow(content,visible?SW_HIDE:SW_SHOWNA);
    ShowWindow(home_edit,visible?SW_SHOWNA:SW_HIDE);
    InvalidateRect(frame,NULL,FALSE);
}
static void refresh_theme(void) {
    HBRUSH old=address_brush;
    address_brush=CreateSolidBrush(rgb(theme->field));
    if (old) DeleteObject(old);
    InvalidateRect(frame,NULL,TRUE);
    InvalidateRect(address,NULL,TRUE);
    InvalidateRect(home_edit,NULL,TRUE);
    InvalidateRect(content,NULL,TRUE);
    moon_find_layout();
    moon_dialog_refresh();
}
static bool theme_path(char *path,size_t size) {
    if (private_window) return false;
    int written=snprintf(path,size,"%s\\chrome-theme",moon_profile_dir());
    return written>0 && (size_t)written<size;
}
bool moon_shell_set_appearance(bool dark_mode, bool focused) {
    const Theme *next=dark_mode?&dark:&light;
    const bool theme_changed=next!=theme, focus_changed=focused!=focus_mode;
    if (!theme_changed && !focus_changed) return true;
    if (theme_changed && !private_window) {
        char path[4096];
        if (!theme_path(path,sizeof(path)) || !moon_write_text(path,dark_mode?"dark":"light")) return false;
    }
    theme=next;
    focus_mode=focused;
    if (theme_changed) refresh_theme();
    if (focus_changed) {
        cancel_tab_drag();
        layout();
    }
    moon_engine_refresh_extension_appearance();
    return true;
}
void moon_shell_refresh_tab_order(bool reveal_active) {
    clamp_tab_strip(reveal_active);
    InvalidateRect(frame,NULL,FALSE);
}
void moon_shell_refresh(void) { moon_shell_refresh_tab_order(!tab_drag.active); }
void moon_quit(int status) {
    if (quitting) return;
    quitting = true;
    moon_command(MOON_SHUTDOWN,status==0?0:1,NULL);
    if (frame) DestroyWindow(frame);
    PostQuitMessage(status);
}
void moon_engine_test_fallback(bool value) {
    force_fallback = value;
    if (value) release_target();
    if (frame) InvalidateRect(frame,NULL,FALSE);
}

static void open_palette(void);
bool moon_shell_download_default(char *folder,size_t capacity) {
    PWSTR path=NULL;
    const HRESULT result=SHGetKnownFolderPath(&FOLDERID_Downloads,KF_FLAG_DONT_VERIFY,NULL,&path);
    const bool copied=SUCCEEDED(result) && path && moon_utf8(path,folder,capacity);
    CoTaskMemFree(path);
    return copied;
}

int moon_shell_choose_download_folder(const char *initial,char *folder,size_t capacity) {
    static bool choosing;
    if (choosing || private_window) return -1;
    IFileOpenDialog *picker=NULL;
    HRESULT result=CoCreateInstance(&CLSID_FileOpenDialog,NULL,CLSCTX_INPROC_SERVER,
        &IID_IFileOpenDialog,(void **)&picker);
    if (FAILED(result)) return -1;
    FILEOPENDIALOGOPTIONS options=0;
    result=IFileOpenDialog_GetOptions(picker,&options);
    if (SUCCEEDED(result)) result=IFileOpenDialog_SetOptions(picker,options |
        FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_DONTADDTORECENT);
    if (SUCCEEDED(result)) result=IFileOpenDialog_SetTitle(picker,L"选择下载文件夹");
    if (SUCCEEDED(result) && initial && *initial) {
        wchar_t path[4096];
        IShellItem *start=NULL;
        if (moon_utf16(initial,path,ARRAYSIZE(path)) &&
            SUCCEEDED(SHCreateItemFromParsingName(path,NULL,&IID_IShellItem,(void **)&start))) {
            IFileOpenDialog_SetFolder(picker,start);
            IShellItem_Release(start);
        }
    }
    if (SUCCEEDED(result)) {
        choosing=true;
        result=IFileOpenDialog_Show(picker,frame);
        choosing=false;
    }
    IShellItem *selected=NULL;
    if (SUCCEEDED(result)) result=IFileOpenDialog_GetResult(picker,&selected);
    PWSTR path=NULL;
    if (SUCCEEDED(result)) result=IShellItem_GetDisplayName(selected,SIGDN_FILESYSPATH,&path);
    const DWORD attributes=path ? GetFileAttributesW(path) : INVALID_FILE_ATTRIBUTES;
    const bool copied=SUCCEEDED(result) && attributes!=INVALID_FILE_ATTRIBUTES &&
        (attributes&FILE_ATTRIBUTE_DIRECTORY) && moon_utf8(path,folder,capacity);
    CoTaskMemFree(path);
    if (selected) IShellItem_Release(selected);
    IFileOpenDialog_Release(picker);
    if (copied) return 1;
    return result==HRESULT_FROM_WIN32(ERROR_CANCELLED)?0:-1;
}

static int pick_html_file(bool save,const wchar_t *title,wchar_t *file,DWORD capacity) {
    OPENFILENAMEW dialog={.lStructSize=sizeof(dialog), .hwndOwner=frame,
        .lpstrFilter=L"HTML 文件 (*.html;*.htm)\0*.html;*.htm\0\0",
        .lpstrFile=file, .nMaxFile=capacity, .lpstrDefExt=L"html", .lpstrTitle=title,
        .Flags=OFN_EXPLORER|OFN_NOCHANGEDIR|OFN_PATHMUSTEXIST|(save?OFN_OVERWRITEPROMPT:OFN_FILEMUSTEXIST)|
            (private_window?OFN_DONTADDTORECENT:0)};
    const BOOL chosen=save?GetSaveFileNameW(&dialog):GetOpenFileNameW(&dialog);
    if (!chosen) return CommDlgExtendedError() ? -1 : 0;
    return 1;
}
int moon_shell_pick_bookmarks(bool save,char *path,size_t capacity) {
    wchar_t file[2048]=L"";
    if (save) wcscpy(file,L"Moon-Bookmarks.html");
    int result=pick_html_file(save,save?L"导出 HTML 书签":L"导入 HTML 书签",file,ARRAYSIZE(file));
    return result==1 && !moon_utf8(file,path,capacity) ? -1 : result;
}
int moon_shell_pick_html(const char *title,char *path,size_t capacity,bool *replace) {
    wchar_t file[2048]=L"网页.html", cleaned[512];
    if (moon_utf16(title,cleaned,ARRAYSIZE(cleaned)) && cleaned[0]) {
        size_t length=wcslen(cleaned);
        if (length>100) {
            length=100;
            if (IS_HIGH_SURROGATE(cleaned[length-1])) --length;
        }
        for (size_t i=0;i<length;++i)
            if (cleaned[i]<32 || wcschr(L"<>:\"/\\|?*",cleaned[i])) cleaned[i]=L' ';
        while (length && (cleaned[length-1]==L' ' || cleaned[length-1]==L'.')) --length;
        cleaned[length]=0;
        if (length) swprintf(file,ARRAYSIZE(file),L"网页 - %ls.html",cleaned);
    }
    int result=pick_html_file(true,L"网页另存为 HTML",file,ARRAYSIZE(file));
    if (result!=1) return result;
    const wchar_t *extension=wcsrchr(file,L'.');
    if (!extension || (_wcsicmp(extension,L".html")!=0 && _wcsicmp(extension,L".htm")!=0)) return -2;
    *replace=GetFileAttributesW(file)!=INVALID_FILE_ATTRIBUTES;
    return moon_utf8(file,path,capacity)?1:-1;
}
static void plugin_menu_item(HMENU menu, size_t plugin, size_t entry, bool enabled) {
    wchar_t action[300];
    if (!moon_utf16(moon_plugin_action(plugin,entry),action,256)) return;
    const char *shortcut=moon_plugin_action_shortcut(plugin,entry);
    if (*shortcut) {
        size_t end=wcslen(action);
        action[end++]=L'\t';
        if (!moon_utf16(shortcut,action+end,ARRAYSIZE(action)-end)) action[end-1]=0;
    }
    const unsigned id=MENU_PLUGIN_BASE+(unsigned)plugin*MENU_PLUGIN_STRIDE+MENU_PLUGIN_ACTIONS+(unsigned)entry;
    AppendMenuW(menu,MF_STRING|(enabled?0:MF_GRAYED),id,action);
}

static bool site_menu(HWND hwnd) {
    MoonSiteContext site;
    if (!moon_site_context(&site)) return false;
    wchar_t origin[320];
    if (!moon_utf16(site.origin,origin,ARRAYSIZE(origin))) return false;
    HMENU popup=CreatePopupMenu();
    if (!popup) return false;
    AppendMenuW(popup,MF_STRING|MF_GRAYED,0,origin);
    if (!strncmp(site.origin,"http://",7)) AppendMenuW(popup,MF_STRING|MF_GRAYED,0,L"HTTP · 未加密");
    if (!strncmp(site.origin,"https://",8)) AppendMenuW(popup,MF_STRING|MF_GRAYED,0,L"HTTPS · 证书详情不可用");
    if (site.site_muted) AppendMenuW(popup,MF_STRING|MF_GRAYED,0,L"此网站已静音");
    if (site.tab_muted) AppendMenuW(popup,MF_STRING|MF_GRAYED,0,L"此标签页已静音");

    const int header=GetMenuItemCount(popup);
    for (size_t i=0;i<moon_plugin_count();++i)
        for (size_t j=0;j<moon_plugin_action_count(i);++j)
            if (moon_plugin_action_site_menu(i,j)) plugin_menu_item(popup,i,j,true);
    if (GetMenuItemCount(popup)>header) InsertMenuW(popup,header,MF_BYPOSITION|MF_SEPARATOR,0,NULL);

    RECT button=rectangle(address_left()+3,ADDRESS_TOP,24,ADDRESS_HEIGHT);
    MapWindowPoints(hwnd,NULL,(POINT *)&button,2);
    TPMPARAMS placement={.cbSize=sizeof(placement),.rcExclude=button};
    const UINT command=TrackPopupMenuEx(popup,TPM_RETURNCMD|TPM_NONOTIFY|TPM_TOPALIGN|TPM_LEFTALIGN,
        button.left,button.bottom,hwnd,&placement);
    DestroyMenu(popup);
    if (command>=MENU_PLUGIN_BASE) {
        const UINT value=command-MENU_PLUGIN_BASE, offset=value%MENU_PLUGIN_STRIDE;
        if (offset>=MENU_PLUGIN_ACTIONS) moon_site_menu_run(&site,value/MENU_PLUGIN_STRIDE,offset-MENU_PLUGIN_ACTIONS);
    }
    return true;
}

static void plugin_command_groups(HMENU popup, size_t count) {
    static const wchar_t *labels[MOON_MENU_COUNT]={
        [MOON_MENU_PAGE]=L"标签与页面",
        [MOON_MENU_LIBRARY]=L"浏览资料",
        [MOON_MENU_PRIVACY]=L"隐私与安全",
        [MOON_MENU_DEVELOPER]=L"开发与诊断",
        [MOON_MENU_EXTENSIONS]=L"扩展工具",
    };
    HMENU groups[MOON_MENU_COUNT]={0};
    groups[MOON_MENU_PINNED]=popup;
    for (size_t i=0;i<count;++i) {
        for (size_t j=0;j<moon_plugin_action_count(i);++j) {
            unsigned location=moon_plugin_action_menu(i,j);
            if (location==MOON_MENU_NONE || location>=ARRAYSIZE(groups)) continue;
            if (!groups[location]) groups[location]=CreatePopupMenu();
            if (groups[location]) plugin_menu_item(groups[location],i,j,true);
        }
    }
    for (unsigned location=MOON_MENU_PAGE;location<ARRAYSIZE(groups);++location)
        if (groups[location] && !AppendMenuW(popup,MF_POPUP,(UINT_PTR)groups[location],labels[location]))
            DestroyMenu(groups[location]);
}
static void menu(HWND hwnd, RECT button, bool above, bool right_aligned) {
    HMENU popup=CreatePopupMenu();
    if (!popup) return;
    AppendMenuW(popup,MF_STRING,MENU_ADD,L"\u65b0\u5efa\u6807\u7b7e\u9875\tCtrl+T");
    AppendMenuW(popup,MF_STRING,MENU_PALETTE,L"\u547d\u4ee4\u9762\u677f\tCtrl+K");
    if (!private_window) {
        AppendMenuW(popup,MF_STRING,MENU_UPDATES,L"\u7248\u672c\u4e0e\u66f4\u65b0");
        AppendMenuW(popup,MF_STRING,MENU_MARKET,L"插件市场");
        AppendMenuW(popup,MF_STRING,MENU_MANAGE_PLUGINS,L"管理插件");
    }
    size_t count=moon_plugin_count();
    if (count) {
        AppendMenuW(popup,MF_SEPARATOR,0,NULL);
        plugin_command_groups(popup,count);
    }
    HMENU extensions=count && !private_window ? CreatePopupMenu() : NULL;
    if (extensions) AppendMenuW(popup,MF_POPUP,(UINT_PTR)extensions,L"插件");
    for(size_t i=0;extensions && i<count;++i) {
        wchar_t name[256],action[300];
        if (!moon_utf16(moon_plugin_label(i),name,ARRAYSIZE(name))) continue;
        HMENU sub=CreatePopupMenu();
        if (!sub) continue;
        const bool enabled=moon_plugin_enabled(i);
        const unsigned id=MENU_PLUGIN_BASE+(unsigned)i*MENU_PLUGIN_STRIDE;
        AppendMenuW(sub,MF_STRING|(enabled?MF_CHECKED:0),id,L"启用插件");
        if (moon_plugin_has_settings(i)) AppendMenuW(sub,MF_STRING|(enabled?0:MF_GRAYED),id+1,L"配置页面");
        for (size_t j=0;j<MENU_PLUGIN_ACTIONS-2;++j) {
            const char *permission=moon_plugin_permission_label(j);
            if (!*permission) break;
            const unsigned flags=moon_plugin_permission_flags(i,j);
            if ((flags&1) && moon_utf16(permission,action,ARRAYSIZE(action)))
                AppendMenuW(sub,MF_STRING|(flags&2?MF_CHECKED:0)|(enabled?0:MF_GRAYED),id+2+j,action);
        }
        for(size_t j=0;j<moon_plugin_action_count(i);++j)
            if (!moon_plugin_bound_action(i,j)) plugin_menu_item(sub,i,j,enabled);
        AppendMenuW(extensions,MF_POPUP,(UINT_PTR)sub,name);
    }
    MapWindowPoints(hwnd,NULL,(POINT *)&button,2);
    TPMPARAMS placement={.cbSize=sizeof(placement),.rcExclude=button};
    UINT flags=TPM_RETURNCMD|TPM_NONOTIFY|
        (above ? TPM_BOTTOMALIGN|TPM_VERTICAL : TPM_TOPALIGN)|
        (right_aligned ? TPM_RIGHTALIGN : TPM_LEFTALIGN);
    UINT command=TrackPopupMenuEx(popup,flags,right_aligned?button.right:button.left,
        above?button.top:button.bottom,hwnd,&placement);
    DestroyMenu(popup);
    if (command==MENU_ADD) moon_command(MOON_NEW,0,NULL);
    else if (command==MENU_PALETTE) open_palette();
    else if (command==MENU_UPDATES) moon_command(MOON_UPDATES,0,NULL);
    else if (command==MENU_MARKET) moon_command(MOON_MARKET,0,NULL);
    else if (command==MENU_MANAGE_PLUGINS) moon_command(MOON_OPEN_PLUGINS,0,NULL);
    else if (command>=MENU_PLUGIN_BASE) {
        unsigned value=command-MENU_PLUGIN_BASE;
        const unsigned offset=value%MENU_PLUGIN_STRIDE, plugin=value/MENU_PLUGIN_STRIDE;
        if (!offset) moon_command(MOON_PLUGIN_ENABLE,plugin,NULL);
        else if (offset==1) moon_command(MOON_PLUGIN_SETTINGS,plugin,NULL);
        else if (offset<MENU_PLUGIN_ACTIONS) moon_command(MOON_PLUGIN_GRANT,((uint64_t)plugin<<32)|(offset-2),NULL);
        else moon_command(MOON_PLUGIN_COMMAND,((uint64_t)plugin<<32)|(offset-MENU_PLUGIN_ACTIONS),NULL);
        moon_shell_refresh();
    }
}
static void palette_row(const wchar_t *name,LPARAM data) {
    LRESULT row=SendMessageW(palette_list,LB_ADDSTRING,0,(LPARAM)name);
    if (row>=0) SendMessageW(palette_list,LB_SETITEMDATA,(WPARAM)row,data);
}
static void filter_palette(void) {
    if (!palette_list || !palette_input) return;
    wchar_t query[4096], name[4096];
    GetWindowTextW(palette_input,query,ARRAYSIZE(query));
    bool url_like=wcspbrk(query,L"./:")!=NULL;
    SendMessageW(palette_list,WM_SETREDRAW,FALSE,0);
    SendMessageW(palette_list,LB_RESETCONTENT,0,0);
    if (palette_tabs) {
        wchar_t url[4096];
        for (size_t i=0;i<moon_tab_count();++i) {
            if (!moon_utf16(moon_tab_label(i),name,ARRAYSIZE(name))) continue;
            if (!*query || StrStrIW(name,query) ||
                (moon_utf16(moon_tab_url(i),url,ARRAYSIZE(url)) && StrStrIW(url,query)))
                palette_row(name,(LPARAM)moon_tab_id(i));
        }
        if (!SendMessageW(palette_list,LB_GETCOUNT,0,0)) palette_row(L"没有匹配的标签页",0);
    } else {
        if (url_like) palette_row(L"打开或搜索输入内容",-2);
        for (size_t i=0;i<moon_action_count(false);++i) {
            if (moon_utf16(moon_action_label(i,false),name,ARRAYSIZE(name)) && (!*query || StrStrIW(name,query)))
                palette_row(name,(LPARAM)i);
        }
        for (size_t i=0;i<moon_tab_count();++i) {
            if (moon_utf16(moon_tab_label(i),name,ARRAYSIZE(name)) && (!*query || StrStrIW(name,query)))
                palette_row(name,PALETTE_TAB_OFFSET+(LPARAM)i);
        }
        if (*query && !url_like) palette_row(L"打开或搜索输入内容",-2);
    }
    SendMessageW(palette_list,LB_SETCURSEL,0,0);
    SendMessageW(palette_list,WM_SETREDRAW,TRUE,0);
    InvalidateRect(palette_list,NULL,TRUE);
}
static void close_palette(bool restore_focus) {
    HWND previous=palette_previous_focus;
    DestroyWindow(palette);
    if (restore_focus && IsWindow(previous) && IsWindowVisible(previous)) SetFocus(previous);
}
static void run_palette(void) {
    LRESULT row=SendMessageW(palette_list,LB_GETCURSEL,0,0);
    if (row==LB_ERR) return;
    LRESULT action=SendMessageW(palette_list,LB_GETITEMDATA,(WPARAM)row,0);
    if (palette_tabs) {
        if (action<=0) return;
        const size_t index=moon_tab_index((uint64_t)action);
        if (index>=moon_tab_count()) { filter_palette(); return; }
        const bool was_current=index==moon_active_index();
        close_palette(was_current);
        moon_command(MOON_SELECT,index,NULL);
        return;
    }
    wchar_t query[4096];
    char value[16384];
    GetWindowTextW(palette_input,query,ARRAYSIZE(query));
    DestroyWindow(palette);
    if (action==-2 && moon_utf8(query,value,sizeof(value))) moon_command(MOON_ADDRESS,0,value);
    else if (action>=PALETTE_TAB_OFFSET) moon_command(MOON_SELECT,(uint64_t)(action-PALETTE_TAB_OFFSET),NULL);
    else if (action>=0) moon_action_run((size_t)action,false);
}
static LRESULT CALLBACK tab_search_list(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp,UINT_PTR id,DWORD_PTR ref) {
    if (msg==WM_LBUTTONUP) {
        LRESULT hit=SendMessageW(hwnd,LB_ITEMFROMPOINT,0,lp);
        RECT row;
        POINT at={(short)LOWORD(lp),(short)HIWORD(lp)};
        if (!HIWORD(hit) && LOWORD(hit)==SendMessageW(hwnd,LB_GETCURSEL,0,0) &&
            SendMessageW(hwnd,LB_GETITEMRECT,LOWORD(hit),(LPARAM)&row)!=LB_ERR && PtInRect(&row,at)) {
            LRESULT result=DefSubclassProc(hwnd,msg,wp,lp);
            if (IsWindow(hwnd)) run_palette();
            return result;
        }
    }
    if (msg==WM_NCDESTROY) RemoveWindowSubclass(hwnd,tab_search_list,id);
    return DefSubclassProc(hwnd,msg,wp,lp);
}
static void paint_tab_search_row(const DRAWITEMSTRUCT *item) {
    if (item->itemID==(UINT)-1) return;
    HDC dc=item->hDC;
    RECT bounds=item->rcItem;
    const uint64_t token=(uint64_t)item->itemData;
    const bool selected=token && (item->itemState&ODS_SELECTED);
    SetBkColor(dc,rgb(selected?theme->soft:theme->panel));
    ExtTextOutW(dc,0,0,ETO_OPAQUE,&bounds,L"",0,NULL);
    SetBkMode(dc,TRANSPARENT);
    HGDIOBJ font=SelectObject(dc,edit_font);
    const size_t index=moon_tab_index(token);
    wchar_t title[4096], url[4096];
    bounds.left+=px(10);
    bounds.right-=px(10);
    if (index<moon_tab_count() && moon_utf16(moon_tab_label(index),title,ARRAYSIZE(title))) {
        const UINT format=DT_SINGLELINE|DT_VCENTER|DT_END_ELLIPSIS|DT_NOPREFIX;
        if (moon_utf16(moon_tab_url(index),url,ARRAYSIZE(url)) && *url && wcscmp(title,url)!=0) {
            RECT line=bounds;
            line.top+=px(2);
            line.bottom=line.top+px(21);
            SetTextColor(dc,rgb(theme->text));
            DrawTextW(dc,title,-1,&line,format);
            bounds.top=line.bottom;
            SetTextColor(dc,rgb(theme->muted));
            DrawTextW(dc,url,-1,&bounds,format);
        } else {
            SetTextColor(dc,rgb(theme->text));
            DrawTextW(dc,title,-1,&bounds,format);
        }
    } else if (!token) {
        SetTextColor(dc,rgb(theme->muted));
        DrawTextW(dc,L"没有匹配的标签页",-1,&bounds,DT_SINGLELINE|DT_VCENTER|DT_NOPREFIX);
    }
    SelectObject(dc,font);
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
        const int header=palette_tabs?px(34):0;
        if (palette_input) MoveWindow(palette_input,px(12),px(12)+header,r.right-px(24),px(27),TRUE);
        if (palette_list) MoveWindow(palette_list,px(12),px(47)+header,r.right-px(24),r.bottom-px(59)-header,TRUE);
        return 0;
    }
    if (palette_tabs && msg==WM_ACTIVATE && LOWORD(wp)==WA_INACTIVE) PostMessageW(hwnd,WM_CLOSE,0,0);
    if (palette_tabs && msg==WM_PAINT) {
        PAINTSTRUCT paint;
        RECT area;
        HDC dc=BeginPaint(hwnd,&paint);
        GetClientRect(hwnd,&area);
        SetBkColor(dc,rgb(theme->panel));
        ExtTextOutW(dc,0,0,ETO_OPAQUE,&area,L"",0,NULL);
        SetBkMode(dc,TRANSPARENT);
        SetTextColor(dc,rgb(theme->text));
        HGDIOBJ font=SelectObject(dc,edit_font);
        area.left=px(12);
        area.bottom=px(46);
        DrawTextW(dc,L"搜索打开的标签",-1,&area,DT_SINGLELINE|DT_VCENTER|DT_NOPREFIX);
        SelectObject(dc,font);
        EndPaint(hwnd,&paint);
        return 0;
    }
    if (palette_tabs && msg==WM_DRAWITEM && wp==PALETTE_LIST) {
        paint_tab_search_row((const DRAWITEMSTRUCT *)lp);
        return TRUE;
    }
    if (msg==WM_DESTROY) {
        palette=NULL; palette_input=NULL; palette_list=NULL;
        palette_previous_focus=NULL; palette_tabs=false;
        return 0;
    }
    if (msg==WM_CTLCOLOREDIT || msg==WM_CTLCOLORLISTBOX) {
        SetBkColor((HDC)wp,rgb(theme->field));
        SetTextColor((HDC)wp,rgb(theme->text));
        return (LRESULT)address_brush;
    }
    return DefWindowProcW(hwnd,msg,wp,lp);
}
static bool open_palette_mode(bool tabs_only) {
    HWND foreground=GetForegroundWindow();
    const bool activate=!tabs_only || (foreground && (foreground==frame || foreground==palette));
    if (palette && palette_tabs==tabs_only) {
        if (activate) SetFocus(palette_input);
        return true;
    }
    if (palette) close_palette(true);
    RECT owner;
    GetWindowRect(frame,&owner);
    int width=px(client_width()<740?450:540);
    int height=px(312), x=owner.left+(owner.right-owner.left-width)/2, y=owner.top+px(62);
    if (tabs_only) {
        MONITORINFO monitor={.cbSize=sizeof(monitor)};
        if (GetMonitorInfoW(MonitorFromWindow(frame,MONITOR_DEFAULTTONEAREST),&monitor)) {
            const RECT work=monitor.rcWork;
            width=min(px(440),work.right-work.left);
            height=min(px(376),work.bottom-work.top);
            x=max(work.left,min(owner.right-px(136)-width,work.right-width));
            y=max(work.top,min(owner.top+px(48),work.bottom-height));
        }
        if (activate) palette_previous_focus=GetFocus();
    }
    palette_tabs=tabs_only;
    HINSTANCE instance=GetModuleHandleW(NULL);
    palette=CreateWindowExW(WS_EX_TOOLWINDOW,L"MoonPalette",tabs_only?L"搜索打开的标签":L"命令面板",
        WS_POPUP|WS_CLIPCHILDREN|(tabs_only?WS_BORDER:WS_CAPTION|WS_SYSMENU),
        x,y,width,height,frame,NULL,instance,NULL);
    if (!palette) { palette_previous_focus=NULL; palette_tabs=false; return false; }
    palette_input=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",NULL,WS_CHILD|WS_VISIBLE|WS_TABSTOP|ES_AUTOHSCROLL,
        0,0,0,0,palette,(HMENU)PALETTE_INPUT,instance,NULL);
    palette_list=CreateWindowExW(tabs_only?0:WS_EX_CLIENTEDGE,L"LISTBOX",NULL,
        WS_CHILD|WS_VISIBLE|WS_VSCROLL|WS_TABSTOP|LBS_NOTIFY|LBS_NOINTEGRALHEIGHT|
        (tabs_only?LBS_OWNERDRAWFIXED|LBS_HASSTRINGS:0),
        0,0,0,0,palette,(HMENU)PALETTE_LIST,instance,NULL);
    if (!palette_input || !palette_list) { close_palette(tabs_only); return false; }
    SendMessageW(palette_input,WM_SETFONT,(WPARAM)edit_font,TRUE);
    SendMessageW(palette_list,WM_SETFONT,(WPARAM)edit_font,TRUE);
    SendMessageW(palette_input,EM_SETLIMITTEXT,4095,0);
    SendMessageW(palette_input,EM_SETCUEBANNER,TRUE,(LPARAM)(tabs_only?L"搜索标题或网址":L"搜索标签页、命令，或输入网址"));
    if (tabs_only) {
        SendMessageW(palette_list,LB_SETITEMHEIGHT,0,px(46));
        SetWindowSubclass(palette_list,tab_search_list,1,0);
    }
    SendMessageW(palette,WM_SIZE,0,0);
    filter_palette();
    ShowWindow(palette,activate?SW_SHOW:SW_SHOWNOACTIVATE);
    if (activate) SetFocus(palette_input);
    return true;
}
static void open_palette(void) { open_palette_mode(false); }
bool moon_shell_tab_search(void) {
    moon_suggest_hide();
    return open_palette_mode(true);
}
static bool palette_key(const MSG *msg) {
    switch(msg->wParam) {
        case VK_ESCAPE: close_palette(palette_tabs); return true;
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
static void tab_context_menu(HWND hwnd, POINT screen) {
    if (focus_mode) return;
    POINT client=screen;
    ScreenToClient(hwnd,&client);
    int x=MulDiv(client.x,96,dpi), y=MulDiv(client.y,96,dpi);
    if (x<PAD || x>=pane_left() || y<TAB_START || y>=client_height()-FOOTER) return;
    const MoonSidebarRow *row=sidebar_row_at(y);
    if (!row) return;
    const size_t index=row->tab;
    uint64_t id=moon_tab_id(index);
    unsigned flags=moon_tab_flags(index);
    HMENU popup=CreatePopupMenu();
    if (!popup) return;
    const unsigned tab_tools=moon_tab_tools_permissions();
    if (row->header) {
        if (tab_tools&MOON_TAB_GROUPS) AppendMenuW(popup,MF_STRING,MOON_TAB_GROUP_PANEL,L"管理标签组");
        const UINT command=TrackPopupMenuEx(popup,TPM_RETURNCMD|TPM_NONOTIFY|TPM_RIGHTBUTTON,screen.x,screen.y,hwnd,NULL);
        DestroyMenu(popup);
        if (command) moon_command((int)command,id,NULL);
        return;
    }
    const uint64_t selection=(flags&MOON_TAB_SELECTED)?moon_tab_selection_epoch():0;
    if (selection && (tab_tools&MOON_TAB_MANAGE)) {
        enum { CANCEL_SELECTION = 1 };
        wchar_t close_label[48];
        swprintf(close_label,ARRAYSIZE(close_label),L"关闭所选标签（%u）",(unsigned)moon_tab_selection_count());
        AppendMenuW(popup,MF_STRING,MOON_TAB_CLOSE_SELECTED,close_label);
        AppendMenuW(popup,MF_STRING,CANCEL_SELECTION,L"取消选择");
        const UINT command=TrackPopupMenuEx(popup,TPM_RETURNCMD|TPM_NONOTIFY|TPM_RIGHTBUTTON,screen.x,screen.y,hwnd,NULL);
        DestroyMenu(popup);
        if (command==CANCEL_SELECTION && selection==moon_tab_selection_epoch()) moon_tab_selection_clear();
        if (command==MOON_TAB_CLOSE_SELECTED) moon_command((int)command,selection,NULL);
        return;
    }
    if (tab_tools&MOON_TAB_ORGANIZE) {
        AppendMenuW(popup,MF_STRING|((flags&MOON_TAB_CAN_PIN)?0:MF_GRAYED),MOON_TAB_PIN,
            (flags&MOON_TAB_PINNED)?L"取消固定标签":L"固定标签");
        AppendMenuW(popup,MF_STRING|((flags&MOON_TAB_CAN_MUTE)?0:MF_GRAYED),MOON_TAB_MUTE,
            (flags&MOON_TAB_MUTED)?L"取消标签静音":L"静音此标签");
    }
    if (tab_tools&MOON_TAB_MANAGE) {
        AppendMenuW(popup,MF_STRING|((flags&MOON_TAB_CAN_DUPLICATE)?0:MF_GRAYED),MOON_TAB_DUPLICATE,L"复制标签");
        AppendMenuW(popup,MF_STRING|((flags&MOON_TAB_CAN_COPY_ADDRESS)?0:MF_GRAYED),MOON_TAB_COPY_ADDRESS,L"复制标签网址");
    }
    if ((tab_tools&MOON_TAB_GROUPS) && !(flags&MOON_TAB_PINNED)) {
        AppendMenuW(popup,MF_STRING,MOON_TAB_GROUP_NEW,L"新建标签组");
        AppendMenuW(popup,MF_STRING,MOON_TAB_GROUP_PANEL,L"移入标签组…");
        if (row->group) AppendMenuW(popup,MF_STRING,MOON_TAB_GROUP_REMOVE,L"移出标签组");
    }
    if (tab_tools) AppendMenuW(popup,MF_SEPARATOR,0,NULL);
    AppendMenuW(popup,MF_STRING,MOON_TAB_CLOSE_TARGET,L"关闭标签");
    if (tab_tools&MOON_TAB_MANAGE) {
        AppendMenuW(popup,MF_STRING|(moon_tab_count()>1?0:MF_GRAYED),MOON_TAB_CLOSE_OTHERS,L"关闭其他标签");
        AppendMenuW(popup,MF_STRING|(index+1<moon_tab_count()?0:MF_GRAYED),MOON_TAB_CLOSE_BELOW,L"关闭下方标签");
    }
    const UINT command=TrackPopupMenuEx(popup,TPM_RETURNCMD|TPM_NONOTIFY|TPM_RIGHTBUTTON,screen.x,screen.y,hwnd,NULL);
    DestroyMenu(popup);
    if (command) moon_command((int)command,id,NULL);
}
static uint64_t tab_drag_row(POINT point) {
    if (point.x<12 || point.x>=SIDEBAR+4 || point.y<TAB_START) return 0;
    const MoonSidebarRow *row=sidebar_row_at(point.y);
    return row && !row->header?moon_tab_id(row->tab):0;
}

static void start_tab_drag(POINT pixel) {
    ignore_tab_release=false;
    if (fullscreen || focus_mode || !moon_tab_drop_enabled()) return;
    POINT point={MulDiv(pixel.x,96,dpi),MulDiv(pixel.y,96,dpi)};
    const uint64_t source=tab_drag_row(point);
    if (!source) return;
    const size_t index=sidebar_row_at(point.y)->tab;
    if (point.x>=SIDEBAR-26 && !(moon_tab_flags(index)&MOON_TAB_PINNED)) return;
    SetCapture(frame);
    if (GetCapture()!=frame) return;
    moon_tab_selection_clear();
    tab_drag.source=source;
    tab_drag.start=pixel;
    tab_drag.pointer=point;
}

static void update_tab_drag_target(void) {
    POINT point=tab_drag.pointer;
    tab_drag.target=(MoonTabDrop){0};
    const size_t count=sidebar_count, capacity=tab_capacity();
    size_t visible=count>first_tab?count-first_tab:0;
    if (visible>capacity) visible=capacity;
    if (visible && point.y>=TAB_START-5 && point.y<client_height()-FOOTER) {
        const int end=TAB_START+(int)visible*ROW;
        if (point.y<TAB_START) point.y=TAB_START;
        if (point.y>=end) point.y=end-1;
        const int row=(point.y-TAB_START)/ROW;
        const int top=TAB_START+row*ROW;
        const MoonSidebarRow *target=sidebar_row_at(point.y);
        MoonTabDrop drop={.source=tab_drag.source,
            .anchor=target && point.x>=12 && point.x<SIDEBAR+4 ? moon_tab_id(target->tab) : 0,
            .after=point.y-top>=ROW/2,.into_group=target && target->header};
        if (drop.anchor && moon_tab_drop_valid(&drop)) {
            tab_drag.target=drop;
            tab_drag.guide=top+(drop.after?ROW-3:-3);
        }
    }
    SetCursor(LoadCursorW(NULL,tab_drag.target.anchor?IDC_SIZENS:IDC_NO));
}

static void track_tab_drag(POINT pixel, POINT point) {
    tab_drag.pointer=point;
    if (!tab_drag.active) {
        if (abs(pixel.x-tab_drag.start.x)<GetSystemMetricsForDpi(SM_CXDRAG,dpi) &&
            abs(pixel.y-tab_drag.start.y)<GetSystemMetricsForDpi(SM_CYDRAG,dpi)) return;
        tab_drag.active=true;
        SetTimer(frame,TAB_DRAG_TIMER,110,NULL);
    }
    update_tab_drag_target();
}

static void cancel_tab_drag(void) {
    if (!tab_drag.source) return;
    tab_drag.source=0;
    tab_drag.target=(MoonTabDrop){0};
    tab_drag.active=false;
    ignore_tab_release=true;
    KillTimer(frame,TAB_DRAG_TIMER);
    if (GetCapture()==frame) ReleaseCapture();
    SetCursor(LoadCursorW(NULL,IDC_ARROW));
    InvalidateRect(frame,NULL,FALSE);
}

static void scroll_tab_drag(void) {
    const POINT pointer=tab_drag.pointer;
    if (!tab_drag.active || pointer.x<12 || pointer.x>=SIDEBAR+4) return;
    const size_t prev=first_tab;
    const int end=TAB_START+(int)tab_capacity()*ROW;
    if (pointer.y>=TAB_START-5 && pointer.y<TAB_START+14 && first_tab) --first_tab;
    else if (pointer.y>=end-15 && pointer.y<client_height()-FOOTER) ++first_tab;
    clamp_tab_strip(false);
    if (first_tab==prev) return;
    update_tab_drag_target();
    InvalidateRect(frame,NULL,FALSE);
}

static void click(HWND hwnd,int psx,int psy,WPARAM buttons) {
    int x=MulDiv(psx,96,dpi), y=MulDiv(psy,96,dpi);
    int width=client_width(), height=client_height(), left=pane_left();
    if (y<TOP) {
        if (x>=width-50) { PostMessageW(hwnd,WM_SYSCOMMAND,SC_CLOSE,0); return; }
        if (x>=width-94) { ShowWindow(hwnd,IsZoomed(hwnd)?SW_RESTORE:SW_MAXIMIZE); return; }
        if (x>=width-138) { ShowWindow(hwnd,SW_MINIMIZE); return; }
        if (x>=width-175) { menu(hwnd,rectangle(width-175,8,32,32),false,true); return; }
        if (x>=width-213) {
            moon_command(MOON_TOGGLE_SIDEBAR,0,NULL);
            return;
        }
        if (x>=left && x<left+31) moon_command(MOON_BACK,0,NULL);
        else if (x>=left+34 && x<left+65) moon_command(MOON_FORWARD,0,NULL);
        else if (x>=left+68 && x<left+99) moon_command(MOON_RELOAD,0,NULL);
        else if (within(x,y,address_left()+3,ADDRESS_TOP,24,ADDRESS_HEIGHT) && site_menu(hwnd)) return;
        else if (x>=address_left() && x<address_right(width)) moon_shell_focus_address();
        return;
    }
    if (!focus_mode && x<left) {
        if (within(x,y,12,50,SIDEBAR-8,34)) open_palette();
        else if (within(x,y,SIDEBAR-28,92,40,29)) moon_command(MOON_NEW,0,NULL);
        else if (y>=TAB_START && y<height-FOOTER) {
            const MoonSidebarRow *row=sidebar_row_at(y);
            if (row && row->header) moon_group_toggle(row->group);
            else if (row) {
                const size_t index=row->tab;
                if ((buttons&(MK_CONTROL|MK_SHIFT)) && moon_tab_selection_pick(index,(buttons&MK_SHIFT)!=0)) return;
                const bool close=x>=SIDEBAR-26 && !(moon_tab_flags(index)&MOON_TAB_PINNED);
                moon_command(close ? MOON_CLOSE : MOON_SELECT,index,NULL);
            }
        } else if (y>=height-FOOTER) {
            if (x<49) menu(hwnd,rectangle(14,height-FOOTER+7,32,31),true,false);
            else if (x<86) moon_command(MOON_DIAGNOSTICS,0,NULL);
            else if (x<125) menu(hwnd,rectangle(88,height-FOOTER+7,32,31),true,false);
        }
        return;
    }
    if (bookmark_bar_drawn() && y<pane_top() && x>=left) {
        BookmarkButton buttons[MOON_BOOKMARK_BAR_PAGE+1];
        size_t shown;
        const size_t count=bookmark_buttons(width,buttons,&shown);
        for (size_t i=0;i<count;++i) {
            const BookmarkButton item=buttons[i];
            if (!within(x,y,item.x,TOP+1,item.width,BOOKMARK_HEIGHT-5)) continue;
            const RECT anchor=rectangle(item.x,TOP+1,item.width,BOOKMARK_HEIGHT-5);
            if (item.index==BOOKMARK_MANAGE) (void)moon_plugin_open_page("moon.bookmarks");
            else if (item.index==BOOKMARK_OVERFLOW) moon_bookmark_menu_show("",shown,anchor);
            else if (!bookmark_roots[item.index].id) moon_bookmark_menu_show(bookmark_roots[item.index].folder,0,anchor);
            else (void)moon_bookmark_bar_open(bookmark_roots[item.index].id,GetKeyState(VK_CONTROL)<0);
            break;
        }
        return;
    }
    if (show_home) {
        int home_x=home_left(width), search=home_top(height)+98;
        if (within(x,y,home_x,search,home_width(width),44)) { SetFocus(home_edit); return; }
        if (private_window) return;
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
        moon_engine_resize_views(false);
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
static void refresh_presentation(HWND hwnd) {
    if (IsIconic(hwnd) || !IsWindowVisible(hwnd) || quitting) return;
    RedrawWindow(hwnd,NULL,NULL,RDW_INVALIDATE|RDW_NOCHILDREN);
    // WebKit presents through its own child HWND. Keep host repaint out of that surface.
    if (content) RedrawWindow(content,NULL,NULL,RDW_INVALIDATE|RDW_NOCHILDREN);
    if (address) InvalidateRect(address,NULL,FALSE);
    if (home_edit && IsWindowVisible(home_edit)) InvalidateRect(home_edit,NULL,FALSE);
}
static void queue_presentation(HWND hwnd) {
    if (!IsIconic(hwnd) && IsWindowVisible(hwnd) && !SetTimer(hwnd,PRESENTATION_TIMER,65,NULL))
        refresh_presentation(hwnd);
}
static LRESULT CALLBACK frame_message(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp) {
    switch (msg) {
        case WM_INITMENUPOPUP:
            if (moon_bookmark_menu_init((HMENU)wp)) return 0;
            break;
        case WM_COPYDATA: return !quitting && moon_instance_accept(hwnd,(const COPYDATASTRUCT *)lp);
        case WM_NCDESTROY:
            moon_instance_remove(hwnd);
            break;
        case WM_NCCALCSIZE: {
            if (!fullscreen && IsZoomed(hwnd)) {
                MONITORINFO area={.cbSize=sizeof(area)};
                RECT *client=wp ? &((NCCALCSIZE_PARAMS *)lp)->rgrc[0] : (RECT *)lp;
                if (GetMonitorInfoW(MonitorFromRect(client,MONITOR_DEFAULTTONEAREST),&area))
                    *client=area.rcWork;
            }
            return 0;
        }
        case WM_NCPAINT:
            if (!IsIconic(hwnd)) return 0;
            break;
        case WM_NCACTIVATE:
            if (!IsIconic(hwnd)) return DefWindowProcW(hwnd,msg,wp,-1);
            break;
        case WM_NCHITTEST: {
            if (fullscreen) return HTCLIENT;
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
        case WM_SIZE:
            if (content && address && wp!=SIZE_MINIMIZED) {
                layout();
                queue_presentation(hwnd);
            }
            return 0;
        case WM_MOVE: case WM_EXITSIZEMOVE:
            moon_suggest_hide();
            queue_presentation(hwnd);
            return 0;
        case WM_ACTIVATE:
            if (LOWORD(wp)==WA_INACTIVE) moon_suggest_hide();
            break;
        case WM_DISPLAYCHANGE: case WM_DWMCOMPOSITIONCHANGED:
            release_target();
            if (msg==WM_DISPLAYCHANGE && fullscreen) fit_fullscreen(MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST));
            queue_presentation(hwnd);
            break;
        case WM_DPICHANGED: {
            cancel_tab_drag();
            dpi = LOWORD(wp);
            const RECT *r = (RECT *)lp;
            release_target();
            if (fullscreen) fit_fullscreen(MonitorFromRect(r,MONITOR_DEFAULTTONEAREST));
            else SetWindowPos(hwnd,NULL,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER | SWP_NOACTIVATE);
            if (address && content) {
                set_font();
                layout();
                moon_engine_resize_views(true);
            }
            queue_presentation(hwnd);
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
            if ((HWND)lp==address || (HWND)lp==home_edit) {
                if (HIWORD(wp)==EN_CHANGE && !syncing_address) moon_suggest_change((HWND)lp);
                else if (HIWORD(wp)==EN_KILLFOCUS) moon_suggest_hide();
            }
            if (LOWORD(wp)==FULLSCREEN_EXIT_CONTROL && HIWORD(wp)==BN_CLICKED && (HWND)lp==fullscreen_exit)
                moon_shell_leave_fullscreen();
            if (HIWORD(wp)==EN_SETFOCUS || HIWORD(wp)==EN_KILLFOCUS) InvalidateRect(hwnd,NULL,FALSE);
            return 0;
        case WM_DRAWITEM: {
            if (wp!=FULLSCREEN_EXIT_CONTROL) break;
            const DRAWITEMSTRUCT *item=(const DRAWITEMSTRUCT *)lp;
            HBRUSH background=CreateSolidBrush(rgb(item->itemState&(ODS_SELECTED|ODS_HOTLIGHT)?theme->soft:theme->field));
            FillRect(item->hDC,&item->rcItem,background);
            DeleteObject(background);
            SetBkMode(item->hDC,TRANSPARENT);
            SetTextColor(item->hDC,rgb(theme->text));
            HFONT old=SelectObject(item->hDC,edit_font);
            RECT label=item->rcItem;
            DrawTextW(item->hDC,L"退出全屏   ·   F11 或 Esc",-1,&label,DT_CENTER|DT_VCENTER|DT_SINGLELINE);
            SelectObject(item->hDC,old);
            return TRUE;
        }
        case WM_MOUSEMOVE:
            hover=(POINT){MulDiv((short)LOWORD(lp),96,dpi),MulDiv((short)HIWORD(lp),96,dpi)};
            if (tab_drag.source) track_tab_drag((POINT){(short)LOWORD(lp),(short)HIWORD(lp)},hover);
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
        case WM_LBUTTONDOWN:
            if (wp&(MK_CONTROL|MK_SHIFT)) ignore_tab_release=false;
            else start_tab_drag((POINT){(short)LOWORD(lp),(short)HIWORD(lp)});
            return 0;
        case WM_LBUTTONUP: {
            const POINT pixel={(short)LOWORD(lp),(short)HIWORD(lp)};
            if (tab_drag.source) {
                POINT point={MulDiv(pixel.x,96,dpi),MulDiv(pixel.y,96,dpi)};
                track_tab_drag(pixel,point);
                const MoonTabDrop drop=tab_drag.target;
                const bool select=!tab_drag.active && tab_drag_row(point)==tab_drag.source;
                cancel_tab_drag();
                if (drop.anchor) moon_tab_drop_run(&drop);
                else if (select) moon_command(MOON_SELECT,sidebar_row_at(point.y)->tab,NULL);
            } else if (!fullscreen && !ignore_tab_release) {
                click(hwnd,pixel.x,pixel.y,wp);
            }
            ignore_tab_release=false;
            return 0;
        }
        case WM_CANCELMODE: case WM_CAPTURECHANGED:
            cancel_tab_drag();
            break;
        case WM_CONTEXTMENU:
            if (!fullscreen && (HWND)wp==hwnd && lp!=-1) tab_context_menu(hwnd,(POINT){(short)LOWORD(lp),(short)HIWORD(lp)});
            return 0;
        case WM_MOUSEWHEEL:
            if (!fullscreen && !focus_mode && sidebar_count > tab_capacity()) {
                if (GET_WHEEL_DELTA_WPARAM(wp) < 0) ++first_tab;
                else if (first_tab) --first_tab;
                clamp_tab_strip(false);
                if (tab_drag.active) update_tab_drag_target();
                InvalidateRect(hwnd,NULL,FALSE);
            }
            return 0;
        case WM_TIMER:
            if (wp==MOON_SUGGEST_TIMER) {
                moon_suggest_update();
                return 0;
            }
            if (wp==MAINTENANCE_TIMER) moon_command(MOON_TICK,0,NULL);
            if (wp==TAB_DRAG_TIMER) scroll_tab_drag();
            if (wp==PRESENTATION_TIMER) {
                KillTimer(hwnd,PRESENTATION_TIMER);
                refresh_presentation(hwnd);
            }
            if (wp==FULLSCREEN_HINT_TIMER) {
                RECT bounds;
                POINT mouse;
                if (!GetWindowRect(fullscreen_exit,&bounds) || !GetCursorPos(&mouse) || !PtInRect(&bounds,mouse)) {
                    KillTimer(hwnd,FULLSCREEN_HINT_TIMER);
                    ShowWindow(fullscreen_exit,SW_HIDE);
                }
            }
            return 0;
        case WM_HOTKEY:
            if (GetForegroundWindow()==frame && IsChild(content,GetFocus()) &&
                moon_plugin_capture_key(LOWORD(lp),HIWORD(lp))) return 0;
            if (moon_plugin_global_key((unsigned)wp,LOWORD(lp),HIWORD(lp))) return 0;
            break;
        case WM_CLOSE: moon_quit(0); return 0;
        case WM_ENDSESSION:
            if (wp) moon_quit(0);
            return 0;
    }
    return DefWindowProcW(hwnd,msg,wp,lp);
}
bool moon_ime_composing(HWND input) {
    HIMC context=ImmGetContext(input);
    if (!context) return false;
    bool active=ImmGetCompositionStringW(context,GCS_COMPSTR,NULL,0)>0;
    ImmReleaseContext(input,context);
    return active;
}
static bool keyboard(MSG *msg) {
    bool ctrl = GetKeyState(VK_CONTROL) < 0, shift = GetKeyState(VK_SHIFT) < 0;
    bool alt = (msg->lParam & (1L<<29)) != 0;
    const unsigned modifiers=(ctrl?MOD_CONTROL:0)|(alt?MOD_ALT:0)|(shift?MOD_SHIFT:0);
    static WPARAM captured_key;
    const bool repeated=(msg->lParam&(1L<<30))!=0;
    const bool in_content=IsChild(content,msg->hwnd);
    const bool in_page=in_content && moon_engine_page_window(msg->hwnd);
    if (tab_drag.source && !modifiers && msg->wParam==VK_ESCAPE) {
        cancel_tab_drag();
        return true;
    }
    if (in_page) {
        if (repeated && captured_key==msg->wParam) return true;
        captured_key=0;
        if (moon_plugin_capture_key(modifiers,(unsigned)msg->wParam)) {
            captured_key=msg->wParam;
            return true;
        }
    }
    if (!modifiers && msg->wParam==VK_ESCAPE && (!in_content || in_page) &&
        !moon_ime_composing(msg->hwnd) && moon_devtools_cancel_picker()) return true;
    if (fullscreen && !modifiers && msg->wParam==VK_ESCAPE && !moon_ime_composing(msg->hwnd)) {
        if (!repeated) moon_shell_leave_fullscreen();
        return true;
    }
    if (!modifiers && msg->wParam==VK_ESCAPE && !moon_ime_composing(msg->hwnd) && moon_tab_selection_clear()) return true;
    const bool in_address=msg->hwnd==address || msg->hwnd==home_edit;
    if (in_address && !modifiers && !moon_ime_composing(msg->hwnd) && moon_suggest_key(msg->hwnd,msg->wParam)) return true;
    if (in_address && msg->wParam==VK_RETURN && !ctrl && !alt && !moon_ime_composing(msg->hwnd)) {
        moon_suggest_hide();
        wchar_t wide[4096];
        char value[16384];
        GetWindowTextW(msg->hwnd,wide,ARRAYSIZE(wide));
        if (moon_utf8(wide,value,sizeof(value))) moon_command(MOON_ADDRESS,0,value);
        return true;
    }
    if ((ctrl && msg->wParam == 'L') || msg->wParam == VK_F6) { moon_shell_focus_address(); return true; }
    if (ctrl && msg->wParam == 'K') { open_palette(); return true; }
    if (ctrl && !shift && !alt && msg->wParam == 'T') { moon_command(MOON_NEW,0,NULL); return true; }
    if (ctrl && msg->wParam == 'W') { moon_command(MOON_CLOSE,moon_active_index(),NULL); return true; }
    if (ctrl && msg->wParam == VK_TAB) { moon_command(shift ? MOON_KEY_PREV : MOON_KEY_NEXT,0,NULL); return true; }
    if (!fullscreen && modifiers==(MOD_CONTROL|MOD_SHIFT) &&
        (msg->wParam==VK_PRIOR || msg->wParam==VK_NEXT) && moon_tab_drop_enabled()) {
        if (!repeated) moon_tab_nudge(msg->wParam==VK_NEXT);
        return true;
    }
    const bool appearance=(modifiers==MOD_CONTROL && msg->wParam=='B') ||
        (modifiers==(MOD_CONTROL|MOD_SHIFT) && msg->wParam=='L');
    if (appearance && !moon_ime_composing(msg->hwnd) &&
        moon_plugin_key(modifiers,(unsigned)msg->wParam,repeated)) return true;
    const bool hard_reload=(modifiers==(MOD_CONTROL|MOD_SHIFT) && msg->wParam=='R') ||
        (modifiers==MOD_SHIFT && msg->wParam==VK_F5);
    if (hard_reload && (moon_ime_composing(msg->hwnd) ||
        moon_plugin_key(modifiers,(unsigned)msg->wParam,repeated))) return true;
    if (msg->wParam == VK_F5 || (ctrl && msg->wParam == 'R')) { moon_command(MOON_RELOAD,0,NULL); return true; }
    if (alt && msg->wParam == VK_LEFT) { moon_command(MOON_BACK,0,NULL); return true; }
    if (alt && msg->wParam == VK_RIGHT) { moon_command(MOON_FORWARD,0,NULL); return true; }
    if (modifiers==MOD_ALT && msg->wParam=='I' && !moon_ime_composing(msg->hwnd))
        return repeated || site_menu(frame);
    const bool shell_chord=modifiers==(MOD_CONTROL|MOD_SHIFT) && (msg->wParam=='I' || msg->wParam=='C' || msg->wParam=='A' || msg->wParam=='E');
    if (in_content && !in_page && msg->wParam!=VK_F11 && msg->wParam!=VK_F12 && !shell_chord) return false;
    if ((ctrl || alt || msg->wParam==VK_F9 || msg->wParam==VK_F11 || msg->wParam==VK_F12) && !moon_ime_composing(msg->hwnd) &&
        moon_plugin_key(modifiers,(unsigned)msg->wParam,repeated)) return true;
    return false;
}
bool moon_shell_register_hotkey(unsigned id, unsigned modifiers, unsigned key) {
    return frame && RegisterHotKey(frame,(int)id,modifiers|MOD_NOREPEAT,key);
}
void moon_shell_unregister_hotkey(unsigned id) {
    if (frame) UnregisterHotKey(frame,(int)id);
}
void moon_shell_wake(void) {
    if (!frame) return;
    if (IsIconic(frame)) ShowWindow(frame,SW_RESTORE);
    if (!SetForegroundWindow(frame)) FlashWindow(frame,TRUE);
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
static int run_shell(int argc, wchar_t **argv) {
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_USER_DIRS);
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    const bool explicit_link=argc>1 && wcscmp(argv[1],L"--open-url")==0;
    if (explicit_link && argc!=3) return 1;
    const bool web_link=explicit_link || (argc==2 &&
        (_wcsnicmp(argv[1],L"https://",8)==0 || _wcsnicmp(argv[1],L"http://",7)==0));
    char external_url[4096];
    if (web_link && (!moon_utf8(argv[explicit_link?2:1],external_url,sizeof(external_url)) ||
        !moon_external_url_valid(external_url))) return 1;
    if (!init_paths()) {
        MessageBoxW(NULL,L"Cannot open the Moon Browser profile.",L"Moon Browser",MB_ICONERROR);
        return 1;
    }
    if (!private_window && (argc==1 || web_link)) {
        const MoonInstance state=moon_instance_enter(profile_dir,web_link?external_url:NULL);
        if (state==MOON_INSTANCE_DELIVERED) return 0;
        if (state==MOON_INSTANCE_FAILED) return 1;
    }
    if (explicit_link) {
        argv[1]=argv[2];
        argc=2;
    }
    if (private_window) theme=&dark;
    char appearance[4096], preference[8];
    if (theme_path(appearance,sizeof(appearance)) && moon_read_text(appearance,preference,sizeof(preference)) &&
        strcmp(preference,"dark")==0) theme=&dark;
    OleInitialize(NULL);
    INITCOMMONCONTROLSEX controls={sizeof(controls),ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&controls);
    init_graphics();
    low_memory = CreateMemoryResourceNotification(LowMemoryResourceNotification);
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSEXW class = { .cbSize=sizeof(class),.hInstance=instance,.hCursor=LoadCursorW(NULL,IDC_ARROW),.lpfnWndProc=frame_message,
        .lpszClassName=L"MoonBrowserWindow",
        .hIcon=LoadIconW(instance,MAKEINTRESOURCEW(1)),
        .hIconSm=LoadImageW(instance,MAKEINTRESOURCEW(1),IMAGE_ICON,GetSystemMetrics(SM_CXSMICON),GetSystemMetrics(SM_CYSMICON),LR_SHARED) };
    if (!RegisterClassExW(&class)) return 1;
    class.lpfnWndProc = content_message;
    class.lpszClassName = L"MoonContent";
    if (!RegisterClassExW(&class)) return 1;
    class.lpfnWndProc = palette_message;
    class.lpszClassName = L"MoonPalette";
    class.hbrBackground=(HBRUSH)(COLOR_WINDOW+1);
    if (!RegisterClassExW(&class)) return 1;
    frame = CreateWindowExW(0,L"MoonBrowserWindow",private_window?L"Moon Browser · 隐私浏览":L"Moon Browser",WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
        CW_USEDEFAULT,CW_USEDEFAULT,1120,760,NULL,NULL,instance,NULL);
    if (!frame) return 1;
    // Windows adds WS_CAPTION when creating an overlapped frame. Remove it while hidden.
    SetWindowLongPtrW(frame,GWL_STYLE,GetWindowLongPtrW(frame,GWL_STYLE) & ~(LONG_PTR)WS_CAPTION);
    SetWindowPos(frame,NULL,0,0,0,0,SWP_FRAMECHANGED|SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE);
    dpi = GetDpiForWindow(frame);
    address_brush = CreateSolidBrush(rgb(theme->field));
    content = CreateWindowExW(0,L"MoonContent",NULL,WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN,
        0,0,0,0,frame,NULL,instance,NULL);
    address = CreateWindowExW(0,L"EDIT",NULL,WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL,
        0,0,0,0,frame,(HMENU)ADDRESS_CONTROL,instance,NULL);
    home_edit = CreateWindowExW(0,L"EDIT",NULL,WS_CHILD | WS_TABSTOP | ES_AUTOHSCROLL,
        0,0,0,0,frame,(HMENU)HOME_CONTROL,instance,NULL);
    if (!address || !home_edit || !content) return 1;
    fullscreen_exit=CreateWindowExW(0,L"BUTTON",L"退出全屏",WS_CHILD|BS_OWNERDRAW,
        0,0,0,0,frame,(HMENU)FULLSCREEN_EXIT_CONTROL,instance,NULL);
    SendMessageW(address,EM_SETLIMITTEXT,4095,0);
    SendMessageW(address,EM_SETCUEBANNER,TRUE,(LPARAM)L"搜索或输入网址");
    SendMessageW(home_edit,EM_SETLIMITTEXT,4095,0);
    SendMessageW(home_edit,EM_SETCUEBANNER,TRUE,(LPARAM)L"搜索或输入网址");
    set_font();
    layout();
    ShowWindow(frame,SW_SHOW);
    UpdateWindow(frame);
    bool ready = moon_start(argc,(const uint16_t *const *)argv);
    if (ready && !quitting) ready=moon_instance_ready(frame);
    if (!ready && !quitting) moon_quit(1);
    if (!quitting) SetTimer(frame,MAINTENANCE_TIMER,100,NULL);
    MSG msg = {0};
    BOOL next;
    while ((next=GetMessageW(&msg,NULL,0,0)) > 0) {
        if (moon_dialog_message(&msg)) continue;
        if (palette && (msg.hwnd==palette || IsChild(palette,msg.hwnd)) && msg.message==WM_KEYDOWN &&
            !moon_ime_composing(msg.hwnd) && palette_key(&msg)) continue;
        if ((msg.hwnd==frame || IsChild(frame,msg.hwnd)) &&
            (msg.message==WM_KEYDOWN || msg.message==WM_SYSKEYDOWN) &&
            ((tab_drag.source && msg.wParam==VK_ESCAPE && keyboard(&msg)) || moon_find_key(&msg) || moon_viewport_key(&msg) || keyboard(&msg))) continue;
        if (fullscreen && fullscreen_exit && msg.message==WM_MOUSEMOVE && GetForegroundWindow()==frame &&
            !IsWindowVisible(fullscreen_exit) && (msg.hwnd==frame || IsChild(frame,msg.hwnd))) {
            RECT bounds;
            POINT pointer={(short)LOWORD(msg.lParam),(short)HIWORD(msg.lParam)};
            MapWindowPoints(msg.hwnd,frame,&pointer,1);
            if (GetClientRect(frame,&bounds) && pointer.y>=0 && pointer.y<px(8) &&
                abs(pointer.x-bounds.right/2)<px(103)) show_fullscreen_exit();
        }
        if (page_input(msg.message,msg.wParam) && IsChild(content,msg.hwnd) && moon_engine_page_window(msg.hwnd))
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
int moon_shell_run(void) {
    int argc=0;
    wchar_t **argv=CommandLineToArgvW(GetCommandLineW(),&argc);
    if (!argv) return 1;
    private_window=argc>1 && wcscmp(argv[1],L"--private")==0;
    const int result=run_shell(argc,argv);
    moon_instance_leave();
    LocalFree(argv);
    return result;
}
