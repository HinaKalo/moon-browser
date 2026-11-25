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
    __typeof__(&WKStringGetMaximumUTF8CStringSize) string_capacity;
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
    GET(wk,string_capacity,WKStringGetMaximumUTF8CStringSize)
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
    "globalThis.__moonSiteRecordPage=undefined;"
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

static const char cache_remove_script[] =
    "((revision,url,payload,reply) => {"
    "const change=JSON.parse(payload);"
    "if(location.href!==url||globalThis.__moonSiteDataRevision!==change.previous)return false;"
    "const done=mutation=>{if(location.href===url&&globalThis.__moonSiteDataRevision===change.previous)"
        "reply(revision+'\\n'+JSON.stringify({mutation}));};"
    "try{caches.delete(change.name).then(existed=>done(existed?'removed':'conflict'),()=>done('failed'));}"
    "catch{done('failed');}"
    "return true;"
    "})";

static void post_reply(WKBundlePageRef page,const char *channel,const char *text) {
    WKStringRef name=api.new_string(channel), body=api.new_string(text);
    if (name && body) api.post(page,name,body);
    if (body) api.release(body);
    if (name) api.release(name);
}

static JSValueRef send_async_reply(JSContextRef context,size_t argc,const JSValueRef argv[],
                                   JSValueRef *exception,const char *channel) {
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
                if (bytes>2 && response[bytes-2]=='}') post_reply(page,channel,response);
                free(response);
            }
            api.release_js(text);
        }
    }
    return api.make_undefined(context);
}

static JSValueRef catalog_finished(JSContextRef context,JSObjectRef function,JSObjectRef self,size_t argc,
                                   const JSValueRef argv[],JSValueRef *exception) {
    return send_async_reply(context,argc,argv,exception,"MoonSiteCatalog");
}

static JSValueRef cache_remove_finished(JSContextRef context,JSObjectRef function,JSObjectRef self,size_t argc,
                                        const JSValueRef argv[],JSValueRef *exception) {
    return send_async_reply(context,argc,argv,exception,"MoonSiteCacheRemoval");
}

static JSValueRef database_finished(JSContextRef context,JSObjectRef function,JSObjectRef self,size_t argc,
                                    const JSValueRef argv[],JSValueRef *exception) {
    return send_async_reply(context,argc,argv,exception,"MoonSiteDatabase");
}
static JSValueRef media_finished(JSContextRef context,JSObjectRef function,JSObjectRef self,size_t argc,
                                const JSValueRef argv[],JSValueRef *exception) {
    return send_async_reply(context,argc,argv,exception,"MoonMediaResult");
}

static const char media_script[] =
    "((request,url,action,reply) => {"
    "const finish=status=>{if(location.href===url)reply(request+'\\n'+JSON.stringify({status}));};"
    "if(location.href!==url)return;"
    "const saved=(globalThis.__moonPausedMedia||[]).filter(el=>el.isConnected&&el.paused&&!el.ended);"
    "if(action==='resume'){"
        "if(!saved.length){globalThis.__moonPausedMedia=[];finish('unavailable');return;}"
        "Promise.all(saved.map(async el=>{try{await el.play();return null;}catch{return el;}})).then(results=>{"
            "const remaining=results.filter(Boolean);globalThis.__moonPausedMedia=remaining;"
            "finish(remaining.length===saved.length?'failed':remaining.length?'partial':'resumed');"
        "});return;"
    "}"
    "const docs=[document],paused=new Set(saved);let changed=false,visited=0;"
    "for(let i=0;i<docs.length&&paused.size<32&&visited<256;i++){"
        "const doc=docs[i];"
        "for(const el of doc.querySelectorAll('audio,video')){"
            "if(++visited>256||paused.size===32)break;"
            "if(el.paused||el.ended)continue;"
            "el.pause();if(el.paused){paused.add(el);changed=true;}"
        "}"
        "if(docs.length<16)for(const frame of doc.querySelectorAll('iframe,frame')){"
            "if(++visited>256||docs.length===16)break;"
            "try{if(frame.contentDocument)docs.push(frame.contentDocument);}catch{}"
        "}"
    "}"
    "globalThis.__moonPausedMedia=[...paused];"
    "finish(changed?'paused':'unavailable');"
    "})";

static const char lua_dom_script[] =
    "((url,json) => {"
      "if(location.href!==url || document.contentType!=='text/html') return;"
      "for(const op of JSON.parse(json)) {"
        "try {"
          "const nodes=document.querySelectorAll(op.selector);"
          "for(let i=0;i<nodes.length && i<64;++i) {"
            "const node=nodes[i];"
            "if(op.kind===1 && !node.matches('script,style,iframe,object,template')) node.textContent=op.value;"
            "if(op.kind===2) node.hidden=true;"
            "if(op.kind===3) node.classList.add(op.value);"
          "}"
        "} catch {}"
      "}"
    "})";

typedef enum { SITE_SNAPSHOT, SITE_CATALOG, SITE_ARTICLE, SITE_CACHE_REMOVE, SITE_DATABASE, SITE_LUA_DOM, SITE_MEDIA } SiteRequest;

