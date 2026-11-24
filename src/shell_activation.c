#include "win_internal.h"
#include <shellapi.h>
#include <string.h>
#include <wchar.h>

static HANDLE instance_mutex;
static wchar_t instance_name[64];
static const ULONG_PTR activation_message = 0x4d4f4f4e;

static BOOL CALLBACK find_instance(HWND window, LPARAM result) {
    if (!GetPropW(window,instance_name)) return TRUE;
    wchar_t class_name[32];
    if (!GetClassNameW(window,class_name,ARRAYSIZE(class_name)) || wcscmp(class_name,L"MoonBrowserWindow")!=0)
        return TRUE;
    *(HWND *)result=window;
    return FALSE;
}

MoonInstance moon_instance_enter(const char *profile, const char *url) {
    wchar_t path[2048], canonical[2048];
    if (!moon_utf16(profile,path,ARRAYSIZE(path))) return MOON_INSTANCE_FAILED;
    DWORD length=GetFullPathNameW(path,ARRAYSIZE(canonical),canonical,NULL);
    if (!length || length>=ARRAYSIZE(canonical)) return MOON_INSTANCE_FAILED;
    CharLowerBuffW(canonical,length);
    uint64_t hash=UINT64_C(14695981039346656037);
    for (DWORD i=0;i<length;++i) hash=(hash^canonical[i])*UINT64_C(1099511628211);
    swprintf(instance_name,ARRAYSIZE(instance_name),L"Local\\MoonBrowser.Activation.%016llx",(unsigned long long)hash);
    HANDLE mutex=CreateMutexW(NULL,TRUE,instance_name);
    if (!mutex) return MOON_INSTANCE_FAILED;
    if (GetLastError()!=ERROR_ALREADY_EXISTS) {
        instance_mutex=mutex;
        return MOON_INSTANCE_OWNER;
    }

    const ULONGLONG deadline=GetTickCount64()+3500;
    do {
        HWND window=NULL;
        EnumWindows(find_instance,(LPARAM)&window);
        if (window) {
            DWORD process;
            if (GetWindowThreadProcessId(window,&process)) AllowSetForegroundWindow(process);
            COPYDATASTRUCT message={.dwData=activation_message,
                .cbData=url ? (DWORD)strlen(url)+1 : 0,.lpData=(void *)url};
            DWORD_PTR accepted=0;
            const LRESULT sent=SendMessageTimeoutW(window,WM_COPYDATA,0,(LPARAM)&message,
                SMTO_ABORTIFHUNG|SMTO_BLOCK|SMTO_ERRORONEXIT,3000,&accepted);
            CloseHandle(mutex);
            return sent && accepted ? MOON_INSTANCE_DELIVERED : MOON_INSTANCE_FAILED;
        }
        const DWORD waited=WaitForSingleObject(mutex,50);
        if (waited==WAIT_OBJECT_0 || waited==WAIT_ABANDONED) {
            instance_mutex=mutex;
            return MOON_INSTANCE_OWNER;
        }
        if (waited!=WAIT_TIMEOUT) break;
    } while (GetTickCount64()<deadline);
    CloseHandle(mutex);
    return MOON_INSTANCE_FAILED;
}

bool moon_instance_ready(HWND window) {
    return !instance_mutex || SetPropW(window,instance_name,(HANDLE)(UINT_PTR)1);
}

void moon_instance_remove(HWND window) {
    if (instance_mutex) RemovePropW(window,instance_name);
}

void moon_instance_leave(void) {
    if (!instance_mutex) return;
    ReleaseMutex(instance_mutex);
    CloseHandle(instance_mutex);
    instance_mutex=NULL;
}

bool moon_instance_accept(HWND window, const COPYDATASTRUCT *message) {
    if (!instance_mutex || !GetPropW(window,instance_name) || !message || message->dwData!=activation_message) return false;
    if (message->cbData) {
        const char *url=message->lpData;
        if (!url || message->cbData>4096 || memchr(url,0,message->cbData)!=url+message->cbData-1 ||
            !moon_external_url_open(url)) return false;
    }
    if (IsIconic(window)) ShowWindow(window,SW_RESTORE);
    SetForegroundWindow(window);
    return true;
}

int moon_shell_open_default_apps(void) {
    wchar_t executable[2048], expected[2100], command[2100], capabilities[128];
    const DWORD length=GetModuleFileNameW(NULL,executable,ARRAYSIZE(executable));
    if (!length || length>=ARRAYSIZE(executable)) return MOON_DEFAULT_APPS_UNAVAILABLE;
    const int formatted=swprintf(expected,ARRAYSIZE(expected),L"\"%ls\" --open-url \"%%1\"",executable);
    if (formatted<=0 || formatted>=ARRAYSIZE(expected)) return MOON_DEFAULT_APPS_UNAVAILABLE;
    DWORD capabilities_size=sizeof(capabilities);
    DWORD size=sizeof(command);
    if (RegGetValueW(HKEY_CURRENT_USER,L"Software\\RegisteredApplications",L"Moon Browser",RRF_RT_REG_SZ,NULL,
        capabilities,&capabilities_size)!=ERROR_SUCCESS ||
        _wcsicmp(capabilities,L"Software\\Clients\\StartMenuInternet\\MoonBrowser\\Capabilities")!=0 ||
        RegGetValueW(HKEY_CURRENT_USER,L"Software\\Classes\\MoonBrowser.URL\\shell\\open\\command",
        NULL,RRF_RT_REG_SZ,NULL,command,&size)!=ERROR_SUCCESS || _wcsicmp(command,expected)!=0) {
        return MOON_DEFAULT_APPS_INSTALL_REQUIRED;
    }
    HWND owner=moon_shell_window();
    if ((INT_PTR)ShellExecuteW(owner,L"open",L"ms-settings:defaultapps?registeredAppUser=Moon%20Browser",NULL,NULL,SW_SHOWNORMAL)>32 ||
        (INT_PTR)ShellExecuteW(owner,L"open",L"ms-settings:defaultapps",NULL,NULL,SW_SHOWNORMAL)>32) {
        return MOON_DEFAULT_APPS_OPENED;
    }
    return MOON_DEFAULT_APPS_UNAVAILABLE;
}
