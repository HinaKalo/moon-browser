#include "win_internal.h"
#include <wchar.h>
#include <string.h>

enum { BODY_ID = 101, COPY_ID };
typedef enum { INFO, CONFIRM, ERROR_DIALOG, TOAST } Kind;

typedef struct Popup {
    Kind kind;
    HWND window, edit, primary, cancel, copy;
    HFONT normal, heading;
    HBRUSH surface;
    MoonDialogTheme colors;
    UINT dpi;
    bool details;
    wchar_t title[256];
    wchar_t body[16384];
} Popup;

static Popup notice;
static Popup toast = { .kind=TOAST };
static HWND modal;
static _Alignas(DWORD) const struct {
    DLGTEMPLATE dialog;
    WORD menu, window_class, title;
} popup_template = { .dialog = { .style = WS_POPUP | WS_CLIPCHILDREN,
                                     .dwExtendedStyle = WS_EX_TOOLWINDOW, .cx = 260, .cy = 80 } };

static int scale(const Popup *popup, int dip) { return MulDiv(dip, popup->dpi, 96); }
static int minimum(int a, int b) { return a < b ? a : b; }
static int clamp(int value, int low, int high) {
    if (value < low) return low;
    return value > high ? high : value;
}

static bool set_text(Popup *popup, const char *title, const char *body) {
    wchar_t heading[256], text[8192];
    if (!moon_utf16(title,heading,ARRAYSIZE(heading)) || !moon_utf16(body,text,ARRAYSIZE(text))) return false;
    wcscpy(popup->title,heading);
    size_t used = 0;
    for (size_t i = 0; text[i]; ++i) {
        if (text[i] == L'\n' && (!i || text[i-1] != L'\r')) popup->body[used++] = L'\r';
        popup->body[used++] = text[i];
    }
    popup->body[used] = 0;
    return true;
}

static void apply_colors(Popup *popup) {
    popup->colors = moon_dialog_theme();
    HBRUSH old = popup->surface;
    popup->surface = CreateSolidBrush(popup->colors.panel);
    if (old) DeleteObject(old);
    RedrawWindow(popup->window,NULL,NULL,RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_ERASE);
}

