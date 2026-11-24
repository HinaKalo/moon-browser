#include <windows.h>
#include <stdbool.h>
#include <WebKit/WKBase.h>
#include <WebKit/WKString.h>
#include <WebKit/WKType.h>
#include <WebKit/WKURL.h>
#include <string.h>
#include <stdlib.h>

typedef const struct OpaqueJSContext *JSContextRef;
typedef const struct OpaqueJSValue *JSValueRef;
typedef struct OpaqueJSString *JSStringRef;
typedef struct OpaqueJSValue *JSObjectRef;
typedef JSValueRef (*JSFunctionCallback)(JSContextRef,JSObjectRef,JSObjectRef,size_t,const JSValueRef[],JSValueRef *);

/* Only the worker's isolated world evaluates the fixed expression below. */
static struct {
    WKBundleFrameRef (*main_frame)(WKBundlePageRef);
    WKBundleFrameRef (*frame_for_context)(JSContextRef);
    WKBundlePageRef (*page_for_frame)(WKBundleFrameRef);
    WKURLRef (*frame_url)(WKBundleFrameRef);
    WKBundleScriptWorldRef (*create_world)(void);
    JSContextRef (*global_context)(WKBundleFrameRef,WKBundleScriptWorldRef);
    void (*post)(WKBundlePageRef,WKStringRef,WKTypeRef);
    __typeof__(&WKGetTypeID) type_id;
    __typeof__(&WKStringGetTypeID) string_type_id;
    __typeof__(&WKStringCreateWithUTF8CString) new_string;
    __typeof__(&WKStringIsEqualToUTF8CString) text_equals;
    __typeof__(&WKStringGetUTF8CString) read_string;
    __typeof__(&WKURLCopyString) url_text;
    __typeof__(&WKRelease) release;
    JSStringRef (*source)(const char *);
    JSValueRef (*evaluate)(JSContextRef,JSStringRef,JSObjectRef,JSStringRef,int,JSValueRef *);
    JSObjectRef (*to_object)(JSContextRef,JSValueRef,JSValueRef *);
    JSValueRef (*make_string)(JSContextRef,JSStringRef);
    JSValueRef (*make_undefined)(JSContextRef);
    JSObjectRef (*make_callback)(JSContextRef,JSStringRef,JSFunctionCallback);
    JSValueRef (*call)(JSContextRef,JSObjectRef,JSObjectRef,size_t,const JSValueRef *,JSValueRef *);
    JSStringRef (*to_string)(JSContextRef,JSValueRef,JSValueRef *);
    size_t (*size)(JSStringRef);
    size_t (*utf8)(JSStringRef,char *,size_t);
    void (*release_js)(JSStringRef);
} api;

static bool resolve(void) {
    static bool ready;
    if (ready) return true;
    HMODULE wk=GetModuleHandleW(L"WebKit2.dll"), js=GetModuleHandleW(L"JavaScriptCore.dll");
    if (!wk || !js) return false;
#define GET(module,field,name) api.field=(__typeof__(api.field))GetProcAddress(module,#name); if (!api.field) return false;
    GET(wk,main_frame,WKBundlePageGetMainFrame)
    GET(wk,frame_for_context,WKBundleFrameForJavaScriptContext)
    GET(wk,page_for_frame,WKBundleFrameGetPage)
    GET(wk,frame_url,WKBundleFrameCopyURL)
    GET(wk,create_world,WKBundleScriptWorldCreateWorld)
    GET(wk,global_context,WKBundleFrameGetJavaScriptContextForWorld)
    GET(wk,post,WKBundlePagePostMessage)
    GET(wk,type_id,WKGetTypeID)
    GET(wk,string_type_id,WKStringGetTypeID)
    GET(wk,new_string,WKStringCreateWithUTF8CString)
    GET(wk,text_equals,WKStringIsEqualToUTF8CString)
    GET(wk,read_string,WKStringGetUTF8CString)
    GET(wk,url_text,WKURLCopyString)
    GET(wk,release,WKRelease)
    GET(js,source,JSStringCreateWithUTF8CString)
    GET(js,evaluate,JSEvaluateScript)
    GET(js,to_object,JSValueToObject)
    GET(js,make_string,JSValueMakeString)
    GET(js,make_undefined,JSValueMakeUndefined)
    GET(js,make_callback,JSObjectMakeFunctionWithCallback)
    GET(js,call,JSObjectCallAsFunction)
    GET(js,to_string,JSValueToStringCopy)
    GET(js,size,JSStringGetMaximumUTF8CStringSize)
    GET(js,utf8,JSStringGetUTF8CString)
    GET(js,release_js,JSStringRelease)
#undef GET
    ready=true;
    return true;
}

