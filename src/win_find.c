#include "win_internal.h"
#include <commctrl.h>
#include <wchar.h>

enum { FIND_INPUT = 1201, FIND_COUNT, FIND_PREVIOUS, FIND_NEXT, FIND_CLOSE };
enum { QUERY_LIMIT = 255, SEARCH_TIMER = 1 };
static HWND bar, input, count_label, previous, next, close_button;
static HFONT font;
static UINT font_dpi;
static bool result_missing;

static int scale(int value, UINT dpi) { return MulDiv(value,(int)dpi,96); }

static void search(bool backwards) {
    KillTimer(bar,SEARCH_TIMER);
    wchar_t text[QUERY_LIMIT+1];
    char query[QUERY_LIMIT*4+1];
    GetWindowTextW(input,text,ARRAYSIZE(text));
    if (moon_utf8(text,query,sizeof(query))) moon_find_query(query,backwards);
}

static void buttons(bool enabled) {
    EnableWindow(previous,enabled);
    EnableWindow(next,enabled);
}

static LRESULT CALLBACK find_message(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
        case WM_COMMAND:
            if (LOWORD(wparam)==FIND_INPUT && (HIWORD(wparam)==EN_SETFOCUS || HIWORD(wparam)==EN_KILLFOCUS))
                InvalidateRect(window,NULL,FALSE);
            if (LOWORD(wparam)==FIND_INPUT && HIWORD(wparam)==EN_CHANGE && IsWindowVisible(window)) {
                result_missing = false;
                SetWindowTextW(count_label,L"");
                buttons(GetWindowTextLengthW(input)!=0);
                SetTimer(window,SEARCH_TIMER,110,NULL);
                return 0;
            }
            if (HIWORD(wparam)==BN_CLICKED) {
                if (LOWORD(wparam)==FIND_CLOSE) moon_find_dismiss(true);
                if (LOWORD(wparam)==FIND_PREVIOUS || LOWORD(wparam)==FIND_NEXT)
                    search(LOWORD(wparam)==FIND_PREVIOUS);
                return 0;
            }
            break;
        case WM_TIMER:
            if (wparam==SEARCH_TIMER && !moon_ime_composing(input)) search(false);
            return 0;
        case WM_CTLCOLOREDIT:
        case WM_CTLCOLORSTATIC: {
            const MoonDialogTheme theme = moon_dialog_theme();
            const COLORREF background = message==WM_CTLCOLOREDIT ? theme.field : theme.panel;
            SetTextColor((HDC)wparam,message==WM_CTLCOLOREDIT ? theme.text :
                (result_missing ? theme.danger : theme.muted));
            SetBkColor((HDC)wparam,background);
            SetDCBrushColor((HDC)wparam,background);
            return (LRESULT)GetStockObject(DC_BRUSH);
        }
        case WM_DRAWITEM: {
            const DRAWITEMSTRUCT *item = (const DRAWITEMSTRUCT *)lparam;
            const MoonDialogTheme theme = moon_dialog_theme();
            RECT rect = item->rcItem;
            HDC dc = item->hDC;
            SetDCBrushColor(dc,item->itemState & ODS_SELECTED ? theme.hover : theme.panel);
            HBRUSH brush = GetStockObject(DC_BRUSH);
            FillRect(dc,&rect,brush);
            if (item->itemState & ODS_FOCUS) {
                SetDCBrushColor(dc,theme.accent);
                FrameRect(dc,&rect,brush);
            }
            wchar_t title[16];
            GetWindowTextW(item->hwndItem,title,ARRAYSIZE(title));
            HFONT original = SelectObject(dc,font);
            SetBkMode(dc,TRANSPARENT);
            SetTextColor(dc,item->itemState & ODS_DISABLED ? theme.muted : theme.text);
            DrawTextW(dc,title,-1,&rect,DT_CENTER|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX);
            SelectObject(dc,original);
            return TRUE;
        }
        case WM_PAINT: {
            PAINTSTRUCT paint;
            HDC dc = BeginPaint(window,&paint);
            RECT rect;
            GetClientRect(window,&rect);
            const MoonDialogTheme theme = moon_dialog_theme();
            HBRUSH brush = GetStockObject(DC_BRUSH);
            SetDCBrushColor(dc,theme.panel);
            FillRect(dc,&rect,brush);
            SetDCBrushColor(dc,theme.border);
            FrameRect(dc,&rect,brush);
            RECT field;
            if (input && GetWindowRect(input,&field)) {
                MapWindowPoints(NULL,window,(POINT *)&field,2);
                InflateRect(&field,1,1);
                SetDCBrushColor(dc,GetFocus()==input ? theme.accent : theme.border);
                FrameRect(dc,&field,brush);
            }
            EndPaint(window,&paint);
            return 0;
        }
        case WM_NCDESTROY:
            KillTimer(window,SEARCH_TIMER);
            if (font) DeleteObject(font);
            font = NULL;
            font_dpi = 0;
            bar = input = count_label = previous = next = close_button = NULL;
            break;
    }
    return DefWindowProcW(window,message,wparam,lparam);
}

