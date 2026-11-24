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
    MOON_SCRIPTS_INSTALL, MOON_SCRIPTS_TOGGLE, MOON_SCRIPTS_REMOVE, MOON_PLUGIN_SETTINGS, MOON_MARKET,
    MOON_TAB_PIN, MOON_TAB_MUTE, MOON_TAB_CLOSE_TARGET, MOON_TAB_DUPLICATE, MOON_TAB_COPY_ADDRESS,
    MOON_TAB_CLOSE_OTHERS, MOON_TAB_CLOSE_BELOW
};
enum MoonEngineEvent {
    MOON_STARTED = 1, MOON_COMMITTED, MOON_FINISHED, MOON_FAILED, MOON_CHANGED,
    MOON_TERMINATED, MOON_UNSAFE, MOON_DOWNLOAD_START, MOON_DOWNLOAD_END, MOON_POPUP,
    MOON_PAINTED, MOON_SAME_DOCUMENT
};
enum MoonDownloadResult { MOON_DL_COMPLETE, MOON_DL_FAILED, MOON_DL_CANCELLED, MOON_DL_INTERRUPTED };

typedef struct MoonView MoonView;
typedef struct MoonPipe MoonPipe;
typedef struct MoonSample { uint32_t pid; uint64_t bytes; } MoonSample;
typedef struct MoonTaskOverview {
    uint64_t private_bytes, peak_bytes, high_bytes, target_bytes, before_bytes, after_bytes;
    uint32_t open, live, dormant, protected_tabs, processes, evictions, retiring, warm_limit, idle_seconds;
    bool pressure, has_sweep, sweep_pending;
} MoonTaskOverview;
typedef struct MoonTaskTab {
    uint64_t id;
    uint32_t phase, pid;
    int protection;
    char title[193];
} MoonTaskTab;
typedef struct MoonTaskProcess { uint64_t private_bytes; uint32_t pid, tabs; bool browser; } MoonTaskProcess;
void moon_tasks_overview(MoonTaskOverview *overview);
size_t moon_tasks_tabs(uint32_t offset, MoonTaskTab *rows, size_t cap);
size_t moon_tasks_processes(uint32_t offset, MoonTaskProcess *rows, size_t cap);
unsigned moon_tasks_action(uint64_t source, uint64_t id, bool discard);
enum { MOON_DOM_SET_TEXT = 1, MOON_DOM_HIDE, MOON_DOM_ADD_CLASS, MOON_DOM_MAX_OPS = 32 };
enum { MOON_RELOAD_NO_MATCH = 0, MOON_RELOAD_OK, MOON_RELOAD_PROTECTED };
typedef struct MoonDomOp { unsigned kind; char selector[257]; char value[1025]; } MoonDomOp;

int moon_shell_run(void);
unsigned moon_shell_test_dpi(void);
void moon_shell_address(const char *value, bool replace_focused);
void moon_shell_status(const char *value);
void moon_shell_show_home(bool visible);
void moon_shell_refresh(void);
uint64_t moon_shell_window_handle(void);
bool moon_shell_dark_mode(void);
void moon_shell_focus_address(void);
void moon_shell_toggle_sidebar(void);
void moon_shell_toggle_theme(void);
void moon_shell_info(const char *title, const char *body);
void moon_shell_toast(const char *title, const char *body);
int moon_shell_pick_bookmarks(bool save, char *path, size_t capacity);
bool moon_bookmark_transfer_allowed(uint64_t source, const char *owner);
bool moon_shell_copy_text(const char *text);
void moon_shell_error(const char *body);
bool moon_shell_confirm(const char *title, const char *body);
const char *moon_profile_dir(void);
bool moon_shell_private(void);
bool moon_shell_open_private(void);
const char *moon_app_dir(void);
uint64_t moon_clock(void);
uint64_t moon_wall_ms(void);
uint32_t moon_current_pid(void);
uint64_t moon_process_birth(uint32_t pid);
bool moon_shell_reveal_file(const char *path);
uint64_t moon_perf_us(void);
bool moon_low_memory(void);
size_t moon_memory_samples(MoonSample *samples, size_t cap);
void moon_quit(int status);
void moon_log(const char *path, const char *line);
bool moon_read_text(const char *path, char *output, size_t cap);
bool moon_read_plain_text(const char *path, char *output, size_t cap);
bool moon_write_text(const char *path, const char *text);
size_t moon_plugin_directories(const char *parent, char *names, size_t stride, size_t cap);
bool moon_plugin_thread(void *task);
void *moon_process_watch(uint32_t pid);
bool moon_process_exited(void *watch);
void moon_process_unwatch(void *watch);