static JSStringRef inspect(WKBundlePageRef page,const char *revision,const char *expected,char *change,
                           SiteRequest kind,bool *scheduled,const char **failure) {
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
        const char *source = kind==SITE_ARTICLE ? change : kind==SITE_CATALOG ? catalog_script :
                             kind==SITE_CACHE_REMOVE ? cache_remove_script :
                             kind==SITE_MEDIA ? media_script :
                             kind==SITE_LUA_DOM ? lua_dom_script : snapshot_script;
        if (kind==SITE_DATABASE) {
            char *separator=strchr(change,'\n');
            if (!separator || !separator[1]) return NULL;
            *separator=0;
            source=separator+1;
        }
        JSStringRef script=api.source(source);
        if (kind==SITE_ARTICLE) {
            JSValueRef exception=NULL;
            JSValueRef value=script ? api.evaluate(context,script,NULL,NULL,1,&exception) : NULL;
            if (!exception && value) result=api.to_string(context,value,NULL);
            if (script) api.release_js(script);
            return result;
        }
        const bool direct = kind==SITE_SNAPSHOT || kind==SITE_LUA_DOM;
        JSStringRef id=api.source(kind==SITE_LUA_DOM ? expected : revision), url=direct ? NULL : api.source(expected);
        JSStringRef payload=kind==SITE_CATALOG ? NULL : api.source(change);
        if (script && id && (url || direct) && (payload || kind==SITE_CATALOG)) {
            JSValueRef exception=NULL;
            JSValueRef function=api.evaluate(context,script,NULL,NULL,1,&exception);
            JSObjectRef callback=!exception && function ? api.to_object(context,function,&exception) : NULL;
            if (!exception && callback) {
                JSValueRef arguments[4]={api.make_string(context,id)};
                size_t count=2;
                if (direct) arguments[1]=api.make_string(context,payload);
                else {
                    arguments[1]=api.make_string(context,url);
                    if (kind!=SITE_CATALOG) arguments[count++]=api.make_string(context,payload);
                    const JSFunctionCallback handler=kind==SITE_CATALOG ? catalog_finished :
                        kind==SITE_DATABASE ? database_finished : kind==SITE_MEDIA ? media_finished : cache_remove_finished;
                    arguments[count++]=api.make_callback(context,NULL,handler);
                }
                JSValueRef value=api.call(context,callback,NULL,count,arguments,&exception);
                *failure="\"conversionFailed\"";
                if (!exception && value) {
                    if (kind!=SITE_SNAPSHOT) *scheduled=true;
                    else result=api.to_string(context,value,NULL);
                }
            }
        }
        if (script) api.release_js(script);
        if (id) api.release_js(id);
        if (url) api.release_js(url);
        if (payload) api.release_js(payload);
    }
    return result;
}

void moon_bundle_site_message(WKBundleRef bundle,WKBundlePageRef page,WKStringRef name,WKTypeRef data,const void *info) {
    if (!resolve() || !data || api.type_id(data)!=api.string_type_id()) return;
    SiteRequest kind;
    const char *channel;
    if (api.text_equals(name,"MoonInspectSite")) { kind=SITE_SNAPSHOT; channel="MoonSiteSnapshot"; }
    else if (api.text_equals(name,"MoonInspectCatalog")) { kind=SITE_CATALOG; channel="MoonSiteCatalog"; }
    else if (api.text_equals(name,"MoonReadArticle")) { kind=SITE_ARTICLE; channel="MoonArticleSnapshot"; }
    else if (api.text_equals(name,"MoonRemoveSiteCache")) { kind=SITE_CACHE_REMOVE; channel="MoonSiteCacheRemoval"; }
    else if (api.text_equals(name,"MoonInspectDatabase")) { kind=SITE_DATABASE; channel="MoonSiteDatabase"; }
    else if (api.text_equals(name,"MoonApplyLuaDOM")) { kind=SITE_LUA_DOM; channel=NULL; }
    else if (api.text_equals(name,"MoonControlMedia")) { kind=SITE_MEDIA; channel="MoonMediaResult"; }
    else return;
    // Lua emits at most 32 operations with 1280 argument bytes each, before JSON escaping.
    size_t request_cap=(kind==SITE_LUA_DOM ? 256 : kind==SITE_ARTICLE ? 144 : 32)*1024;
    if (kind==SITE_LUA_DOM) {
        const size_t needed=api.string_capacity((WKStringRef)data);
        if (needed<request_cap) request_cap=needed+1;
    }
    char *request=malloc(request_cap);
    if (!request) return;
    const size_t n=api.read_string((WKStringRef)data,request,request_cap);
    if (!n || n>=request_cap || strlen(request)+1!=n) { free(request); return; }
    char *split=strchr(request,'\n');
    if (!split || split==request || (size_t)(split-request)>20) { free(request); return; }
    char *update=strchr(split+1,'\n');
    if (!update || update==split+1 || !update[1]) { free(request); return; }
    const size_t prefix=(size_t)(split-request)+1;
    const char *failure;
    *split=0;
    *update=0;
    bool scheduled=false;
    JSStringRef snapshot=inspect(page,request,split+1,update+1,kind,&scheduled,&failure);
    if (scheduled || !channel) { free(request); return; }
    *split='\n';
    const size_t capacity=snapshot ? api.size(snapshot) : 0;
    const size_t limit=(kind==SITE_ARTICLE ? 192 : 512)*1024;
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
        post_reply(page,channel,response);
        free(response);
    }
    if (snapshot) api.release_js(snapshot);
    free(request);
}
