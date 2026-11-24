#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commdlg.h>
#include <stdbool.h>
#include <stdint.h>
#include <wchar.h>

size_t moon_manager_count(void);
const char *moon_manager_name(size_t index);
bool moon_manager_enabled(void);
bool moon_manager_read(size_t index, char *output, size_t cap);
bool moon_manager_import(const char *source, size_t size);
bool moon_manager_save(const char *source, size_t size);
bool moon_manager_toggle(void);

enum { SELECT_SCRIPT=101, OPEN_SCRIPT, IMPORT_SCRIPT, SOURCE, SAVE_SCRIPT, SWITCH_SCRIPT };
static HWND combo, open_button, import_button, editor, save, toggle, status;
static HFONT ui_font, code_font;
static HBRUSH background, field;
static bool changing, dirty, has_source, dark;
static UINT dpi = 96;
static wchar_t status_text[256];

static int px(int dip) { return MulDiv(dip,dpi,96); }
static void set_status(const wchar_t *text) {
    wcsncpy(status_text,text,ARRAYSIZE(status_text)-1);
    status_text[ARRAYSIZE(status_text)-1] = 0;
    if (status) SetWindowTextW(status,status_text);
}
void moon_manager_status(const char *text) {
    wchar_t wide[256];
    if (MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text,-1,wide,ARRAYSIZE(wide))) set_status(wide);
}

static HWND control(HWND window, const wchar_t *kind, const wchar_t *text, DWORD style, int id) {
    return CreateWindowExW(0,kind,text,WS_CHILD | WS_VISIBLE | style,0,0,0,0,
        window,(HMENU)(INT_PTR)id,GetModuleHandleW(NULL),NULL);
}
static void update_fonts(void) {
    if (ui_font) DeleteObject(ui_font);
    if (code_font) DeleteObject(code_font);
    ui_font = CreateFontW(-px(14),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Segoe UI");
    code_font = CreateFontW(-px(15),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Consolas");
    HWND controls[] = {combo,open_button,import_button,save,toggle,status};
    for (size_t i=0;i<ARRAYSIZE(controls);++i) SendMessageW(controls[i],WM_SETFONT,(WPARAM)ui_font,TRUE);
    SendMessageW(editor,WM_SETFONT,(WPARAM)code_font,TRUE);
}
static void layout(HWND window) {
    RECT r;
    GetClientRect(window,&r);
    const int pad=px(20), row=px(32), gap=px(8), button=px(100);
    const int right=r.right-pad, bottom=r.bottom-pad;
    MoveWindow(combo,pad,pad,right-pad-2*(button+gap),px(220),TRUE);
    MoveWindow(open_button,right-2*button-gap,pad,button,row,TRUE);
    MoveWindow(import_button,right-button,pad,button,row,TRUE);
    MoveWindow(editor,pad,pad+row+gap,right-pad,bottom-pad-2*row-2*gap,TRUE);
    MoveWindow(status,pad,bottom-row+px(7),right-pad-2*button-2*gap,row,TRUE);
    MoveWindow(toggle,right-2*button-gap,bottom-row,button,row,TRUE);
    MoveWindow(save,right-button,bottom-row,button,row,TRUE);
}

static void add_name(size_t index) {
    wchar_t name[256];
    if (MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,moon_manager_name(index),-1,name,ARRAYSIZE(name)))
        SendMessageW(combo,CB_ADDSTRING,0,(LPARAM)name);
}

static void open_source(void) {
    const LRESULT choice = SendMessageW(combo,CB_GETCURSEL,0,0);
    if (choice == CB_ERR) return;
    char bytes[16385];
    if (!moon_manager_read((size_t)choice,bytes,sizeof(bytes))) return;
    wchar_t source[16385], display[32769];
    if (!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,bytes,-1,source,ARRAYSIZE(source))) return;
    size_t used=0;
    for (size_t i=0;source[i];++i) {
        if (source[i]==L'\n' && (!i || source[i-1]!=L'\r')) display[used++]=L'\r';
        display[used++]=source[i];
    }
    display[used]=0;
    changing=true;
    SetWindowTextW(editor,display);
    changing=false;
    has_source=true;
    SetWindowTextW(toggle,moon_manager_enabled() ? L"停用脚本" : L"启用脚本");
    EnableWindow(combo,FALSE); EnableWindow(open_button,FALSE); EnableWindow(import_button,FALSE);
    EnableWindow(editor,TRUE); EnableWindow(save,TRUE); EnableWindow(toggle,TRUE);
    SetFocus(editor);
    set_status(L"编辑 Lua 源码，Ctrl+S 保存并重载。");
}

