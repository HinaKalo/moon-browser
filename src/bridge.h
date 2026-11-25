#ifndef MOON_BRIDGE_H
#define MOON_BRIDGE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum MoonCommand {
    MOON_NEW = 1, MOON_CLOSE, MOON_SELECT, MOON_BACK, MOON_FORWARD, MOON_RELOAD,
    MOON_ADDRESS, MOON_TICK, MOON_INPUT, MOON_DIAGNOSTICS, MOON_PLUGIN_COMMAND,
    MOON_PLUGIN_ENABLE, MOON_PLUGIN_GRANT, MOON_SHUTDOWN, MOON_KEY_NEXT, MOON_KEY_PREV,
    MOON_FOCUS_ADDRESS, MOON_TOGGLE_SIDEBAR, MOON_OPEN_PLUGINS, MOON_UPDATES,
    MOON_PLUGIN_SETTINGS, MOON_MARKET,
    MOON_TAB_PIN, MOON_TAB_MUTE, MOON_TAB_CLOSE_TARGET, MOON_TAB_DUPLICATE, MOON_TAB_COPY_ADDRESS,
    MOON_TAB_CLOSE_OTHERS, MOON_TAB_CLOSE_BELOW, MOON_TAB_GROUP_NEW, MOON_TAB_GROUP_PANEL, MOON_TAB_GROUP_REMOVE,
    MOON_TAB_CLOSE_SELECTED
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
enum { MOON_MEDIA_AUDIO=1, MOON_MEDIA_VIDEO=2 };
typedef struct MoonMediaTab {
    uint64_t id, navigation;
    unsigned playing, playback_result;
    bool muted, site_muted, paused, pending, can_playback;
    char title[193], origin[320];
} MoonMediaTab;
size_t moon_media_tabs(uint32_t offset, MoonMediaTab *rows, size_t cap);
int moon_media_control(uint64_t panel, const char *owner, uint64_t id, uint64_t navigation, unsigned action);
unsigned moon_engine_playing(const MoonView *view);
bool moon_engine_media_action(MoonView *view, uint64_t request, bool resume);
bool moon_engine_media_actions_available(void);
void moon_media_action_result(uint64_t tab, uint64_t request, const char *result);
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
bool moon_shell_focus_mode(void);
bool moon_shell_set_appearance(bool dark, bool focused);
bool moon_appearance_available(void);
bool moon_extension_panel_active(uint64_t panel);
typedef struct { char id[96], title[129], description[257]; unsigned section; } MoonSettingsEntry;
size_t moon_settings_list(uint64_t panel, size_t offset, MoonSettingsEntry *entries, size_t capacity, size_t *next);
bool moon_settings_open(uint64_t panel, const char *target);
unsigned moon_site_settings_tools(uint64_t panel, const char *owner, uint64_t *revision);
bool moon_site_settings_open_tool(uint64_t panel, const char *owner, uint64_t revision, unsigned tool);
int moon_site_settings_set_filtering(uint64_t panel, const char *owner, uint64_t revision, bool enabled);
void moon_site_zoom_apply(const char *origin, unsigned percent, uint64_t except_tab);
void moon_shell_focus_address(void);
bool moon_shell_tab_search(void);
int moon_shell_toggle_fullscreen(void);
void moon_shell_leave_fullscreen(void);
void moon_shell_info(const char *title, const char *body);
void moon_shell_toast(const char *title, const char *body);
int moon_shell_pick_bookmarks(bool save, char *path, size_t capacity);
int moon_shell_pick_html(const char *title, char *path, size_t capacity, bool *replace);
bool moon_shell_write_html(const char *path, const char *data, size_t length, bool replace);
bool moon_bookmark_transfer_allowed(uint64_t source, const char *owner);
bool moon_shell_copy_text(const char *text);
void moon_shell_error(const char *body);
bool moon_shell_confirm(const char *title, const char *body);
const char *moon_profile_dir(void);
bool moon_shell_private(void);
bool moon_shell_open_private(void);
enum { MOON_DEFAULT_APPS_OPENED, MOON_DEFAULT_APPS_INSTALL_REQUIRED, MOON_DEFAULT_APPS_UNAVAILABLE };
int moon_shell_open_default_apps(void);
bool moon_external_url_valid(const char *url);
bool moon_external_url_open(const char *url);
enum { MOON_ADDRESS_SUGGESTION_LIMIT = 6 };
typedef struct { char title[512], url[4096]; bool bookmark; } MoonAddressSuggestion;
size_t moon_suggest_collect(const char *query, MoonAddressSuggestion *output, size_t capacity);
enum { MOON_BOOKMARK_BAR_PAGE = 24 };
typedef struct { uint32_t id; char text[512], folder[161]; } MoonBookmarkBarEntry;
bool moon_bookmark_bar_visible(void);
int moon_bookmark_bar_toggle(void);
size_t moon_bookmark_bar_entries(const char *folder, size_t offset, MoonBookmarkBarEntry *output, size_t capacity, bool *more);
bool moon_bookmark_bar_open(uint32_t id, bool background);
int moon_bookmarks_open_many(uint64_t panel, const uint32_t *ids, size_t length, uint32_t *opened, uint32_t *missing);
void moon_shell_bookmarks_changed(void);
const char *moon_app_dir(void);
uint64_t moon_clock(void);
uint64_t moon_wall_ms(void);
uint32_t moon_current_pid(void);
uint64_t moon_process_birth(uint32_t pid);
bool moon_shell_reveal_file(const char *path);
enum MoonDownloadOpen { MOON_OPEN_DOWNLOAD_DONE, MOON_OPEN_DOWNLOAD_MISSING, MOON_OPEN_DOWNLOAD_CANCELLED,
    MOON_OPEN_DOWNLOAD_BLOCKED, MOON_OPEN_DOWNLOAD_UNAVAILABLE, MOON_OPEN_DOWNLOAD_SYSTEM_PROMPT };
