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

typedef struct MoonDialogTheme {
    COLORREF panel, field, border, text, muted, accent, on_accent, danger, hover;
} MoonDialogTheme;
MoonDialogTheme moon_dialog_theme(void);
void moon_dialog_refresh(void);
bool moon_dialog_message(MSG *message);
enum { MOON_FIND_MATCH_LIMIT = 999 };
void moon_find_layout(void);
bool moon_find_key(MSG *message);
bool moon_ime_composing(HWND input);
#endif