static void import_script(HWND window) {
    wchar_t file[2048]={0};
    OPENFILENAMEW dialog={.lStructSize=sizeof(dialog),.hwndOwner=window,.lpstrFile=file,.nMaxFile=ARRAYSIZE(file),
        .lpstrFilter=L"Lua 用户脚本 (*.lua)\0*.lua\0\0",.lpstrTitle=L"导入 Lua 用户脚本",
        .Flags=OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER};
    if (!GetOpenFileNameW(&dialog)) return;
    HANDLE input=CreateFileW(file,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if (input==INVALID_HANDLE_VALUE) { set_status(L"无法读取脚本文件。"); return; }
    char buffer[16388];
    DWORD size=0;
    bool ok=ReadFile(input,buffer,sizeof(buffer),&size,NULL) && size>0 && size<sizeof(buffer);
    CloseHandle(input);
    if (!ok) { set_status(L"请选择 16 KiB 以内的 UTF-8 Lua 文件。"); return; }
    if (moon_manager_import(buffer,size)) {
        const size_t index=moon_manager_count()-1;
        add_name(index);
        SendMessageW(combo,CB_SETCURSEL,index,0);
        EnableWindow(open_button,TRUE);
    }
}

static void save_source(void) {
    if (!has_source) return;
    wchar_t wide[32769];
    char bytes[16388];
    if (GetWindowTextLengthW(editor)>=(int)ARRAYSIZE(wide)) {
        set_status(L"脚本超过 16 KiB。");
        return;
    }
    const int chars=GetWindowTextW(editor,wide,ARRAYSIZE(wide));
    int length=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,wide,chars,bytes,sizeof(bytes),NULL,NULL);
    if (length<=0 || length>16384) { set_status(L"脚本内容为空、编码无效或超过 16 KiB。"); return; }
    if (moon_manager_save(bytes,(size_t)length)) {
        dirty=false;
        SetWindowTextW(toggle,moon_manager_enabled() ? L"停用脚本" : L"启用脚本");
    }
}