const char *moon_engine_init(void);
bool moon_engine_set_request_policy(const char *rules, const char *document_script);
void moon_engine_shutdown(void);
MoonView *moon_engine_open(uint64_t token);
void moon_engine_close(MoonView *view);
void moon_engine_show(MoonView *view, bool visible);
bool moon_engine_load(MoonView *view, const char *url);
MoonView *moon_engine_open_extension(uint64_t token, const char *plugin_id, const char *address);
bool moon_engine_load_extension(MoonView *view, const char *html);
void moon_engine_refresh_extension_theme(void);
bool moon_engine_inspect(MoonView *view, int panel);
enum { MOON_SOURCE_LIMIT = 512 * 1024 };
bool moon_engine_page_source(MoonView *view, uint64_t generation);
bool moon_engine_inspect_site(MoonView *view, uint64_t request);
bool moon_engine_update_site(MoonView *view, uint64_t request, const char *update);
void moon_engine_find(MoonView *view, const char *query, bool backwards);
void moon_engine_hide_find(MoonView *view);
void moon_engine_set_zoom(MoonView *view, unsigned percent);
unsigned moon_engine_zoom(MoonView *view);
void moon_engine_back(MoonView *view);
void moon_engine_forward(MoonView *view);
void moon_engine_reload(MoonView *view);
unsigned moon_engine_controls(MoonView *view);
bool moon_engine_restore(MoonView *view, const void *state);
const void *moon_engine_save(MoonView *view);
const void *moon_engine_retain_state(const void *state);
void moon_engine_release_state(const void *state);
uint32_t moon_engine_pid(MoonView *view);
bool moon_engine_media(MoonView *view);
void moon_engine_mute(MoonView *view, bool muted);
void moon_engine_read(MoonView *view, char *title, size_t title_cap, char *url, size_t url_cap);
void moon_engine_committed_url(MoonView *view, char *url, size_t cap);
void moon_engine_apply_dom(MoonView *view, const char *javascript);
void moon_engine_trim(void);
bool moon_engine_test_crash(MoonView *view);
int moon_engine_test_download(MoonView *view, const char *path);
bool moon_engine_cancel_download(uint32_t id);
uint32_t moon_download_begin(void);
void moon_download_destination(uint32_t id, const char *path);
void moon_download_progress(uint32_t id, uint64_t chunk, uint64_t total);
void moon_download_finish(uint32_t id, int result);
void moon_engine_probe(MoonView *view);
void moon_engine_test_fallback(bool enabled);

MoonPipe *moon_pipe_open(const char *executable, uint32_t *error);
bool moon_pipe_send(MoonPipe *pipe, const char *line);
int moon_pipe_read(MoonPipe *pipe, char *data, size_t capacity);
typedef bool (*MoonPipeActive)(const void *context);
int moon_pipe_read_active(MoonPipe *pipe, char *data, size_t capacity, MoonPipeActive active, const void *context);
bool moon_pipe_close(MoonPipe *pipe);
void moon_pipe_set_budget(MoonPipe *pipe, unsigned millis);
void moon_plugin_wait(void);
const char *moon_lua_version(void);
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
uint64_t moon_tab_id(size_t index);
enum {
    MOON_TAB_DORMANT = 1, MOON_TAB_FAILED = 2, MOON_TAB_LOADING = 4, MOON_TAB_PINNED = 8,
    MOON_TAB_MUTED = 16, MOON_TAB_CAN_PIN = 32, MOON_TAB_CAN_MUTE = 64,
    MOON_TAB_CAN_DUPLICATE = 128, MOON_TAB_CAN_COPY_ADDRESS = 256
};
enum { MOON_TAB_ORGANIZE = 1, MOON_TAB_MANAGE = 2 };
unsigned moon_tab_tools_permissions(void);
unsigned moon_controls(void);
size_t moon_plugin_count(void);
const char *moon_plugin_label(size_t index);
size_t moon_plugin_action_count(size_t index);
const char *moon_plugin_action(size_t index, size_t command);
const char *moon_plugin_action_shortcut(size_t index, size_t command);
bool moon_plugin_enabled(size_t index);
const char *moon_plugin_permission_label(size_t permission);
unsigned moon_plugin_permission_flags(size_t index, size_t permission);
bool moon_plugin_has_settings(size_t index);
int moon_userscript_reload_active(const char *id);
bool moon_devtools_open(int panel, uint64_t tab_id);
bool moon_extension_settings(const char *id, const char *request, char *result, size_t cap);
bool moon_extension_request(uint64_t page, const char *id, const char *request, char *result, size_t cap);
#define MOON_PLUGIN_MANAGER_ADDRESS "moon://plugins/"
bool moon_plugins_request(uint64_t panel, const char *request, char *result, size_t cap);
bool moon_site_data_open(const char *id, uint64_t source, const char *expected);
bool moon_page_source_open(const char *id, uint64_t source, const char *expected);
void moon_page_source_result(uint64_t generation, const char *html, size_t bytes);
bool moon_site_data_action(uint64_t panel, const char *id, bool inspector);
bool moon_site_data_update(uint64_t panel, const char *id, bool session, uint32_t entry, uint64_t generation,
    const char *value, size_t length);
