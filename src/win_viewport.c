#include "win_internal.h"
#include <commctrl.h>
#include <wchar.h>

enum { VIEW_WIDTH=1310, VIEW_SEPARATOR, VIEW_HEIGHT, VIEW_APPLY, VIEW_ROTATE, VIEW_CLOSE, VIEW_ACTUAL };
static const wchar_t bar_class[]=L"MoonResponsiveViewport";

static void apply_fields(MoonViewport *preview) {
    BOOL valid_width, valid_height;
    const unsigned width=GetDlgItemInt(preview->bar,VIEW_WIDTH,&valid_width,FALSE);
    const unsigned height=GetDlgItemInt(preview->bar,VIEW_HEIGHT,&valid_height,FALSE);
    if (!valid_width || !valid_height || width<MOON_VIEWPORT_MIN || width>MOON_VIEWPORT_MAX ||
        height<MOON_VIEWPORT_MIN || height>MOON_VIEWPORT_MAX) {
        moon_shell_toast("响应式预览","宽度和高度应介于 120 和 2400 之间。");
        return;
    }
    moon_engine_viewport_apply(preview->view,width,height);
}

static LRESULT CALLBACK background(HWND window, UINT message, WPARAM wparam, LPARAM lparam,
                                   UINT_PTR id, DWORD_PTR data) {
    if (message==WM_ERASEBKGND) {
        RECT rect;
        GetClientRect(window,&rect);
        const MoonDialogTheme theme=moon_dialog_theme();
        SetDCBrushColor((HDC)wparam,theme.hover);
        FillRect((HDC)wparam,&rect,GetStockObject(DC_BRUSH));
        return 1;
    }
    return DefSubclassProc(window,message,wparam,lparam);
}

static LRESULT CALLBACK keep_position(HWND window, UINT message, WPARAM wparam, LPARAM lparam,
                                      UINT_PTR id, DWORD_PTR data) {
    const LRESULT result=DefSubclassProc(window,message,wparam,lparam);
    if (message==WM_WINDOWPOSCHANGING) {
        const MoonViewport *preview=(const MoonViewport *)data;
        const RECT rect=preview->bounds;
        if (rect.right<=rect.left) return result;
        // The independent Inspector can resize the inspected child while opening or closing.
        WINDOWPOS *position=(WINDOWPOS *)lparam;
        if (!(position->flags & SWP_NOMOVE)) { position->x=rect.left; position->y=rect.top; }
        if (!(position->flags & SWP_NOSIZE)) { position->cx=rect.right-rect.left; position->cy=rect.bottom-rect.top; }
    }
    return result;
}

