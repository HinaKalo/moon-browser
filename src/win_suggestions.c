#include "win_internal.h"
#include <commctrl.h>
#include <wchar.h>

static HWND popup, list, input;
static bool registered;
static size_t visible_rows;
static int hovered=-1;
static MoonAddressSuggestion rows[MOON_ADDRESS_SUGGESTION_LIMIT];

void moon_suggest_hide(void) {
    HWND owner=moon_shell_window();
    if (owner) KillTimer(owner,MOON_SUGGEST_TIMER);
    input=NULL;
    visible_rows=0;
    hovered=-1;
    if (popup) ShowWindow(popup,SW_HIDE);
}

void moon_suggest_change(HWND edit) {
    moon_suggest_hide();
    if (GetFocus()!=edit || moon_shell_private()) return;
    input=edit;
    SetTimer(moon_shell_window(),MOON_SUGGEST_TIMER,140,NULL);
}

static void open_row(size_t row) {
    if (row>=visible_rows) return;
    moon_suggest_hide();
    moon_command(MOON_ADDRESS,0,rows[row].url);
}

static LRESULT CALLBACK suggestion_mouse(HWND hwnd,UINT message,WPARAM wp,LPARAM lp,UINT_PTR id,DWORD_PTR data) {
    (void)id;
    (void)data;
    if (message==WM_LBUTTONDOWN || message==WM_LBUTTONDBLCLK) return 0;
    if (message==WM_LBUTTONUP || message==WM_MOUSEMOVE) {
        const LRESULT hit=SendMessageW(hwnd,LB_ITEMFROMPOINT,0,lp);
        const int row=!HIWORD(hit) && LOWORD(hit)<visible_rows?(int)LOWORD(hit):-1;
        if (message==WM_LBUTTONUP) {
            if (row>=0) open_row((size_t)row);
        } else if (hovered!=row) {
            TRACKMOUSEEVENT event={sizeof(event),TME_LEAVE,hwnd,0};
            TrackMouseEvent(&event);
            hovered=row;
            InvalidateRect(hwnd,NULL,FALSE);
        }
        return 0;
    }
    if (message==WM_MOUSELEAVE) {
        hovered=-1;
        InvalidateRect(hwnd,NULL,FALSE);
    }
    return DefSubclassProc(hwnd,message,wp,lp);
}

static void draw_row(const DRAWITEMSTRUCT *item) {
    if (item->itemID>=visible_rows) return;
    const MoonAddressSuggestion *entry=&rows[item->itemID];
    const MoonDialogTheme theme=moon_dialog_theme();
    const UINT dpi=GetDpiForWindow(list);
    const bool selected=(item->itemState&ODS_SELECTED)!=0;
    HBRUSH fill=CreateSolidBrush(selected || (int)item->itemID==hovered?theme.hover:theme.panel);
    FillRect(item->hDC,&item->rcItem,fill);
    DeleteObject(fill);
    if (selected) {
        RECT marker=item->rcItem;
        marker.right=marker.left+MulDiv(3,dpi,96);
        HBRUSH accent=CreateSolidBrush(theme.accent);
        FillRect(item->hDC,&marker,accent);
        DeleteObject(accent);
    }
    HFONT font=(HFONT)SendMessageW(list,WM_GETFONT,0,0);
    HGDIOBJ previous=font?SelectObject(item->hDC,font):NULL;
    SetBkMode(item->hDC,TRANSPARENT);
    RECT title=item->rcItem, address=item->rcItem;
    title.left+=MulDiv(12,dpi,96);
    title.right-=MulDiv(62,dpi,96);
    title.bottom=title.top+MulDiv(25,dpi,96);
    address.left=title.left;
    address.right-=MulDiv(12,dpi,96);
    address.top=title.bottom-MulDiv(2,dpi,96);
    RECT label=title;
    label.left=title.right;
    label.right=address.right;
    wchar_t name[512], url[4096];
    if (!moon_utf16(entry->url,url,ARRAYSIZE(url))) url[0]=0;
    if (!moon_utf16(entry->title,name,ARRAYSIZE(name))) name[0]=0;
    const UINT text=DT_SINGLELINE|DT_VCENTER|DT_NOPREFIX|DT_END_ELLIPSIS;
    SetTextColor(item->hDC,theme.text);
    DrawTextW(item->hDC,*name?name:url,-1,&title,text);
    SetTextColor(item->hDC,theme.muted);
    DrawTextW(item->hDC,url,-1,&address,text);
    SetTextColor(item->hDC,entry->bookmark?theme.accent:theme.muted);
    DrawTextW(item->hDC,entry->bookmark?L"书签":L"历史",-1,&label,text|DT_RIGHT);
    if (previous) SelectObject(item->hDC,previous);
}

static LRESULT CALLBACK suggestions_message(HWND window,UINT message,WPARAM wp,LPARAM lp) {
    switch (message) {
        case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
        case WM_DRAWITEM: draw_row((const DRAWITEMSTRUCT *)lp); return TRUE;
        case WM_NCDESTROY: popup=NULL; list=NULL; break;
    }
    return DefWindowProcW(window,message,wp,lp);
}

