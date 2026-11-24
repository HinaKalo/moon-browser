#include <windows.h>
#include <stdbool.h>
#include <WebKit/WKBase.h>
#include <WebKit/WKBundlePageResourceLoadClient.h>
#include <WebKit/WKString.h>
#include <WebKit/WKType.h>
#include <WebKit/WKURL.h>
#include <WebKit/WKURLRequest.h>
#include <stdlib.h>
#include <string.h>

/* These client slots mirror WKBundleClientV1 at the engine lock revision. */
typedef struct { int version; const void *info; } BundleClientBase;
typedef struct {
    BundleClientBase base;
    void (*did_create_page)(WKBundleRef,WKBundlePageRef,const void *);
    void (*will_destroy_page)(WKBundleRef,WKBundlePageRef,const void *);
    void (*did_initialize_page_group)(WKBundleRef,WKBundlePageGroupRef,const void *);
    void (*did_receive_message)(WKBundleRef,WKStringRef,WKTypeRef,const void *);
    void (*did_receive_page_message)(WKBundleRef,WKBundlePageRef,WKStringRef,WKTypeRef,const void *);
} BundleClient;

void moon_bundle_site_message(WKBundleRef bundle,WKBundlePageRef page,WKStringRef name,WKTypeRef data,const void *info);

static void (*set_bundle_client)(WKBundleRef,const BundleClientBase *);
static void (*set_load_client)(WKBundlePageRef,const WKBundlePageResourceLoadClientBase *);
static WKBundleFrameRef (*main_frame)(WKBundlePageRef);
static WKURLRef (*frame_url)(WKBundleFrameRef);
static WKURLRef (*frame_provisional_url)(WKBundleFrameRef);

#define WK_APIS(X) \
    X(WKRetain) X(WKRelease) X(WKGetTypeID) X(WKStringGetTypeID) \
    X(WKStringGetMaximumUTF8CStringSize) X(WKStringGetUTF8CString) X(WKStringIsEqualToUTF8CString) \
    X(WKURLRequestCopyURL) X(WKURLCopyHostName) X(WKURLCopyPath)

static struct {
#define FIELD(name) __typeof__(&name) name;
    WK_APIS(FIELD)
#undef FIELD
} wk;

enum { MAX_RULE_BYTES = 128 * 1024, MAX_HOST_BYTES = 256, MAX_PATH_BYTES = 2048 };
typedef struct { const char *host, *prefix; } PathRule;
typedef struct {
    char *text;
    const char **blocked, **allowed;
    PathRule *paths;
    size_t blocked_count, allowed_count, path_count;
} Rules;
typedef struct Page {
    WKBundlePageRef page;
    struct Page *next;
} Page;
static Rules rules;
static Page *pages;

