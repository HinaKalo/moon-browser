#include "win_internal.h"
#include <WebKit/WKContext.h>
#include <WebKit/WKContextConfigurationRef.h>
#include <WebKit/WKContextDownloadClient.h>
#include <WebKit/WKContextInjectedBundleClient.h>
#include <WebKit/WKData.h>
#include <WebKit/WKDownloadRef.h>
#include <WebKit/WKErrorRef.h>
#include <WebKit/WKFramePolicyListener.h>
#include <WebKit/WKFrameInfoRef.h>
#include <WebKit/WKInspector.h>
#include <WebKit/WKNavigationActionRef.h>
#include <WebKit/WKNavigationResponseRef.h>
#include <WebKit/WKPage.h>
#include <WebKit/WKPageConfigurationRef.h>
#include <WebKit/WKPageNavigationClient.h>
#include <WebKit/WKPagePrivate.h>
#include <WebKit/WKPageStateClient.h>
#include <WebKit/WKPageUIClient.h>
#include <WebKit/WKPreferencesRef.h>
#include <WebKit/WKSessionStateRef.h>
#include <WebKit/WKScriptMessageRef.h>
#include <WebKit/WKString.h>
#include <WebKit/WKType.h>
#include <WebKit/WKUserContentControllerRef.h>
#include <WebKit/WKUserScriptRef.h>
#include <WebKit/WKURL.h>
#include <WebKit/WKURLRequest.h>
#include <WebKit/WKURLResponse.h>
#include <WebKit/WKView.h>
#include <WebKit/WKWebsiteDataStoreConfigurationRef.h>
#include <WebKit/WKWebsiteDataStoreRef.h>
#include <commdlg.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define WK_FUNCTIONS(X) \
    X(WKRelease) X(WKGetTypeID) X(WKSessionStateGetTypeID) X(WKSessionStateCopyData) X(WKDataGetSize) \
    X(WKStringCreateWithUTF8CString) X(WKStringGetUTF8CString) X(WKStringIsEqualToUTF8CString) \
    X(WKURLCreateWithUTF8CString) X(WKURLCopyString) X(WKURLCopyScheme) X(WKURLRequestCopyURL) \
    X(WKURLRequestCopyHTTPMethod) X(WKURLResponseIsAttachment) X(WKURLResponseGetExpectedContentLength) \
    X(WKContextConfigurationCreate) X(WKContextConfigurationSetPrewarmsProcessesAutomatically) \
    X(WKContextConfigurationSetUsesWebProcessCache) X(WKContextConfigurationSetAlwaysKeepAndReuseSwappedProcesses) \
    X(WKContextCreateWithConfiguration) X(WKContextSetCacheModel) X(WKContextSetDownloadClient) \
    X(WKContextConfigurationSetInjectedBundlePath) X(WKContextSetInjectedBundleClient) X(WKContextPostMessageToInjectedBundle) \
    X(WKRetain) \
    X(WKWebsiteDataStoreConfigurationCreate) X(WKWebsiteDataStoreConfigurationSetGeneralStorageDirectory) \
    X(WKWebsiteDataStoreConfigurationSetNetworkCacheDirectory) X(WKWebsiteDataStoreConfigurationSetCookieStorageFile) \
    X(WKWebsiteDataStoreConfigurationSetLocalStorageDirectory) X(WKWebsiteDataStoreConfigurationSetIndexedDBDatabaseDirectory) \
    X(WKWebsiteDataStoreConfigurationSetCacheStorageDirectory) X(WKWebsiteDataStoreConfigurationSetServiceWorkerRegistrationDirectory) \
    X(WKWebsiteDataStoreCreateWithConfiguration) X(WKWebsiteDataStoreRemoveMemoryCaches) \
    X(WKPageConfigurationCreate) X(WKPageConfigurationSetContext) X(WKPageConfigurationSetWebsiteDataStore) \
    X(WKPageConfigurationSetPreferences) X(WKPreferencesCreate) X(WKPreferencesSetJavaScriptCanOpenWindowsAutomatically) \
    X(WKViewCreate) X(WKViewGetWindow) X(WKViewGetPage) X(WKViewSetIsInWindow) \
    X(WKPageSetPageNavigationClient) X(WKPageSetPageUIClient) X(WKPageSetPageStateClient) \
    X(WKPageLoadURL) X(WKPageCopyTitle) X(WKPageCopyActiveURL) X(WKPageClose) \
    X(WKPageCopyCommittedURL) X(WKPageCallAsyncJavaScriptWithoutUserGesture) \
    X(WKPageSetPageInjectedBundleClient) X(WKPagePostMessageToInjectedBundle) \
    X(WKPageLoadHTMLString) X(WKStringGetTypeID) X(WKFrameInfoGetIsMainFrame) \
    X(WKWebsiteDataStoreCreateNonPersistentDataStore) X(WKPageConfigurationSetUserContentController) \
    X(WKUserContentControllerCreate) X(WKUserContentControllerAddScriptMessageHandler) \
    X(WKUserContentControllerAddUserScript) X(WKUserContentControllerRemoveAllUserScripts) X(WKUserScriptCreateWithSource) \
    X(WKUserContentControllerRemoveAllUserMessageHandlers) X(WKScriptMessageGetBody) \
    X(WKScriptMessageGetFrameInfo) X(WKCompletionListenerComplete) \
    X(WKPreferencesSetDeveloperExtrasEnabled) \
    X(WKPageGetInspector) X(WKInspectorShow) X(WKInspectorShowConsole) X(WKInspectorShowResources) \
    X(WKPageGoBack) X(WKPageCanGoBack) X(WKPageGoForward) X(WKPageCanGoForward) X(WKPageReload) \
    X(WKPageSetPageFindClient) X(WKPageFindString) X(WKPageHideFindUI) \
    X(WKPageGetPageZoomFactor) X(WKPageSetPageZoomFactor) \
    X(WKPageCopySessionState) X(WKPageRestoreFromSessionState) X(WKPageGetProcessIdentifier) X(WKPageGetMediaState) \
    X(WKNavigationActionCopyRequest) X(WKNavigationActionShouldPerformDownload) \
    X(WKNavigationActionGetNavigationType) X(WKNavigationActionHasUnconsumedUserGesture) \
    X(WKNavigationResponseCopyResponse) X(WKNavigationResponseCanShowMIMEType) \
    X(WKFramePolicyListenerUse) X(WKFramePolicyListenerIgnore) X(WKFramePolicyListenerDownload) \
    X(WKErrorCopyLocalizedDescription) X(WKDownloadGetOriginatingPage) X(WKDownloadCancel) \
    X(WKPageListenForLayoutMilestones) X(WKPageCallAfterNextPresentationUpdate)