static HFONT ui_font(const Popup *popup, int size, int weight) {
    return CreateFontW(-scale(popup,size),0,0,0,weight,FALSE,FALSE,FALSE,DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
}

static void layout_popup(Popup *popup, const RECT *suggested) {
    HWND window = popup->window;
    RECT owner;
    if (suggested) owner = *suggested;
    else if (!GetWindowRect(GetWindow(window,GW_OWNER),&owner)) GetWindowRect(window,&owner);
    MONITORINFO monitor = { .cbSize = sizeof(monitor) };
    if (!GetMonitorInfoW(MonitorFromRect(&owner,MONITOR_DEFAULTTONEAREST),&monitor)) return;

    const int pad = scale(popup,22), gap = scale(popup,8);
    const int work_w = monitor.rcWork.right - monitor.rcWork.left;
    const int work_h = monitor.rcWork.bottom - monitor.rcWork.top;
    if (popup->kind==TOAST) {
        const int width=minimum(scale(popup,330),work_w-2*gap), height=scale(popup,78), inset=scale(popup,20);
        const int left=clamp(owner.right-width-inset,monitor.rcWork.left+gap,monitor.rcWork.right-width-gap);
        const int top=clamp(owner.bottom-height-inset,monitor.rcWork.top+gap,monitor.rcWork.bottom-height-gap);
        SetWindowPos(window,NULL,left,top,width,height,SWP_NOZORDER | SWP_NOACTIVATE);
        HRGN region=CreateRoundRectRgn(0,0,width+1,height+1,scale(popup,16),scale(popup,16));
        if (region && !SetWindowRgn(window,region,TRUE)) DeleteObject(region);
        InvalidateRect(window,NULL,TRUE);
        return;
    }
    const int width = minimum(scale(popup,wcslen(popup->body) > 300 ? 550 : 426),work_w - 2*gap);
    const int body_y = scale(popup,55), row_h = scale(popup,34);
    const int body_cap = minimum(scale(popup,225),work_h - body_y - row_h - 4*pad);
    HDC dc = GetDC(window);
    HGDIOBJ font = SelectObject(dc,popup->normal);
    RECT measured = {0,0,width - 2*pad - scale(popup,7),0};
    DrawTextW(dc,popup->body,-1,&measured,DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX | DT_EDITCONTROL);
    SelectObject(dc,font);
    ReleaseDC(window,dc);
    const int ideal_body = measured.bottom + scale(popup,7);
    const int body_h = clamp(ideal_body,scale(popup,25),body_cap);
    popup->details = ideal_body > body_h;
    const int buttons_y = body_y + body_h + scale(popup,16);
    const int height = buttons_y + row_h + scale(popup,18);
    const int left = clamp(owner.left + (owner.right-owner.left-width)/2,monitor.rcWork.left+gap,monitor.rcWork.right-width-gap);
    const int top = clamp(owner.top + (owner.bottom-owner.top-height)/2,monitor.rcWork.top+gap,monitor.rcWork.bottom-height-gap);
    SetWindowPos(window,NULL,left,top,width,height,SWP_NOZORDER | SWP_NOACTIVATE);
    HRGN region = CreateRoundRectRgn(0,0,width+1,height+1,scale(popup,16),scale(popup,16));
    if (region && !SetWindowRgn(window,region,TRUE)) DeleteObject(region);
    ShowScrollBar(popup->edit,SB_VERT,popup->details);
    MoveWindow(popup->edit,pad-2,body_y,width-2*pad+2,body_h,TRUE);
    const int button_w = scale(popup,84);
    MoveWindow(popup->primary,width-pad-button_w,buttons_y,button_w,row_h,TRUE);
    if (popup->cancel)
        MoveWindow(popup->cancel,width-pad-2*button_w-gap,buttons_y,button_w,row_h,TRUE);
    if (popup->copy) {
        MoveWindow(popup->copy,pad,buttons_y,button_w,row_h,TRUE);
        ShowWindow(popup->copy,(popup->details || wcslen(popup->body)>300) ? SW_SHOWNA : SW_HIDE);
    }
    InvalidateRect(window,NULL,TRUE);
}

static void reset_fonts(Popup *popup) {
    HFONT normal = popup->normal, heading = popup->heading;
    popup->normal = ui_font(popup,14,FW_NORMAL);
    popup->heading = ui_font(popup,18,FW_SEMIBOLD);
    if (!popup->normal) popup->normal = normal;
    if (!popup->heading) popup->heading = heading;
    SendMessageW(popup->edit,WM_SETFONT,(WPARAM)popup->normal,TRUE);
    if (normal && normal != popup->normal) DeleteObject(normal);
    if (heading && heading != popup->heading) DeleteObject(heading);
}

static HWND add_button(HWND window, int id, const wchar_t *label) {
    return CreateWindowExW(0,L"BUTTON",label,WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
        0,0,0,0,window,(HMENU)(INT_PTR)id,GetModuleHandleW(NULL),NULL);
}

static void draw_button(const Popup *popup, const DRAWITEMSTRUCT *item) {
    const bool primary = item->hwndItem == popup->primary;
    const bool pressed = item->itemState & ODS_SELECTED;
    const bool focused = item->itemState & ODS_FOCUS;
    COLORREF fill = primary ? (pressed ? popup->colors.muted : popup->colors.accent) :
        (pressed ? popup->colors.hover : popup->colors.field);
    RECT box = item->rcItem;
    HDC dc = item->hDC;
    FillRect(dc,&box,popup->surface);
    HPEN pen = CreatePen(PS_SOLID,1,primary ? fill : popup->colors.border);
    HBRUSH brush = CreateSolidBrush(fill);
    HGDIOBJ old_pen = SelectObject(dc,pen), old_brush = SelectObject(dc,brush);
    const int radius = scale(popup,9);
    RoundRect(dc,box.left,box.top,box.right,box.bottom,radius,radius);
    SelectObject(dc,old_pen); SelectObject(dc,old_brush);
    DeleteObject(pen); DeleteObject(brush);
    HGDIOBJ old_font = SelectObject(dc,popup->normal);
    SetTextColor(dc,primary ? popup->colors.on_accent : popup->colors.text);
    SetBkMode(dc,TRANSPARENT);
    wchar_t label[24];
    GetWindowTextW(item->hwndItem,label,ARRAYSIZE(label));
    DrawTextW(dc,label,-1,&box,DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    SelectObject(dc,old_font);
    if (focused) {
        InflateRect(&box,-scale(popup,4),-scale(popup,4));
        DrawFocusRect(dc,&box);
    }
}

static bool copy_text(HWND window, const wchar_t *text) {
    const size_t size = (wcslen(text)+1)*sizeof(wchar_t);
    HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE,size);
    if (!data) return false;
    bool copied = false;
    void *memory = GlobalLock(data);
    if (memory) {
        memcpy(memory,text,size);
        GlobalUnlock(data);
        if (OpenClipboard(window)) {
            if (EmptyClipboard() && SetClipboardData(CF_UNICODETEXT,data)) {
                data = NULL;
                copied = true;
            }
            CloseClipboard();
        }
    }
    if (data) GlobalFree(data);
    return copied;
}

bool moon_shell_copy_text(const char *text) {
    wchar_t wide[4096];
    return moon_utf16(text,wide,ARRAYSIZE(wide)) && copy_text(moon_shell_window(),wide);
}

static void copy_details(Popup *popup) {
    if (copy_text(popup->window,popup->body)) SetWindowTextW(popup->copy,L"已复制");
}

static void close_popup(Popup *popup, int result) {
    if (popup->kind == INFO || popup->kind == TOAST) DestroyWindow(popup->window);
    else EndDialog(popup->window,result);
}

static INT_PTR CALLBACK popup_message(HWND window, UINT msg, WPARAM wp, LPARAM lp) {
    Popup *popup = (Popup *)GetWindowLongPtrW(window,DWLP_USER);
    if (msg == WM_INITDIALOG) {
        popup = (Popup *)lp;
        SetWindowLongPtrW(window,DWLP_USER,(LONG_PTR)popup);
        popup->window = window;
        if (popup->kind == CONFIRM || popup->kind == ERROR_DIALOG) modal = window;
        popup->dpi = GetDpiForWindow(GetWindow(window,GW_OWNER));
        if (!popup->dpi) popup->dpi = 96;
        SetWindowTextW(window,popup->title);
        if (popup->kind==TOAST) {
            SetWindowLongPtrW(window,GWL_EXSTYLE,GetWindowLongPtrW(window,GWL_EXSTYLE)|WS_EX_NOACTIVATE);
            reset_fonts(popup);
            apply_colors(popup);
            layout_popup(popup,NULL);
            return FALSE;
        }
        popup->edit = CreateWindowExW(0,L"EDIT",popup->body,
            WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY,
            0,0,0,0,window,(HMENU)BODY_ID,GetModuleHandleW(NULL),NULL);
        if (popup->kind == CONFIRM) popup->cancel = add_button(window,IDNO,L"取消");
        if (popup->kind == INFO) popup->copy = add_button(window,COPY_ID,L"复制");
        popup->primary = add_button(window,popup->kind == CONFIRM ? IDYES : IDOK,popup->kind == CONFIRM ? L"继续" : L"关闭");
        if (!popup->edit || !popup->primary || (popup->kind == CONFIRM && !popup->cancel)) {
            close_popup(popup,IDCANCEL);
            return FALSE;
        }
        reset_fonts(popup);
        apply_colors(popup);
        layout_popup(popup,NULL);
        SendMessageW(window,DM_SETDEFID,popup->kind == CONFIRM ? IDNO : IDOK,0);
        SetFocus(popup->cancel ? popup->cancel : popup->primary);
        return FALSE;
    }
    if (!popup) return FALSE;
    switch (msg) {
        case WM_PAINT: {
            PAINTSTRUCT paint;
            HDC dc = BeginPaint(window,&paint);
            RECT rect;
            GetClientRect(window,&rect);
            FillRect(dc,&rect,popup->surface);
            HPEN pen = CreatePen(PS_SOLID,1,popup->colors.border);
            HGDIOBJ original_pen = SelectObject(dc,pen), original_brush = SelectObject(dc,popup->surface);
            const int radius = scale(popup,16);
            RoundRect(dc,rect.left,rect.top,rect.right,rect.bottom,radius,radius);
            SelectObject(dc,original_pen); SelectObject(dc,original_brush);
            DeleteObject(pen);
            RECT title = {scale(popup,22),scale(popup,17),rect.right-scale(popup,22),scale(popup,42)};
            HGDIOBJ font = SelectObject(dc,popup->heading);
            SetTextColor(dc,popup->kind == ERROR_DIALOG ? popup->colors.danger : popup->colors.text);
            SetBkMode(dc,TRANSPARENT);
            DrawTextW(dc,popup->title,-1,&title,DT_END_ELLIPSIS | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX);
            if (popup->kind==TOAST) {
                SelectObject(dc,popup->normal);
                SetTextColor(dc,popup->colors.muted);
                RECT text={scale(popup,22),scale(popup,39),rect.right-scale(popup,22),scale(popup,64)};
                DrawTextW(dc,popup->body,-1,&text,DT_END_ELLIPSIS|DT_SINGLELINE|DT_VCENTER|DT_NOPREFIX);
            }
            SelectObject(dc,font);
            EndPaint(window,&paint);
            return TRUE;
        }
        case WM_CTLCOLORSTATIC:
        case WM_CTLCOLOREDIT:
            SetTextColor((HDC)wp,popup->colors.muted);
            SetBkColor((HDC)wp,popup->colors.panel);
            return (INT_PTR)popup->surface;
        case WM_DRAWITEM:
            if (((DRAWITEMSTRUCT *)lp)->CtlType == ODT_BUTTON) {
                draw_button(popup,(const DRAWITEMSTRUCT *)lp);
                return TRUE;
            }
            break;
        case WM_COMMAND:
            switch (LOWORD(wp)) {
                case COPY_ID: copy_details(popup); return TRUE;
                case IDYES:
                    if (popup->kind == CONFIRM) close_popup(popup,IDYES);
                    return TRUE;
                case IDOK: case IDNO: case IDCANCEL: close_popup(popup,IDCANCEL); return TRUE;
            }
            break;
        case WM_CLOSE: close_popup(popup,IDCANCEL); return TRUE;
        case WM_TIMER:
            if (popup->kind==TOAST && wp==1) {
                DestroyWindow(window);
                return TRUE;
            }
            break;
        case WM_DPICHANGED:
            popup->dpi = LOWORD(wp);
            reset_fonts(popup);
            layout_popup(popup,(const RECT *)lp);
            return TRUE;
        case WM_NCDESTROY:
            if (modal == window) modal = NULL;
            if (popup->surface) DeleteObject(popup->surface);
            if (popup->normal) DeleteObject(popup->normal);
            if (popup->heading) DeleteObject(popup->heading);
            popup->window = popup->edit = popup->primary = popup->cancel = popup->copy = NULL;
            popup->normal = popup->heading = NULL;
            popup->surface = NULL;
            SetWindowLongPtrW(window,DWLP_USER,0);
            break;
    }
    return FALSE;
}

bool moon_dialog_message(MSG *message) {
    return notice.window && (message->hwnd == notice.window || IsChild(notice.window,message->hwnd)) &&
        IsDialogMessageW(notice.window,message);
}

void moon_dialog_refresh(void) {
    if (notice.window) apply_colors(&notice);
    if (toast.window) apply_colors(&toast);
}

void moon_shell_toast(const char *title,const char *body) {
    HWND owner=moon_shell_window();
    if (!owner || !set_text(&toast,title,body)) return;
    if (!toast.window) CreateDialogIndirectParamW(GetModuleHandleW(NULL),&popup_template.dialog,owner,popup_message,(LPARAM)&toast);
    if (!toast.window) return;
    layout_popup(&toast,NULL);
    ShowWindow(toast.window,SW_SHOWNOACTIVATE);
    if (!SetTimer(toast.window,1,2500,NULL)) DestroyWindow(toast.window);
}

void moon_shell_info(const char *title, const char *body) {
    HWND owner = moon_shell_window();
    if (!owner || !set_text(&notice,title,body)) return;
    if (notice.window) {
        SetWindowTextW(notice.window,notice.title);
        SetWindowTextW(notice.edit,notice.body);
        if (notice.copy) SetWindowTextW(notice.copy,L"复制");
        layout_popup(&notice,NULL);
    } else {
        CreateDialogIndirectParamW(GetModuleHandleW(NULL),&popup_template.dialog,owner,popup_message,(LPARAM)&notice);
    }
    if (notice.window) {
        const HWND foreground = GetForegroundWindow();
        ShowWindow(notice.window,(!modal && (foreground == owner || foreground == notice.window)) ? SW_SHOW : SW_SHOWNOACTIVATE);
    }
}

static INT_PTR show_modal(Kind kind, const char *title, const char *body) {
    if (modal) return IDCANCEL;
    Popup popup = { .kind = kind };
    if (!set_text(&popup,title,body)) return IDCANCEL;
    if (notice.window && wcscmp(notice.title,popup.title) == 0) DestroyWindow(notice.window);
    return DialogBoxIndirectParamW(GetModuleHandleW(NULL),&popup_template.dialog,moon_shell_window(),
        popup_message,(LPARAM)&popup);
}

bool moon_shell_confirm(const char *title, const char *body) {
    return show_modal(CONFIRM,title,body) == IDYES;
}

void moon_shell_error(const char *body) {
    show_modal(ERROR_DIALOG,"Moon Browser",body);
}