static bool read_string(WKStringRef value,char *out,size_t size) {
    if (!value) return false;
    const size_t length = wk.WKStringGetUTF8CString(value,out,size);
    wk.WKRelease(value);
    return length > 1 && length < size && length == strlen(out)+1;
}
static bool read_host(WKURLRef url,char host[MAX_HOST_BYTES]) {
    if (!read_string(wk.WKURLCopyHostName(url),host,MAX_HOST_BYTES)) return false;
    /* A DNS root dot does not change the rule or exception that applies. */
    const size_t length = strlen(host);
    if (host[length-1]=='.') host[length-1]='\0';
    return *host!=0;
}
static int compare_host(const void *left,const void *right) {
    return strcmp(*(const char * const *)left,*(const char * const *)right);
}
static int compare_path_host(const void *left,const void *right) {
    const PathRule *a = left, *b = right;
    return strcmp(a->host,b->host);
}
static bool domain_match(const char *host,const char *const *items,size_t count) {
    if (!count) return false;
    const char *candidate = host;
    while (*candidate) {
        if (bsearch(&candidate,items,count,sizeof(*items),compare_host)) return true;
        const char *dot = strchr(candidate,'.');
        if (!dot) break;
        candidate = dot+1;
    }
    return false;
}
static bool path_match(const char *host,WKURLRef url) {
    if (!rules.path_count) return false;
    PathRule target = { .host=host };
    const PathRule *first = bsearch(&target,rules.paths,rules.path_count,sizeof(*rules.paths),compare_path_host);
    if (!first) return false;
    while (first > rules.paths && !strcmp((first-1)->host,host)) --first;
    char path[MAX_PATH_BYTES];
    if (!read_string(wk.WKURLCopyPath(url),path,sizeof(path))) return false;
    const PathRule *end = rules.paths+rules.path_count;
    for (; first < end && !strcmp(first->host,host); ++first) {
        if (!strncmp(path,first->prefix,strlen(first->prefix))) return true;
    }
    return false;
}
static bool allowed_page(WKBundlePageRef page) {
    if (!rules.allowed_count) return false;
    WKBundleFrameRef frame = main_frame(page);
    if (!frame) return false;
    char host[MAX_HOST_BYTES];
    WKURLRef url = frame_provisional_url(frame);
    bool found = false;
    if (url) {
        found = read_host(url,host);
        wk.WKRelease(url);
    }
    if (!found && (url=frame_url(frame))) {
        found = read_host(url,host);
        wk.WKRelease(url);
    }
    return found && domain_match(host,rules.allowed,rules.allowed_count);
}
static WKURLRequestRef will_send_request(WKBundlePageRef page,WKBundleFrameRef frame,uint64_t id,
                                       WKURLRequestRef request,WKURLResponseRef redirect,const void *info) {
    WKURLRef url = request ? wk.WKURLRequestCopyURL(request) : NULL;
    if (!url) return request ? (WKURLRequestRef)wk.WKRetain(request) : NULL;
    char host[MAX_HOST_BYTES];
    const bool blocked = read_host(url,host) &&
        (domain_match(host,rules.blocked,rules.blocked_count) || path_match(host,url));
    wk.WKRelease(url);
    if (blocked && !allowed_page(page)) return NULL;
    return (WKURLRequestRef)wk.WKRetain(request);
}
static void configure_page(WKBundlePageRef page) {
    const WKBundlePageResourceLoadClientV0 client = {
        .base = {0,NULL}, .willSendRequestForFrame=will_send_request,
    };
    set_load_client(page,(rules.blocked_count || rules.path_count) ? &client.base : NULL);
}
static void release_rules(Rules *old) {
    free(old->paths);
    free(old->allowed);
    free(old->blocked);
    free(old->text);
    *old = (Rules){0};
}
static bool decode_rules(WKTypeRef data,Rules *next) {
    if (!data || wk.WKGetTypeID(data)!=wk.WKStringGetTypeID()) return false;
    WKStringRef value = (WKStringRef)data;
    const size_t cap = wk.WKStringGetMaximumUTF8CStringSize(value);
    if (!cap || cap > MAX_RULE_BYTES*3+1) return false;
    next->text = malloc(cap);
    if (!next->text) return false;
    const size_t length = wk.WKStringGetUTF8CString(value,next->text,cap);
    if (!length || length > MAX_RULE_BYTES || length!=strlen(next->text)+1) return false;
    size_t block = 0, allow = 0, path = 0;
    for (const char *line=next->text; *line; ++line) {
        if (line!=next->text && line[-1]!='\n') continue;
        if (*line=='-') ++block;
        else if (*line=='!') ++allow;
        else if (*line=='@') ++path;
        else return false;
    }
    if (block && !(next->blocked=calloc(block,sizeof(*next->blocked)))) return false;
    if (allow && !(next->allowed=calloc(allow,sizeof(*next->allowed)))) return false;
    if (path && !(next->paths=calloc(path,sizeof(*next->paths)))) return false;
    for (char *line=next->text; line && *line;) {
        char *lf = strchr(line,'\n');
        if (lf) *lf++ = '\0';
        if (!line[1]) return false;
        if (*line=='-') next->blocked[next->blocked_count++]=line+1;
        else if (*line=='!') next->allowed[next->allowed_count++]=line+1;
        else {
            char *tab = strchr(line,'\t');
            if (!tab || tab[1]!='/') return false;
            *tab='\0';
            next->paths[next->path_count++] = (PathRule){line+1,tab+1};
        }
        line=lf;
    }
    if (block) qsort(next->blocked,block,sizeof(*next->blocked),compare_host);
    if (allow) qsort(next->allowed,allow,sizeof(*next->allowed),compare_host);
    if (path) qsort(next->paths,path,sizeof(*next->paths),compare_path_host);
    return true;
}
static void set_rules(WKTypeRef data) {
    Rules next={0};
    if (!decode_rules(data,&next)) {
        release_rules(&next);
        return;
    }
    release_rules(&rules);
    rules=next;
    for (Page *page=pages; page; page=page->next) configure_page(page->page);
}
static void created_page(WKBundleRef bundle,WKBundlePageRef page,const void *info) {
    Page *entry=malloc(sizeof(*entry));
    if (entry) {
        *entry=(Page){page,pages};
        pages=entry;
    }
    configure_page(page);
}
static void destroyed_page(WKBundleRef bundle,WKBundlePageRef page,const void *info) {
    Page **entry=&pages;
    while (*entry && (*entry)->page!=page) entry=&(*entry)->next;
    if (*entry) {
        Page *removed=*entry;
        *entry=removed->next;
        free(removed);
    }
}
static void receive_message(WKBundleRef bundle,WKStringRef name,WKTypeRef data,const void *info) {
    if (wk.WKStringIsEqualToUTF8CString(name,"MoonRequestPolicy")) set_rules(data);
}

__declspec(dllexport) void WKBundleInitialize(WKBundleRef bundle,WKTypeRef data) {
    HMODULE module=GetModuleHandleW(L"WebKit2.dll");
    if (!module) return;
#define RESOLVE(name) wk.name=(__typeof__(wk.name))GetProcAddress(module,#name); if (!wk.name) return;
    WK_APIS(RESOLVE)
#undef RESOLVE
#define RESOLVE_AS(field,name) field=(__typeof__(field))GetProcAddress(module,name); if (!field) return;
    RESOLVE_AS(set_bundle_client,"WKBundleSetClient")
    RESOLVE_AS(set_load_client,"WKBundlePageSetResourceLoadClient")
    RESOLVE_AS(main_frame,"WKBundlePageGetMainFrame")
    RESOLVE_AS(frame_url,"WKBundleFrameCopyURL")
    RESOLVE_AS(frame_provisional_url,"WKBundleFrameCopyProvisionalURL")
#undef RESOLVE_AS
    if (data) set_rules(data);
    const BundleClient client = {
        .base={1,NULL},.did_create_page=created_page,.will_destroy_page=destroyed_page,.did_receive_message=receive_message,
        .did_receive_page_message=moon_bundle_site_message,
    };
    set_bundle_client(bundle,&client.base);
}