static bool ensure_popup(HWND owner) {
    if (popup) return true;
    HINSTANCE instance=GetModuleHandleW(NULL);
    if (!registered) {
        const WNDCLASSW type={.lpfnWndProc=suggestions_message,.hInstance=instance,.lpszClassName=L"MoonAddressSuggestions"};
        if (!RegisterClassW(&type)) return false;
        registered=true;
    }
    popup=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE,L"MoonAddressSuggestions",L"地址栏建议",
        WS_POPUP|WS_BORDER,0,0,0,0,owner,NULL,instance,NULL);
    if (!popup) return false;
    list=CreateWindowExW(0,L"LISTBOX",L"地址栏建议",WS_CHILD|WS_VISIBLE|LBS_OWNERDRAWFIXED|LBS_HASSTRINGS|LBS_NOINTEGRALHEIGHT,
        0,0,0,0,popup,(HMENU)1,instance,NULL);
    if (list && SetWindowSubclass(list,suggestion_mouse,1,0)) return true;
    DestroyWindow(popup);
    return false;
}

void moon_suggest_update(void) {
    HWND owner=moon_shell_window();
    KillTimer(owner,MOON_SUGGEST_TIMER);
    const HWND edit=input;
    input=NULL;
    if (!edit || GetFocus()!=edit || !IsWindowVisible(edit) || moon_ime_composing(edit)) return;
    wchar_t wide[257];
    char query[1025];
    const int length=GetWindowTextLengthW(edit);
    if (length<=0 || length>=ARRAYSIZE(wide) || !GetWindowTextW(edit,wide,ARRAYSIZE(wide)) ||
        !moon_utf8(wide,query,ARRAYSIZE(query))) return;
    size_t count=moon_suggest_collect(query,rows,ARRAYSIZE(rows));
    if (!count || !ensure_popup(owner)) return;

    RECT anchor;
    if (!GetWindowRect(edit,&anchor)) return;
    MONITORINFO monitor={.cbSize=sizeof(monitor)};
    if (!GetMonitorInfoW(MonitorFromRect(&anchor,MONITOR_DEFAULTTONEAREST),&monitor)) return;
    const UINT dpi=GetDpiForWindow(edit);
    const int row_height=MulDiv(46,dpi,96), gap=MulDiv(4,dpi,96);
    const int below=monitor.rcWork.bottom-anchor.bottom-gap, above=anchor.top-monitor.rcWork.top-gap;
    const BOOL upwards=below<(int)count*row_height+2 && above>below;
    const int room=(upwards?above:below)-2;
    if (room<row_height) return;
    if ((size_t)(room/row_height)<count) count=(size_t)(room/row_height);
    const int height=(int)count*row_height;
    const int width=min(max(anchor.right-anchor.left,MulDiv(410,dpi,96)),monitor.rcWork.right-monitor.rcWork.left-2);
    const int left=max(monitor.rcWork.left,min(anchor.left,monitor.rcWork.right-width-2));
    const int top=upwards?anchor.top-gap-height-2:anchor.bottom+gap;
    if (width<MulDiv(115,dpi,96)) return;

    visible_rows=0;
    (void)SendMessageW(list,WM_SETREDRAW,FALSE,0);
    (void)SendMessageW(list,LB_RESETCONTENT,0,0);
    (void)SendMessageW(list,WM_SETFONT,SendMessageW(edit,WM_GETFONT,0,0),FALSE);
    (void)SendMessageW(list,LB_SETITEMHEIGHT,0,row_height);
    for (size_t i=0;i<count;++i) {
        wchar_t label[4630], title[512], url[4096];
        if (!moon_utf16(rows[i].title,title,ARRAYSIZE(title))) title[0]=0;
        if (!moon_utf16(rows[i].url,url,ARRAYSIZE(url))) break;
        swprintf(label,ARRAYSIZE(label),L"%ls%ls%ls",title,*title?L" — ":L"",url);
        if (SendMessageW(list,LB_ADDSTRING,0,(LPARAM)label)<0) break;
        ++visible_rows;
    }
    (void)SendMessageW(list,WM_SETREDRAW,TRUE,0);
    if (!visible_rows) return;
    input=edit;
    MoveWindow(list,0,0,width,(int)visible_rows*row_height,FALSE);
    SetWindowPos(popup,HWND_TOP,left,top,width+2,(int)visible_rows*row_height+2,SWP_NOACTIVATE|SWP_SHOWWINDOW);
    InvalidateRect(list,NULL,TRUE);
}

bool moon_suggest_key(HWND edit,WPARAM key) {
    if (input!=edit) return false;
    if (key==VK_ESCAPE) { moon_suggest_hide(); return true; }
    if (!visible_rows || !IsWindowVisible(popup)) return false;
    LRESULT current=SendMessageW(list,LB_GETCURSEL,0,0);
    switch (key) {
        case VK_RETURN:
            if (current==LB_ERR) return false;
            open_row((size_t)current);
            return true;
        case VK_DOWN:
            current=(current+1)%(LRESULT)visible_rows;
            break;
        case VK_UP:
            current=current>0?current-1:(LRESULT)visible_rows-1;
            break;
        default: return false;
    }
    SendMessageW(list,LB_SETCURSEL,(WPARAM)current,0);
    return true;
}