static LRESULT CALLBACK bar_message(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    MoonViewport *preview=(MoonViewport *)GetWindowLongPtrW(window,GWLP_USERDATA);
    switch (message) {
        case WM_NCCREATE:
            SetWindowLongPtrW(window,GWLP_USERDATA,(LONG_PTR)((CREATESTRUCTW *)lparam)->lpCreateParams);
            break;
        case WM_COMMAND:
            if (HIWORD(wparam)!=BN_CLICKED || !preview->bar) break;
            switch (LOWORD(wparam)) {
                case VIEW_APPLY: apply_fields(preview); return 0;
                case VIEW_ROTATE: moon_engine_viewport_apply(preview->view,preview->height,preview->width); return 0;
                case VIEW_CLOSE: moon_engine_viewport_close(preview->view,true); return 0;
            }
            break;
        case WM_CTLCOLORSTATIC:
        case WM_CTLCOLOREDIT: {
            const MoonDialogTheme theme=moon_dialog_theme();
            const bool edit=message==WM_CTLCOLOREDIT;
            const COLORREF color=edit ? theme.field : theme.panel;
            SetTextColor((HDC)wparam,edit ? theme.text : theme.muted);
            SetBkColor((HDC)wparam,color);
            SetDCBrushColor((HDC)wparam,color);
            return (LRESULT)GetStockObject(DC_BRUSH);
        }
        case WM_DRAWITEM: {
            const DRAWITEMSTRUCT *item=(const DRAWITEMSTRUCT *)lparam;
            const MoonDialogTheme theme=moon_dialog_theme();
            HDC dc=item->hDC;
            RECT rect=item->rcItem;
            const HBRUSH brush=GetStockObject(DC_BRUSH);
            SetDCBrushColor(dc,item->itemState & ODS_SELECTED ? theme.hover : theme.field);
            FillRect(dc,&rect,brush);
            SetDCBrushColor(dc,item->itemState & ODS_FOCUS ? theme.accent : theme.border);
            FrameRect(dc,&rect,brush);
            wchar_t text[16];
            GetWindowTextW(item->hwndItem,text,ARRAYSIZE(text));
            const HFONT old=preview->font ? SelectObject(dc,preview->font) : NULL;
            SetBkMode(dc,TRANSPARENT);
            SetTextColor(dc,theme.text);
            DrawTextW(dc,text,-1,&rect,DT_CENTER|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX);
            if (old) SelectObject(dc,old);
            return TRUE;
        }
        case WM_PAINT: {
            PAINTSTRUCT paint;
            const HDC dc=BeginPaint(window,&paint);
            const MoonDialogTheme theme=moon_dialog_theme();
            SetDCBrushColor(dc,theme.panel);
            FillRect(dc,&paint.rcPaint,GetStockObject(DC_BRUSH));
            EndPaint(window,&paint);
            return 0;
        }
    }
    return DefWindowProcW(window,message,wparam,lparam);
}

bool moon_viewport_open(MoonViewport *preview, MoonView *view, HWND surface, HWND page) {
    HINSTANCE instance=GetModuleHandleW(NULL);
    const WNDCLASSW cls={.lpfnWndProc=bar_message,.hInstance=instance,
        .hCursor=LoadCursorW(NULL,IDC_ARROW),.lpszClassName=bar_class};
    if (!RegisterClassW(&cls) && GetLastError()!=ERROR_CLASS_ALREADY_EXISTS) return false;
    preview->view=view;
    preview->page=page;
    preview->bar=CreateWindowExW(WS_EX_CONTROLPARENT,bar_class,L"响应式预览",WS_CHILD|WS_VISIBLE|WS_CLIPCHILDREN,
        0,0,0,0,surface,NULL,instance,preview);
    if (!preview->bar) return false;
    const DWORD input=ES_NUMBER|ES_AUTOHSCROLL|WS_TABSTOP|WS_BORDER;
    const DWORD button=BS_OWNERDRAW|WS_TABSTOP;
    const struct { const wchar_t *type,*text; DWORD style; } controls[]={
        {L"EDIT",L"",input},{L"STATIC",L"×",SS_CENTER|SS_CENTERIMAGE},{L"EDIT",L"",input},
        {L"BUTTON",L"应用",button},{L"BUTTON",L"旋转",button},{L"BUTTON",L"关闭",button},
        {L"STATIC",L"",SS_CENTERIMAGE},
    };
    for (unsigned i=0;i<ARRAYSIZE(controls);++i) {
        if (!CreateWindowExW(0,controls[i].type,controls[i].text,WS_CHILD|WS_VISIBLE|controls[i].style,
                0,0,0,0,preview->bar,(HMENU)(INT_PTR)(VIEW_WIDTH+i),instance,NULL)) {
            moon_viewport_close(preview);
            return false;
        }
    }
    SendDlgItemMessageW(preview->bar,VIEW_WIDTH,EM_SETLIMITTEXT,4,0);
    SendDlgItemMessageW(preview->bar,VIEW_HEIGHT,EM_SETLIMITTEXT,4,0);
    if (!SetWindowSubclass(surface,background,1,0) || !SetWindowSubclass(page,keep_position,1,(DWORD_PTR)preview)) {
        moon_viewport_close(preview);
        return false;
    }
    if (!preview->width) preview->width=390;
    if (!preview->height) preview->height=640;
    return true;
}