int moon_shell_download_open_status(const char *path);
int moon_shell_open_download(const char *path, bool system_prompt);
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
bool moon_engine_supports_network_capture(void);
bool moon_engine_network_capture(MoonView *view, bool enabled);
enum { MOON_NETWORK_COMPLETE, MOON_NETWORK_REDIRECT, MOON_NETWORK_FAILED };
void moon_network_capture_event(MoonView *view, uint64_t tab, const char *url, uint16_t status, int kind);
bool moon_network_capture_open(const char *id, uint64_t tab, uint64_t navigation);
int moon_network_capture_control(const char *id, uint64_t panel, int action);
void moon_engine_show(MoonView *view, bool visible);
bool moon_engine_load(MoonView *view, const char *url);
MoonView *moon_engine_open_extension(uint64_t token, const char *plugin_id, const char *address);
bool moon_engine_load_extension(MoonView *view, const char *html);
void moon_engine_refresh_extension_appearance(void);
enum MoonInspectorPlacement { MOON_INSPECT_DOCKED, MOON_INSPECT_WINDOW, MOON_INSPECT_PREFERRED };
bool moon_engine_inspect(MoonView *view, int panel, int placement);
bool moon_engine_close_inspector(MoonView *view);
void moon_engine_context_inspect_available(bool available);
const char *moon_context_inspect_label(uint64_t tab);
const char *moon_context_highlight_label(uint64_t tab);
bool moon_engine_cancel_pick(MoonView *view);
bool moon_engine_inspecting(MoonView *view);
enum { MOON_VIEWPORT_MIN = 120, MOON_VIEWPORT_MAX = 2400 };
bool moon_viewport_preset_size(unsigned preset, unsigned *width, unsigned *height);
int moon_engine_viewport(MoonView *view, const char *owner, unsigned width, unsigned height, int fit);
bool moon_engine_viewport_active(const MoonView *view);
void moon_engine_check_viewports(void);
void moon_engine_update_inspectors(void);
void moon_engine_resize_views(bool dpi_changed);
bool moon_engine_page_window(void *window);
enum { MOON_SOURCE_LIMIT = 512 * 1024 };
bool moon_engine_page_source(MoonView *view, uint64_t generation);
bool moon_engine_can_save_html(MoonView *view);
bool moon_engine_save_html(MoonView *view, uint64_t generation);
enum { MOON_HTML_SAVE_LIMIT = 16 * 1024 * 1024 };
bool moon_engine_inspect_site(MoonView *view, uint64_t request);
bool moon_engine_inspect_catalog(MoonView *view, uint64_t request);
bool moon_engine_update_site(MoonView *view, uint64_t request, const char *update);
void moon_engine_find(MoonView *view, const char *query, bool backwards);
void moon_engine_hide_find(MoonView *view);
void moon_engine_set_zoom(MoonView *view, unsigned percent);
unsigned moon_engine_zoom(MoonView *view);
void moon_engine_back(MoonView *view);
void moon_engine_forward(MoonView *view);
void moon_engine_reload(MoonView *view);
void moon_engine_reload_from_origin(MoonView *view);
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
bool moon_engine_apply_lua_dom(MoonView *view, const char *operations);
void moon_engine_trim(void);
bool moon_engine_test_crash(MoonView *view);
int moon_engine_test_download(MoonView *view, const char *path);
bool moon_engine_cancel_download(uint32_t id);
bool moon_engine_retry_available(void);
bool moon_engine_retry_download(uint32_t id, const char *url);
void moon_engine_retry_poll(uint64_t now);
uint32_t moon_download_begin(const char *source);
bool moon_download_source_allowed(const char *source);
int moon_download_retry(uint64_t panel, uint32_t id);
void moon_download_destination(uint32_t id, const char *path);
bool moon_download_folder(char *folder, size_t capacity, bool *ask);
bool moon_download_preferences_allowed(const char *owner, uint64_t panel);
bool moon_download_open_allowed(const char *owner, uint64_t panel);
int moon_download_open(const char *owner, uint64_t panel, uint32_t id);
bool moon_shell_download_default(char *folder, size_t capacity);
int moon_shell_choose_download_folder(const char *initial, char *folder, size_t capacity);
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