static LRESULT CALLBACK window_message(HWND window, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
        case WM_CREATE:
            dpi=GetDpiForWindow(window);
            if (!dpi) dpi=96;
            combo=control(window,L"COMBOBOX",L"",CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL,SELECT_SCRIPT);
            open_button=control(window,L"BUTTON",L"打开源码",WS_TABSTOP,OPEN_SCRIPT);
            import_button=control(window,L"BUTTON",L"导入脚本…",WS_TABSTOP,IMPORT_SCRIPT);
            editor=control(window,L"EDIT",L"",WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN,SOURCE);
            save=control(window,L"BUTTON",L"保存并重载",WS_TABSTOP,SAVE_SCRIPT);
            toggle=control(window,L"BUTTON",L"启用脚本",WS_TABSTOP,SWITCH_SCRIPT);
            status=control(window,L"STATIC",L"",SS_LEFT,0);
            if (!combo || !editor || !save || !toggle || !status || !open_button || !import_button) return -1;
            SendMessageW(editor,EM_SETLIMITTEXT,32768,0);
            for (size_t i=0;i<moon_manager_count();++i) add_name(i);
            SendMessageW(combo,CB_SETCURSEL,0,0);
            EnableWindow(open_button,moon_manager_count()!=0);
            EnableWindow(editor,FALSE); EnableWindow(save,FALSE); EnableWindow(toggle,FALSE);
            set_status(moon_manager_count() ? L"选择一个已安装的 Lua 用户脚本。" : L"导入 .lua 文件后可查看和编辑源码。");
            update_fonts();
            return 0;
        case WM_SIZE: if (editor) layout(window); return 0;
        case WM_GETMINMAXINFO:
            ((MINMAXINFO *)lp)->ptMinTrackSize=(POINT){px(615),px(380)};
            return 0;
        case WM_DPICHANGED: {
            dpi=LOWORD(wp);
            const RECT *r=(const RECT *)lp;
            update_fonts();
            SetWindowPos(window,NULL,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER | SWP_NOACTIVATE);
            return 0;
        }
        case WM_CTLCOLOREDIT: case WM_CTLCOLORSTATIC:
            SetTextColor((HDC)wp,dark ? RGB(233,235,242) : RGB(20,22,29));
            SetBkColor((HDC)wp,(HWND)lp==editor ? (dark ? RGB(37,39,47) : RGB(255,255,255)) : (dark ? RGB(25,28,35) : RGB(242,244,249)));
            return (LRESULT)((HWND)lp==editor ? field : background);
        case WM_COMMAND:
            switch (LOWORD(wp)) {
                case OPEN_SCRIPT: if (!has_source) open_source(); break;
                case IMPORT_SCRIPT: if (!has_source) import_script(window); break;
                case SOURCE: if (has_source && !changing && HIWORD(wp)==EN_CHANGE) dirty=true; break;
                case SAVE_SCRIPT: save_source(); break;
                case SWITCH_SCRIPT:
                    if (moon_manager_toggle()) SetWindowTextW(toggle,moon_manager_enabled() ? L"停用脚本" : L"启用脚本");
                    break;
            }
            return 0;
        case WM_CLOSE:
            if (!dirty || MessageBoxW(window,L"丢弃未保存的源码改动？",L"关闭 Lua 编辑器",
                    MB_YESNO | MB_DEFBUTTON2 | MB_ICONQUESTION)==IDYES) DestroyWindow(window);
            return 0;
        case WM_DESTROY: PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(window,msg,wp,lp);
}

bool moon_manager_window(uint64_t owner, bool dark_mode) {
    dark=dark_mode;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    background=CreateSolidBrush(dark ? RGB(25,28,35) : RGB(242,244,249));
    field=CreateSolidBrush(dark ? RGB(37,39,47) : RGB(255,255,255));
    const HINSTANCE instance=GetModuleHandleW(NULL);
    WNDCLASSW type={.lpfnWndProc=window_message,.hInstance=instance,.hCursor=LoadCursorW(NULL,IDC_ARROW),
        .hbrBackground=background,.lpszClassName=L"MoonLuaEditor"};
    if (!RegisterClassW(&type)) return false;
    HWND parent=(HWND)(uintptr_t)owner;
    if (parent && !IsWindow(parent)) parent=NULL;
    HWND window=CreateWindowExW(WS_EX_CONTROLPARENT,L"MoonLuaEditor",L"Lua 脚本编辑器",
        WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,CW_USEDEFAULT,CW_USEDEFAULT,850,630,parent,NULL,instance,NULL);
    if (!window) return false;
    ShowWindow(window,SW_SHOW);
    MSG message;
    while (GetMessageW(&message,NULL,0,0)>0) {
        if (message.message==WM_KEYDOWN && message.wParam=='S' && (GetKeyState(VK_CONTROL)&0x8000)) {
            save_source();
            continue;
        }
        if (IsDialogMessageW(window,&message)) continue;
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    DeleteObject(ui_font); DeleteObject(code_font); DeleteObject(field); DeleteObject(background);
    return true;
}
