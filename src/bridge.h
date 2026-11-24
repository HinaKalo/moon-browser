#ifndef MOON_BRIDGE_H
#define MOON_BRIDGE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum MoonCommand {
    MOON_NEW = 1, MOON_CLOSE, MOON_SELECT, MOON_BACK, MOON_FORWARD, MOON_RELOAD,
    MOON_ADDRESS, MOON_TICK, MOON_INPUT, MOON_DIAGNOSTICS, MOON_PLUGIN_COMMAND,
    MOON_PLUGIN_ENABLE, MOON_PLUGIN_GRANT, MOON_SHUTDOWN, MOON_KEY_NEXT, MOON_KEY_PREV,
    MOON_FOCUS_ADDRESS, MOON_TOGGLE_SIDEBAR, MOON_TOGGLE_THEME, MOON_OPEN_PLUGINS, MOON_UPDATES,
    MOON_SCRIPTS_INSTALL, MOON_SCRIPTS_TOGGLE, MOON_SCRIPTS_REMOVE
};
enum MoonEngineEvent {
    MOON_STARTED = 1, MOON_COMMITTED, MOON_FINISHED, MOON_FAILED, MOON_CHANGED,
    MOON_TERMINATED, MOON_UNSAFE, MOON_DOWNLOAD_START, MOON_DOWNLOAD_END, MOON_POPUP,
    MOON_PAINTED
};

typedef struct MoonView MoonView;
typedef struct MoonPipe MoonPipe;
typedef struct MoonSample { uint32_t pid; uint64_t bytes; } MoonSample;
enum { MOON_DOM_SET_TEXT = 1, MOON_DOM_HIDE, MOON_DOM_ADD_CLASS, MOON_DOM_MAX_OPS = 32 };
typedef struct MoonDomOp { unsigned kind; char selector[257]; char value[1025]; } MoonDomOp;

int moon_shell_run(void);
unsigned moon_shell_test_dpi(void);
void moon_shell_address(const char *value, bool replace_focused);
void moon_shell_status(const char *value);
void moon_shell_show_home(bool visible);
void moon_shell_refresh(void);
void moon_shell_focus_address(void);
void moon_shell_toggle_sidebar(void);
void moon_shell_toggle_theme(void);
void moon_shell_open_plugins(void);
void moon_shell_info(const char *title, const char *body);
void moon_shell_error(const char *body);
bool moon_shell_confirm(const char *title, const char *body);
const char *moon_profile_dir(void);
const char *moon_app_dir(void);
uint64_t moon_clock(void);
uint64_t moon_perf_us(void);
bool moon_low_memory(void);
size_t moon_memory_samples(MoonSample *samples, size_t cap);
void moon_quit(int status);
void moon_log(const char *path, const char *line);
bool moon_read_text(const char *path, char *output, size_t cap);
bool moon_write_text(const char *path, const char *text);
size_t moon_plugin_directories(const char *parent, char *names, size_t stride, size_t cap);
bool moon_plugin_thread(void *task);
void *moon_process_watch(uint32_t pid);
bool moon_process_exited(void *watch);
void moon_process_unwatch(void *watch);

const char *moon_engine_init(void);
void moon_engine_shutdown(void);
MoonView *moon_engine_open(uint64_t token);
void moon_engine_close(MoonView *view);
void moon_engine_show(MoonView *view, bool visible);
bool moon_engine_load(MoonView *view, const char *url);
void moon_engine_back(MoonView *view);
void moon_engine_forward(MoonView *view);
void moon_engine_reload(MoonView *view);
unsigned moon_engine_controls(MoonView *view);
bool moon_engine_restore(MoonView *view, const void *state);
const void *moon_engine_save(MoonView *view);
void moon_engine_release_state(const void *state);
uint32_t moon_engine_pid(MoonView *view);
bool moon_engine_media(MoonView *view);
void moon_engine_read(MoonView *view, char *title, size_t title_cap, char *url, size_t url_cap);
void moon_engine_committed_url(MoonView *view, char *url, size_t cap);
void moon_engine_apply_dom(MoonView *view, const char *javascript);
void moon_engine_trim(void);
bool moon_engine_test_crash(MoonView *view);
int moon_engine_test_download(MoonView *view, const char *path);
void moon_engine_probe(MoonView *view);
void moon_engine_test_fallback(bool enabled);

MoonPipe *moon_pipe_open(const char *executable, uint32_t *error);
bool moon_pipe_send(MoonPipe *pipe, const char *line);
int moon_pipe_read(MoonPipe *pipe, char *data, size_t capacity);
bool moon_pipe_close(MoonPipe *pipe);
bool moon_lua_check(const char *source, char *error, size_t cap);
int moon_lua_userscript(const char *source, const char *url, MoonDomOp *ops, char *error, size_t cap);
size_t moon_userscript_count(void);
const char *moon_userscript_label(size_t index);
const char *moon_userscript_error(size_t index);
bool moon_userscript_enabled(size_t index);

bool moon_start(int argc, const uint16_t *const *argv);
void moon_command(int command, uint64_t argument, const char *text);
void moon_engine_event(int kind, uint64_t token, const char *detail);
size_t moon_tab_count(void);
size_t moon_active_index(void);
const char *moon_tab_label(size_t index);
unsigned moon_tab_flags(size_t index);
unsigned moon_controls(void);
size_t moon_plugin_count(void);
const char *moon_plugin_label(size_t index);
const char *moon_plugin_action(size_t index);
unsigned moon_plugin_flags(size_t index);
size_t moon_action_count(bool home);
const char *moon_action_label(size_t index, bool home);
void moon_action_run(size_t index, bool home);
void moon_plugin_worker(void *task);
bool moon_update_thread(void);
void moon_update_worker(void);
int moon_update_read(const char *path, char *buffer, size_t capacity, size_t *length);
bool moon_update_download(const char *path, bool portable, uint64_t size, const uint8_t *hash);
bool moon_update_open(bool portable, uint64_t size, const uint8_t *hash);
#endif