bool moon_start(int argc, const uint16_t *const *argv);
void moon_command(int command, uint64_t argument, const char *text);
void moon_engine_event(int kind, uint64_t token, const char *detail);
size_t moon_tab_count(void);
size_t moon_active_index(void);
const char *moon_tab_label(size_t index);
const char *moon_tab_url(size_t index);
size_t moon_tab_index(uint64_t tab);
bool moon_tabs_open_search(uint64_t source);
bool moon_tabs_activate_position(unsigned position);
unsigned moon_tab_flags(size_t index);
uint64_t moon_tab_id(size_t index);
bool moon_tab_selection_pick(size_t index, bool range);
bool moon_tab_selection_clear(void);
int moon_tab_selection_mute_action(void);
void moon_tab_selection_mute_command(uint64_t epoch, bool muted);
int moon_tab_selection_set_muted(uint64_t epoch, bool muted);
uint64_t moon_tab_selection_epoch(void);
size_t moon_tab_selection_count(void);
enum {
    MOON_TAB_DORMANT = 1, MOON_TAB_FAILED = 2, MOON_TAB_LOADING = 4, MOON_TAB_PINNED = 8,
    MOON_TAB_MUTED = 16, MOON_TAB_CAN_PIN = 32, MOON_TAB_CAN_MUTE = 64,
    MOON_TAB_CAN_DUPLICATE = 128, MOON_TAB_CAN_COPY_ADDRESS = 256, MOON_TAB_HAS_SITE = 512, MOON_TAB_SITE_MUTED = 1024,
    MOON_TAB_SELECTED = 2048
};
enum { MOON_TAB_ORGANIZE = 1, MOON_TAB_MANAGE = 2, MOON_TAB_GROUPS = 4 };
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
bool moon_devtools_open(int panel, int placement, uint64_t tab_id, uint64_t navigation);
bool moon_devtools_prefer_window(void);
int moon_devtools_viewport(const char *owner, uint64_t tab, uint64_t navigation, unsigned width, unsigned height, int fit);
bool moon_devtools_viewport_granted(const char *owner);
int moon_devtools_hard_reload(uint64_t tab_id, uint64_t navigation);
int moon_devtools_toggle(uint64_t tab_id, uint64_t navigation);
bool moon_devtools_cancel_picker(void);
bool moon_extension_settings(const char *id, const char *request, char *result, size_t cap);
bool moon_extension_request(uint64_t page, const char *id, const char *request, char *result, size_t cap);
#define MOON_PLUGIN_MANAGER_ADDRESS "moon://plugins/"
bool moon_plugins_request(uint64_t panel, const char *request, char *result, size_t cap);
bool moon_plugin_capture_key(unsigned modifiers, unsigned key);
bool moon_site_data_open(const char *id, uint64_t source, const char *expected);
bool moon_page_source_open(const char *id, uint64_t source, const char *expected);
void moon_page_source_result(uint64_t generation, const char *html, size_t bytes);
void moon_page_save_result(uint64_t request, const char *html, size_t bytes, bool too_large);
bool moon_engine_read_article(MoonView *view, uint64_t request, const char *script);
void moon_reader_result(uint64_t source, uint64_t request, const char *result);
bool moon_reader_open(const char *owner, uint64_t source, uint64_t navigation);
bool moon_reader_return(uint64_t panel, const char *owner);
void moon_web_popup(uint64_t source, const char *opener, const char *target, bool gesture);
bool moon_popups_open(const char *owner, uint64_t source);
bool moon_popups_open_blocked(const char *owner, uint64_t panel, uint64_t notice_id);
bool moon_popups_change_allowed(const char *owner, uint64_t panel, const char *origin, bool allow);
enum { MOON_AUTOPLAY_DEFAULT, MOON_AUTOPLAY_ALLOW, MOON_AUTOPLAY_MUTED, MOON_AUTOPLAY_BLOCK };
bool moon_autoplay_rules_active(void);
unsigned moon_autoplay_mode(const char *url);
bool moon_autoplay_change_allowed(const char *owner, uint64_t panel, const char *origin, bool allow);
enum { MOON_NOTIFICATION_ASK, MOON_NOTIFICATION_ALLOW, MOON_NOTIFICATION_BLOCK };
bool moon_engine_notifications_available(void);
void moon_engine_notification_policy(const char *origin, unsigned mode);
bool moon_notification_request(uint64_t tab, const char *origin);
bool moon_notification_display_allowed(uint64_t tab, const char *origin);
bool moon_notification_change_allowed(const char *owner, uint64_t panel, const char *origin, bool allow);
bool moon_notification_rules_enabled(void);
size_t moon_notification_rules(size_t index, char *origin, size_t capacity, bool *allowed);
bool moon_site_sound_rules_active(void);
bool moon_site_sound_mutes(const char *url);
bool moon_site_sound_panel_allowed(const char *owner, uint64_t panel);
unsigned moon_site_sound_toggle(const char *owner, uint64_t tab, uint64_t navigation);
void moon_site_sound_update(void);
void moon_engine_site_mute(MoonView *view, bool muted);
bool moon_engine_site_muted(const MoonView *view);
enum MoonSiteDataAction { MOON_SITE_REFRESH, MOON_SITE_INSPECTOR, MOON_SITE_CATALOG };
bool moon_engine_remove_site_cache(MoonView *view, uint64_t generation, const char *change);
bool moon_engine_clear_site_cookies_available(void);
bool moon_engine_clear_site_cookies(const char *url, uint64_t request);
int moon_site_clear_cookies(uint64_t panel, const char *owner, uint64_t generation);
void moon_site_cookies_cleared(uint64_t request);
bool moon_engine_inspect_storage_page(MoonView *view, uint64_t request, const char *query);
bool moon_site_storage_page(uint64_t panel, const char *owner, bool session, uint64_t generation,
    const char *query, size_t length, uint32_t offset, bool refresh);