static struct {
#define FIELD(name) __typeof__(&name) name;
    WK_FUNCTIONS(FIELD)
#undef FIELD
} wk;
static HMODULE module;
static WKContextRef context;
static WKWebsiteDataStoreRef store;
static WKUserContentControllerRef normal_page_content;
static DLL_DIRECTORY_COOKIE dll_directory;
static wchar_t engine_dir[2048];
static char engine_error[256];
static char test_download_path[4096];
static int test_download_result;
static bool filter_bundle_available;
static WKStringRef current_request_policy;

struct MoonView {
    WKViewRef view;
    WKPageRef page;
    WKPreferencesRef view_preferences;
    HWND hwnd;
    uint64_t token;
    uintptr_t extension_serial;
    WKUserContentControllerRef extension_controller;
    char extension_id[96];
    char *extension_address;
    struct MoonView *next;
};
static MoonView *views;
static uintptr_t extension_sequence;
typedef struct {
    WKDownloadRef download;
    uint64_t token;
    uint32_t id;
} DownloadSlot;
static DownloadSlot downloads[64];

static void release(WKTypeRef ref) { if (ref) wk.WKRelease(ref); }
static void find_succeeded(WKPageRef page, WKStringRef string, unsigned matches, const void *client) {
    (void)page;
    const MoonView *view = client;
    char query[1024];
    if (string && wk.WKStringGetUTF8CString(string,query,sizeof(query)) < sizeof(query))
        moon_find_result(view->token,query,matches);
}
static void find_failed(WKPageRef page, WKStringRef string, const void *client) {
    find_succeeded(page,string,0,client);
}
static void copy_string(WKStringRef string, char *buffer, size_t cap) {
    buffer[0] = 0;
    if (string) {
        wk.WKStringGetUTF8CString(string, buffer, cap);
        buffer[cap-1] = 0;
        release(string);
    }
}
static void copy_url(WKURLRef url, char *buffer, size_t cap) {
    if (!url) { buffer[0] = 0; return; }
    copy_string(wk.WKURLCopyString(url), buffer, cap);
    release(url);
}
static void emit(const void *client, int kind, const char *detail) {
    moon_engine_event(kind, ((const MoonView *)client)->token, detail);
}
static bool supported_scheme(WKURLRequestRef request) {
    WKURLRef url = request ? wk.WKURLRequestCopyURL(request) : NULL;
    WKStringRef scheme = url ? wk.WKURLCopyScheme(url) : NULL;
    bool allowed = scheme &&
        (wk.WKStringIsEqualToUTF8CString(scheme, "https") ||
         wk.WKStringIsEqualToUTF8CString(scheme, "http") ||
         wk.WKStringIsEqualToUTF8CString(scheme, "about") ||
         wk.WKStringIsEqualToUTF8CString(scheme, "blob") ||
         wk.WKStringIsEqualToUTF8CString(scheme, "data"));
    release(scheme);
    release(url);
    return allowed;
}
static bool safe_method(WKURLRequestRef request) {
    WKStringRef method = request ? wk.WKURLRequestCopyHTTPMethod(request) : NULL;
    bool safe = method && wk.WKStringIsEqualToUTF8CString(method, "GET");
    release(method);
    return safe;
}
static void navigation_action(WKPageRef page, WKNavigationActionRef action, WKFramePolicyListenerRef listener,
                              WKTypeRef user, const void *client) {
    WKURLRequestRef request = wk.WKNavigationActionCopyRequest(action);
    const MoonView *view = client;
    if (view->extension_address) {
        char url[4096];
        copy_url(request ? wk.WKURLRequestCopyURL(request) : NULL,url,sizeof(url));
        if (!strcmp(url,"about:blank") || !strcmp(url,view->extension_address)) {
            wk.WKFramePolicyListenerUse(listener);
        } else {
            const char *docs = "https://docs.browser.moonl.cloud/";
            bool market_link = !strcmp(view->extension_address,"moon://market/") && !strncmp(url,docs,strlen(docs));
            bool plugin_link = view->extension_id[0] && supported_scheme(request) &&
                wk.WKNavigationActionHasUnconsumedUserGesture(action);
            if ((market_link || plugin_link) && wk.WKNavigationActionGetNavigationType(action)==kWKFrameNavigationTypeLinkClicked && safe_method(request))
                emit(client,MOON_POPUP,url);
            wk.WKFramePolicyListenerIgnore(listener);
        }
        release(request);
        return;
    }
    bool allowed = supported_scheme(request);
    if (!safe_method(request)) emit(client, MOON_UNSAFE, NULL);
    release(request);
    if (!allowed) wk.WKFramePolicyListenerIgnore(listener);
    else if (wk.WKNavigationActionShouldPerformDownload(action)) wk.WKFramePolicyListenerDownload(listener);
    else wk.WKFramePolicyListenerUse(listener);
}
static void navigation_response(WKPageRef page, WKNavigationResponseRef response, WKFramePolicyListenerRef listener,
                                WKTypeRef user, const void *client) {
    WKURLResponseRef url_response = wk.WKNavigationResponseCopyResponse(response);
    bool download = (url_response && wk.WKURLResponseIsAttachment(url_response)) ||
        !wk.WKNavigationResponseCanShowMIMEType(response);
    release(url_response);
    if (download) wk.WKFramePolicyListenerDownload(listener);
    else wk.WKFramePolicyListenerUse(listener);
}
static void started(WKPageRef page, WKNavigationRef nav, WKTypeRef user, const void *client) {
    emit(client, MOON_STARTED, NULL);
}
static void committed(WKPageRef page, WKNavigationRef nav, WKTypeRef user, const void *client) {
    emit(client, MOON_COMMITTED, NULL);
}
static void finished(WKPageRef page, WKNavigationRef nav, WKTypeRef user, const void *client) {
    emit(client, MOON_FINISHED, NULL);
}
static void same_document(WKPageRef page, WKNavigationRef nav, WKSameDocumentNavigationType type,
                          WKTypeRef user, const void *client) {
    emit(client, MOON_SAME_DOCUMENT, NULL);
}
static void failed(WKPageRef page, WKNavigationRef nav, WKErrorRef error, WKTypeRef user, const void *client) {
    char description[512];
    copy_string(error ? wk.WKErrorCopyLocalizedDescription(error) : NULL, description, sizeof(description));
    emit(client, MOON_FAILED, description);
}
static void changed(const void *client) { emit(client, MOON_CHANGED, NULL); }
static void terminated(WKPageRef page, WKProcessTerminationReason reason, const void *client) {
    emit(client, MOON_TERMINATED, NULL);
}
static void rendering(WKPageRef page, WKPageRenderingProgressEvents events, WKTypeRef user, const void *client) {
    if (events & WKPageRenderingProgressEventFirstVisuallyNonEmptyLayout)
        emit(client, MOON_PAINTED, "layout");
}
static WKPageRef popup_requested(WKPageRef page, WKURLRequestRef request, WKDictionaryRef features,
                                 WKEventModifiers modifiers, WKEventMouseButton button, const void *client) {
    if (((const MoonView *)client)->extension_address) return NULL;
    if (!request || !supported_scheme(request) || !safe_method(request)) return NULL;
    char url[4096];
    copy_url(wk.WKURLRequestCopyURL(request),url,sizeof(url));
    if (!strncmp(url,"http://",7) || !strncmp(url,"https://",8))
        emit(client, MOON_POPUP, url);
    return NULL;
}
static DownloadSlot *download_slot(WKDownloadRef download) {
    for (size_t i=0;i<ARRAYSIZE(downloads);++i) {
        if (downloads[i].download == download) return &downloads[i];
    }
    return NULL;
}
static void download_started(WKContextRef unused, WKDownloadRef download, const void *client) {
    DownloadSlot *slot=download_slot(NULL);
    if (!slot) return;
    *slot=(DownloadSlot){ .download=download,.id=moon_download_begin() };
    WKPageRef page = wk.WKDownloadGetOriginatingPage(download);
    for (MoonView *view=views;view;view=view->next) {
        if (view->page != page) continue;
        slot->token=view->token;
        emit(view, MOON_DOWNLOAD_START, NULL);
        return;
    }
}
static void download_response(WKContextRef unused, WKDownloadRef download, WKURLResponseRef response, const void *client) {
    DownloadSlot *slot=download_slot(download);
    if (!slot || !slot->id || !response) return;
    const uint32_t length=wk.WKURLResponseGetExpectedContentLength(response);
    if (length!=UINT32_MAX) moon_download_progress(slot->id,0,length);
}
static void download_data(WKContextRef unused, WKDownloadRef download, uint64_t chunk, const void *client) {
    DownloadSlot *slot=download_slot(download);
    if (slot && slot->id) moon_download_progress(slot->id,chunk,0);
}
static void finish_download(WKDownloadRef download, int state, const char *detail) {
    DownloadSlot *slot=download_slot(download);
    if (!slot) return;
    const DownloadSlot result=*slot;
    *slot=(DownloadSlot){0};
    if (result.id) moon_download_finish(result.id,state);
    if (*test_download_path) test_download_result = state==MOON_DL_COMPLETE ? 1 : -1;
    if (result.token) moon_engine_event(MOON_DOWNLOAD_END,result.token,detail);
}
static WKStringRef download_destination(WKContextRef unused, WKDownloadRef download, WKStringRef suggested,
                                         bool *overwrite, const void *client) {
    if (*test_download_path) {
        *overwrite = false;
        DownloadSlot *slot=download_slot(download);
        if (slot && slot->id) moon_download_destination(slot->id,test_download_path);
        return wk.WKStringCreateWithUTF8CString(test_download_path);
    }
    char suggested_utf8[1024] = {0}, path_utf8[8192];
    wchar_t path[4096];
    if (suggested) wk.WKStringGetUTF8CString(suggested,suggested_utf8,sizeof(suggested_utf8));
    if (!moon_utf16(suggested_utf8,path,ARRAYSIZE(path))) path[0] = 0;
    if (!*path || wcspbrk(path, L"\\/:*?\"<>|") || !wcscmp(path,L".") || !wcscmp(path,L".."))
        wcscpy(path,L"download");
    OPENFILENAMEW dialog = { .lStructSize = sizeof(dialog), .hwndOwner = moon_shell_window(),
        .lpstrFile = path, .nMaxFile = ARRAYSIZE(path), .lpstrTitle = L"保存下载",
        .Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER };
    if (!GetSaveFileNameW(&dialog) || !moon_utf8(path,path_utf8,sizeof(path_utf8))) {
        finish_download(download,MOON_DL_CANCELLED,NULL);
        return NULL;
    }
    *overwrite = true;
    DownloadSlot *slot=download_slot(download);
    if (slot && slot->id) moon_download_destination(slot->id,path_utf8);
    return wk.WKStringCreateWithUTF8CString(path_utf8);
}
static void download_finished(WKContextRef unused, WKDownloadRef download, const void *client) {
    finish_download(download,MOON_DL_COMPLETE,"下载完成");
}
static void download_failed(WKContextRef unused, WKDownloadRef download, WKErrorRef error, const void *client) {
    finish_download(download,MOON_DL_FAILED,"下载失败");
}
static void download_cancelled(WKContextRef unused, WKDownloadRef download, const void *client) {
    finish_download(download,MOON_DL_CANCELLED,"已取消下载");
}
static void download_crashed(WKContextRef unused, WKDownloadRef download, const void *client) {
    finish_download(download,MOON_DL_INTERRUPTED,"下载已中断");
}
static void download_cancel_complete(WKDataRef resume, const void *cookie) {
    const uint32_t id=(uint32_t)(uintptr_t)cookie;
    for (size_t i=0;i<ARRAYSIZE(downloads);++i) {
        if (!downloads[i].download || downloads[i].id!=id) continue;
        finish_download(downloads[i].download,MOON_DL_CANCELLED,"已取消下载");
        return;
    }
}
bool moon_engine_cancel_download(uint32_t id) {
    if (!id) return false;
    for (size_t i=0;i<ARRAYSIZE(downloads);++i) {
        if (!downloads[i].download || downloads[i].id!=id) continue;
        wk.WKDownloadCancel(downloads[i].download,(const void *)(uintptr_t)id,download_cancel_complete);
        return true;
    }
    return false;
}
static void set_profile_path(WKWebsiteDataStoreConfigurationRef configuration,
    void (*setter)(WKWebsiteDataStoreConfigurationRef, WKStringRef), const char *name) {
    char path[8192];
    int written = snprintf(path,sizeof(path),"%s\\%s",moon_profile_dir(),name);
    if (written < 0 || written >= (int)sizeof(path)) return;
    WKStringRef value = wk.WKStringCreateWithUTF8CString(path);
    setter(configuration,value);
    release(value);
}
static WKTypeRef initial_request_policy(WKContextRef unused,const void *info) {
    return current_request_policy ? wk.WKRetain(current_request_policy) : NULL;
}
bool moon_engine_set_request_policy(const char *rules,const char *document_script) {
    if (!context || !filter_bundle_available || !normal_page_content) return false;
    WKStringRef policy = wk.WKStringCreateWithUTF8CString(rules);
    WKStringRef message = wk.WKStringCreateWithUTF8CString("MoonRequestPolicy");
    WKStringRef source = document_script && *document_script ? wk.WKStringCreateWithUTF8CString(document_script) : NULL;
    WKUserScriptRef script = source ? wk.WKUserScriptCreateWithSource(source,kWKInjectAtDocumentStart,true) : NULL;
    release(source);
    if (!policy || !message || (document_script && *document_script && !script)) {
        release(policy);
        release(message);
        release(script);
        return false;
    }
    release(current_request_policy);
    current_request_policy = policy;
    wk.WKContextPostMessageToInjectedBundle(context,message,policy);
    release(message);
    wk.WKUserContentControllerRemoveAllUserScripts(normal_page_content);
    if (script) wk.WKUserContentControllerAddUserScript(normal_page_content,script);
    release(script);
    return true;
}
const char *moon_engine_init(void) {
    wchar_t app[2048], library[2048];
    if (!moon_utf16(moon_app_dir(), app, ARRAYSIZE(app)) ||
        !moon_path(engine_dir,ARRAYSIZE(engine_dir),app,L"engine") ||
        !moon_path(library,ARRAYSIZE(library),engine_dir,L"WebKit2.dll")) return "Invalid engine path.";
    if (wcslen(engine_dir) + ARRAYSIZE(L"\\WebKitNetworkProcess.exe") >= MAX_PATH)
        return "Move the Moon Browser folder to a shorter Windows path.";
    dll_directory = AddDllDirectory(engine_dir);
    if (!dll_directory) return "Could not register the packaged engine directory.";
    module = LoadLibraryExW(library,NULL,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_USER_DIRS);
    if (!module) {
        snprintf(engine_error,sizeof(engine_error),"Could not load packaged WebKit2.dll (Windows error %lu).",GetLastError());
        return engine_error;
    }
#define RESOLVE(name) wk.name = (__typeof__(wk.name))GetProcAddress(module,#name); \
    if (!wk.name) return "Packaged engine is missing " #name ".";
    WK_FUNCTIONS(RESOLVE)
#undef RESOLVE
    WKContextConfigurationRef ctx = wk.WKContextConfigurationCreate();
    if (!ctx) return "Could not create process configuration.";
    wk.WKContextConfigurationSetPrewarmsProcessesAutomatically(ctx,false);
    wk.WKContextConfigurationSetUsesWebProcessCache(ctx,false);
    wk.WKContextConfigurationSetAlwaysKeepAndReuseSwappedProcesses(ctx,false);
    wchar_t bundle[2048];
    char bundle_utf8[8192];
    if (moon_path(bundle,ARRAYSIZE(bundle),app,L"MoonRequestFilter.dll") &&
        moon_utf8(bundle,bundle_utf8,sizeof(bundle_utf8))) {
        DWORD attrs=GetFileAttributesW(bundle);
        if (attrs!=INVALID_FILE_ATTRIBUTES && !(attrs & (FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT))) {
            WKStringRef path=wk.WKStringCreateWithUTF8CString(bundle_utf8);
            if (path) {
                wk.WKContextConfigurationSetInjectedBundlePath(ctx,path);
                release(path);
                filter_bundle_available=true;
            }
        }
    }
    context = wk.WKContextCreateWithConfiguration(ctx);
    release(ctx);
    if (!context) return "Could not create WebKit context.";
    if (filter_bundle_available) {
        const WKContextInjectedBundleClientV1 client = {
            .base={1,NULL},.getInjectedBundleInitializationUserData=initial_request_policy,
        };
        wk.WKContextSetInjectedBundleClient(context,&client.base);
    }
    wk.WKContextSetCacheModel(context,kWKCacheModelDocumentBrowser);
    normal_page_content = wk.WKUserContentControllerCreate();
    if (!normal_page_content) return "Could not create content controller.";

    WKWebsiteDataStoreConfigurationRef config = wk.WKWebsiteDataStoreConfigurationCreate();
    if (!config) return "Could not create profile configuration.";
    set_profile_path(config,wk.WKWebsiteDataStoreConfigurationSetGeneralStorageDirectory,"WebsiteData");
    set_profile_path(config,wk.WKWebsiteDataStoreConfigurationSetNetworkCacheDirectory,"NetworkCache");
    set_profile_path(config,wk.WKWebsiteDataStoreConfigurationSetCookieStorageFile,"Cookies.db");
    set_profile_path(config,wk.WKWebsiteDataStoreConfigurationSetLocalStorageDirectory,"LocalStorage");
    set_profile_path(config,wk.WKWebsiteDataStoreConfigurationSetIndexedDBDatabaseDirectory,"IndexedDB");
    set_profile_path(config,wk.WKWebsiteDataStoreConfigurationSetCacheStorageDirectory,"CacheStorage");
    set_profile_path(config,wk.WKWebsiteDataStoreConfigurationSetServiceWorkerRegistrationDirectory,"ServiceWorkers");
    store = wk.WKWebsiteDataStoreCreateWithConfiguration(config);
    release(config);
    if (!store) return "Could not open website data.";
    WKContextDownloadClientV0 client = { .base={0,NULL}, .didStart=download_started,
        .didReceiveResponse=download_response,.didReceiveData=download_data,
        .decideDestinationWithSuggestedFilename=download_destination,.didFinish=download_finished,
        .didFail=download_failed,.didCancel=download_cancelled,.processDidCrash=download_crashed };
    wk.WKContextSetDownloadClient(context,&client.base);
    return NULL;
}
void moon_engine_shutdown(void) {
    if (context) {
        wk.WKContextSetDownloadClient(context,NULL);
        if (filter_bundle_available) wk.WKContextSetInjectedBundleClient(context,NULL);
    }
    release(current_request_policy);
    current_request_policy = NULL;
    if (store) release(store);
    if (context) release(context);
    store = NULL; context = NULL;
    // WK's run loop can have posted completion callbacks. Let Windows unload
    // the DLL on process exit after the UI message pump has stopped.
}
static void extension_message(WKScriptMessageRef message, WKCompletionListenerRef reply, const void *context, bool settings) {
    if (!reply) return;
    const uintptr_t serial = (uintptr_t)context;
    const MoonView *view = views;
    while (view && view->extension_serial != serial) view = view->next;
    char request[8192], response[32*1024];
    const WKTypeRef data = wk.WKScriptMessageGetBody(message);
    const WKFrameInfoRef frame = wk.WKScriptMessageGetFrameInfo(message);
    bool ok = false;
    if (view && frame && wk.WKFrameInfoGetIsMainFrame(frame) && data && wk.WKGetTypeID(data) == wk.WKStringGetTypeID()) {
        size_t bytes = wk.WKStringGetUTF8CString((WKStringRef)data,request,sizeof(request));
        if (bytes && bytes < sizeof(request) && strlen(request)+1 == bytes)
            ok = settings ? moon_extension_settings(view->extension_id,request,response,sizeof(response)) :
                moon_extension_request(view->token,view->extension_id,request,response,sizeof(response));
    }
    WKStringRef value = wk.WKStringCreateWithUTF8CString(ok ? response : "{\"ok\":false}");
    wk.WKCompletionListenerComplete(reply,value);
    release(value);
}
static void settings_message(WKScriptMessageRef message, WKCompletionListenerRef reply, const void *context) {
    extension_message(message,reply,context,true);
}
static void plugin_message(WKScriptMessageRef message, WKCompletionListenerRef reply, const void *context) {
    extension_message(message,reply,context,false);
}
static void site_snapshot_received(WKPageRef page,WKStringRef name,WKTypeRef body,const void *context) {
    const MoonView *view=context;
    if (!wk.WKStringIsEqualToUTF8CString(name,"MoonSiteSnapshot") || !body ||
        wk.WKGetTypeID(body)!=wk.WKStringGetTypeID()) return;
    const size_t cap=512*1024+32;
    char *response=malloc(cap);
    if (!response) return;
    const size_t n=wk.WKStringGetUTF8CString((WKStringRef)body,response,cap);
    if (n && n<cap && strlen(response)+1==n) {
        char *end=NULL;
        const uint64_t request=strtoull(response,&end,10);
        if (end!=response && *end=='\n') moon_site_data_result(view->token,request,end+1);
    }
    free(response);
}
bool moon_engine_inspect_site(MoonView *view,uint64_t request) {
    if (!filter_bundle_available || !view || view->extension_address) return false;
    char url[4096], payload[4160];
    moon_engine_committed_url(view,url,sizeof(url));
    if (!*url) return false;
    const int length=snprintf(payload,sizeof(payload),"%" PRIu64 "\n%s",request,url);
    if (length<0 || (size_t)length>=sizeof(payload)) return false;
    WKStringRef name=wk.WKStringCreateWithUTF8CString("MoonInspectSite");
    WKStringRef body=wk.WKStringCreateWithUTF8CString(payload);
    const bool ok=name && body;
    if (ok) wk.WKPagePostMessageToInjectedBundle(view->page,name,body);
    release(body);
    release(name);
    return ok;
}