static HWND child(const wchar_t *type, const wchar_t *label, DWORD style, int id) {
    return CreateWindowExW(0,type,label,WS_CHILD|WS_VISIBLE|style,0,0,0,0,
        bar,(HMENU)(INT_PTR)id,GetModuleHandleW(NULL),NULL);
}

static bool create_bar(void) {
    HINSTANCE instance = GetModuleHandleW(NULL);
    const WNDCLASSW cls = { .lpfnWndProc=find_message,.hInstance=instance,
        .hCursor=LoadCursorW(NULL,IDC_ARROW),.lpszClassName=L"MoonFind" };
    if (!RegisterClassW(&cls) && GetLastError()!=ERROR_CLASS_ALREADY_EXISTS) return false;
    bar = CreateWindowExW(WS_EX_CONTROLPARENT,L"MoonFind",L"页内查找",WS_CHILD|WS_CLIPCHILDREN,
        0,0,0,0,moon_shell_window(),NULL,instance,NULL);
    if (!bar) return false;
    input = child(L"EDIT",L"",ES_AUTOHSCROLL|WS_TABSTOP,FIND_INPUT);
    count_label = child(L"STATIC",L"",SS_RIGHT|SS_CENTERIMAGE,FIND_COUNT);
    previous = child(L"BUTTON",L"上一个",BS_OWNERDRAW|WS_TABSTOP,FIND_PREVIOUS);
    next = child(L"BUTTON",L"下一个",BS_OWNERDRAW|WS_TABSTOP,FIND_NEXT);
    close_button = child(L"BUTTON",L"关闭",BS_OWNERDRAW|WS_TABSTOP,FIND_CLOSE);
    if (!input || !count_label || !previous || !next || !close_button) {
        DestroyWindow(bar);
        return false;
    }
    SendMessageW(input,EM_SETLIMITTEXT,QUERY_LIMIT,0);
    SendMessageW(input,EM_SETCUEBANNER,TRUE,(LPARAM)L"在页面中查找");
    buttons(false);
    return true;
}