void moon_site_storage_page_result(uint64_t tab, uint64_t request, const char *result);
bool moon_engine_inspect_database(MoonView *view, uint64_t request, const char *query);
bool moon_site_data_database(uint64_t panel, const char *owner, unsigned index, uint64_t generation, bool refresh);
bool moon_site_database_records(uint64_t panel, const char *owner, unsigned index, uint64_t generation,
    uint64_t revision, unsigned store, uint16_t offset, bool refresh);
void moon_site_database_result(MoonView *view, uint64_t tab, uint64_t request, const char *result);
int moon_site_database_clear(uint64_t panel, const char *owner, unsigned index, uint64_t generation,
    uint64_t revision, unsigned store);
int moon_site_database_remove_record(uint64_t panel, const char *owner, unsigned index, uint64_t generation,
    uint64_t revision, unsigned store, uint64_t page_revision, unsigned row);
void moon_site_cache_result(MoonView *view, uint64_t tab, uint64_t generation, const char *result);
int moon_site_cache_remove(uint64_t panel, const char *owner, unsigned index, uint64_t generation);
bool moon_site_data_action(uint64_t panel, const char *id, int action);
int moon_site_remove_cookie(uint64_t panel, const char *owner, uint32_t entry, uint64_t generation, uint64_t page_revision);
bool moon_site_data_cookie_url(uint64_t panel, const char *id, char *url, size_t cap);
bool moon_site_data_update(uint64_t panel, const char *id, bool session, uint32_t entry, uint64_t generation,
    uint64_t page_revision, const char *value, size_t length);
