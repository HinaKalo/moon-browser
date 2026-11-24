#include "win_internal.h"
#include <string.h>
#include <wchar.h>

enum { BOOKMARK_MENU_LIMIT=96, MANAGE_BOOKMARKS=1, FIRST_BOOKMARK=2 };

typedef struct {
    HMENU handle;
    char folder[161];
    size_t offset;
    bool populated;
} BookmarkMenuPage;

typedef struct {
    BookmarkMenuPage pages[BOOKMARK_MENU_LIMIT];
    uint32_t entries[BOOKMARK_MENU_LIMIT*MOON_BOOKMARK_BAR_PAGE];
    size_t pages_used, entries_used;
} BookmarkMenu;

static BookmarkMenu *active_menu;

static HMENU new_page(BookmarkMenu *menu, const char *folder, size_t offset) {
    const size_t bytes=strlen(folder)+1;
    if (menu->pages_used>=ARRAYSIZE(menu->pages) || bytes>sizeof(menu->pages[0].folder)) return NULL;
    HMENU handle=CreatePopupMenu();
    if (!handle) return NULL;
    if (!AppendMenuW(handle,MF_STRING|MF_GRAYED,0,L"正在读取…")) {
        DestroyMenu(handle);
        return NULL;
    }
    BookmarkMenuPage *page=&menu->pages[menu->pages_used++];
    page->handle=handle;
    page->offset=offset;
    memcpy(page->folder,folder,bytes);
    return handle;
}

static void submenu(BookmarkMenu *menu, HMENU parent, const wchar_t *label, const char *folder, size_t offset) {
    HMENU child=new_page(menu,folder,offset);
    if (!child) return;
    if (!AppendMenuW(parent,MF_POPUP,(UINT_PTR)child,label)) {
        DestroyMenu(child);
        --menu->pages_used;
    }
}

static bool menu_label(const char *text, wchar_t *output) {
    wchar_t wide[512];
    if (!moon_utf16(text,wide,ARRAYSIZE(wide))) return false;
    for (const wchar_t *ch=wide;*ch;++ch) {
        if (*ch==L'&') *output++=L'&';
        *output++=*ch;
    }
    *output=0;
    return true;
}

bool moon_bookmark_menu_init(HMENU handle) {
    BookmarkMenu *menu=active_menu;
    if (!menu) return false;
    for (size_t index=0;index<menu->pages_used;++index) {
        BookmarkMenuPage *page=&menu->pages[index];
        if (page->handle!=handle) continue;
        if (page->populated) return true;
        page->populated=true;
        DeleteMenu(handle,0,MF_BYPOSITION);
        MoonBookmarkBarEntry rows[MOON_BOOKMARK_BAR_PAGE];
        bool more=false;
        const size_t count=moon_bookmark_bar_entries(page->folder,page->offset,rows,ARRAYSIZE(rows),&more);
        for (size_t i=0;i<count;++i) {
            wchar_t label[1024];
            if (!menu_label(rows[i].text,label)) continue;
            if (rows[i].id==0) {
                submenu(menu,handle,label,rows[i].folder,0);
            } else if (menu->entries_used<ARRAYSIZE(menu->entries)) {
                const UINT item=FIRST_BOOKMARK+(UINT)menu->entries_used;
                if (AppendMenuW(handle,MF_STRING,item,label)) menu->entries[menu->entries_used++]=rows[i].id;
            }
        }
        if (more) submenu(menu,handle,L"更多书签",page->folder,page->offset+MOON_BOOKMARK_BAR_PAGE);
        if (GetMenuItemCount(handle)>0) AppendMenuW(handle,MF_SEPARATOR,0,NULL);
        AppendMenuW(handle,MF_STRING,MANAGE_BOOKMARKS,L"管理全部书签");
        return true;
    }
    return false;
}

void moon_bookmark_menu_cancel(void) {
    if (active_menu) EndMenu();
}

void moon_bookmark_menu_show(const char *folder, size_t offset, RECT anchor) {
    if (active_menu || !moon_bookmark_bar_visible()) return;
    HWND owner=moon_shell_window();
    BookmarkMenu menu={0};
    HMENU popup=new_page(&menu,folder,offset);
    if (!popup) return;
    MapWindowPoints(owner,NULL,(POINT *)&anchor,2);
    TPMPARAMS params={sizeof(params),anchor};
    active_menu=&menu;
    (void)moon_bookmark_menu_init(popup);
    const UINT selected=TrackPopupMenuEx(popup,TPM_RETURNCMD|TPM_RIGHTBUTTON|TPM_VERTICAL,
        anchor.left,anchor.bottom,owner,&params);
    active_menu=NULL;
    DestroyMenu(popup);
    if (!moon_bookmark_bar_visible()) return;
    if (selected==MANAGE_BOOKMARKS) {
        (void)moon_plugin_open_page("moon.bookmarks");
    } else if (selected>=FIRST_BOOKMARK && selected-FIRST_BOOKMARK<menu.entries_used) {
        (void)moon_bookmark_bar_open(menu.entries[selected-FIRST_BOOKMARK],GetKeyState(VK_CONTROL)<0);
    }
}