void moon_site_data_result(uint64_t source, uint64_t request, const char *snapshot);
bool moon_plugin_open_page(const char *id);
enum MoonPluginMenu {
    MOON_MENU_NONE, MOON_MENU_PINNED, MOON_MENU_PAGE, MOON_MENU_LIBRARY,
    MOON_MENU_PRIVACY, MOON_MENU_DEVELOPER, MOON_MENU_EXTENSIONS, MOON_MENU_COUNT
};
unsigned moon_plugin_action_menu(size_t index, size_t command);
bool moon_plugin_key(unsigned modifiers, unsigned key, bool repeated);
bool moon_plugin_global_key(unsigned id, unsigned modifiers, unsigned key);
bool moon_shell_register_hotkey(unsigned id, unsigned modifiers, unsigned key);
void moon_shell_unregister_hotkey(unsigned id);
void moon_shell_wake(void);
unsigned moon_plugin_ui_menu(const char *owner, const char *command, bool add);
typedef bool (*MoonPluginConsent)(const void *context);
unsigned moon_plugin_ui_shortcut(const char *owner, const char *command, const char *shortcut, bool global,
    const void *context, MoonPluginConsent consent);
bool moon_reading_find(uint64_t tab, const char *owner);
unsigned moon_reading_zoom(uint64_t tab, int action);
int moon_recent_reopen(uint64_t tab, bool specific, uint32_t entry);
int moon_session_restore(uint64_t source);
int moon_tabs_organize(uint64_t tab, int operation);
typedef struct MoonTabCloseResult { uint32_t closed, kept; } MoonTabCloseResult;
bool moon_tabs_close_group(uint64_t tab, bool below, MoonTabCloseResult *result);
enum { MOON_ERASE_SITE = 1, MOON_ERASE_CACHE = 2 };
unsigned moon_engine_erase_data(unsigned requested);
void moon_privacy_engine_done(unsigned category);
bool moon_privacy_allowed(uint64_t tab, const char *owner);
bool moon_shell_find_show(void);
bool moon_shell_find_hide(void);
void moon_shell_find_result(const char *query, unsigned matches);
void moon_find_query(const char *query, bool backwards);
void moon_find_dismiss(bool refocus);
void moon_find_result(uint64_t tab, const char *query, unsigned matches);
size_t moon_action_count(bool home);
const char *moon_action_label(size_t index, bool home);
void moon_action_run(size_t index, bool home);
void moon_plugin_worker(void *task);
bool moon_update_thread(void);
void moon_update_worker(void);
int moon_update_read(const char *path, char *buffer, size_t capacity, size_t *length);
bool moon_update_download(const char *path, bool portable, uint64_t size, const uint8_t *hash);
bool moon_update_open(bool portable, uint64_t size, const uint8_t *hash);
bool moon_market_read(char *buffer, size_t capacity, size_t *length);
bool moon_market_thread(void);
void moon_market_worker(void);
#endif