bool moon_site_data_create(uint64_t panel, const char *id, bool session, uint64_t generation,
    const char *key, size_t key_length, const char *value, size_t value_length);
int moon_site_data_clear(uint64_t panel, const char *id, bool session, uint64_t generation);
void moon_site_data_result(uint64_t source, uint64_t request, const char *snapshot, bool catalog);
bool moon_plugin_open_page(const char *id);
enum MoonPluginMenu {
    MOON_MENU_NONE, MOON_MENU_PINNED, MOON_MENU_PAGE, MOON_MENU_LIBRARY,
    MOON_MENU_PRIVACY, MOON_MENU_DEVELOPER, MOON_MENU_EXTENSIONS, MOON_MENU_COUNT
};
unsigned moon_plugin_action_menu(size_t index, size_t command);
bool moon_plugin_action_site_menu(size_t index, size_t command);
typedef struct { uint64_t tab_id, navigation; bool site_muted, tab_muted; char origin[320]; } MoonSiteContext;
bool moon_site_context(MoonSiteContext *site);
void moon_site_menu_run(const MoonSiteContext *site, size_t index, size_t command);
enum MoonLinkMenu { MOON_LINK_OPEN = 1, MOON_LINK_COPY, MOON_LINK_BOOKMARK, MOON_LINK_MENU_STRIDE = 14 };
enum { MOON_PLUGIN_LIMIT = 64, MOON_PLUGIN_MENU_PERMISSION_LIMIT = 42 };
typedef struct { uint64_t tab_id, navigation; char url[4096], label[512]; } MoonLinkContext;
bool moon_link_capture(MoonLinkContext *link, uint64_t tab);
bool moon_link_current(const MoonLinkContext *link);
unsigned moon_plugin_link_action(size_t index, size_t command);
bool moon_plugin_bound_action(size_t index, size_t command);
void moon_link_menu_run(const MoonLinkContext *link, size_t index, size_t command);
unsigned moon_link_open(const MoonLinkContext *link);
typedef struct { uint64_t source, anchor; bool after, into_group; } MoonTabDrop;
bool moon_tab_drop_enabled(void);
bool moon_tab_drop_valid(const MoonTabDrop *drop);
void moon_tab_drop_run(const MoonTabDrop *drop);
void moon_tab_nudge(bool down);
int moon_tabs_reorder(const MoonTabDrop *drop);
void moon_shell_refresh_tab_order(bool reveal_active);
enum { MOON_MAX_GROUPS = 24, MOON_MAX_SIDEBAR_ROWS = 128 + MOON_MAX_GROUPS };
typedef struct {
    size_t tab;
    uint32_t group, color, members;
    bool header, collapsed, active;
} MoonSidebarRow;
typedef struct {
    uint32_t id, color, members;
    bool collapsed;
    char name[97];
} MoonTabGroup;
enum { MOON_GROUP_CREATE, MOON_GROUP_ASSIGN, MOON_GROUP_REMOVE };
typedef struct { uint32_t moved, kept; } MoonGroupSelectionResult;
size_t moon_group_selection_choices(MoonTabGroup *groups, size_t capacity, bool *can_assign, bool *can_remove);
void moon_group_selection_command(uint64_t epoch, int action, uint32_t id);
int moon_group_selection_apply(uint64_t epoch, int action, uint32_t id, MoonGroupSelectionResult *result);
size_t moon_sidebar_rows(MoonSidebarRow *rows, size_t capacity, size_t *active_row);
const char *moon_group_name(uint32_t group);
void moon_group_toggle(uint32_t group);
bool moon_group_panel(const char *owner, uint64_t source);
int moon_group_create(uint64_t source);
int moon_group_remove_tab(uint64_t source);
bool moon_group_list(uint64_t panel, const char *owner, MoonTabGroup *groups, size_t capacity,
    size_t *count, uint32_t *assigned, bool *assignable);