void moon_find_layout(void) {
    if (!bar) return;
    HWND frame = moon_shell_window();
    const UINT dpi = GetDpiForWindow(frame);
    RECT pane;
    if (!GetWindowRect(moon_shell_content(),&pane)) return;
    MapWindowPoints(NULL,frame,(POINT *)&pane,2);
    int width = pane.right-pane.left-scale(20,dpi);
    if (width>scale(386,dpi)) width=scale(386,dpi);
    if (width<scale(210,dpi)) return;
    SetWindowPos(bar,HWND_TOP,pane.right-scale(10,dpi)-width,pane.top+scale(8,dpi),
        width,scale(48,dpi),SWP_NOACTIVATE);
    if (font_dpi!=dpi) {
        HFONT replacement = CreateFontW(-scale(14,dpi),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,
            DEFAULT_CHARSET,CLIP_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
        if (replacement) {
            HWND controls[] = {input,count_label,previous,next,close_button};
            for (size_t i=0;i<ARRAYSIZE(controls);i++) SendMessageW(controls[i],WM_SETFONT,(WPARAM)replacement,FALSE);
            if (font) DeleteObject(font);
            font = replacement;
            font_dpi = dpi;
        }
        SendMessageW(input,EM_SETMARGINS,EC_LEFTMARGIN|EC_RIGHTMARGIN,MAKELONG(scale(6,dpi),scale(6,dpi)));
    }
    const int left = scale(10,dpi), row = scale(11,dpi), height = scale(26,dpi);
    const int count_x = width-scale(193,dpi);
    MoveWindow(input,left,row+scale(3,dpi),count_x-left-scale(6,dpi),height-scale(6,dpi),TRUE);
    MoveWindow(count_label,count_x,row,scale(67,dpi),height,TRUE);
    MoveWindow(previous,width-scale(121,dpi),row,scale(39,dpi),height,TRUE);
    MoveWindow(next,width-scale(80,dpi),row,scale(39,dpi),height,TRUE);
    MoveWindow(close_button,width-scale(39,dpi),row,scale(33,dpi),height,TRUE);
    RedrawWindow(bar,NULL,NULL,RDW_INVALIDATE|RDW_ALLCHILDREN);
}

bool moon_shell_find_show(void) {
    if (!bar && !create_bar()) return false;
    moon_find_layout();
    ShowWindow(bar,SW_SHOWNA);
    SetFocus(input);
    SendMessageW(input,EM_SETSEL,0,-1);
    return true;
}

bool moon_shell_find_hide(void) {
    if (!bar || !IsWindowVisible(bar)) return false;
    HWND focus = GetFocus();
    bool focused = focus == bar || IsChild(bar,focus);
    KillTimer(bar,SEARCH_TIMER);
    ShowWindow(bar,SW_HIDE);
    SetWindowTextW(input,L"");
    SetWindowTextW(count_label,L"");
    buttons(false);
    result_missing = false;
    return focused;
}

void moon_shell_find_result(const char *query, unsigned matches) {
    if (!bar || !IsWindowVisible(bar)) return;
    wchar_t entered[QUERY_LIMIT+1], searched[QUERY_LIMIT+1];
    GetWindowTextW(input,entered,ARRAYSIZE(entered));
    if (!entered[0] || !moon_utf16(query,searched,ARRAYSIZE(searched)) || wcscmp(entered,searched)!=0) return;
    wchar_t label[24];
    if (matches>MOON_FIND_MATCH_LIMIT) swprintf(label,ARRAYSIZE(label),L"%u+ 项",MOON_FIND_MATCH_LIMIT);
    else if (matches) swprintf(label,ARRAYSIZE(label),L"%u 项匹配",matches);
    else wcscpy(label,L"无匹配");
    result_missing = matches==0;
    SetWindowTextW(count_label,label);
}

bool moon_find_key(MSG *message) {
    if (!bar || !IsWindowVisible(bar) || message->message!=WM_KEYDOWN ||
        moon_ime_composing(message->hwnd)) return false;
    if (message->wParam==VK_ESCAPE) {
        moon_find_dismiss(true);
        return true;
    }
    if (message->hwnd==input && message->wParam==VK_RETURN) {
        search(GetKeyState(VK_SHIFT)<0);
        return true;
    }
    if (IsChild(bar,message->hwnd) && message->wParam==VK_TAB && GetKeyState(VK_CONTROL)>=0) {
        HWND focus = GetNextDlgTabItem(bar,message->hwnd,GetKeyState(VK_SHIFT)<0);
        if (focus) SetFocus(focus);
        return true;
    }
    return false;
}