static const char snapshot_script[] =
    "((revision,json) => {"
    "const max=32;"
    "const update=JSON.parse(json);"
    "let mutation=null;"
    "if(update){"
        "if(globalThis.__moonSiteDataRevision!==update.revision)return JSON.stringify('sourceChanged');"
        "try{const store=update.group==='local'?localStorage:update.group==='session'?sessionStorage:null;"
            "if(!store)mutation='failed';"
            "else if(update.clear){store.clear();mutation='cleared';}"
            "else if(store.getItem(update.key)!==update.previous)mutation='conflict';"
            "else if(update.replacement===null){store.removeItem(update.key);mutation='removed';}"
            "else{store.setItem(update.key,update.replacement);mutation='saved';}"
        "}catch{mutation='failed';}"
    "}"
    "globalThis.__moonSiteDataRevision=revision;"
    "const make=(name,value)=>{const key=name.slice(0,128).toWellFormed(),text=value.slice(0,512).toWellFormed();"
        "return {name:key,value:text,shortened:name!==key||value!==text};};"
    "const storage=(read)=>{try{const store=read(), entries=[];"
        "for(let i=0;i<Math.min(store.length,max);++i){const key=store.key(i);"
        "if(key!==null)entries.push(make(key,store.getItem(key) ?? ''));}"
        "return {entries,more:store.length>max};}catch{return null;}};"
    "const cookies=()=>{try{const value=document.cookie;"
        "const lines=value?value.split(';'):[];"
        "const entries=lines.slice(0,max).map(text=>{text=text.trimStart();const split=text.indexOf('=');"
        "return split<0?make(text,''):make(text.slice(0,split),text.slice(split+1));});"
        "return {entries,more:lines.length>max};}catch{return null;}};"
    "return JSON.stringify({cookies:cookies(),local:storage(()=>localStorage),session:storage(()=>sessionStorage),mutation});"
    "})";

static const char catalog_script[] =
    "((revision,url,reply) => {"
    "if(globalThis.__moonSiteDataRevision!==revision)return JSON.stringify('sourceChanged');"
    "const item=(full)=>{const name=full.slice(0,128).toWellFormed();return {name,shortened:name!==full};};"
    "const section=async(read,describe)=>{try{const entries=await read();"
        "return {entries:entries.slice(0,32).map(describe),more:entries.length>32};}catch{return null;}};"
    "Promise.all([section(()=>indexedDB.databases(),db=>({ ...item(db.name),"
        "version:Number.isSafeInteger(db.version)?db.version:null })),section(()=>caches.keys(),item)])"
      ".then(([indexedDB,cacheStorage])=>{if(location.href===url&&globalThis.__moonSiteDataRevision===revision)"
        "reply(revision+'\\n'+JSON.stringify({indexedDB,cacheStorage}));});"
    "})";

static void post_reply(WKBundlePageRef page,const char *channel,const char *text) {
    WKStringRef name=api.new_string(channel), body=api.new_string(text);
    if (name && body) api.post(page,name,body);
    if (body) api.release(body);
    if (name) api.release(name);
}

static JSValueRef catalog_finished(JSContextRef context,JSObjectRef function,JSObjectRef self,size_t argc,
                                   const JSValueRef argv[],JSValueRef *exception) {
    WKBundleFrameRef frame=api.frame_for_context(context);
    WKBundlePageRef page=frame ? api.page_for_frame(frame) : NULL;
    if (page && api.main_frame(page)==frame && argc==1) {
        JSStringRef text=api.to_string(context,argv[0],exception);
        if (text) {
            const size_t capacity=api.size(text);
            const size_t max=64*1024;
            const size_t estimated=capacity<max ? capacity : max;
            char *response=estimated ? malloc(estimated) : NULL;
            if (response) {
                const size_t bytes=api.utf8(text,response,estimated);
                if (bytes>2 && response[bytes-2]=='}') post_reply(page,"MoonSiteCatalog",response);
                free(response);
            }
            api.release_js(text);
        }
    }
    return api.make_undefined(context);
}