int moon_group_assign(uint64_t panel, const char *owner, uint32_t group);
int moon_group_update(uint64_t panel, const char *owner, uint32_t group, const char *name, unsigned color, bool collapsed);
int moon_group_dissolve(uint64_t panel, const char *owner, uint32_t group);
bool moon_plugin_key(unsigned modifiers, unsigned key, bool repeated);
bool moon_plugin_global_key(unsigned id, unsigned modifiers, unsigned key);
bool moon_shell_register_hotkey(unsigned id, unsigned modifiers, unsigned key);
void moon_shell_unregister_hotkey(unsigned id);
void moon_shell_wake(void);
unsigned moon_plugin_ui_menu(const char *owner, const char *command, bool add);
typedef bool (*MoonPluginConsent)(const void *context);
int moon_page_save(const char *owner, uint64_t tab, uint64_t navigation, const void *context, MoonPluginConsent consent);
unsigned moon_plugin_ui_shortcut(const char *owner, const char *command, const char *shortcut, bool global,
    const void *context, MoonPluginConsent consent);
bool moon_reading_find(uint64_t tab, const char *owner);
unsigned moon_reading_zoom(uint64_t tab, int action);
int moon_window_fullscreen(uint64_t tab, uint64_t navigation, const char *owner);
int moon_recent_reopen(uint64_t tab, bool specific, uint32_t entry);
int moon_session_restore(uint64_t source);
int moon_tabs_organize(uint64_t tab, int operation);
typedef struct MoonTabCloseResult { uint32_t closed, kept; } MoonTabCloseResult;
bool moon_tabs_close_group(uint64_t tab, bool below, MoonTabCloseResult *result);
bool moon_tabs_close_selection(uint64_t epoch, MoonTabCloseResult *result);
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
