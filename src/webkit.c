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
#include <WebKit/WKArray.h>
#include <WebKit/WKContextMenuItem.h>
#include <WebKit/WKHitTestResult.h>
#include <WebKit/WKNavigationActionRef.h>
#include <WebKit/WKNavigationResponseRef.h>
#include <WebKit/WKPage.h>
#include <WebKit/WKPageConfigurationRef.h>
#include <WebKit/WKPageNavigationClient.h>
#include <WebKit/WKPagePrivate.h>
#include <WebKit/WKPageResourceLoadClient.h>
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

extern void WKHTTPCookieStoreDeleteAllCookies(WKHTTPCookieStoreRef, void *, void (*)(void *));
extern WKStringRef WKFrameCopyMIMEType(WKFrameRef);
enum WKWebsiteAutoplayPolicy {
    kWKWebsiteAutoplayPolicyDefault, kWKWebsiteAutoplayPolicyAllow,
    kWKWebsiteAutoplayPolicyAllowWithoutSound, kWKWebsiteAutoplayPolicyDeny
};
extern WKWebsitePoliciesRef WKWebsitePoliciesCreate(void);
extern void WKWebsitePoliciesSetAutoplayPolicy(WKWebsitePoliciesRef, enum WKWebsiteAutoplayPolicy);

// Windows WebKit's C notification provider ABI, version 0.
typedef struct { int version; const void *clientInfo; } MoonWKNotificationProviderBase;
typedef struct {
    MoonWKNotificationProviderBase base;
    void (*show)(WKPageRef,WKNotificationRef,const void *);
    void (*cancel)(WKNotificationRef,const void *);
    void (*didDestroyNotification)(WKNotificationRef,const void *);
    void (*addNotificationManager)(WKNotificationManagerRef,const void *);
    void (*removeNotificationManager)(WKNotificationManagerRef,const void *);
    WKDictionaryRef (*notificationPermissions)(const void *);
    void (*clearNotifications)(WKArrayRef,const void *);
} MoonWKNotificationProviderV0;
extern WKNotificationManagerRef WKContextGetNotificationManager(WKContextRef);
extern void WKNotificationManagerSetProvider(WKNotificationManagerRef,const MoonWKNotificationProviderBase *);
extern void WKNotificationManagerProviderDidShowNotification(WKNotificationManagerRef,uint64_t);
extern void WKNotificationManagerProviderDidCloseNotifications(WKNotificationManagerRef,WKArrayRef);
extern void WKNotificationManagerProviderDidUpdateNotificationPolicy(WKNotificationManagerRef,WKSecurityOriginRef,bool);
extern void WKNotificationManagerProviderDidRemoveNotificationPolicies(WKNotificationManagerRef,WKArrayRef);
extern void WKNotificationPermissionRequestAllow(WKNotificationPermissionRequestRef);
extern void WKNotificationPermissionRequestDeny(WKNotificationPermissionRequestRef);
extern WKStringRef WKSecurityOriginCopyToString(WKSecurityOriginRef);
extern WKSecurityOriginRef WKSecurityOriginCreateFromString(WKStringRef);
extern WKStringRef WKNotificationCopyTitle(WKNotificationRef);
extern WKStringRef WKNotificationCopyBody(WKNotificationRef);
extern WKSecurityOriginRef WKNotificationGetSecurityOrigin(WKNotificationRef);
extern uint64_t WKNotificationGetID(WKNotificationRef);
extern bool WKNotificationGetIsPersistent(WKNotificationRef);
extern WKBooleanRef WKBooleanCreate(bool);
extern WKUInt64Ref WKUInt64Create(uint64_t);
extern WKDictionaryRef WKDictionaryCreate(const WKStringRef *, const WKTypeRef *, size_t);

#define WK_NOTIFICATION_FUNCTIONS(X) \
    X(WKContextGetNotificationManager) X(WKNotificationManagerSetProvider) \
    X(WKNotificationManagerProviderDidShowNotification) X(WKNotificationManagerProviderDidCloseNotifications) \
    X(WKNotificationManagerProviderDidUpdateNotificationPolicy) X(WKNotificationManagerProviderDidRemoveNotificationPolicies) \
    X(WKNotificationPermissionRequestAllow) X(WKNotificationPermissionRequestDeny) \
    X(WKSecurityOriginCopyToString) X(WKSecurityOriginCreateFromString) \
    X(WKNotificationCopyTitle) X(WKNotificationCopyBody) X(WKNotificationGetSecurityOrigin) \
    X(WKNotificationGetID) X(WKNotificationGetIsPersistent) X(WKBooleanCreate) X(WKUInt64Create) X(WKDictionaryCreate)

#define WK_FUNCTIONS(X) \
    X(WKRelease) X(WKGetTypeID) X(WKSessionStateGetTypeID) X(WKSessionStateCopyData) X(WKDataGetSize) \
    X(WKStringCreateWithUTF8CString) X(WKStringGetUTF8CString) X(WKStringIsEqualToUTF8CString) \
    X(WKURLCreateWithUTF8CString) X(WKURLCopyString) X(WKURLCopyScheme) X(WKURLRequestCopyURL) \
    X(WKURLRequestCopyHTTPMethod) X(WKURLResponseIsAttachment) X(WKURLResponseGetExpectedContentLength) X(WKURLResponseHTTPStatusCode) X(WKURLResponseCopyURL) \
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
    X(WKWebsiteDataStoreGetHTTPCookieStore) X(WKHTTPCookieStoreDeleteAllCookies) \
    X(WKWebsiteDataStoreRemoveLocalStorage) X(WKWebsiteDataStoreRemoveAllIndexedDatabases) \
    X(WKWebsiteDataStoreRemoveAllServiceWorkerRegistrations) X(WKWebsiteDataStoreRemoveAllFetchCaches) \
    X(WKWebsiteDataStoreRemoveNetworkCache) \
    X(WKPageConfigurationCreate) X(WKPageConfigurationSetContext) X(WKPageConfigurationSetWebsiteDataStore) \
    X(WKPageConfigurationSetPreferences) X(WKPreferencesCreate) X(WKPreferencesSetJavaScriptCanOpenWindowsAutomatically) \
    X(WKViewCreate) X(WKViewGetWindow) X(WKViewGetPage) X(WKViewSetIsInWindow) \
    X(WKPageSetPageNavigationClient) X(WKPageSetPageUIClient) X(WKPageSetPageStateClient) \
    X(WKPageSetPageContextMenuClient) X(WKArrayCreate) X(WKArrayGetSize) X(WKArrayGetItemAtIndex) \
    X(WKHitTestResultCopyAbsoluteLinkURL) X(WKHitTestResultCopyLinkLabel) \
    X(WKContextMenuItemCreateAsAction) X(WKContextMenuItemGetEnabled) X(WKContextMenuItemGetTag) X(WKContextMenuItemSeparatorItem) \
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
    X(WKInspectorIsVisible) X(WKInspectorIsAttached) X(WKInspectorAttach) X(WKInspectorDetach) X(WKInspectorClose) \
    X(WKInspectorIsElementSelectionActive) X(WKInspectorToggleElementSelection) \
    X(WKPageGetMainFrame) X(WKPageGetSourceForFrame) X(WKStringGetUTF8CStringNonStrict) \
    X(WKFrameCopyMIMEType) X(WKStringGetMaximumUTF8CStringSize) \
    X(WKPageGoBack) X(WKPageCanGoBack) X(WKPageGoForward) X(WKPageCanGoForward) X(WKPageReload) X(WKPageReloadFromOrigin) \
    X(WKPageSetPageFindClient) X(WKPageFindString) X(WKPageHideFindUI) \
    X(WKPageGetPageZoomFactor) X(WKPageSetPageZoomFactor) \
    X(WKPageCopySessionState) X(WKPageRestoreFromSessionState) X(WKPageGetProcessIdentifier) X(WKPageGetMediaState) X(WKPageSetMuted) \
    X(WKNavigationActionCopyRequest) X(WKNavigationActionShouldPerformDownload) X(WKNavigationActionCopyTargetFrameInfo) \
    X(WKNavigationActionGetNavigationType) X(WKNavigationActionHasUnconsumedUserGesture) \
    X(WKNavigationResponseCopyResponse) X(WKNavigationResponseCanShowMIMEType) \
    X(WKFramePolicyListenerUse) X(WKFramePolicyListenerIgnore) X(WKFramePolicyListenerDownload) \
    X(WKFramePolicyListenerUseWithPolicies) X(WKWebsitePoliciesCreate) X(WKWebsitePoliciesSetAutoplayPolicy) \
    X(WKErrorCopyLocalizedDescription) X(WKDownloadGetOriginatingPage) X(WKDownloadCopyRequest) X(WKDownloadCancel) \
    X(WKPageListenForLayoutMilestones) X(WKPageCallAfterNextPresentationUpdate) \
    X(WKPageSetCustomUserAgent)

static const char default_user_agent[] =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15";

static struct {
#define FIELD(name) __typeof__(&name) name;
    WK_FUNCTIONS(FIELD)
    WK_NOTIFICATION_FUNCTIONS(FIELD)
#undef FIELD
} wk;
static HMODULE module;
static WKContextRef context;
static WKWebsiteDataStoreRef store;
static WKNotificationManagerRef notification_manager;
static uint64_t notification_visible, next_notification;
static char notification_source[320];
static void (*delete_site_cookies)(WKWebsiteDataStoreRef, WKStringRef, bool, void *, void (*)(void *));
static void (*set_resource_load_client)(WKPageRef, WKPageResourceLoadClientBase *);
static WKUserContentControllerRef normal_page_content;
static DLL_DIRECTORY_COOKIE dll_directory;
static wchar_t engine_dir[2048];
static char engine_error[256];
static char test_download_path[4096];
static int test_download_result;
static bool filter_bundle_available;
static bool context_inspect_available;
static WKStringRef current_request_policy;