static JSStringRef inspect(WKBundlePageRef page,const char *revision,const char *expected,const char *change,
                           bool catalog,bool *scheduled,const char **failure) {
    *failure="\"frameUnavailable\"";
    WKBundleFrameRef frame=api.main_frame(page);
    if (!frame) return NULL;
    WKURLRef url=api.frame_url(frame);
    if (!url) return NULL;
    WKStringRef text=api.url_text(url);
    api.release(url);
    if (!text) return NULL;
    const bool matches=api.text_equals(text,expected);
    api.release(text);
    if (!matches) { *failure="\"sourceChanged\""; return NULL; }
    *failure="\"worldUnavailable\"";
    // Retain one isolated world per web process. Each document's global holds its own revision.
    static WKBundleScriptWorldRef world;
    if (!world) world=api.create_world();
    if (!world) return NULL;
    *failure="\"contextUnavailable\"";
    JSContextRef context=api.global_context(frame,world);
    JSStringRef result=NULL;
    if (context) {
        *failure="\"evaluationFailed\"";
        JSStringRef script=api.source(catalog ? catalog_script : snapshot_script);
        JSStringRef id=api.source(revision), payload=api.source(catalog ? expected : change);
        if (script && id && payload) {
            JSValueRef exception=NULL;
            JSValueRef function=api.evaluate(context,script,NULL,NULL,1,&exception);
            JSObjectRef callback=!exception && function ? api.to_object(context,function,&exception) : NULL;
            if (!exception && callback) {
                const JSValueRef arguments[]={api.make_string(context,id),api.make_string(context,payload),
                    catalog ? api.make_callback(context,NULL,catalog_finished) : NULL};
                JSValueRef value=api.call(context,callback,NULL,catalog ? 3 : 2,arguments,&exception);
                *failure="\"conversionFailed\"";
                if (!exception && value) {
                    if (catalog) *scheduled=true;
                    else result=api.to_string(context,value,NULL);
                }
            }
        }
        if (script) api.release_js(script);
        if (id) api.release_js(id);
        if (payload) api.release_js(payload);
    }
    return result;
}

void moon_bundle_site_message(WKBundleRef bundle,WKBundlePageRef page,WKStringRef name,WKTypeRef data,const void *info) {
    if (!resolve() || !data || api.type_id(data)!=api.string_type_id()) return;
    const bool catalog=api.text_equals(name,"MoonInspectCatalog");
    if (!catalog && !api.text_equals(name,"MoonInspectSite")) return;
    char request[32*1024];
    const size_t n=api.read_string((WKStringRef)data,request,sizeof(request));
    if (!n || n>=sizeof(request) || strlen(request)+1!=n) return;
    char *split=strchr(request,'\n');
    if (!split || split==request || (size_t)(split-request)>20) return;
    char *update=strchr(split+1,'\n');
    if (!update || update==split+1 || !update[1]) return;
    const size_t prefix=(size_t)(split-request)+1;
    const char *failure;
    *split=0;
    *update=0;
    bool scheduled=false;
    JSStringRef snapshot=inspect(page,request,split+1,update+1,catalog,&scheduled,&failure);
    if (scheduled) return;
    *split='\n';
    const size_t capacity=snapshot ? api.size(snapshot) : 0;
    const size_t limit=512*1024;
    const size_t estimated=capacity<limit ? capacity : limit;
    char *response=malloc(prefix+(estimated>32 ? estimated : 32));
    if (response) {
        memcpy(response,request,prefix);
        if (!snapshot) strcpy(response+prefix,failure);
        else {
            const size_t bytes=estimated ? api.utf8(snapshot,response+prefix,estimated) : 0;
            if (bytes<2 || (response[prefix+bytes-2]!='}' && response[prefix+bytes-2]!='"'))
                strcpy(response+prefix,"\"invalidResult\"");
        }
        post_reply(page,catalog ? "MoonSiteCatalog" : "MoonSiteSnapshot",response);
        free(response);
    }
    if (snapshot) api.release_js(snapshot);
}