static MoonView *open_view(uint64_t token, const char *extension_id, const char *address) {
    if (!context) return NULL;
    MoonView *view = calloc(1,sizeof(*view));
    if (!view) return NULL;
    WKPageConfigurationRef config = wk.WKPageConfigurationCreate();
    if (!config) { free(view); return NULL; }
    wk.WKPageConfigurationSetContext(config,context);
    if (address) {
        view->extension_address = _strdup(address);
        WKWebsiteDataStoreRef temporary = wk.WKWebsiteDataStoreCreateNonPersistentDataStore();
        if (!view->extension_address || !temporary) {
            release(temporary);
            goto fail;
        }
        wk.WKPageConfigurationSetWebsiteDataStore(config,temporary);
        release(temporary);
        if (extension_id) {
            if (strlen(extension_id)>=sizeof(view->extension_id)) goto fail;
            view->extension_controller = wk.WKUserContentControllerCreate();
            if (!view->extension_controller) goto fail;
            strcpy(view->extension_id,extension_id);
            view->extension_serial = ++extension_sequence;
            WKStringRef channel = wk.WKStringCreateWithUTF8CString("moonSettings");
            if (!channel) goto fail;
            wk.WKUserContentControllerAddScriptMessageHandler(view->extension_controller,channel,settings_message,
                (const void *)view->extension_serial);
            release(channel);
            channel = wk.WKStringCreateWithUTF8CString("moonHost");
            if (!channel) goto fail;
            wk.WKUserContentControllerAddScriptMessageHandler(view->extension_controller,channel,plugin_message,
                (const void *)view->extension_serial);
            release(channel);
            wk.WKPageConfigurationSetUserContentController(config,view->extension_controller);
        }
    } else {
        wk.WKPageConfigurationSetWebsiteDataStore(config,store);
        wk.WKPageConfigurationSetUserContentController(config,normal_page_content);
    }
    view->view_preferences = wk.WKPreferencesCreate();
    if (!view->view_preferences) goto fail;
    wk.WKPreferencesSetJavaScriptCanOpenWindowsAutomatically(view->view_preferences,false);
    wk.WKPageConfigurationSetPreferences(config,view->view_preferences);
    RECT bounds;
    HWND parent = moon_shell_content();
    GetClientRect(parent,&bounds);
    view->view = wk.WKViewCreate(bounds,config,parent);
    if (!view->view) goto fail;
    view->page = wk.WKViewGetPage(view->view);
    view->hwnd = wk.WKViewGetWindow(view->view);
    view->token = token;
    if (!view->page || !view->hwnd) goto fail;
    release(config);
    view->next = views;
    views = view;
    WKPageNavigationClientV1 navigation = { .base={1,view},
        .decidePolicyForNavigationAction=navigation_action,.decidePolicyForNavigationResponse=navigation_response,
        .didStartProvisionalNavigation=started,.didFailProvisionalNavigation=failed,
        .didCommitNavigation=committed,.didFinishNavigation=finished,.didFailNavigation=failed,
        .didSameDocumentNavigation=same_document,
        .renderingProgressDidChange=rendering,.webProcessDidTerminate=terminated };
    WKPageStateClientV0 state = { .base={0,view},.didChangeTitle=changed,.didChangeActiveURL=changed,
        .didChangeCanGoBack=changed,.didChangeCanGoForward=changed };
    WKPageUIClientV1 ui = { .base={1,view}, .createNewPage=popup_requested };
    const WKPageFindClientV0 find = { .base={0,view},
        .didFindString=find_succeeded, .didFailToFindString=find_failed };
    wk.WKPageSetPageNavigationClient(view->page,&navigation.base);
    wk.WKPageSetPageStateClient(view->page,&state.base);
    wk.WKPageSetPageFindClient(view->page,&find.base);
    if (!address && filter_bundle_available) {
        const WKPageInjectedBundleClientV0 client = {
            .base={0,view},.didReceiveMessageFromInjectedBundle=site_snapshot_received,
        };
        wk.WKPageSetPageInjectedBundleClient(view->page,&client.base);
    }
    wk.WKPageSetPageUIClient(view->page,&ui.base);
    wk.WKPageListenForLayoutMilestones(view->page,kWKDidFirstVisuallyNonEmptyLayout);
    ShowWindow(view->hwnd,SW_HIDE);
    return view;
fail:
    release(config);
    release(view->view);
    release(view->extension_controller);
    release(view->view_preferences);
    free(view->extension_address);
    free(view);
    return NULL;
}
MoonView *moon_engine_open(uint64_t token) {
    return open_view(token,NULL,NULL);
}
MoonView *moon_engine_open_extension(uint64_t token, const char *plugin_id, const char *address) {
    return open_view(token,plugin_id,address);
}
bool moon_engine_load_extension(MoonView *view, const char *html) {
    if (!view->extension_address) return false;
    static const char policy[] = "<meta charset=utf-8><meta http-equiv=\"Content-Security-Policy\" "
        "content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; "
        "connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'; object-src 'none'\">";
    const char *theme = moon_shell_dark_mode() ? "<!doctype html><html data-moon-theme=dark>" : "<!doctype html><html data-moon-theme=light>";
    size_t size = sizeof(policy)+strlen(theme)+strlen(html);
    char *document = malloc(size);
    if (!document) return false;
    snprintf(document,size,"%s%s%s",theme,policy,html);
    WKStringRef source = wk.WKStringCreateWithUTF8CString(document);
    WKURLRef base = wk.WKURLCreateWithUTF8CString(view->extension_address);
    free(document);
    bool ok = source && base;
    if (ok) wk.WKPageLoadHTMLString(view->page,source,base);
    release(source);
    release(base);
    return ok;
}
void moon_engine_refresh_extension_theme(void) {
    const char *script = moon_shell_dark_mode() ? "document.documentElement.dataset.moonTheme='dark'" :
        "document.documentElement.dataset.moonTheme='light'";
    for (MoonView *view=views; view; view=view->next)
        if (view->extension_address) moon_engine_apply_dom(view,script);
}
void moon_engine_close(MoonView *view) {
    MoonView **link = &views;
    while (*link && *link != view) link = &(*link)->next;
    if (*link) *link = view->next;
    if (view->extension_controller) {
        wk.WKUserContentControllerRemoveAllUserMessageHandlers(view->extension_controller);
        release(view->extension_controller);
    }
    wk.WKPageSetPageStateClient(view->page,NULL);
    wk.WKPageSetPageNavigationClient(view->page,NULL);
    wk.WKPageSetPageUIClient(view->page,NULL);
    wk.WKPageSetPageFindClient(view->page,NULL);
    if (!view->extension_address && filter_bundle_available) wk.WKPageSetPageInjectedBundleClient(view->page,NULL);
    wk.WKPageClose(view->page);
    if (IsWindow(view->hwnd)) DestroyWindow(view->hwnd);
    release(view->view);
    release(view->view_preferences);
    free(view->extension_address);
    free(view);
}
void moon_engine_show(MoonView *view, bool visible) {
    ShowWindow(view->hwnd,visible ? SW_SHOWNA : SW_HIDE);
    wk.WKViewSetIsInWindow(view->view,visible);
    if (visible && GetForegroundWindow() == moon_shell_window()) SetFocus(view->hwnd);
}
bool moon_engine_load(MoonView *view, const char *url) {
    WKURLRef target_url = wk.WKURLCreateWithUTF8CString(url);
    if (!target_url) return false;
    wk.WKPageLoadURL(view->page,target_url);
    release(target_url);
    return true;
}
void moon_engine_back(MoonView *view) { if (wk.WKPageCanGoBack(view->page)) wk.WKPageGoBack(view->page); }
void moon_engine_forward(MoonView *view) { if (wk.WKPageCanGoForward(view->page)) wk.WKPageGoForward(view->page); }
void moon_engine_reload(MoonView *view) { wk.WKPageReload(view->page); }
void moon_engine_find(MoonView *view, const char *query, bool backwards) {
    WKStringRef string = wk.WKStringCreateWithUTF8CString(query);
    if (!string) return;
    WKFindOptions options = kWKFindOptionsCaseInsensitive | kWKFindOptionsWrapAround |
        kWKFindOptionsShowHighlight | kWKFindOptionsShowFindIndicator;
    if (backwards) options |= kWKFindOptionsBackwards;
    wk.WKPageFindString(view->page,string,options,MOON_FIND_MATCH_LIMIT);
    release(string);
}
void moon_engine_hide_find(MoonView *view) { wk.WKPageHideFindUI(view->page); }
void moon_engine_set_zoom(MoonView *view, unsigned percent) {
    const double factor = percent / 100.0;
    if (factor != wk.WKPageGetPageZoomFactor(view->page)) wk.WKPageSetPageZoomFactor(view->page,factor);
}
unsigned moon_engine_zoom(MoonView *view) {
    const double factor = wk.WKPageGetPageZoomFactor(view->page);
    return factor >= 0.1 && factor <= 10.0 ? (unsigned)(factor * 100.0 + 0.5) : 100;
}
bool moon_engine_inspect(MoonView *view, int panel) {
    if (view->extension_address) return false;
    wk.WKPreferencesSetDeveloperExtrasEnabled(view->view_preferences,true);
    WKInspectorRef inspector = wk.WKPageGetInspector(view->page);
    if (!inspector) return false;
    switch (panel) {
        case 0: wk.WKInspectorShow(inspector); break;
        case 1: wk.WKInspectorShowConsole(inspector); break;
        case 2: wk.WKInspectorShowResources(inspector); break;
        default: return false;
    }
    return true;
}
void moon_engine_committed_url(MoonView *view, char *url, size_t cap) {
    if (!cap) return;
    url[0] = 0;
    WKURLRef committed = wk.WKPageCopyCommittedURL(view->page);
    WKStringRef string = committed ? wk.WKURLCopyString(committed) : NULL;
    if (string && wk.WKStringGetUTF8CString(string, url, cap) >= cap) url[0] = 0;
    release(string);
    release(committed);
}
void moon_engine_apply_dom(MoonView *view, const char *javascript) {
    WKStringRef source = wk.WKStringCreateWithUTF8CString(javascript);
    if (!source) return;
    wk.WKPageCallAsyncJavaScriptWithoutUserGesture(view->page, source, NULL, NULL, NULL, NULL);
    release(source);
}
unsigned moon_engine_controls(MoonView *view) {
    return (wk.WKPageCanGoBack(view->page) ? 1u : 0u) | (wk.WKPageCanGoForward(view->page) ? 2u : 0u);
}
const void *moon_engine_save(MoonView *view) {
    // The pinned WK C implementation uses the low context bit to request a
    // retained WKSessionState object instead of the legacy byte representation.
    WKTypeRef state = wk.WKPageCopySessionState(view->page,(void *)(uintptr_t)1,NULL);
    if (state && wk.WKGetTypeID(state) == wk.WKSessionStateGetTypeID()) {
        WKDataRef encoded = wk.WKSessionStateCopyData((WKSessionStateRef)state);
        size_t bytes = encoded ? wk.WKDataGetSize(encoded) : 0;
        release(encoded);
        if (bytes && bytes <= 2*1024*1024) return state;
    }
    release(state);
    return NULL;
}
bool moon_engine_restore(MoonView *view, const void *state) {
    if (!state) return false;
    wk.WKPageRestoreFromSessionState(view->page,state);
    return true;
}
void moon_engine_release_state(const void *state) { release(state); }
uint32_t moon_engine_pid(MoonView *view) { return (uint32_t)wk.WKPageGetProcessIdentifier(view->page); }
bool moon_engine_media(MoonView *view) {
    WKMediaState state = wk.WKPageGetMediaState(view->page);
    return state & (kWKMediaIsPlayingAudio | kWKMediaIsPlayingVideo | kWKMediaHasActiveAudioCaptureDevice |
        kWKMediaHasActiveVideoCaptureDevice | kWKMediaHasActiveDisplayCaptureDevice |
        kWKMediaHasActiveScreenCaptureDevice | kWKMediaHasActiveWindowCaptureDevice);
}
void moon_engine_read(MoonView *view, char *title, size_t title_cap, char *url, size_t url_cap) {
    copy_string(wk.WKPageCopyTitle(view->page),title,title_cap);
    copy_url(wk.WKPageCopyActiveURL(view->page),url,url_cap);
}
static void cache_trimmed(void *unused) {}
void moon_engine_trim(void) {
    if (store) wk.WKWebsiteDataStoreRemoveMemoryCaches(store,NULL,cache_trimmed);
}
bool moon_engine_test_crash(MoonView *view) {
    DWORD pid = moon_engine_pid(view);
    HANDLE process = pid ? OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid) : NULL;
    wchar_t expected[2048], actual[2048];
    DWORD len = ARRAYSIZE(actual);
    if (!process) return false;
    bool ok = moon_path(expected,ARRAYSIZE(expected),engine_dir,L"WebKitWebProcess.exe") &&
        QueryFullProcessImageNameW(process,0,actual,&len) && !_wcsicmp(actual,expected) &&
        TerminateProcess(process,31);
    CloseHandle(process);
    return ok;
}
int moon_engine_test_download(MoonView *view, const char *path) {
    if (path) {
        test_download_result = 0;
        snprintf(test_download_path,sizeof(test_download_path),"%s",path);
    }
    int result = test_download_result;
    if (result) test_download_path[0] = 0;
    return result;
}
static void presentation(WKErrorRef error, void *opaque) {
    if (!error) moon_engine_event(MOON_PAINTED,(uint64_t)(uintptr_t)opaque,"presentation");
}
void moon_engine_probe(MoonView *view) {
    wk.WKPageCallAfterNextPresentationUpdate(view->page,(void *)(uintptr_t)view->token,presentation);
}
