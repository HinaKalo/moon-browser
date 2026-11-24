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

/* Only the worker's isolated world evaluates the fixed expression below. */
static struct {
    WKBundleFrameRef (*main_frame)(WKBundlePageRef);
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

static JSStringRef inspect(WKBundlePageRef page,const char *revision,const char *expected,const char *change,const char **failure) {
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
        JSStringRef script=api.source(snapshot_script);
        JSStringRef id=api.source(revision), payload=api.source(change);
        if (script && id && payload) {
            JSValueRef exception=NULL;
            JSValueRef function=api.evaluate(context,script,NULL,NULL,1,&exception);
            JSObjectRef callback=!exception && function ? api.to_object(context,function,&exception) : NULL;
            if (!exception && callback) {
                const JSValueRef arguments[]={api.make_string(context,id),api.make_string(context,payload)};
                JSValueRef value=api.call(context,callback,NULL,2,arguments,&exception);
                *failure="\"conversionFailed\"";
                if (!exception && value) result=api.to_string(context,value,NULL);
            }
        }
        if (script) api.release_js(script);
        if (id) api.release_js(id);
        if (payload) api.release_js(payload);
    }
    return result;
}

void moon_bundle_site_message(WKBundleRef bundle,WKBundlePageRef page,WKStringRef name,WKTypeRef data,const void *info) {
    if (!resolve() || !api.text_equals(name,"MoonInspectSite") || !data || api.type_id(data)!=api.string_type_id()) return;
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
    JSStringRef snapshot=inspect(page,request,split+1,update+1,&failure);
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
        WKStringRef message=api.new_string("MoonSiteSnapshot");
        WKStringRef payload=api.new_string(response);
        if (message && payload) api.post(page,message,payload);
        if (payload) api.release(payload);
        if (message) api.release(message);
        free(response);
    }
    if (snapshot) api.release_js(snapshot);
}