typedef enum { INSPECTOR_KEEP, INSPECTOR_DOCK, INSPECTOR_WINDOW } InspectorPlacement;
typedef enum { PICK_IDLE, PICK_WAIT_VISIBLE, PICK_STARTING, PICK_CANCEL_START, PICK_STOPPING } InspectorPicker;
static const wchar_t picker_state_property[]=L"MoonInspectorPickerState";

struct MoonView {
    WKViewRef view;
    WKPageRef page;
    WKPreferencesRef view_preferences;
    HWND surface, hwnd;
    MoonViewport viewport;
    char viewport_owner[96];
    WKInspectorRef inspector;
    InspectorPlacement inspector_placement;
    uint64_t inspector_deadline;
    InspectorPicker picker;
    uint64_t picker_deadline;
    unsigned picker_window_state;
    bool picker_blocked_press;
    bool docked, inspector_visible;
    bool tab_muted, site_muted;
    bool capture_network;
    unsigned document_playing;
    uint64_t media_observer;
    uint64_t token;
    uintptr_t extension_serial;
    WKUserContentControllerRef extension_controller;
    char extension_id[96];
    char *extension_address;
    struct MoonView *next;
};
static MoonView *views;
enum { LINK_COMMANDS = MOON_PLUGIN_LIMIT*MOON_LINK_MENU_STRIDE, LINK_MENU_GENERATIONS = 60 };
_Static_assert(kWKContextMenuItemBaseApplicationTag+LINK_COMMANDS*LINK_MENU_GENERATIONS <= UINT16_MAX,
    "Context menu command IDs must fit a Win32 menu command");
