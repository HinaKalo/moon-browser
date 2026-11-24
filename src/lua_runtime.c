#include "bridge.h"
#include <Lua/lauxlib.h>
#include <Lua/lualib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct LuaBudget {
    size_t memory;
    unsigned checks;
} LuaBudget;

static void *bounded_alloc(void *context, void *ptr, size_t old_size, size_t size) {
    LuaBudget *budget = context;
    if (!ptr) old_size = 0;
    if (!size) {
        budget->memory -= old_size;
        free(ptr);
        return NULL;
    }
    if (size > 512 * 1024 - (budget->memory - old_size)) return NULL;
    void *next = realloc(ptr, size);
    if (next) budget->memory = budget->memory - old_size + size;
    return next;
}

static void bounded_hook(lua_State *state, lua_Debug *unused) {
    void *context;
    lua_getallocf(state, &context);
    LuaBudget *budget = context;
    if (++budget->checks >= 50) luaL_error(state, "Lua instruction limit exceeded");
}

static int open_environment(lua_State *state) {
    luaL_requiref(state, LUA_GNAME, luaopen_base, 1);
    lua_pop(state, 1);
    static const char *blocked[] = {
        "collectgarbage", "dofile", "getmetatable", "load", "loadfile", "pcall",
        "print", "setmetatable", "warn", "xpcall"
    };
    for (size_t i = 0; i < sizeof(blocked) / sizeof(*blocked); ++i) {
        lua_pushnil(state);
        lua_setglobal(state, blocked[i]);
    }
    luaL_requiref(state, LUA_TABLIBNAME, luaopen_table, 1);
    lua_pop(state, 1);
    luaL_requiref(state, LUA_MATHLIBNAME, luaopen_math, 1);
    lua_pop(state, 1);
    luaL_requiref(state, LUA_UTF8LIBNAME, luaopen_utf8, 1);
    lua_pop(state, 1);
    return 0;
}

typedef struct DomRun {
    MoonDomOp *ops;
    int count;
    const char *url;
} DomRun;

static void argument(lua_State *state, int index, char *output, size_t cap, bool empty) {
    luaL_checktype(state, index, LUA_TSTRING);
    size_t length;
    const char *value = lua_tolstring(state, index, &length);
    if ((!length && !empty) || length >= cap || memchr(value, 0, length))
        luaL_argerror(state, index, "invalid length or embedded NUL");
    memcpy(output, value, length + 1);
}

static int dom_op(lua_State *state) {
    DomRun *run = lua_touserdata(state, lua_upvalueindex(1));
    const unsigned op = (unsigned)lua_tointeger(state, lua_upvalueindex(2));
    const int arguments = op == MOON_DOM_HIDE ? 1 : 2;
    if (lua_gettop(state) != arguments) return luaL_error(state, "incorrect number of arguments");
    if (run->count == MOON_DOM_MAX_OPS) return luaL_error(state, "DOM operation limit exceeded");
    MoonDomOp *item = &run->ops[run->count];
    item->kind = op;
    argument(state, 1, item->selector, sizeof(item->selector), false);
    item->value[0] = 0;
    if (arguments == 2) argument(state, 2, item->value, sizeof(item->value), op == MOON_DOM_SET_TEXT);
    ++run->count;
    return 0;
}

static int open_userscript_api(lua_State *state) {
    DomRun *run = lua_touserdata(state, 1);
    lua_newtable(state);
    lua_pushinteger(state, 1);
    lua_setfield(state, -2, "apiVersion");
    lua_newtable(state);
    lua_pushstring(state, run->url);
    lua_setfield(state, -2, "url");
    lua_setfield(state, -2, "page");
    lua_newtable(state);
    static const char *methods[] = {"setText", "hide", "addClass"};
    for (unsigned i = 0; i < sizeof(methods) / sizeof(*methods); ++i) {
        lua_pushlightuserdata(state, run);
        lua_pushinteger(state, MOON_DOM_SET_TEXT + i);
        lua_pushcclosure(state, dom_op, 2);
        lua_setfield(state, -2, methods[i]);
    }
    lua_setfield(state, -2, "dom");
    lua_setglobal(state, "moon");
    return 0;
}

static bool run_source(const char *source, DomRun *run, char *error, size_t cap) {
    LuaBudget budget = {0};
    lua_State *state = lua_newstate(bounded_alloc, &budget);
    if (!state) {
        snprintf(error, cap, "Lua memory limit exceeded");
        return false;
    }
    int status = luaL_loadbufferx(state, source, strlen(source), "@userscript", "t");
    if (status == LUA_OK && run) {
        lua_pushcfunction(state, open_environment);
        status = lua_pcall(state, 0, 0, 0);
        if (status == LUA_OK) {
            lua_pushcfunction(state, open_userscript_api);
            lua_pushlightuserdata(state, run);
            status = lua_pcall(state, 1, 0, 0);
        }
        if (status == LUA_OK) {
            lua_sethook(state, bounded_hook, LUA_MASKCOUNT, 512);
            status = lua_pcall(state, 0, 0, 0);
        }
    }
    if (status != LUA_OK) {
        const char *message = lua_type(state, -1) == LUA_TSTRING ? lua_tostring(state, -1) : NULL;
        snprintf(error, cap, "%s", message ? message : "Lua script failed");
    } else if (cap) error[0] = 0;
    lua_close(state);
    return status == LUA_OK;
}

bool moon_lua_check(const char *source, char *error, size_t cap) {
    return run_source(source, NULL, error, cap);
}

int moon_lua_userscript(const char *source, const char *url, MoonDomOp *ops, char *error, size_t cap) {
    DomRun run = {.ops = ops, .url = url};
    return run_source(source, &run, error, cap) ? run.count : -1;
}