void moon_viewport_close(MoonViewport *preview) {
    if (!preview->bar) return;
    RemoveWindowSubclass(preview->page,keep_position,1);
    RemoveWindowSubclass(GetParent(preview->bar),background,1);
    DestroyWindow(preview->bar);
    preview->bar=NULL;
    preview->bounds=(RECT){0};
    if (preview->font) DeleteObject(preview->font);
    preview->font=NULL;
    preview->dpi=0;
}

int moon_viewport_layout(MoonViewport *preview, int width) {
    const HWND bar=preview->bar;
    const UINT dpi=GetDpiForWindow(bar);
    const int row=MulDiv(37,dpi,96), wide=width>=MulDiv(370,dpi,96);
    const int height=row+(wide ? 0 : MulDiv(21,dpi,96));
    if (preview->dpi!=dpi) {
        const HFONT font=CreateFontW(-MulDiv(14,dpi,96),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
        if (font) {
            for (int id=VIEW_WIDTH;id<=VIEW_ACTUAL;++id) SendDlgItemMessageW(bar,id,WM_SETFONT,(WPARAM)font,FALSE);
            if (preview->font) DeleteObject(preview->font);
            preview->font=font;
        }
        preview->dpi=dpi;
    }
    const int x[]={8,56,72,126,167,208}, sizes[]={48,16,48,38,38,38};
    for (int id=VIEW_WIDTH;id<=VIEW_CLOSE;++id) {
        const unsigned i=id-VIEW_WIDTH;
        MoveWindow(GetDlgItem(bar,id),MulDiv(x[i],dpi,96),MulDiv(6,dpi,96),
            MulDiv(sizes[i],dpi,96),MulDiv(25,dpi,96),TRUE);
    }
    const int label_x=MulDiv(wide ? 260 : 8,dpi,96);
    MoveWindow(GetDlgItem(bar,VIEW_ACTUAL),label_x,wide ? 0 : row,width>label_x ? width-label_x : 0,
        wide ? row : height-row,TRUE);
    SetWindowPos(bar,HWND_TOP,0,0,width,height,SWP_NOACTIVATE);
    return height;
}

void moon_viewport_set_size(MoonViewport *preview, unsigned width, unsigned height) {
    preview->width=width;
    preview->height=height;
    SetDlgItemInt(preview->bar,VIEW_WIDTH,width,FALSE);
    SetDlgItemInt(preview->bar,VIEW_HEIGHT,height,FALSE);
}

void moon_viewport_update(MoonViewport *preview, unsigned width, unsigned height) {
    wchar_t text[40];
    swprintf(text,ARRAYSIZE(text),L"视口 %u × %u",width,height);
    SetDlgItemTextW(preview->bar,VIEW_ACTUAL,text);
}

bool moon_viewport_key(MSG *message) {
    if (message->message!=WM_KEYDOWN || GetKeyState(VK_CONTROL)<0 ||
        (message->wParam!=VK_ESCAPE && message->wParam!=VK_RETURN && message->wParam!=VK_TAB)) return false;
    const HWND parent=GetParent(message->hwnd);
    wchar_t type[ARRAYSIZE(bar_class)];
    if (!parent || !GetClassNameW(parent,type,ARRAYSIZE(type)) || wcscmp(type,bar_class)!=0) return false;
    MoonViewport *preview=(MoonViewport *)GetWindowLongPtrW(parent,GWLP_USERDATA);
    switch (message->wParam) {
        case VK_ESCAPE: moon_engine_viewport_close(preview->view,true); return true;
        case VK_RETURN: {
            const int id=GetDlgCtrlID(message->hwnd);
            if (id==VIEW_WIDTH || id==VIEW_HEIGHT) {
                apply_fields(preview);
                return true;
            }
            if (id>=VIEW_APPLY && id<=VIEW_CLOSE) {
                SendMessageW(message->hwnd,BM_CLICK,0,0);
                return true;
            }
            break;
        }
        case VK_TAB: {
            const HWND next=GetNextDlgTabItem(parent,message->hwnd,GetKeyState(VK_SHIFT)<0);
            if (next) SetFocus(next);
            return true;
        }
    }
    return false;
}
