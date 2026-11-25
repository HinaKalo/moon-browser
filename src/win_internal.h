#ifndef MOON_WIN_INTERNAL_H
#define MOON_WIN_INTERNAL_H
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "bridge.h"

HWND moon_shell_window(void);
HWND moon_shell_content(void);
bool moon_utf16(const char *text, wchar_t *output, size_t capacity);
bool moon_utf8(const wchar_t *text, char *output, size_t capacity);
bool moon_path(wchar_t *output, size_t capacity, const wchar_t *directory, const wchar_t *name);
typedef enum { MOON_INSTANCE_OWNER, MOON_INSTANCE_DELIVERED, MOON_INSTANCE_FAILED } MoonInstance;
MoonInstance moon_instance_enter(const char *profile, const char *url);
bool moon_instance_accept(HWND window, const COPYDATASTRUCT *message);
bool moon_instance_ready(HWND window);
void moon_instance_remove(HWND window);
void moon_instance_leave(void);

typedef struct MoonDialogTheme {
    COLORREF panel, field, border, text, muted, accent, on_accent, danger, hover;
} MoonDialogTheme;
MoonDialogTheme moon_dialog_theme(void);
void moon_dialog_refresh(void);
bool moon_dialog_message(MSG *message);
enum { MOON_FIND_MATCH_LIMIT = 999 };
void moon_find_layout(void);
bool moon_find_key(MSG *message);
typedef struct MoonViewport {
    MoonView *view;
    HWND bar, page;
    RECT bounds;
    HFONT font;
    UINT dpi;
    unsigned width, height;
} MoonViewport;
bool moon_viewport_open(MoonViewport *preview, MoonView *view, HWND surface, HWND page);
void moon_viewport_close(MoonViewport *preview);
int moon_viewport_layout(MoonViewport *preview, int width);
void moon_viewport_set_size(MoonViewport *preview, unsigned width, unsigned height);
void moon_viewport_update(MoonViewport *preview, unsigned width, unsigned height);
bool moon_viewport_key(MSG *message);
void moon_engine_viewport_apply(MoonView *view, unsigned width, unsigned height);
void moon_engine_viewport_close(MoonView *view, bool focus);
bool moon_ime_composing(HWND input);
enum { MOON_SUGGEST_TIMER = 5 };
void moon_suggest_change(HWND input);
void moon_suggest_hide(void);
void moon_suggest_update(void);
bool moon_suggest_key(HWND input, WPARAM key);
bool moon_bookmark_menu_init(HMENU menu);
void moon_bookmark_menu_cancel(void);
void moon_bookmark_menu_show(const char *folder, size_t offset, RECT anchor);
#endif