static MoonLinkContext link_context;
static unsigned link_menu_cycle, link_menu_base;
static bool link_items[LINK_COMMANDS];
static uintptr_t extension_sequence;
typedef struct {
    WKDownloadRef download;
    uint64_t token;
    uint32_t id;
    wchar_t *path;
} DownloadSlot;
static DownloadSlot downloads[64];
typedef enum { RETRY_LOADING, RETRY_CONVERTING, RETRY_TRANSFERRING, RETRY_DONE, RETRY_FAILED } RetryState;
static struct { MoonView *view; uint32_t id; uint64_t deadline; RetryState state; } download_retry;

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
static size_t capture_url(WKURLRef url, char *buffer, size_t cap) {
    WKStringRef value = url ? wk.WKURLCopyString(url) : NULL;
    if (!value) return 0;
    size_t bytes = wk.WKStringGetUTF8CString(value, buffer, cap);
    release(value);
    return bytes;
}
static void report_network_event(const void *client, WKURLResponseRef response, WKURLRef original, int kind) {
    MoonView *view = (MoonView *)client;
    if (!view->capture_network) return;
    char url[4096];
    WKURLRef resolved = response ? wk.WKURLResponseCopyURL(response) : NULL;
    size_t bytes = capture_url(resolved, url, sizeof(url));
    release(resolved);
    if (bytes <= 1) bytes = capture_url(original, url, sizeof(url));
    // An incomplete authority cannot be safely stripped of user information.
    if (bytes <= 1 || bytes >= sizeof(url) || url[bytes-1] != '\0') return;
    int status = response ? wk.WKURLResponseHTTPStatusCode(response) : 0;
    moon_network_capture_event(view, view->token, url, status >= 100 && status <= 599 ? (uint16_t)status : 0, kind);
}
static void capture_redirect(const void *client, WKPageRef page, WKURLResponseRef response, WKURLRequestRef next) {
    (void)page;
    (void)next;
    report_network_event(client, response, NULL, MOON_NETWORK_REDIRECT);
}
static void capture_completion(const void *client, WKPageRef page, WKURLRef original, WKURLResponseRef response, WKErrorRef error) {
    (void)page;
    report_network_event(client, response, original, error ? MOON_NETWORK_FAILED : MOON_NETWORK_COMPLETE);
}
bool moon_engine_supports_network_capture(void) {
    return set_resource_load_client != NULL;
}
bool moon_engine_network_capture(MoonView *view, bool enabled) {
    if (!set_resource_load_client || view->extension_address) return false;
    if (view->capture_network == enabled) return true;
    view->capture_network = enabled;
    WKPageResourceLoadClientV0 client = {
        .base = { .version = 0, .clientInfo = view },
        .didPerformRedirect = capture_redirect,
        .didCompleteWithError = capture_completion,
    };
    set_resource_load_client(view->page, enabled ? &client.base : NULL);
    return true;
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
static bool copy_retry_url(WKURLRef url,char target[4096]) {
    target[0]=0;
    WKStringRef text=url ? wk.WKURLCopyString(url) : NULL;
    release(url);
    const bool valid=text && wk.WKStringGetUTF8CString(text,target,4096)>1 &&
        wk.WKStringIsEqualToUTF8CString(text,target) && moon_download_source_allowed(target);
    release(text);
    if (!valid) target[0]=0;
    return valid;
}
static WKWebsitePoliciesRef media_policies(MoonView *view, WKNavigationActionRef action, WKURLRequestRef request) {
    const bool autoplay=moon_autoplay_rules_active(), sound=moon_site_sound_rules_active();
    if (!request || (!autoplay && !sound)) return NULL;
    WKFrameInfoRef frame=wk.WKNavigationActionCopyTargetFrameInfo(action);
    const bool main=frame && wk.WKFrameInfoGetIsMainFrame(frame);
    release(frame);
    if (!main) return NULL;
    char url[4096];
    copy_url(wk.WKURLRequestCopyURL(request),url,sizeof(url));
    // Mute before the new document starts. Restore sound at commit when leaving a muted site.
    if (sound && moon_site_sound_mutes(url)) moon_engine_site_mute(view,true);
    if (!autoplay) return NULL;
    enum WKWebsiteAutoplayPolicy policy;
    switch (moon_autoplay_mode(url)) {
        case MOON_AUTOPLAY_ALLOW: policy=kWKWebsiteAutoplayPolicyAllow; break;
        case MOON_AUTOPLAY_MUTED: policy=kWKWebsiteAutoplayPolicyAllowWithoutSound; break;
        case MOON_AUTOPLAY_BLOCK: policy=kWKWebsiteAutoplayPolicyDeny; break;
        default: return NULL;
    }
    WKWebsitePoliciesRef settings=wk.WKWebsitePoliciesCreate();
    if (settings) wk.WKWebsitePoliciesSetAutoplayPolicy(settings,policy);
    return settings;
}

static void navigation_action(WKPageRef page, WKNavigationActionRef action, WKFramePolicyListenerRef listener,
                              WKTypeRef user, const void *client) {
    WKURLRequestRef request = wk.WKNavigationActionCopyRequest(action);
    MoonView *view = (MoonView *)client;
    if (view==download_retry.view) {
        char url[4096];
        if (safe_method(request) && copy_retry_url(wk.WKURLRequestCopyURL(request),url)) wk.WKFramePolicyListenerUse(listener);
        else {
            download_retry.state=RETRY_FAILED;
            wk.WKFramePolicyListenerIgnore(listener);
        }
        release(request);
        return;
    }
    if (view->extension_address) {
        char url[4096];
        copy_url(request ? wk.WKURLRequestCopyURL(request) : NULL,url,sizeof(url));
        if (!strcmp(url,"about:blank") || !strcmp(url,view->extension_address)) {
            wk.WKFramePolicyListenerUse(listener);
        } else {
            const char *docs = "https://docs.browser.moonl.cloud/";
            bool market_link = !strcmp(view->extension_address,"moon://market/") &&
                (!strncmp(url,docs,strlen(docs)) || !strcmp(url,MOON_PLUGIN_MANAGER_ADDRESS));
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
    if (!allowed) wk.WKFramePolicyListenerIgnore(listener);
    else if (wk.WKNavigationActionShouldPerformDownload(action)) wk.WKFramePolicyListenerDownload(listener);
    else {
        WKWebsitePoliciesRef policies=media_policies(view,action,request);
        if (policies) wk.WKFramePolicyListenerUseWithPolicies(listener,policies);
        else wk.WKFramePolicyListenerUse(listener);
        release(policies);
    }
    release(request);
}
static void navigation_response(WKPageRef page, WKNavigationResponseRef response, WKFramePolicyListenerRef listener,
                                WKTypeRef user, const void *client) {
    WKURLResponseRef url_response = wk.WKNavigationResponseCopyResponse(response);
    bool download = (url_response && wk.WKURLResponseIsAttachment(url_response)) ||
        !wk.WKNavigationResponseCanShowMIMEType(response);
    if (client==download_retry.view) {
        const int32_t status=url_response ? wk.WKURLResponseHTTPStatusCode(url_response) : 0;
        char final_url[4096];
        download=download && status>=200 && status<300 && copy_retry_url(wk.WKURLResponseCopyURL(url_response),final_url);
        download_retry.state=download ? RETRY_CONVERTING : RETRY_FAILED;
        release(url_response);
        if (download) wk.WKFramePolicyListenerDownload(listener);
        else wk.WKFramePolicyListenerIgnore(listener);
        return;
    }
    release(url_response);
    if (download) wk.WKFramePolicyListenerDownload(listener);
    else wk.WKFramePolicyListenerUse(listener);
}
static void started(WKPageRef page, WKNavigationRef nav, WKTypeRef user, const void *client) {
    moon_engine_cancel_pick((MoonView *)client);
    emit(client, MOON_STARTED, NULL);
}
static bool send_site_request(MoonView *view,uint64_t request,const char *change,const char *channel);

static void committed(WKPageRef page, WKNavigationRef nav, WKTypeRef user, const void *client) {
    MoonView *view=(MoonView *)client;
    view->document_playing=0;
    ++view->media_observer;
    if (view->token) send_site_request(view,view->media_observer,"null","MoonObserveMedia");
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
    if (client==download_retry.view && download_retry.state==RETRY_LOADING) download_retry.state=RETRY_FAILED;
    char description[512];
    copy_string(error ? wk.WKErrorCopyLocalizedDescription(error) : NULL, description, sizeof(description));
    emit(client, MOON_FAILED, description);
}
static void changed(const void *client) { emit(client, MOON_CHANGED, NULL); }
static void terminated(WKPageRef page, WKProcessTerminationReason reason, const void *client) {
    MoonView *view=(MoonView *)client;
    view->document_playing=0;
    ++view->media_observer;
    if (client==download_retry.view && download_retry.state<RETRY_TRANSFERRING) download_retry.state=RETRY_FAILED;
    const char *detail;
    switch (reason) {
        case kWKProcessTerminationReasonExceededMemoryLimit: detail="memory_limit"; break;
        case kWKProcessTerminationReasonExceededCPULimit: detail="cpu_limit"; break;
        case kWKProcessTerminationReasonRequestedByClient: detail="client_request"; break;
        case kWKProcessTerminationReasonCrash: detail="crash"; break;
        default: detail="unknown"; break;
    }
    emit(client, MOON_TERMINATED, detail);
}
static void rendering(WKPageRef page, WKPageRenderingProgressEvents events, WKTypeRef user, const void *client) {
    if (events & WKPageRenderingProgressEventFirstVisuallyNonEmptyLayout)
        emit(client, MOON_PAINTED, "layout");
}
static bool copy_popup_url(WKURLRef url, char buffer[4100]) {
    WKStringRef string = url ? wk.WKURLCopyString(url) : NULL;
    const size_t size = string ? wk.WKStringGetUTF8CString(string,buffer,4100) : 0;
    release(string);
    release(url);
    return size > 1 && size <= 4096 && strlen(buffer)+1 == size;
}
static WKPageRef popup_requested(WKPageRef page, WKPageConfigurationRef config, WKNavigationActionRef action,
                                WKWindowFeaturesRef features, const void *client) {
    const MoonView *view = client;
    if (view->extension_address) return NULL;
    WKURLRequestRef request = wk.WKNavigationActionCopyRequest(action);
    if (request && supported_scheme(request) && safe_method(request)) {
        char target[4100], opener[4100];
        if (copy_popup_url(wk.WKURLRequestCopyURL(request),target) &&
            copy_popup_url(wk.WKPageCopyCommittedURL(page),opener))
            moon_web_popup(view->token,opener,target,wk.WKNavigationActionHasUnconsumedUserGesture(action));
    }
    release(request);
    return NULL;
}

static bool notification_origin(WKSecurityOriginRef origin, char buffer[320]) {
    WKStringRef string = origin ? wk.WKSecurityOriginCopyToString(origin) : NULL;
    if (!string) return false;
    const size_t size=wk.WKStringGetUTF8CString(string,buffer,320);
    release(string);
    return size>1 && size<320 && strlen(buffer)+1==size;
}

static bool notification_view_visible(const MoonView *view) {
    return view && !view->extension_address && IsWindowVisible(view->surface) && !IsIconic(moon_shell_window());
}

static void notification_requested(WKPageRef page, WKSecurityOriginRef origin,
    WKNotificationPermissionRequestRef request, const void *client) {
    const MoonView *view=client;
    char address[320];
    wk.WKRetain(request);
    if (notification_view_visible(view) && GetAncestor(GetForegroundWindow(),GA_ROOTOWNER)==moon_shell_window() &&
        notification_origin(origin,address) &&
        moon_notification_request(view->token,address))
        wk.WKNotificationPermissionRequestAllow(request);
    else
        wk.WKNotificationPermissionRequestDeny(request);
    release(request);
}

static WKDictionaryRef notification_permissions(const void *client) {
    WKStringRef keys[64];
    WKTypeRef values[ARRAYSIZE(keys)];
    size_t count=0;
    for (;count<ARRAYSIZE(keys);++count) {
        char origin[320];
        bool allowed;
        if (!moon_notification_rules(count,origin,sizeof(origin),&allowed)) break;
        keys[count]=wk.WKStringCreateWithUTF8CString(origin);
        values[count]=wk.WKBooleanCreate(allowed);
    }
    WKDictionaryRef result=wk.WKDictionaryCreate(keys,values,count);
    for (size_t i=0;i<count;++i) {
        release(keys[i]);
        release(values[i]);
    }
    return result;
}

static void notification_closed(uint64_t id) {
    WKTypeRef number=wk.WKUInt64Create(id);
    WKArrayRef identifiers=wk.WKArrayCreate(&number,1);
    wk.WKNotificationManagerProviderDidCloseNotifications(notification_manager,identifiers);
    release(identifiers);
    release(number);
}

static void notification_cancelled(WKNotificationRef notification, const void *client) {
    if (notification_visible==wk.WKNotificationGetID(notification)) {
        notification_visible=0;
        moon_shell_dismiss_website_notification();
    }
}

static void notification_toast_closed(void) {
    if (!notification_visible) return;
    const uint64_t id=notification_visible;
    notification_visible=0;
    if (notification_manager) notification_closed(id);
}

static void notification_line(WKStringRef source,char *text,size_t cap) {
    copy_string(source,text,cap);
    for (char *p=text;*p;++p) {
        if ((unsigned char)*p<32 || *p==127) *p=' ';
    }
}

static void notification_show(WKPageRef page, WKNotificationRef notification, const void *client) {
    const uint64_t id=wk.WKNotificationGetID(notification);
    const MoonView *view=views;
    while (view && view->page!=page) view=view->next;
    const uint64_t now=moon_clock();
    char origin[320];
    if (now<next_notification || wk.WKNotificationGetIsPersistent(notification) ||
        !notification_view_visible(view) || !notification_origin(wk.WKNotificationGetSecurityOrigin(notification),origin) ||
        !moon_notification_display_allowed(view->token,origin)) {
        notification_closed(id);
        return;
    }
    char title[170],body[360],description[560];
    notification_line(wk.WKNotificationCopyTitle(notification),title,sizeof(title));
    notification_line(wk.WKNotificationCopyBody(notification),body,sizeof(body));
    snprintf(description,sizeof(description),"%s%s%s",title,body[0] && title[0] ? "\n" : "",body);
    if (!moon_shell_website_notification(origin,description,notification_toast_closed)) {
        notification_closed(id);
        return;
    }
    strcpy(notification_source,origin);
    notification_visible=id;
    next_notification=now+4500;
    wk.WKNotificationManagerProviderDidShowNotification(notification_manager,id);
}

bool moon_engine_notifications_available(void) { return notification_manager!=NULL; }

void moon_engine_notification_policy(const char *origin, unsigned mode) {
    if (!notification_manager) return;
    if (mode!=MOON_NOTIFICATION_ALLOW && notification_visible && strcmp(origin,notification_source)==0)
        moon_shell_dismiss_website_notification();
    WKStringRef address=wk.WKStringCreateWithUTF8CString(origin);
    WKSecurityOriginRef key=wk.WKSecurityOriginCreateFromString(address);
    release(address);
    if (!key) return;
    if (mode==MOON_NOTIFICATION_ASK) {
        WKTypeRef element=key;
        WKArrayRef origins=wk.WKArrayCreate(&element,1);
        wk.WKNotificationManagerProviderDidRemoveNotificationPolicies(notification_manager,origins);
        release(origins);
    } else {
        wk.WKNotificationManagerProviderDidUpdateNotificationPolicy(notification_manager,key,mode==MOON_NOTIFICATION_ALLOW);
    }
    release(key);
}
static DownloadSlot *download_slot(WKDownloadRef download) {
    for (size_t i=0;i<ARRAYSIZE(downloads);++i) {
        if (downloads[i].download == download) return &downloads[i];
    }
    return NULL;
}
static void download_started(WKContextRef unused, WKDownloadRef download, const void *client) {
    WKPageRef page = wk.WKDownloadGetOriginatingPage(download);
    const bool retry = download_retry.view && page==download_retry.view->page;
    if (retry && download_retry.state!=RETRY_CONVERTING) return;
    DownloadSlot *slot=download_slot(NULL);
    if (!slot) {
        if (retry) download_retry.state=RETRY_FAILED;
        return;
    }
    char source[4096]={0};
    if (!retry) {
        WKURLRequestRef request=wk.WKDownloadCopyRequest(download);
        if (safe_method(request)) copy_retry_url(wk.WKURLRequestCopyURL(request),source);
        release(request);
    }
    *slot=(DownloadSlot){ .download=download,.id=retry ? download_retry.id : moon_download_begin(source) };
    if (retry) {
        download_retry.state=RETRY_TRANSFERRING;
        return;
    }
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
    free(result.path);
    if (download_retry.view && result.id==download_retry.id) download_retry.state=RETRY_DONE;
    if (result.id) moon_download_finish(result.id,state);
    if (*test_download_path) test_download_result = state==MOON_DL_COMPLETE ? 1 : -1;
    if (result.token) moon_engine_event(MOON_DOWNLOAD_END,result.token,detail);
}
static bool download_filename_valid(const wchar_t *name) {
    const size_t length=wcslen(name);
    if (!length || length>255 || name[length-1]==L' ' || name[length-1]==L'.' ||
        wcspbrk(name,L"\\/:*?\"<>|")) return false;
    for (const wchar_t *letter=name;*letter;++letter)
        if (*letter<32 || *letter==127 || (*letter>=0x202a && *letter<=0x202e) ||
            (*letter>=0x2066 && *letter<=0x2069)) return false;
    const wchar_t *dot=wcschr(name,L'.');
    size_t stem=dot?(size_t)(dot-name):length;
    while (stem && name[stem-1]==L' ') --stem;
    static const wchar_t *const devices[]={ L"CON",L"PRN",L"AUX",L"NUL",L"CLOCK$",L"CONIN$",L"CONOUT$" };
    for (size_t i=0;i<ARRAYSIZE(devices);++i)
        if (wcslen(devices[i])==stem && !_wcsnicmp(name,devices[i],stem)) return false;
    return stem!=4 || (_wcsnicmp(name,L"COM",3) && _wcsnicmp(name,L"LPT",3)) ||
        !wcschr(L"123456789\u00b9\u00b2\u00b3",name[3]);
}

static bool remember_download_path(DownloadSlot *slot,const wchar_t *path) {
    const size_t bytes=(wcslen(path)+1)*sizeof(*path);
    wchar_t *copy=malloc(bytes);
    if (!copy) return false;
    memcpy(copy,path,bytes);
    free(slot->path);
    slot->path=copy;
    return true;
}

static bool automatic_download_path(DownloadSlot *slot,const wchar_t *folder,const wchar_t *name,wchar_t *path,size_t capacity) {
    const DWORD attributes=GetFileAttributesW(folder);
    if (!slot || attributes==INVALID_FILE_ATTRIBUTES || !(attributes&FILE_ATTRIBUTE_DIRECTORY)) return false;
    const bool drive=folder[0] && folder[1]==L':' && folder[2]==L'\\';
    const bool unc=folder[0]==L'\\' && folder[1]==L'\\' && folder[2]!=L'.' && folder[2]!=L'?';
    if (!drive && !unc) return false;
    const wchar_t *separator=folder[wcslen(folder)-1]==L'\\'?L"":L"\\";
    const wchar_t *extension=wcsrchr(name,L'.');
    if (!extension || extension==name) extension=name+wcslen(name);
    const int stem=(int)(extension-name);
    for (unsigned number=0;number<100;++number) {
        if (number && wcslen(name)+(number>=10?5:4)>255) return false;
        int written=number ? swprintf(path,capacity,L"%ls%ls%.*ls (%u)%ls",folder,separator,stem,name,number,extension) :
            swprintf(path,capacity,L"%ls%ls%ls",folder,separator,name);
        if (written<0 || (size_t)written>=capacity) return false;
        if (GetFileAttributesW(path)!=INVALID_FILE_ATTRIBUTES) continue;
        if (GetLastError()!=ERROR_FILE_NOT_FOUND) return false;
        bool reserved=false;
        for (size_t i=0;i<ARRAYSIZE(downloads);++i)
            if (downloads[i].path && CompareStringOrdinal(downloads[i].path,-1,path,-1,TRUE)==CSTR_EQUAL) {
                reserved=true;
                break;
            }
        if (!reserved) return remember_download_path(slot,path);
    }
    return false;
}

static WKStringRef download_destination(WKContextRef unused, WKDownloadRef download, WKStringRef suggested,
                                         bool *overwrite, const void *client) {
    if (*test_download_path) {
        *overwrite = false;
        DownloadSlot *slot=download_slot(download);
        if (slot && slot->id) moon_download_destination(slot->id,test_download_path);
        return wk.WKStringCreateWithUTF8CString(test_download_path);
    }
    char suggested_utf8[1024] = {0}, path_utf8[8192], preference[4096];
    wchar_t name[1024], path[4096], folder[4096];
    const size_t bytes=suggested ? wk.WKStringGetUTF8CString(suggested,suggested_utf8,sizeof(suggested_utf8)) : 0;
    const bool safe_name=bytes>1 && bytes<sizeof(suggested_utf8) && strlen(suggested_utf8)+1==bytes &&
        moon_utf16(suggested_utf8,name,ARRAYSIZE(name)) && download_filename_valid(name);
    bool ask=true;
    const bool has_folder=moon_download_folder(preference,sizeof(preference),&ask) &&
        moon_utf16(preference,folder,ARRAYSIZE(folder));
    if (!ask && safe_name && has_folder &&
        automatic_download_path(download_slot(download),folder,name,path,ARRAYSIZE(path)) &&
        moon_utf8(path,path_utf8,sizeof(path_utf8))) {
        *overwrite=false;
        DownloadSlot *slot=download_slot(download);
        if (slot && slot->id) moon_download_destination(slot->id,path_utf8);
        return wk.WKStringCreateWithUTF8CString(path_utf8);
    }
    wcscpy(path,safe_name?name:L"download");
    OPENFILENAMEW dialog = { .lStructSize = sizeof(dialog), .hwndOwner = moon_shell_window(),
        .lpstrFile = path, .nMaxFile = ARRAYSIZE(path), .lpstrTitle = L"保存下载",
        .lpstrInitialDir=has_folder?folder:NULL,
        .Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER |
            (moon_shell_private() ? OFN_DONTADDTORECENT : 0) };
    if (!GetSaveFileNameW(&dialog) || !moon_utf8(path,path_utf8,sizeof(path_utf8))) {
        finish_download(download,MOON_DL_CANCELLED,NULL);
        return NULL;
    }
    *overwrite = true;
    DownloadSlot *slot=download_slot(download);
    if (slot) (void)remember_download_path(slot,path);
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
    bool has_notifications=true;
#define RESOLVE_OPTIONAL(name) wk.name=(__typeof__(wk.name))GetProcAddress(module,#name); \
    if (!wk.name) has_notifications=false;
    WK_NOTIFICATION_FUNCTIONS(RESOLVE_OPTIONAL)
#undef RESOLVE_OPTIONAL
    delete_site_cookies = (__typeof__(delete_site_cookies))GetProcAddress(module,"WKWebsiteDataStoreStatisticsDeleteCookiesForTesting");
    set_resource_load_client = (__typeof__(set_resource_load_client))GetProcAddress(module,"WKPageSetResourceLoadClient");
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
    if (has_notifications && !moon_shell_private()) {
        notification_manager=wk.WKContextGetNotificationManager(context);
        if (notification_manager) {
            const MoonWKNotificationProviderV0 provider={
                .base={0,NULL},.show=notification_show,.cancel=notification_cancelled,
                .didDestroyNotification=notification_cancelled,.notificationPermissions=notification_permissions,
            };
            wk.WKNotificationManagerSetProvider(notification_manager,&provider.base);
        }
    }
    if (filter_bundle_available) {
        const WKContextInjectedBundleClientV1 client = {
            .base={1,NULL},.getInjectedBundleInitializationUserData=initial_request_policy,
        };
        wk.WKContextSetInjectedBundleClient(context,&client.base);
    }
    wk.WKContextSetCacheModel(context,kWKCacheModelDocumentBrowser);
    normal_page_content = wk.WKUserContentControllerCreate();
    if (!normal_page_content) return "Could not create content controller.";

    if (moon_shell_private()) {
        store = wk.WKWebsiteDataStoreCreateNonPersistentDataStore();
    } else {
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
    }
    if (!store) return "Could not open website data.";
    WKContextDownloadClientV0 client = { .base={0,NULL}, .didStart=download_started,
        .didReceiveResponse=download_response,.didReceiveData=download_data,
        .decideDestinationWithSuggestedFilename=download_destination,.didFinish=download_finished,
        .didFail=download_failed,.didCancel=download_cancelled,.processDidCrash=download_crashed };
    wk.WKContextSetDownloadClient(context,&client.base);
    return NULL;
}
void moon_engine_shutdown(void) {
    notification_visible=0;
    if (context) {
        wk.WKContextSetDownloadClient(context,NULL);
        if (filter_bundle_available) wk.WKContextSetInjectedBundleClient(context,NULL);
    }
    if (download_retry.view) moon_engine_close(download_retry.view);
    download_retry.view=NULL;
    release(current_request_policy);
    current_request_policy = NULL;
    if (store) release(store);
    if (context) release(context);
    store = NULL; context = NULL; notification_manager=NULL;
    for (size_t i=0;i<ARRAYSIZE(downloads);++i) {
        free(downloads[i].path);
        downloads[i].path=NULL;
    }
    // WK's run loop can have posted completion callbacks. Let Windows unload
    // the DLL on process exit after the UI message pump has stopped.
}
typedef enum { EXTENSION_SETTINGS, EXTENSION_HOST, PLUGIN_MANAGER } ExtensionChannel;

static void extension_message(WKScriptMessageRef message, WKCompletionListenerRef reply, const void *context, ExtensionChannel channel) {
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
        if (bytes && bytes < sizeof(request) && strlen(request)+1 == bytes) {
            if (channel == PLUGIN_MANAGER) {
                if (!view->extension_id[0] && view->extension_address && !strcmp(view->extension_address,MOON_PLUGIN_MANAGER_ADDRESS))
                    ok = moon_plugins_request(view->token,request,response,sizeof(response));
            } else if (view->extension_id[0]) {
                ok = channel == EXTENSION_SETTINGS ? moon_extension_settings(view->extension_id,request,response,sizeof(response)) :
                    moon_extension_request(view->token,view->extension_id,request,response,sizeof(response));
            }
        }
    }
    WKStringRef value = wk.WKStringCreateWithUTF8CString(ok ? response : "{\"ok\":false}");
    wk.WKCompletionListenerComplete(reply,value);
    release(value);
}
static void settings_message(WKScriptMessageRef message, WKCompletionListenerRef reply, const void *context) {
    extension_message(message,reply,context,EXTENSION_SETTINGS);
}
static void plugin_message(WKScriptMessageRef message, WKCompletionListenerRef reply, const void *context) {
    extension_message(message,reply,context,EXTENSION_HOST);
}
static void plugin_manager_message(WKScriptMessageRef message, WKCompletionListenerRef reply, const void *context) {
    extension_message(message,reply,context,PLUGIN_MANAGER);
}
static bool add_message_handler(MoonView *view, const char *name, WKScriptMessageHandlerCallback callback) {
    WKStringRef channel = wk.WKStringCreateWithUTF8CString(name);
    if (!channel) return false;
    wk.WKUserContentControllerAddScriptMessageHandler(view->extension_controller,channel,callback,
        (const void *)view->extension_serial);
    release(channel);
    return true;
}

static size_t web_link_menu(MoonView *view,WKHitTestResultRef hit,WKTypeRef *items,MoonLinkContext *link,
                            bool *replace_open,bool *replace_copy) {
    WKURLRef url=wk.WKHitTestResultCopyAbsoluteLinkURL(hit);
    WKStringRef text=url ? wk.WKURLCopyString(url) : NULL;
    const size_t bytes=text ? wk.WKStringGetUTF8CString(text,link->url,sizeof(link->url)) : 0;
    release(text);
    release(url);
    if (bytes<=1 || bytes>=sizeof(link->url) || strlen(link->url)+1!=bytes || !moon_link_capture(link,view->token)) return 0;
    WKStringRef label=wk.WKHitTestResultCopyLinkLabel(hit);
    if (label) wk.WKStringGetUTF8CStringNonStrict(label,link->label,sizeof(link->label));
    release(label);

    link_menu_cycle = (link_menu_cycle+1)%LINK_MENU_GENERATIONS;
    link_menu_base = kWKContextMenuItemBaseApplicationTag+link_menu_cycle*LINK_COMMANDS;
    memset(link_items,0,sizeof(link_items));
    size_t used=0;
    for (unsigned kind=MOON_LINK_OPEN;kind<=MOON_LINK_BOOKMARK;++kind) {
        for (size_t plugin=0;plugin<moon_plugin_count();++plugin) {
            for (size_t command=0;command<moon_plugin_action_count(plugin);++command) {
                if (moon_plugin_link_action(plugin,command)!=kind) continue;
                const size_t index=plugin*MOON_LINK_MENU_STRIDE+command;
                WKStringRef title=wk.WKStringCreateWithUTF8CString(moon_plugin_action(plugin,command));
                WKContextMenuItemRef item=title ? wk.WKContextMenuItemCreateAsAction(link_menu_base+(unsigned)index,title,true) : NULL;
                release(title);
                if (!item) continue;
                link_items[index]=true;
                items[used++]=item;
                *replace_open |= kind==MOON_LINK_OPEN;
                *replace_copy |= kind==MOON_LINK_COPY;
            }
        }
    }
    return used;
}

static void web_context_menu(WKPageRef page,WKArrayRef proposed,WKArrayRef *result,WKHitTestResultRef hit,
                             WKTypeRef data,const void *client) {
    MoonView *view=(MoonView *)client;
    link_context.tab_id=0;
    const size_t existing=wk.WKArrayGetSize(proposed);
    if (existing>256) {
        *result=(WKArrayRef)wk.WKRetain(proposed);
        return;
    }
    WKTypeRef items[LINK_COMMANDS+257];
    MoonLinkContext current={0};
    bool replace_open=false, replace_copy=false;
    const size_t created=view->extension_address ? 0 : web_link_menu(view,hit,items,&current,&replace_open,&replace_copy);
    size_t used=created;
    const char *inspect_label=context_inspect_available ? moon_context_inspect_label(view->token) : NULL;
    const char *highlight_label=moon_context_highlight_label(view->token);
    WKContextMenuItemRef inspect_item=NULL, highlight_item=NULL;
    WKContextMenuItemRef separator=created ? wk.WKContextMenuItemSeparatorItem() : NULL;
    for (size_t i=0;i<existing;++i) {
        WKContextMenuItemRef item=(WKContextMenuItemRef)wk.WKArrayGetItemAtIndex(proposed,i);
        if (!item) continue;
        WKContextMenuItemTag tag=wk.WKContextMenuItemGetTag(item);
        if ((replace_open && tag==kWKContextMenuItemTagOpenLinkInNewWindow) ||
            (replace_copy && tag==kWKContextMenuItemTagCopyLinkToClipboard)) continue;
        if (tag==kWKContextMenuItemTagNoAction) {
            if (used) separator=item;
            continue;
        }
        if (tag==kWKContextMenuItemTagInspectElement) {
            if (!inspect_label || inspect_item) continue;
            WKStringRef title=wk.WKStringCreateWithUTF8CString(inspect_label);
            inspect_item=title ? wk.WKContextMenuItemCreateAsAction(tag,title,true) : NULL;
            release(title);
            if (!inspect_item) continue;
            view->inspector=wk.WKPageGetInspector(view->page);
            if (!view->inspector) continue;
            item=inspect_item;
        } else if (tag==kWKContextMenuItemTagCopyLinkWithHighlight) {
            if (!highlight_label || highlight_item) continue;
            WKStringRef title=wk.WKStringCreateWithUTF8CString(highlight_label);
            highlight_item=title ? wk.WKContextMenuItemCreateAsAction(tag,title,wk.WKContextMenuItemGetEnabled(item)) : NULL;
            release(title);
            if (!highlight_item) continue;
            item=highlight_item;
        }
        if (separator) items[used++]=separator;
        separator=NULL;
        items[used++]=item;
    }
    *result=(!created && !inspect_item && !highlight_item && used==existing) ? (WKArrayRef)wk.WKRetain(proposed) : wk.WKArrayCreate(items,used);
    for (size_t i=0;i<created;++i) release(items[i]);
    release(inspect_item);
    release(highlight_item);
    if (*result && created) link_context=current;
}

static void web_context_selected(WKPageRef page,WKContextMenuItemRef item,const void *client) {
    const MoonView *view=client;
    const WKContextMenuItemTag tag=wk.WKContextMenuItemGetTag(item);
    if (link_context.tab_id!=view->token || tag<link_menu_base || tag>=link_menu_base+LINK_COMMANDS) return;
    const unsigned index=tag-link_menu_base;
    if (!link_items[index]) return;
    const MoonLinkContext selected=link_context;
    link_context.tab_id=0;
    moon_link_menu_run(&selected,index/MOON_LINK_MENU_STRIDE,index%MOON_LINK_MENU_STRIDE);
}
static void site_snapshot_received(WKPageRef page,WKStringRef name,WKTypeRef body,const void *context) {
    MoonView *view=(MoonView *)context;
    const bool catalog=wk.WKStringIsEqualToUTF8CString(name,"MoonSiteCatalog");
    const bool reader=wk.WKStringIsEqualToUTF8CString(name,"MoonArticleSnapshot");
    const bool cache=wk.WKStringIsEqualToUTF8CString(name,"MoonSiteCacheRemoval");
    const bool database=wk.WKStringIsEqualToUTF8CString(name,"MoonSiteDatabase");
    const bool media=wk.WKStringIsEqualToUTF8CString(name,"MoonMediaResult");
    const bool activity=wk.WKStringIsEqualToUTF8CString(name,"MoonMediaActivity");
    const bool storage=wk.WKStringIsEqualToUTF8CString(name,"MoonStoragePage");
    if ((!catalog && !reader && !cache && !database && !media && !activity && !storage && !wk.WKStringIsEqualToUTF8CString(name,"MoonSiteSnapshot")) || !body ||
        wk.WKGetTypeID(body)!=wk.WKStringGetTypeID()) return;
    const size_t cap=(cache || media || activity ? 1 : database ? 20 : reader ? 192 : catalog ? 64 : storage ? 128 : 512)*1024+32;
    char *response=malloc(cap);
    if (!response) return;
    const size_t n=wk.WKStringGetUTF8CString((WKStringRef)body,response,cap);
    if (n && n<cap && strlen(response)+1==n) {
        char *end=NULL;
        const uint64_t request=strtoull(response,&end,10);
        if (end!=response && *end=='\n') {
            if (reader) moon_reader_result(view->token,request,end+1);
            else if (cache) moon_site_cache_result(view,view->token,request,end+1);
            else if (database) moon_site_database_result(view,view->token,request,end+1);
            else if (storage) moon_site_storage_page_result(view->token,request,end+1);
            else if (media) moon_media_action_result(view->token,request,end+1);
            else if (activity) {
                const char *flags=end+1;
                if (request==view->media_observer && strlen(flags)==13 && !strncmp(flags,"{\"playing\":",11) &&
                    flags[11]>='0' && flags[11]<='3' && flags[12]=='}') view->document_playing=flags[11]-'0';
            }
            else moon_site_data_result(view->token,request,end+1,catalog);
        }
    }
    free(response);
}
static bool send_site_request(MoonView *view,uint64_t request,const char *change,const char *channel) {
    if (!filter_bundle_available || !view || view->extension_address) return false;
    char url[4096];
    moon_engine_committed_url(view,url,sizeof(url));
    if (!*url) return false;
    const size_t capacity=strlen(change)+strlen(url)+32;
    char *payload=malloc(capacity);
    if (!payload) return false;
    const int length=snprintf(payload,capacity,"%" PRIu64 "\n%s\n%s",request,url,change);
    if (length<0 || (size_t)length>=capacity) { free(payload); return false; }
    WKStringRef name=wk.WKStringCreateWithUTF8CString(channel);
    WKStringRef body=wk.WKStringCreateWithUTF8CString(payload);
    free(payload);
    const bool ok=name && body;
    if (ok) wk.WKPagePostMessageToInjectedBundle(view->page,name,body);
    release(body);
    release(name);
    return ok;
}
bool moon_engine_inspect_site(MoonView *view,uint64_t request) {
    return send_site_request(view,request,"null","MoonInspectSite");
}
bool moon_engine_inspect_storage_page(MoonView *view,uint64_t request,const char *query) {
    return send_site_request(view,request,query,"MoonInspectStoragePage");
}
bool moon_engine_inspect_catalog(MoonView *view,uint64_t request) {
    return send_site_request(view,request,"null","MoonInspectCatalog");
}
bool moon_engine_update_site(MoonView *view,uint64_t request,const char *update) {
    return send_site_request(view,request,update,"MoonInspectSite");
}
bool moon_engine_read_article(MoonView *view,uint64_t request,const char *script) {
    return send_site_request(view,request,script,"MoonReadArticle");
}
bool moon_engine_remove_site_cache(MoonView *view,uint64_t request,const char *change) {
    return send_site_request(view,request,change,"MoonRemoveSiteCache");
}
bool moon_engine_inspect_database(MoonView *view,uint64_t request,const char *query) {
    return send_site_request(view,request,query,"MoonInspectDatabase");
}
bool moon_engine_apply_lua_dom(MoonView *view,const char *operations) {
    return send_site_request(view,0,operations,"MoonApplyLuaDOM");
}
bool moon_engine_media_actions_available(void) { return filter_bundle_available; }
bool moon_engine_media_action(MoonView *view,uint64_t request,const char *action) {
    return send_site_request(view,request,action,"MoonControlMedia");
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
        const bool manager = !extension_id && !strcmp(address,MOON_PLUGIN_MANAGER_ADDRESS);
        if (extension_id || manager) {
            view->extension_controller = wk.WKUserContentControllerCreate();
            if (!view->extension_controller) goto fail;
            view->extension_serial = ++extension_sequence;
            if (manager) {
                if (!add_message_handler(view,"moonPlugins",plugin_manager_message)) goto fail;
            } else {
                if (strlen(extension_id)>=sizeof(view->extension_id)) goto fail;
                strcpy(view->extension_id,extension_id);
                if (!add_message_handler(view,"moonSettings",settings_message) ||
                    !add_message_handler(view,"moonHost",plugin_message)) goto fail;
            }
            wk.WKPageConfigurationSetUserContentController(config,view->extension_controller);
        }
    } else {
        wk.WKPageConfigurationSetWebsiteDataStore(config,store);
        wk.WKPageConfigurationSetUserContentController(config,normal_page_content);
    }
    view->view_preferences = wk.WKPreferencesCreate();
    if (!view->view_preferences) goto fail;
    // WebKit forwards scripted requests to our native policy, which decides whether to open a tab.
    wk.WKPreferencesSetJavaScriptCanOpenWindowsAutomatically(view->view_preferences,address==NULL);
    if (!address && context_inspect_available) wk.WKPreferencesSetDeveloperExtrasEnabled(view->view_preferences,true);
    wk.WKPageConfigurationSetPreferences(config,view->view_preferences);
    RECT bounds={0};
    HWND parent = moon_shell_content();
    GetClientRect(parent,&bounds);
    view->surface = CreateWindowExW(0,L"Static",NULL,WS_CHILD|WS_CLIPCHILDREN|WS_CLIPSIBLINGS,
        0,0,bounds.right,bounds.bottom,parent,NULL,GetModuleHandleW(NULL),NULL);
    if (!view->surface) goto fail;
    view->view = wk.WKViewCreate(bounds,config,view->surface);
    if (!view->view) goto fail;
    view->page = wk.WKViewGetPage(view->view);
    view->hwnd = wk.WKViewGetWindow(view->view);
    view->token = token;
    if (!view->page || !view->hwnd) goto fail;
    release(config);
    if (!address) {
        WKStringRef ua = wk.WKStringCreateWithUTF8CString(default_user_agent);
        if (ua) {
            wk.WKPageSetCustomUserAgent(view->page, ua);
            release(ua);
        }
    }
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
    WKPageUIClientV6 ui = { .base={6,view}, .createNewPage=popup_requested };
    if (!address && notification_manager) ui.decidePolicyForNotificationPermissionRequest=notification_requested;
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
    if (!address) {
        const WKPageContextMenuClientV2 menu = { .base={2,view},
            .getContextMenuFromProposedMenu=web_context_menu,.customContextMenuItemSelected=web_context_selected };
        wk.WKPageSetPageContextMenuClient(view->page,&menu.base);
    }
    wk.WKPageListenForLayoutMilestones(view->page,kWKDidFirstVisuallyNonEmptyLayout);
    wk.WKViewSetIsInWindow(view->view,true);
    ShowWindow(view->hwnd,IsWindowVisible(view->surface) ? SW_SHOWNA : SW_HIDE);
    return view;
fail:
    release(config);
    release(view->view);
    if (view->surface) DestroyWindow(view->surface);
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
    char appearance[80];
    snprintf(appearance,sizeof(appearance),"<!doctype html><html data-moon-theme=%s data-moon-focus-mode=%s>",
        moon_shell_dark_mode()?"dark":"light",moon_shell_focus_mode()?"true":"false");
    size_t size = sizeof(policy)+strlen(appearance)+strlen(html);
    char *document = malloc(size);
    if (!document) return false;
    snprintf(document,size,"%s%s%s",appearance,policy,html);
    WKStringRef source = wk.WKStringCreateWithUTF8CString(document);
    WKURLRef base = wk.WKURLCreateWithUTF8CString(view->extension_address);
    free(document);
    bool ok = source && base;
    if (ok) wk.WKPageLoadHTMLString(view->page,source,base);
    release(source);
    release(base);
    return ok;
}
void moon_engine_refresh_extension_appearance(void) {
    char script[160];
    snprintf(script,sizeof(script),"Object.assign(document.documentElement.dataset,{moonTheme:'%s',moonFocusMode:'%s'})",
        moon_shell_dark_mode()?"dark":"light",moon_shell_focus_mode()?"true":"false");
    for (MoonView *view=views; view; view=view->next) {
        if (view->viewport.bar) RedrawWindow(view->surface,NULL,NULL,RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN);
        if (view->extension_address) moon_engine_apply_dom(view,script);
    }
}
void moon_engine_close(MoonView *view) {
    MoonView **link = &views;
    while (*link && *link != view) link = &(*link)->next;
    if (*link) *link = view->next;
    if (view->extension_controller) {
        wk.WKUserContentControllerRemoveAllUserMessageHandlers(view->extension_controller);
        release(view->extension_controller);
    }
    if (view->capture_network) moon_engine_network_capture(view, false);
    wk.WKPageSetPageStateClient(view->page,NULL);
    wk.WKPageSetPageNavigationClient(view->page,NULL);
    wk.WKPageSetPageUIClient(view->page,NULL);
    if (link_context.tab_id==view->token) link_context.tab_id=0;
    if (!view->extension_address) wk.WKPageSetPageContextMenuClient(view->page,NULL);
    wk.WKPageSetPageFindClient(view->page,NULL);
    if (!view->extension_address && filter_bundle_available) wk.WKPageSetPageInjectedBundleClient(view->page,NULL);
    if (view->inspector) wk.WKInspectorClose(view->inspector);
    if (view->picker_window_state) RemovePropW(view->hwnd,picker_state_property);
    moon_viewport_close(&view->viewport);
    wk.WKPageClose(view->page);
    DestroyWindow(view->surface);
    release(view->view);
    release(view->view_preferences);
    free(view->extension_address);
    free(view);
}
void moon_engine_show(MoonView *view, bool visible) {
    // Hiding a tab changes WebKit's visibility, while its WebView remains attached to the window.
    if (!visible) {
        moon_engine_cancel_pick(view);
        ShowWindow(view->hwnd,SW_HIDE);
    }
    ShowWindow(view->surface,visible ? SW_SHOWNA : SW_HIDE);
    if (visible) {
        ShowWindow(view->hwnd,SW_SHOWNA);
        if (GetForegroundWindow()==moon_shell_window()) SetFocus(view->hwnd);
    }
}
bool moon_engine_load(MoonView *view, const char *url) {
    WKURLRef target_url = wk.WKURLCreateWithUTF8CString(url);
    if (!target_url) return false;
    wk.WKPageLoadURL(view->page,target_url);
    release(target_url);
    return true;
}
bool moon_engine_retry_available(void) { return !download_retry.view && download_slot(NULL)!=NULL; }
bool moon_engine_retry_download(uint32_t id, const char *url) {
    if (!moon_engine_retry_available() || !moon_download_source_allowed(url)) return false;
    MoonView *view=open_view(0,NULL,NULL);
    if (!view) return false;
    download_retry.view=view;
    download_retry.id=id;
    download_retry.deadline=moon_clock()+30000;
    download_retry.state=RETRY_LOADING;
    if (moon_engine_load(view,url)) return true;
    download_retry.view=NULL;
    moon_engine_close(view);
    return false;
}
void moon_engine_retry_poll(uint64_t now) {
    MoonView *view=download_retry.view;
    if (!view || download_retry.state==RETRY_TRANSFERRING) return;
    if (download_retry.state<RETRY_DONE && now<download_retry.deadline) return;
    if (download_retry.state!=RETRY_DONE) moon_download_finish(download_retry.id,MOON_DL_FAILED);
    download_retry.view=NULL;
    moon_engine_close(view);
}
void moon_engine_back(MoonView *view) { if (wk.WKPageCanGoBack(view->page)) wk.WKPageGoBack(view->page); }
void moon_engine_forward(MoonView *view) { if (wk.WKPageCanGoForward(view->page)) wk.WKPageGoForward(view->page); }
void moon_engine_reload(MoonView *view) { wk.WKPageReload(view->page); }
void moon_engine_reload_from_origin(MoonView *view) { wk.WKPageReloadFromOrigin(view->page); }
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
static void resize_view(MoonView *view, bool dpi_changed);
static void set_page_zoom(MoonView *view,double factor) {
    if (factor!=wk.WKPageGetPageZoomFactor(view->page)) wk.WKPageSetPageZoomFactor(view->page,factor);
}

void moon_engine_set_zoom(MoonView *view, unsigned percent) {
    if (view->viewport.bar) {
        if (view->viewport.page_zoom==percent) return;
        view->viewport.page_zoom=percent;
        resize_view(view,false);
    } else {
        set_page_zoom(view,percent/100.0);
    }
}
unsigned moon_engine_zoom(MoonView *view) {
    if (view->viewport.bar) return view->viewport.page_zoom;
    const double factor = wk.WKPageGetPageZoomFactor(view->page);
    return factor >= 0.1 && factor <= 10.0 ? (unsigned)(factor * 100.0 + 0.5) : 100;
}
static bool can_dock(MoonView *view) {
    if (view->viewport.bar) return false;
    RECT area;
    if (!GetClientRect(view->surface,&area)) return false;
    const UINT dpi=GetDpiForWindow(view->surface);
    return area.right>=MulDiv(500,dpi,96) && area.bottom>=MulDiv(334,dpi,96);
}

static void resize_view(MoonView *view, bool dpi_changed) {
    RECT area;
    if (!GetClientRect(view->surface,&area)) return;
    if (view->docked && !can_dock(view)) {
        wk.WKInspectorDetach(view->inspector);
        view->docked=wk.WKInspectorIsAttached(view->inspector);
    }
    if (view->viewport.bar) {
        const int toolbar=moon_viewport_layout(&view->viewport,area.right);
        const int dpi=(int)GetDpiForWindow(view->surface);
        const int pad=MulDiv(12,dpi,96);
        const int available_width=max(1,area.right-2*pad);
        const int available_height=max(1,area.bottom-toolbar-2*pad);
        const double dpr=max(1,dpi)/96.0;
        const double preferred=view->viewport.page_zoom/100.0;
        double factor=preferred;
        if (view->viewport.fit) {
            const double horizontal=available_width/(dpr*view->viewport.width);
            const double vertical=available_height/(dpr*view->viewport.height);
            factor=max(0.1,min(preferred,min(horizontal,vertical)));
        }
        set_page_zoom(view,factor);
        const double scale=factor*dpr;
        const int width=max(1,min((int)(view->viewport.width*scale+0.5),available_width));
        const int height=max(1,min((int)(view->viewport.height*scale+0.5),available_height));
        const int x=(area.right-width)/2, y=max(toolbar,toolbar+(area.bottom-toolbar-height)/2);
        view->viewport.bounds=(RECT){x,y,x+width,y+height};
        MoveWindow(view->hwnd,x,y,width,height,TRUE);
        moon_viewport_update(&view->viewport,(unsigned)(width/scale+0.5),(unsigned)(height/scale+0.5),
            (unsigned)(factor/preferred*100+0.5));
        InvalidateRect(view->surface,NULL,TRUE);
    } else {
        // WebKit reserves space for its attached sibling on WM_WINDOWPOSCHANGING.
        MoveWindow(view->hwnd,0,0,area.right,area.bottom,TRUE);
    }
    if (dpi_changed) {
        for (HWND child=GetWindow(view->surface,GW_CHILD); child; child=GetWindow(child,GW_HWNDNEXT)) {
            RECT size;
            if (GetClientRect(child,&size)) SendMessageW(child,WM_SIZE,SIZE_RESTORED,MAKELPARAM(size.right,size.bottom));
        }
    }
}

bool moon_engine_viewport_active(const MoonView *view) { return view->viewport.bar!=NULL; }

void moon_engine_viewport_apply(MoonView *view, unsigned width, unsigned height) {
    moon_viewport_set_size(&view->viewport,width,height);
    resize_view(view,false);
}
void moon_engine_viewport_fit(MoonView *view,bool fit) {
    if (!view->viewport.bar || view->viewport.fit==fit) return;
    view->viewport.fit=fit;
    resize_view(view,false);
}

void moon_engine_viewport_close(MoonView *view, bool focus) {
    if (!view->viewport.bar) return;
    moon_viewport_close(&view->viewport);
    set_page_zoom(view,view->viewport.page_zoom/100.0);
    view->viewport_owner[0]=0;
    resize_view(view,false);
    if (focus && IsWindowVisible(view->surface)) SetFocus(view->hwnd);
}

int moon_engine_viewport(MoonView *view, const char *owner, unsigned width, unsigned height, int fit) {
    if (view->extension_address || strlen(owner)>=sizeof(view->viewport_owner)) return 2;
    if (!width && fit<0 && view->viewport.bar) {
        moon_engine_viewport_close(view,true);
        return 1;
    }
    if (!view->viewport.bar) {
        view->viewport.page_zoom=moon_engine_zoom(view);
        if (!moon_viewport_open(&view->viewport,view,view->surface,view->hwnd)) return 2;
    }
    if (fit>=0) view->viewport.fit=fit!=0;
    strcpy(view->viewport_owner,owner);
    if (view->inspector && wk.WKInspectorIsAttached(view->inspector)) {
        wk.WKInspectorDetach(view->inspector);
        view->docked=wk.WKInspectorIsAttached(view->inspector);
    }
    moon_engine_viewport_apply(view,width ? width : view->viewport.width,height ? height : view->viewport.height);
    return 0;
}

void moon_engine_check_viewports(void) {
    for (MoonView *view=views; view; view=view->next)
        if (view->viewport.bar && !moon_devtools_viewport_granted(view->viewport_owner)) moon_engine_viewport_close(view,false);
}

void moon_engine_resize_views(bool dpi_changed) {
    RECT area;
    if (!GetClientRect(moon_shell_content(),&area)) return;
    for (MoonView *view=views; view; view=view->next) {
        MoveWindow(view->surface,0,0,area.right,area.bottom,TRUE);
        resize_view(view,dpi_changed);
    }
}

bool moon_engine_page_window(void *window) {
    for (MoonView *view=views; view; view=view->next)
        if (window==view->hwnd || IsChild(view->hwnd,window)) return true;
    return false;
}

bool moon_engine_cancel_pick(MoonView *view) {
    if (!view->inspector) return false;
    if (view->picker==PICK_WAIT_VISIBLE) {
        view->picker=PICK_IDLE;
        return true;
    }
    if (view->picker==PICK_STARTING) view->picker=PICK_CANCEL_START;
    if (view->picker==PICK_CANCEL_START || view->picker==PICK_STOPPING) return true;
    if (!wk.WKInspectorIsElementSelectionActive(view->inspector)) return false;
    wk.WKInspectorToggleElementSelection(view->inspector);
    view->picker=PICK_STOPPING;
    view->picker_deadline=moon_clock()+2000;
    return true;
}

bool moon_engine_filter_picker_click(void *window, unsigned message) {
    if (message!=WM_LBUTTONDOWN && message!=WM_LBUTTONUP && message!=WM_LBUTTONDBLCLK) return false;
    for (MoonView *view=views;view;view=view->next) {
        if (window!=view->hwnd && !IsChild(view->hwnd,window)) continue;
        if (message==WM_LBUTTONUP) {
            const bool blocked=view->picker_blocked_press;
            view->picker_blocked_press=false;
            return blocked;
        }
        view->picker_blocked_press=view->picker!=PICK_IDLE;
        return view->picker_blocked_press;
    }
    return false;
}

static void advance_picker(MoonView *view, uint64_t now, bool visible, bool active) {
    if (view->picker==PICK_IDLE) return;
    if (now>=view->picker_deadline) {
        view->picker=PICK_IDLE;
    } else if (view->picker==PICK_WAIT_VISIBLE && visible) {
        view->picker=PICK_IDLE;
        if (!active) {
            view->picker=PICK_STARTING;
            view->picker_deadline=now+2000;
            wk.WKInspectorToggleElementSelection(view->inspector);
        }
    } else if (active && (view->picker==PICK_STARTING || view->picker==PICK_CANCEL_START)) {
        const bool cancel=view->picker==PICK_CANCEL_START;
        view->picker=PICK_IDLE;
        if (cancel) moon_engine_cancel_pick(view);
    } else if (!active && view->picker==PICK_STOPPING) {
        view->picker=PICK_IDLE;
    }
}

static void update_picker(MoonView *view, uint64_t now, bool visible) {
    if (!IsWindowVisible(view->surface)) moon_engine_cancel_pick(view);
    const bool active=visible && wk.WKInspectorIsElementSelectionActive(view->inspector);
    advance_picker(view,now,visible,active);
    const unsigned state=view->picker!=PICK_IDLE?1:active?2:0;
    if (state==view->picker_window_state) return;
    view->picker_window_state=state;
    if (state) SetPropW(view->hwnd,picker_state_property,(HANDLE)(UINT_PTR)state);
    else RemovePropW(view->hwnd,picker_state_property);
}

static void update_inspector(MoonView *view, uint64_t now) {
    if (!view->inspector) return;
    const bool visible=wk.WKInspectorIsVisible(view->inspector);
    const bool opening=visible && (!view->inspector_visible || view->inspector_placement!=INSPECTOR_KEEP);
    view->inspector_visible=visible;
    if (opening) {
        const bool attached=wk.WKInspectorIsAttached(view->inspector);
        const bool window=view->inspector_placement==INSPECTOR_WINDOW ||
            (view->inspector_placement==INSPECTOR_KEEP && moon_devtools_prefer_window());
        const bool dock=!window && can_dock(view);
        if (dock && !attached) wk.WKInspectorAttach(view->inspector);
        if (!dock && attached) wk.WKInspectorDetach(view->inspector);
    }
    if (visible || now>=view->inspector_deadline) view->inspector_placement=INSPECTOR_KEEP;
    if (visible && view->viewport.bar && wk.WKInspectorIsAttached(view->inspector)) wk.WKInspectorDetach(view->inspector);
    const bool docked=visible && wk.WKInspectorIsAttached(view->inspector);
    if (docked!=view->docked) {
        view->docked=docked;
        resize_view(view,false);
    }
    if (opening && view->docked && GetForegroundWindow()==moon_shell_window() && IsWindowVisible(view->surface)) {
        if (view->picker!=PICK_IDLE) SetFocus(view->hwnd);
        else {
            for (HWND child=GetWindow(view->surface,GW_CHILD); child; child=GetWindow(child,GW_HWNDNEXT)) {
                if (child==view->hwnd || !IsWindowVisible(child)) continue;
                SetFocus(child);
                break;
            }
        }
    }
    update_picker(view,now,visible);
}

void moon_engine_update_inspectors(void) {
    const uint64_t now=moon_clock();
    for (MoonView *view=views; view; view=view->next) update_inspector(view,now);
}

bool moon_engine_inspecting(MoonView *view) {
    return view->inspector && (view->inspector_placement!=INSPECTOR_KEEP || wk.WKInspectorIsVisible(view->inspector));
}

void moon_engine_context_inspect_available(bool available) {
    if (context_inspect_available==available) return;
    context_inspect_available=available;
    for (MoonView *view=views;view;view=view->next) {
        if (view->extension_address || (!available && moon_engine_inspecting(view))) continue;
        wk.WKPreferencesSetDeveloperExtrasEnabled(view->view_preferences,available);
    }
}

bool moon_engine_close_inspector(MoonView *view) {
    if (!moon_engine_inspecting(view)) return false;
    view->inspector_placement=INSPECTOR_KEEP;
    moon_engine_cancel_pick(view);
    wk.WKInspectorClose(view->inspector);
    view->picker=PICK_IDLE;
    update_inspector(view,moon_clock());
    if (GetForegroundWindow()==moon_shell_window() && IsWindowVisible(view->surface)) SetFocus(view->hwnd);
    return true;
}

bool moon_engine_inspect(MoonView *view, int panel, int placement) {
    if (view->extension_address || panel<0 || panel>3) return false;
    wk.WKPreferencesSetDeveloperExtrasEnabled(view->view_preferences,true);
    WKInspectorRef inspector = wk.WKPageGetInspector(view->page);
    if (!inspector) return false;
    const uint64_t now=moon_clock();
    view->inspector=inspector;
    bool independent=placement==MOON_INSPECT_WINDOW;
    if (placement==MOON_INSPECT_PREFERRED) {
        independent=wk.WKInspectorIsVisible(inspector) ? !wk.WKInspectorIsAttached(inspector) : moon_devtools_prefer_window();
    }
    view->inspector_placement=independent ? INSPECTOR_WINDOW : INSPECTOR_DOCK;
    view->inspector_deadline=now+5000;
    if (panel!=3) moon_engine_cancel_pick(view);
    switch (panel) {
        case 0: wk.WKInspectorShow(inspector); break;
        case 1: wk.WKInspectorShowConsole(inspector); break;
        case 2: wk.WKInspectorShowResources(inspector); break;
        case 3:
            if (view->picker==PICK_IDLE) {
                view->picker=PICK_WAIT_VISIBLE;
                view->picker_deadline=view->inspector_deadline;
            }
            wk.WKInspectorShow(inspector);
            break;
    }
    update_inspector(view,now);
    return true;
}

static void page_source_received(WKStringRef source, WKErrorRef error, void *context) {
    const uint64_t generation = (uintptr_t)context;
    // Allow enough extra bytes to detect truncation at any UTF-8 character boundary.
    const size_t cap = MOON_SOURCE_LIMIT + 5;
    char *buffer = source && !error ? malloc(cap) : NULL;
    size_t size = buffer ? wk.WKStringGetUTF8CStringNonStrict(source, buffer, cap) : 0;
    moon_page_source_result(generation, size > 1 ? buffer : NULL, size > 1 ? size - 1 : 0);
    free(buffer);
}

bool moon_engine_page_source(MoonView *view, uint64_t generation) {
    if (view->extension_address) return false;
    WKFrameRef frame = wk.WKPageGetMainFrame(view->page);
    if (!frame) return false;
    wk.WKPageGetSourceForFrame(view->page, frame, (void *)(uintptr_t)generation, page_source_received);
    return true;
}

bool moon_engine_can_save_html(MoonView *view) {
    if (view->extension_address) return false;
    WKFrameRef frame=wk.WKPageGetMainFrame(view->page);
    WKStringRef mime=frame?wk.WKFrameCopyMIMEType(frame):NULL;
    const bool html=mime && wk.WKStringIsEqualToUTF8CString(mime,"text/html");
    release(mime);
    return html;
}

static void page_save_received(WKStringRef source, WKErrorRef error, void *context) {
    const uint64_t request=(uintptr_t)context;
    size_t cap=source && !error?wk.WKStringGetMaximumUTF8CStringSize(source):0;
    // Leave room for a complete UTF-8 character beyond the size limit.
    if (cap>MOON_HTML_SAVE_LIMIT+5) cap=MOON_HTML_SAVE_LIMIT+5;
    char *buffer=cap>1?malloc(cap):NULL;
    size_t size=buffer?wk.WKStringGetUTF8CStringNonStrict(source,buffer,cap):0;
    const bool too_large=size>MOON_HTML_SAVE_LIMIT+1;
    moon_page_save_result(request,size>1 && !too_large?buffer:NULL,size>1 && !too_large?size-1:0,too_large);
    free(buffer);
}

bool moon_engine_save_html(MoonView *view, uint64_t request) {
    WKFrameRef frame=wk.WKPageGetMainFrame(view->page);
    if (!frame) return false;
    wk.WKPageGetSourceForFrame(view->page,frame,(void *)(uintptr_t)request,page_save_received);
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
const void *moon_engine_retain_state(const void *state) { return state ? wk.WKRetain(state) : NULL; }
void moon_engine_release_state(const void *state) { release(state); }
uint32_t moon_engine_pid(MoonView *view) { return (uint32_t)wk.WKPageGetProcessIdentifier(view->page); }
static void apply_audio_mute(MoonView *view) {
    wk.WKPageSetMuted(view->page, view->tab_muted || view->site_muted ? kWKMediaAudioMuted : kWKMediaNoneMuted);
}
void moon_engine_mute(MoonView *view, bool muted) {
    if (view->tab_muted==muted) return;
    view->tab_muted=muted;
    apply_audio_mute(view);
}
void moon_engine_site_mute(MoonView *view, bool muted) {
    if (view->site_muted==muted) return;
    view->site_muted=muted;
    apply_audio_mute(view);
}
bool moon_engine_site_muted(const MoonView *view) { return view->site_muted; }
unsigned moon_engine_playing(const MoonView *view) {
    const WKMediaState state=wk.WKPageGetMediaState(view->page);
    _Static_assert(MOON_MEDIA_AUDIO==1 && MOON_MEDIA_VIDEO==2,"Media observer flags must match the host ABI");
    return view->document_playing | (state&kWKMediaIsPlayingAudio ? MOON_MEDIA_AUDIO : 0) |
        (state&kWKMediaIsPlayingVideo ? MOON_MEDIA_VIDEO : 0);
}
bool moon_engine_media(MoonView *view) {
    WKMediaState state = wk.WKPageGetMediaState(view->page);
    return view->document_playing || (state & (kWKMediaIsPlayingAudio | kWKMediaIsPlayingVideo | kWKMediaHasActiveAudioCaptureDevice |
        kWKMediaHasActiveVideoCaptureDevice | kWKMediaHasActiveDisplayCaptureDevice |
        kWKMediaHasActiveScreenCaptureDevice | kWKMediaHasActiveWindowCaptureDevice));
}
void moon_engine_read(MoonView *view, char *title, size_t title_cap, char *url, size_t url_cap) {
    copy_string(wk.WKPageCopyTitle(view->page),title,title_cap);
    copy_url(wk.WKPageCopyActiveURL(view->page),url,url_cap);
}
static void cache_trimmed(void *unused) {}
typedef struct {
    unsigned remaining;
    unsigned category;
} EraseTask;
static EraseTask erase_site, erase_cache;

static void erase_completed(void *context) {
    EraseTask *task = context;
    if (task->remaining && --task->remaining == 0) moon_privacy_engine_done(task->category);
}

bool moon_engine_clear_site_cookies_available(void) {
    return store && delete_site_cookies && !moon_shell_private();
}

static void site_cookies_cleared(void *request) {
    moon_site_cookies_cleared((uint64_t)(uintptr_t)request);
}

bool moon_engine_clear_site_cookies(const char *url, uint64_t request) {
    if (!moon_engine_clear_site_cookies_available() || erase_site.remaining) return false;
    WKStringRef target = wk.WKStringCreateWithUTF8CString(url);
    if (!target) return false;
    // The pinned backend removes cookies through the profile's NetworkProcess.
    delete_site_cookies(store,target,true,(void *)(uintptr_t)request,site_cookies_cleared);
    release(target);
    return true;
}

unsigned moon_engine_erase_data(unsigned requested) {
    if (!store || erase_site.remaining || erase_cache.remaining) return 0;
    WKHTTPCookieStoreRef cookies = requested & MOON_ERASE_SITE ? wk.WKWebsiteDataStoreGetHTTPCookieStore(store) : NULL;
    const unsigned accepted = (cookies ? MOON_ERASE_SITE : 0) | (requested & MOON_ERASE_CACHE);
    erase_site = (EraseTask){ .remaining=cookies ? 5 : 0, .category=MOON_ERASE_SITE };
    erase_cache = (EraseTask){ .remaining=accepted & MOON_ERASE_CACHE ? 2 : 0, .category=MOON_ERASE_CACHE };
    if (cookies) {
        wk.WKHTTPCookieStoreDeleteAllCookies(cookies,&erase_site,erase_completed);
        wk.WKWebsiteDataStoreRemoveLocalStorage(store,&erase_site,erase_completed);
        wk.WKWebsiteDataStoreRemoveAllIndexedDatabases(store,&erase_site,erase_completed);
        wk.WKWebsiteDataStoreRemoveAllServiceWorkerRegistrations(store,&erase_site,erase_completed);
        wk.WKWebsiteDataStoreRemoveAllFetchCaches(store,&erase_site,erase_completed);
    }
    if (accepted & MOON_ERASE_CACHE) {
        wk.WKWebsiteDataStoreRemoveNetworkCache(store,&erase_cache,erase_completed);
        wk.WKWebsiteDataStoreRemoveMemoryCaches(store,&erase_cache,erase_completed);
    }
    return accepted;
}

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
