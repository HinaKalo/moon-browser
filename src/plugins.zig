const std = @import("std");
const native = @import("native");
const sdk = @import("moon_plugin");
const api = @import("plugin_host_api.zig");
const network = @import("network_policy.zig");
const userscripts = @import("userscripts.zig");
const allocator = std.heap.page_allocator;

pub const Snapshot = api.Snapshot;
const Permissions = api.Permissions;
const Protocol = enum { legacy, v2 };

const LegacyManifest = struct {
    api_version: u32,
    id: []const u8,
    name: []const u8,
    executable: []const u8,
    command: []const u8,
    menu: ?sdk.MenuGroup = null,
    permissions: []const []const u8 = &.{},
    events: []const []const u8 = &.{},
};
const Grant = struct {
    id: []const u8, enabled: bool, tabs_read: bool,
    lua_scripts_manage: bool = false, page_inspect: bool = false, history_manage: bool = false, network_filter: bool = false,
    bookmarks_manage: bool = false, downloads_manage: bool = false, site_data_read: bool = false, page_reading: bool = false,
    downloads_preferences: ?bool = null,
    downloads_open: ?bool = null,
    tabs_closed_manage: bool = false,
    privacy_clear: bool = false,
    task_manager_manage: bool = false,
    media_control: ?bool = null,
    network_capture: ?bool = null,
    ui_commands: bool = false,
    tabs_organize: bool = false,
    private_window: bool = false,
    tabs_manage: ?bool = null,
    search_manage: bool = false,
    site_data_write: ?bool = null,
    site_data_cookie_details: ?bool = null,
    site_data_cookie_clear: ?bool = null,
    ui_settings: ?bool = null,
    site_data_cache_write: ?bool = null,
    site_data_records: ?bool = null,
    site_data_database_write: ?bool = null,
    site_settings_autoplay: ?bool = null,
    site_settings_sound: ?bool = null,
    site_settings_zoom: ?bool = null,
    site_settings_notifications: ?bool = null,
    popups_manage: bool = false,
    page_source: bool = false,
    tabs_session_manage: bool = false,
    bookmarks_transfer: ?bool = null,
    window_fullscreen: ?bool = null,
    window_appearance: ?bool = null,
    page_save: ?bool = null,
    page_reader: ?bool = null,
    tabs_groups: ?bool = null,
    browser_default_app: ?bool = null,
    menu_items: []const []const u8 = &.{},
    hidden_menu_items: []const []const u8 = &.{},
    unpinned_menu_items: []const []const u8 = &.{},
    hotkey: ?sdk.RegisteredShortcut = null,
};
const Outcome = enum { ok, failed, timed_out, crashed };
const Trigger = enum { command, changed, timeout_test, crash_test };
const CallState = enum(u8) { idle, queued, serving, ready };
const Rpc = struct {
    state: std.atomic.Value(CallState) = .init(.idle),
    buffer: [sdk.frame_limit]u8 = undefined,
    size: usize = 0,
    deadline: u64 = 0,
    sent: usize = 0,
};
const Task = struct {
    done: std.atomic.Value(bool) = .init(false),
    executable: [*:0]const u8,
    epoch: *const std.atomic.Value(u32),
    expected_epoch: u32,
    snapshot: ?Snapshot,
    target_tab_id: u64,
    target_navigation: u64,
    selection_epoch: u64,
    group_selection: ?sdk.TabGroupSelection,
    mute_selection: ?bool,
    trigger: Trigger,
    plugin_id: [*:0]const u8,
    command_id: [*:0]const u8,
    interactive: bool,
    owner: u64,
    dark: bool,
    grants: Permissions,
    rpc: ?*Rpc = null,
    link: ?*api.LinkInvocation = null,
    drop: ?api.TabDropInvocation = null,
    outcome: Outcome = .failed,
    message: [512:0]u8 = @splat(0),
    toast: bool = false,
};
const MenuOverride = enum { default, pinned, unpinned, hidden };
const UserShortcut = struct { plugin: []const u8, command: []const u8, shortcut: []const u8 };
const PendingCommand = struct { action: usize, tab: u64, navigation: u64 };
const WebContextAction = enum { inspect_element, highlight_link };
const Command = struct {
    id: [64:0]u8 = @splat(0), label: [256:0]u8 = @splat(0), interactive: bool = false,
    shortcut: ?sdk.Shortcut = null,
    menu_group: ?sdk.MenuGroup = null,
    default_pinned: bool = false,
    site_menu: bool = false,
    link_menu: ?sdk.LinkMenuAction = null,
    web_context_action: ?WebContextAction = null,
    web_context_label: [256:0]u8 = @splat(0),
    tab_drop: bool = false,
    menu_override: MenuOverride = .default,
    user_shortcut: ?Hotkey = null,
    fn bound(self: *const Command) bool {
        return self.link_menu!=null or self.tab_drop;
    }
};
comptime {
    if (native.MOON_LINK_MENU_STRIDE != sdk.command_limit) @compileError("WebKit link menu stride must match the plugin command limit");
    if (std.enums.values(sdk.Permission).len > native.MOON_PLUGIN_MENU_PERMISSION_LIMIT)
        @compileError("Native plugin menu must have a slot for every permission");
}
const Hotkey = struct {
    action: usize, mods: c_uint, key: c_uint, scope: sdk.ShortcutScope,
    text: [24:0]u8 = @splat(0), slot: ?u1 = null,
};
const hotkey_id: c_uint = 0x4100;
const menu_limit = 12;
const Plugin = struct {
    id: [96:0]u8,
    label: [256:0]u8,
    actions: [sdk.command_limit]Command = undefined,
    action_count: usize,
    executable: [4096:0]u8,
    settings_page: [96:0]u8 = @splat(0),
    settings_entry: ?native.MoonSettingsEntry = null,
    network_rules: [96:0]u8 = @splat(0),
    protocol: Protocol,
    bundled: bool,
    requests: Permissions,
    default_grants: Permissions = .empty,
    subscribes: bool,
    enabled: bool = false,
    grants: Permissions = .empty,
    epoch: std.atomic.Value(u32) = .init(0),
    work: ?*Task = null,
    queued_change: bool = false,
    pending_command: ?PendingCommand = null,
    pending_drop: ?native.MoonTabDrop = null,
    hotkey: ?Hotkey = null,
};

var all: [native.MOON_PLUGIN_LIMIT]Plugin = undefined;
const state_limit = 256 * 1024;
var len: usize = 0;
var file_path: [4096:0]u8 = @splat(0);
var shortcut_path: [4096:0]u8 = @splat(0);
var smoke_message: [512:0]u8 = @splat(0);
var smoke_outcome: ?Outcome = null;
var serving_rpc = false;
var confirming_hotkey = false;
var changing_state = false;

fn copy(output: []u8, value: []const u8) bool {
    if (value.len >= output.len or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value))
        return false;
    @memcpy(output[0..value.len], value);
    output[value.len] = 0;
    return true;
}

fn validComponent(value: []const u8) bool {
    if (value.len == 0 or value[0] == '.' or value[value.len - 1] == '.') return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    }
    return true;
}

fn contains(items: []const []const u8, value: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}

fn addManifest(directory: []const u8, sub: []const u8, id: []const u8, name: []const u8, entry: []const u8, settings_page: ?[]const u8, network_rules: ?[]const u8, commands: []const sdk.Command, settings: ?sdk.SettingsContribution, requests: Permissions, subscribes: bool, protocol: Protocol, bundled: bool) void {
    if (!validComponent(id) or !validComponent(entry) or !std.ascii.endsWithIgnoreCase(entry, ".exe") or
        name.len == 0 or commands.len == 0 or commands.len > sdk.command_limit) return;
    if (protocol == .v2 and std.mem.indexOfScalar(u8, id, '.') == null) return;
    if (settings_page) |page| {
        if (!validComponent(page) or !std.mem.endsWith(u8,page,".html")) return;
    }
    if (network_rules) |file| {
        if (!validComponent(file) or !std.mem.endsWith(u8,file,".rules") or !requests.contains(.@"network.filter")) return;
    } else if (requests.contains(.@"network.filter")) return;
    if (native.moon_shell_private() and (!bundled or protocol!=.v2 or !privatePlugin(id))) return;
    for (all[0..len]) |*existing| if (std.ascii.eqlIgnoreCase(std.mem.sliceTo(&existing.id, 0), id)) return;
    var path: [4096]u8 = undefined;
    const executable = std.fmt.bufPrint(&path, "{s}\\{s}\\{s}", .{ directory, sub, entry }) catch return;
    const plugin = &all[len];
    plugin.* = .{
        .id = @splat(0), .label = @splat(0), .executable = @splat(0), .action_count = commands.len,
        .protocol = protocol, .bundled = bundled, .requests = requests, .subscribes = subscribes,
    };
    if (!copy(&plugin.id, id) or !copy(&plugin.label, name) or !copy(&plugin.executable, executable)) return;
    if (!copy(&plugin.settings_page,settings_page orelse "")) return;
    if (settings) |contribution| {
        if (settings_page==null or contribution.title.len==0 or contribution.description.len==0) return;
        var destination: native.MoonSettingsEntry = std.mem.zeroes(native.MoonSettingsEntry);
        if (!copy(&destination.id,id) or !copy(&destination.title,contribution.title) or
            !copy(&destination.description,contribution.description)) return;
        destination.section = @intFromEnum(contribution.section);
        plugin.settings_entry = destination;
    }
    if (!copy(&plugin.network_rules,network_rules orelse "")) return;
    var has_tab_drop = false;
    var has_inspect_element = false;
    var has_highlight_link = false;
    for (commands, 0..) |item, index| {
        if (!validComponent(item.id) or item.label.len == 0) return;
        if ((item.linkMenu != null or item.tabDrop) and (item.shortcut != null or item.siteMenu or item.menu != null or item.menuPinned)) return;
        if (item.tabDrop) {
            if (has_tab_drop or item.linkMenu!=null or !requests.contains(.@"tabs.organize")) return;
            has_tab_drop = true;
        }
        if (item.inspectElementMenu) |menu_label| {
            if (has_inspect_element or menu_label.len==0 or item.linkMenu!=null or item.tabDrop or
                !requests.contains(.@"page.inspect")) return;
            has_inspect_element = true;
        }
        if (item.highlightLinkMenu) |menu_label| {
            if (has_highlight_link or menu_label.len==0 or item.linkMenu!=null or item.tabDrop or item.inspectElementMenu!=null or
                !requests.contains(.@"tabs.manage")) return;
            has_highlight_link = true;
        }
        for (commands[0..index]) |prior| if (std.mem.eql(u8, prior.id, item.id)) return;
        plugin.actions[index] = .{};
        plugin.actions[index].interactive = item.interactive;
        plugin.actions[index].shortcut = item.shortcut;
        plugin.actions[index].menu_group = item.menu;
        plugin.actions[index].default_pinned = bundled and item.menuPinned;
        plugin.actions[index].site_menu = item.siteMenu;
        plugin.actions[index].link_menu = item.linkMenu;
        plugin.actions[index].tab_drop = item.tabDrop;
        plugin.actions[index].web_context_action = if (item.inspectElementMenu!=null) .inspect_element
            else if (item.highlightLinkMenu!=null) .highlight_link else null;
        if (!copy(&plugin.actions[index].web_context_label,item.inspectElementMenu orelse item.highlightLinkMenu orelse "")) return;
        if (!copy(&plugin.actions[index].id, item.id) or !copy(&plugin.actions[index].label, item.label)) return;
    }
    if (bundled) {
        const default_permission: ?sdk.Permission = if (std.mem.eql(u8,id,"moon.history")) .@"history.manage"
            else if (std.mem.eql(u8,id,"moon.lua-manager")) .@"lua.scripts.manage"
            else if (std.mem.eql(u8,id,"moon.devtools")) .@"page.inspect"
            else if (std.mem.eql(u8,id,"moon.network")) .@"network.capture"
            else if (std.mem.eql(u8,id,"moon.source")) .@"page.source"
            else if (std.mem.eql(u8,id,"moon.popups")) .@"popups.manage"
            else if (std.mem.eql(u8,id,"moon.bookmarks")) .@"bookmarks.manage"
            else if (std.mem.eql(u8,id,"moon.downloads")) .@"downloads.manage"
            else if (std.mem.eql(u8,id,"moon.site-data")) .@"siteData.read"
            else if (std.mem.eql(u8,id,"moon.reading")) .@"page.reading"
            else if (std.mem.eql(u8,id,"moon.recent-tabs")) .@"tabs.closed.manage"
            else if (std.mem.eql(u8,id,"moon.privacy")) .@"privacy.clear"
            else if (std.mem.eql(u8,id,"moon.task-manager")) .@"taskManager.manage"
            else if (std.mem.eql(u8,id,"moon.media")) .@"media.control"
            else if (std.mem.eql(u8,id,"moon.tab-tools")) .@"tabs.organize"
            else if (std.mem.eql(u8,id,"moon.private-window")) .@"privacy.privateWindow"
            else if (std.mem.eql(u8,id,"moon.search")) .@"search.manage"
            else if (std.mem.eql(u8,id,"moon.session")) .@"tabs.session.manage"
            else if (std.mem.eql(u8,id,"moon.settings")) .@"ui.settings"
            else if (std.mem.eql(u8,id,"moon.appearance")) .@"window.appearance" else null;
        if (default_permission) |scope| {
            if (requests.contains(scope)) {
                plugin.enabled = true;
                plugin.default_grants = .initOne(scope);
                plugin.grants = plugin.default_grants;
            }
        }
        if (std.mem.eql(u8,id,"moon.downloads") and plugin.enabled and requests.contains(.@"downloads.preferences")) {
            plugin.default_grants.insert(.@"downloads.preferences");
            plugin.grants.insert(.@"downloads.preferences");
        }
        if (std.mem.eql(u8,id,"moon.downloads") and plugin.enabled and requests.contains(.@"downloads.open")) {
            plugin.default_grants.insert(.@"downloads.open");
            plugin.grants.insert(.@"downloads.open");
        }
        if (std.mem.eql(u8,id,"moon.tab-tools") and plugin.enabled and requests.contains(.@"tabs.manage")) {
            plugin.default_grants.insert(.@"tabs.manage");
            plugin.grants.insert(.@"tabs.manage");
        }
        if (std.mem.eql(u8,id,"moon.tab-tools") and plugin.enabled and requests.contains(.@"tabs.groups")) {
            plugin.default_grants.insert(.@"tabs.groups");
            plugin.grants.insert(.@"tabs.groups");
        }
        if (std.mem.eql(u8,id,"moon.session") and plugin.enabled and requests.contains(.@"browser.defaultApp")) {
            plugin.default_grants.insert(.@"browser.defaultApp");
            plugin.grants.insert(.@"browser.defaultApp");
        }
        if (std.mem.eql(u8,id,"moon.site-data") and plugin.enabled and requests.contains(.@"siteData.write")) {
            plugin.default_grants.insert(.@"siteData.write");
            plugin.grants.insert(.@"siteData.write");
        }
        if (std.mem.eql(u8,id,"moon.site-data") and plugin.enabled and requests.contains(.@"siteData.cookieDetails")) {
            plugin.default_grants.insert(.@"siteData.cookieDetails");
            plugin.grants.insert(.@"siteData.cookieDetails");
        }
        if (std.mem.eql(u8,id,"moon.site-data") and plugin.enabled and requests.contains(.@"siteData.cookieClear")) {
            plugin.default_grants.insert(.@"siteData.cookieClear");
            plugin.grants.insert(.@"siteData.cookieClear");
        }
        if (std.mem.eql(u8,id,"moon.site-data") and plugin.enabled and requests.contains(.@"siteData.cacheWrite")) {
            plugin.default_grants.insert(.@"siteData.cacheWrite");
            plugin.grants.insert(.@"siteData.cacheWrite");
        }
        if (std.mem.eql(u8,id,"moon.site-data") and plugin.enabled and requests.contains(.@"siteData.records")) {
            plugin.default_grants.insert(.@"siteData.records");
            plugin.grants.insert(.@"siteData.records");
        }
        if (std.mem.eql(u8,id,"moon.site-data") and plugin.enabled and requests.contains(.@"siteData.databaseWrite")) {
            plugin.default_grants.insert(.@"siteData.databaseWrite");
            plugin.grants.insert(.@"siteData.databaseWrite");
        }
        if (std.mem.eql(u8,id,"moon.popups") and plugin.enabled and requests.contains(.@"siteSettings.autoplay")) {
            plugin.default_grants.insert(.@"siteSettings.autoplay");
            plugin.grants.insert(.@"siteSettings.autoplay");
        }
        if (std.mem.eql(u8,id,"moon.popups") and plugin.enabled and requests.contains(.@"siteSettings.sound")) {
            plugin.default_grants.insert(.@"siteSettings.sound");
            plugin.grants.insert(.@"siteSettings.sound");
        }
        if (std.mem.eql(u8,id,"moon.popups") and plugin.enabled and requests.contains(.@"siteSettings.zoom")) {
            plugin.default_grants.insert(.@"siteSettings.zoom");
            plugin.grants.insert(.@"siteSettings.zoom");
        }
        if (std.mem.eql(u8,id,"moon.popups") and plugin.enabled and requests.contains(.@"siteSettings.notifications")) {
            plugin.default_grants.insert(.@"siteSettings.notifications");
            plugin.grants.insert(.@"siteSettings.notifications");
        }
        if (std.mem.eql(u8,id,"moon.bookmarks") and plugin.enabled and requests.contains(.@"bookmarks.transfer")) {
            plugin.default_grants.insert(.@"bookmarks.transfer");
            plugin.grants.insert(.@"bookmarks.transfer");
        }
        if (std.mem.eql(u8,id,"moon.reading") and plugin.enabled and requests.contains(.@"window.fullscreen")) {
            plugin.default_grants.insert(.@"window.fullscreen");
            plugin.grants.insert(.@"window.fullscreen");
        }
        if (std.mem.eql(u8,id,"moon.reading") and plugin.enabled and requests.contains(.@"page.reader")) {
            plugin.default_grants.insert(.@"page.reader");
            plugin.grants.insert(.@"page.reader");
        }
        if (std.mem.eql(u8,id,"moon.source") and plugin.enabled and requests.contains(.@"page.save")) {
            plugin.default_grants.insert(.@"page.save");
            plugin.grants.insert(.@"page.save");
        }
        if (std.mem.eql(u8,id,"moon.blocker") and requests.contains(.@"network.filter"))
            plugin.default_grants.insert(.@"network.filter");
    }
    len += 1;
}

fn discover(root: []const u8, bundled: bool) void {
    var c_path: [4096]u8 = undefined;
    const directory = std.fmt.bufPrintSentinel(&c_path, "{s}\\plugins", .{root}, 0) catch return;
    // Allow some entries to be skipped because their manifests are invalid or missing.
    var names: [native.MOON_PLUGIN_LIMIT * 2][256]u8 = undefined;
    const found = native.moon_plugin_directories(directory.ptr, &names[0][0], names[0].len, names.len);
    for (names[0..found]) |*name| {
        if (len == all.len) break;
        const sub = std.mem.sliceTo(name, 0);
        var path: [4096]u8 = undefined;
        var json: [8192]u8 = undefined;
        const manifest_path = std.fmt.bufPrintSentinel(&path, "{s}\\{s}\\plugin.json", .{ directory, sub }, 0) catch continue;
        if (!native.moon_read_text(manifest_path.ptr, &json, json.len)) continue;
        const bytes = std.mem.sliceTo(&json, 0);
        if (std.json.parseFromSlice(sdk.Manifest, allocator, bytes, .{})) |parsed| {
            defer parsed.deinit();
            const manifest = parsed.value;
            if (manifest.apiVersion != sdk.api_version) continue;
            _ = std.SemanticVersion.parse(manifest.version) catch continue;
            var requested = Permissions.empty;
            for (manifest.permissions) |permission| requested.insert(permission);
            const subscribes = std.mem.indexOfScalar(sdk.Event, manifest.events, .@"tabs.changed") != null;
            if (subscribes and !requested.contains(.@"tabs.read")) continue;
            addManifest(directory, sub, manifest.id, manifest.name, manifest.entry, manifest.settingsPage, manifest.networkRules, manifest.contributes.commands, manifest.contributes.settings, requested, subscribes, .v2, bundled);
        } else |_| {
            const parsed = std.json.parseFromSlice(LegacyManifest, allocator, bytes, .{}) catch continue;
            defer parsed.deinit();
            const manifest = parsed.value;
            if (manifest.api_version != 1) continue;
            var requested = Permissions.empty;
            if (contains(manifest.permissions, "tabs.read")) requested.insert(.@"tabs.read");
            addManifest(directory, sub, manifest.id, manifest.name, manifest.executable, null, null, &.{.{ .id = "run", .label = manifest.command, .menu = manifest.menu }},
                null, requested, contains(manifest.events, "tabs.changed"), .legacy, bundled);
        }
    }
}

fn privatePlugin(id: []const u8) bool {
    const allowed = [_][]const u8{
        "moon.private-window", "moon.devtools", "moon.site-data", "moon.reading", "moon.source",
        "moon.recent-tabs", "moon.tab-tools", "moon.task-manager", "moon.appearance",
    };
    for (allowed) |item| if (std.mem.eql(u8,id,item)) return true;
    return false;
}

pub fn init(app: []const u8, profile: []const u8) void {
    discover(app,true);
    if (profile.len==0) return;
    discover(profile,false);
    _ = std.fmt.bufPrintSentinel(&file_path, "{s}\\plugin-state.json", .{profile}, 0) catch return;
    _ = std.fmt.bufPrintSentinel(&shortcut_path, "{s}\\plugin-shortcuts.json", .{profile}, 0) catch return;
    // Load user choices after the plugin registrations, even when there is no grant file.
    defer loadUserShortcuts();
    const raw = allocator.alloc(u8,state_limit) catch return;
    defer allocator.free(raw);
    if (!native.moon_read_text(&file_path,raw.ptr,raw.len)) return;
    const saved = std.json.parseFromSlice([]Grant,allocator,std.mem.sliceTo(raw,0),.{}) catch return;
    defer saved.deinit();
    for (all[0..len]) |*plugin| for (saved.value) |grant| {
        if (!std.mem.eql(u8, grant.id, std.mem.sliceTo(&plugin.id, 0))) continue;
        plugin.enabled = grant.enabled;
        plugin.grants = .empty;
        if (grant.enabled and grant.tabs_read and plugin.requests.contains(.@"tabs.read")) plugin.grants.insert(.@"tabs.read");
        if (grant.enabled and grant.lua_scripts_manage and plugin.requests.contains(.@"lua.scripts.manage")) plugin.grants.insert(.@"lua.scripts.manage");
        if (grant.enabled and grant.page_inspect and plugin.requests.contains(.@"page.inspect")) plugin.grants.insert(.@"page.inspect");
        if (grant.enabled and (grant.network_capture orelse plugin.default_grants.contains(.@"network.capture")) and
            plugin.requests.contains(.@"network.capture")) plugin.grants.insert(.@"network.capture");
        if (grant.enabled and grant.history_manage and plugin.requests.contains(.@"history.manage")) plugin.grants.insert(.@"history.manage");
        if (grant.enabled and grant.network_filter and plugin.requests.contains(.@"network.filter")) plugin.grants.insert(.@"network.filter");
        if (grant.enabled and grant.bookmarks_manage and plugin.requests.contains(.@"bookmarks.manage")) plugin.grants.insert(.@"bookmarks.manage");
        if (grant.enabled and grant.downloads_manage and plugin.requests.contains(.@"downloads.manage")) plugin.grants.insert(.@"downloads.manage");
        if (grant.enabled and (grant.downloads_preferences orelse plugin.default_grants.contains(.@"downloads.preferences")) and
            plugin.requests.contains(.@"downloads.preferences")) plugin.grants.insert(.@"downloads.preferences");
        if (grant.enabled and (grant.downloads_open orelse plugin.default_grants.contains(.@"downloads.open")) and
            plugin.requests.contains(.@"downloads.open")) plugin.grants.insert(.@"downloads.open");
        if (grant.enabled and grant.site_data_read and plugin.requests.contains(.@"siteData.read")) plugin.grants.insert(.@"siteData.read");
        if (grant.enabled and grant.page_source and plugin.requests.contains(.@"page.source")) plugin.grants.insert(.@"page.source");
        if (grant.enabled and grant.popups_manage and plugin.requests.contains(.@"popups.manage")) plugin.grants.insert(.@"popups.manage");
        if (grant.enabled and grant.page_reading and plugin.requests.contains(.@"page.reading")) plugin.grants.insert(.@"page.reading");
        if (grant.enabled and grant.tabs_closed_manage and plugin.requests.contains(.@"tabs.closed.manage")) plugin.grants.insert(.@"tabs.closed.manage");
        if (grant.enabled and grant.privacy_clear and plugin.requests.contains(.@"privacy.clear")) plugin.grants.insert(.@"privacy.clear");
        if (grant.enabled and grant.task_manager_manage and plugin.requests.contains(.@"taskManager.manage")) plugin.grants.insert(.@"taskManager.manage");
        if (grant.enabled and (grant.media_control orelse plugin.default_grants.contains(.@"media.control")) and
            plugin.requests.contains(.@"media.control")) plugin.grants.insert(.@"media.control");
        if (grant.enabled and grant.ui_commands and plugin.requests.contains(.@"ui.commands")) plugin.grants.insert(.@"ui.commands");
        if (grant.enabled and grant.tabs_organize and plugin.requests.contains(.@"tabs.organize")) plugin.grants.insert(.@"tabs.organize");
        if (grant.enabled and grant.private_window and plugin.requests.contains(.@"privacy.privateWindow")) plugin.grants.insert(.@"privacy.privateWindow");
        if (grant.enabled and (grant.tabs_manage orelse plugin.default_grants.contains(.@"tabs.manage")) and
            plugin.requests.contains(.@"tabs.manage")) plugin.grants.insert(.@"tabs.manage");
        if (grant.enabled and grant.search_manage and plugin.requests.contains(.@"search.manage")) plugin.grants.insert(.@"search.manage");
        if (grant.enabled and (grant.site_data_write orelse plugin.default_grants.contains(.@"siteData.write")) and
            plugin.requests.contains(.@"siteData.write")) plugin.grants.insert(.@"siteData.write");
        if (grant.enabled and (grant.site_data_cookie_details orelse plugin.default_grants.contains(.@"siteData.cookieDetails")) and
            plugin.requests.contains(.@"siteData.cookieDetails")) plugin.grants.insert(.@"siteData.cookieDetails");
        if (grant.enabled and (grant.site_data_cookie_clear orelse plugin.default_grants.contains(.@"siteData.cookieClear")) and
            plugin.requests.contains(.@"siteData.cookieClear")) plugin.grants.insert(.@"siteData.cookieClear");
        if (grant.enabled and (grant.ui_settings orelse plugin.default_grants.contains(.@"ui.settings")) and
            plugin.requests.contains(.@"ui.settings")) plugin.grants.insert(.@"ui.settings");
        if (grant.enabled and (grant.site_data_cache_write orelse plugin.default_grants.contains(.@"siteData.cacheWrite")) and
            plugin.requests.contains(.@"siteData.cacheWrite")) plugin.grants.insert(.@"siteData.cacheWrite");
        if (grant.enabled and (grant.site_data_records orelse plugin.default_grants.contains(.@"siteData.records")) and
            plugin.requests.contains(.@"siteData.records")) plugin.grants.insert(.@"siteData.records");
        if (grant.enabled and (grant.site_data_database_write orelse plugin.default_grants.contains(.@"siteData.databaseWrite")) and
            plugin.requests.contains(.@"siteData.databaseWrite")) plugin.grants.insert(.@"siteData.databaseWrite");
        if (grant.enabled and (grant.site_settings_autoplay orelse plugin.default_grants.contains(.@"siteSettings.autoplay")) and
            plugin.requests.contains(.@"siteSettings.autoplay")) plugin.grants.insert(.@"siteSettings.autoplay");
        if (grant.enabled and (grant.site_settings_sound orelse plugin.default_grants.contains(.@"siteSettings.sound")) and
            plugin.requests.contains(.@"siteSettings.sound")) plugin.grants.insert(.@"siteSettings.sound");
        if (grant.enabled and (grant.site_settings_zoom orelse plugin.default_grants.contains(.@"siteSettings.zoom")) and
            plugin.requests.contains(.@"siteSettings.zoom")) plugin.grants.insert(.@"siteSettings.zoom");
        if (grant.enabled and (grant.site_settings_notifications orelse plugin.default_grants.contains(.@"siteSettings.notifications")) and
            plugin.requests.contains(.@"siteSettings.notifications")) plugin.grants.insert(.@"siteSettings.notifications");
        if (grant.enabled and grant.tabs_session_manage and plugin.requests.contains(.@"tabs.session.manage")) plugin.grants.insert(.@"tabs.session.manage");
        if (grant.enabled and (grant.bookmarks_transfer orelse plugin.default_grants.contains(.@"bookmarks.transfer")) and
            plugin.requests.contains(.@"bookmarks.transfer")) plugin.grants.insert(.@"bookmarks.transfer");
        if (grant.enabled and (grant.window_fullscreen orelse plugin.default_grants.contains(.@"window.fullscreen")) and
            plugin.requests.contains(.@"window.fullscreen")) plugin.grants.insert(.@"window.fullscreen");
        if (grant.enabled and (grant.window_appearance orelse plugin.default_grants.contains(.@"window.appearance")) and
            plugin.requests.contains(.@"window.appearance")) plugin.grants.insert(.@"window.appearance");
        if (grant.enabled and (grant.page_save orelse plugin.default_grants.contains(.@"page.save")) and
            plugin.requests.contains(.@"page.save")) plugin.grants.insert(.@"page.save");
        if (grant.enabled and (grant.page_reader orelse plugin.default_grants.contains(.@"page.reader")) and
            plugin.requests.contains(.@"page.reader")) plugin.grants.insert(.@"page.reader");
        if (grant.enabled and (grant.tabs_groups orelse plugin.default_grants.contains(.@"tabs.groups")) and
            plugin.requests.contains(.@"tabs.groups")) plugin.grants.insert(.@"tabs.groups");
        if (grant.enabled and (grant.browser_default_app orelse plugin.default_grants.contains(.@"browser.defaultApp")) and
            plugin.requests.contains(.@"browser.defaultApp")) plugin.grants.insert(.@"browser.defaultApp");
        if (grant.enabled) {
            for (grant.unpinned_menu_items) |id| {
                if (findAction(plugin,id)) |index| {
                    if (plugin.actions[index].default_pinned) plugin.actions[index].menu_override = .unpinned;
                }
            }
            for (grant.menu_items) |id| {
                if (menuSize() >= menu_limit) break;
                if (findAction(plugin,id)) |index| {
                    if (!plugin.actions[index].bound()) plugin.actions[index].menu_override = .pinned;
                }
            }
        }
        if (canContribute(plugin)) {
            for (grant.hidden_menu_items) |id| {
                if (findAction(plugin,id)) |index| {
                    if (plugin.actions[index].menu_group!=null) plugin.actions[index].menu_override = .hidden;
                }
            }
            if (grant.hotkey) |saved_key| {
                if (findAction(plugin,saved_key.id)) |index| {
                    if (parseHotkey(index,saved_key.shortcut,saved_key.scope)) |key| {
                        if (!plugin.actions[index].bound() and !hotkeyReserved(key) and !hotkeyConflict(key,plugin)) plugin.hotkey = key;
                    }
                }
            }
        }
        break;
    };
    for (all[0..len],0..) |*plugin,index| {
        if (plugin.hotkey) |*key| {
            if (key.scope==.global and native.moon_shell_register_hotkey(globalId(index,0),key.mods,key.key)) key.slot = 0;
        }
    }
}

fn persist() bool {
    if (file_path[0]==0) return false;
    var items: [all.len]Grant = undefined;
    var menus: [all.len][sdk.command_limit][]const u8 = undefined;
    var hidden_menus: [all.len][sdk.command_limit][]const u8 = undefined;
    var unpinned_menus: [all.len][sdk.command_limit][]const u8 = undefined;
    for (all[0..len], 0..) |*plugin, index| {
        var used: usize = 0;
        var hidden: usize = 0;
        var unpinned: usize = 0;
        for (plugin.actions[0..plugin.action_count]) |*action_entry| {
            const id = std.mem.sliceTo(&action_entry.id,0);
            switch (action_entry.menu_override) {
                .default => {},
                .pinned => { menus[index][used] = id; used += 1; },
                .unpinned => { unpinned_menus[index][unpinned] = id; unpinned += 1; },
                .hidden => { hidden_menus[index][hidden] = id; hidden += 1; },
            }
        }
        const saved_key: ?sdk.RegisteredShortcut = if (plugin.hotkey) |*key| .{
            .id=std.mem.sliceTo(&plugin.actions[key.action].id,0),.shortcut=std.mem.sliceTo(&key.text,0),.scope=key.scope,
        } else null;
        items[index] = .{
        .id = std.mem.sliceTo(&plugin.id, 0),
        .enabled = plugin.enabled,
        .tabs_read = plugin.grants.contains(.@"tabs.read"),
        .lua_scripts_manage = plugin.grants.contains(.@"lua.scripts.manage"),
        .page_inspect = plugin.grants.contains(.@"page.inspect"),
        .history_manage = plugin.grants.contains(.@"history.manage"),
        .network_filter = plugin.grants.contains(.@"network.filter"),
        .network_capture = plugin.grants.contains(.@"network.capture"),
        .bookmarks_manage = plugin.grants.contains(.@"bookmarks.manage"),
        .downloads_manage = plugin.grants.contains(.@"downloads.manage"),
        .downloads_preferences = plugin.grants.contains(.@"downloads.preferences"),
        .downloads_open = plugin.grants.contains(.@"downloads.open"),
        .site_data_read = plugin.grants.contains(.@"siteData.read"),
        .page_reading = plugin.grants.contains(.@"page.reading"),
        .tabs_closed_manage = plugin.grants.contains(.@"tabs.closed.manage"),
        .privacy_clear = plugin.grants.contains(.@"privacy.clear"),
        .task_manager_manage = plugin.grants.contains(.@"taskManager.manage"),
        .media_control = plugin.grants.contains(.@"media.control"),
        .ui_commands = plugin.grants.contains(.@"ui.commands"),
        .tabs_organize = plugin.grants.contains(.@"tabs.organize"),
        .private_window = plugin.grants.contains(.@"privacy.privateWindow"),
        .tabs_manage = plugin.grants.contains(.@"tabs.manage"),
        .search_manage = plugin.grants.contains(.@"search.manage"),
        .site_data_write = plugin.grants.contains(.@"siteData.write"),
        .site_data_cookie_details = plugin.grants.contains(.@"siteData.cookieDetails"),
        .site_data_cookie_clear = plugin.grants.contains(.@"siteData.cookieClear"),
        .ui_settings = plugin.grants.contains(.@"ui.settings"),
        .site_data_cache_write = plugin.grants.contains(.@"siteData.cacheWrite"),
        .site_data_records = plugin.grants.contains(.@"siteData.records"),
        .site_data_database_write = plugin.grants.contains(.@"siteData.databaseWrite"),
        .site_settings_autoplay = plugin.grants.contains(.@"siteSettings.autoplay"),
        .site_settings_sound = plugin.grants.contains(.@"siteSettings.sound"),
        .site_settings_zoom = plugin.grants.contains(.@"siteSettings.zoom"),
        .site_settings_notifications = plugin.grants.contains(.@"siteSettings.notifications"),
        .page_source = plugin.grants.contains(.@"page.source"),
        .popups_manage = plugin.grants.contains(.@"popups.manage"),
        .tabs_session_manage = plugin.grants.contains(.@"tabs.session.manage"),
        .bookmarks_transfer = plugin.grants.contains(.@"bookmarks.transfer"),
        .window_fullscreen = plugin.grants.contains(.@"window.fullscreen"),
        .window_appearance = plugin.grants.contains(.@"window.appearance"),
        .page_save = plugin.grants.contains(.@"page.save"),
        .page_reader = plugin.grants.contains(.@"page.reader"),
        .tabs_groups = plugin.grants.contains(.@"tabs.groups"),
        .browser_default_app = plugin.grants.contains(.@"browser.defaultApp"),
        .menu_items = menus[index][0..used],
        .hidden_menu_items = hidden_menus[index][0..hidden],
        .unpinned_menu_items = unpinned_menus[index][0..unpinned],
        .hotkey = saved_key,
        };
    }
    const bytes = std.json.Stringify.valueAlloc(allocator, items[0..len], .{}) catch return false;
    defer allocator.free(bytes);
    if (bytes.len>=state_limit) return false;
    const string = allocator.dupeSentinel(u8, bytes, 0) catch return false;
    defer allocator.free(string);
    return native.moon_write_text(&file_path, string.ptr);
}
pub const Change = enum { saved, cancelled, unavailable };

pub fn toggle(index: usize, permission: ?sdk.Permission) Change {
    if (index >= len or changing_state or confirming_hotkey) return .unavailable;
    changing_state = true;
    defer changing_state = false;
    const plugin = &all[index];
    const enabled = plugin.enabled;
    const grants = plugin.grants;
    const old_key = plugin.hotkey;
    var old_menu: [sdk.command_limit]MenuOverride = undefined;
    for (plugin.actions[0..plugin.action_count],old_menu[0..plugin.action_count]) |action_entry,*menu|
        menu.* = action_entry.menu_override;
    if (permission) |scope| {
        if (!plugin.requests.contains(scope) or !enabled) {
            return .unavailable;
        }
        if (grants.contains(scope)) {
            plugin.grants.remove(scope);
        } else {
            const disclosure = switch (scope) {
                .@"tabs.read" => "此插件可读取触发时的活动标签标题和网址。",
                .@"lua.scripts.manage" => "此插件可导入、停用或移除 Lua 用户脚本。新脚本首次启用时，浏览器会单独确认网站范围。",
                .@"page.inspect" => "此插件可为触发命令时的网页打开开发者工具。控制台和站点存储可在工具中查看。",
                .@"page.source" => "你从网页触发此插件命令时，它的专属页面可读取该网页已经加载的主文档源代码。",
                .@"page.save" => "此插件可在你触发命令时打开保存对话框，将已加载的网页写到你选中的 HTML 文件。",
                .@"tabs.groups" => "此插件可管理组名称、颜色与标签成员。读取标签网址仍需要单独授权。",
                .@"browser.defaultApp" => "此插件可在你执行命令时打开 Windows 默认应用设置。系统会由你决定是否更改默认应用。",
                .@"popups.manage" => "此插件可管理网站弹窗权限，并为触发命令的网页打开最近拦截的链接。",
                .@"siteSettings.autoplay" => "此插件可查看和修改网站的媒体自动播放规则。允许有声自动播放时需要单独确认。",
                .@"siteSettings.sound" => "此插件可查看和修改网站静音规则。规则适用于同一来源的标签页。",
                .@"siteSettings.notifications" => "此插件可查看和修改网站通知规则。允许通知需要用户确认。",
                .@"siteSettings.zoom" => "此插件可查看保存过缩放比例的网站，并修改或删除例外。",
                .@"history.manage" => "此插件可读取和删除本机浏览记录，包括网页标题、网址和访问时间。",
                .@"network.filter" => "此插件可阻止匹配规则的网页请求，并为你指定的站点停用过滤。",
                .@"network.capture" => "此插件可记录手动选中的网页标签的地址、响应状态和加载结果。记录仅在内存中保留，网址会去掉查询参数。",
                .@"bookmarks.manage" => "此插件可读取、添加、编辑和删除本机书签。",
                .@"bookmarks.transfer" => "此插件可打开文件选择框，从所选 HTML 文件导入书签，或导出书签到你选的位置。",
                .@"downloads.manage" => "此插件可读取本机下载记录、取消或重试传输，并在文件夹中显示已保存的文件。",
                .@"downloads.preferences" => "此插件可查看和更改是否询问保存位置，并通过系统对话框选择默认下载文件夹。",
                .@"downloads.open" => "此插件可在活动页面请求打开已下载的文件。浏览器确认文件后，Windows 会按系统策略处理。",
                .@"siteData.read" => "你从网页触发此插件命令时，它的页面可读取该网页可见的 Cookie 和站点存储。",
                .@"siteData.write" => "此插件可在绑定到网页的站点数据面板编辑或删除 Local Storage 和 Session Storage 条目。",
                .@"siteData.cookieDetails" => "此插件可在绑定到网页的站点数据面板查看 Cookie 属性及值，包含可能用于登录的 HttpOnly Cookie。",
                .@"siteData.cookieClear" => "此插件经确认可删除选中的普通 Cookie，或清除当前站点所属注册域及其子域的 Cookie。整站清除包含 HttpOnly Cookie。",
                .@"ui.settings" => "此插件可列出并打开其他已启用插件登记的浏览器设置页面。",
                .@"window.appearance" => "此插件可以切换浏览器亮色或深色主题，并显示或隐藏当前窗口的标签侧栏。",
                .@"siteData.cacheWrite" => "此插件经你确认后，可删除当前站点数据面板中指定的 Cache Storage 缓存。",
                .@"siteData.records" => "此插件可在当前站点数据面板按需读取 IndexedDB 记录的键和值预览。",
                .@"siteData.databaseWrite" => "此插件经你确认后，可删除当前站点指定的一条 IndexedDB 记录，或清空指定对象仓库。",
                .@"page.reading" => "此插件可在当前页打开查找栏，并调整页面缩放。",
                .@"page.reader" => "你从网页打开阅读模式时，此插件的专属页面可以读取该网页提取的正文。",
                .@"window.fullscreen" => "此插件可在你触发命令时切换浏览器全屏。按 Esc 可以退出全屏。",
                .@"tabs.closed.manage" => "此插件可查看最近关闭标签的标题和站点，并恢复或清空这些标签。",
                .@"privacy.clear" => "此插件可以请求清除所选浏览数据。浏览器会在删除前单独确认。",
                .@"taskManager.manage" => "此插件可查看标签标题和浏览器进程内存，以及切换标签和卸载可回收的后台标签。",
                .@"media.control" => "此插件可查看媒体标签的标题和来源，并切换标签、静音或控制网页内的音视频播放。",
                .@"ui.commands" => "此插件可为已声明的命令添加菜单入口，并设置一个快捷键。链接操作由右键菜单发起，全局快捷键仍需单独确认。",
                .@"tabs.organize" => "此插件可固定或取消固定触发命令的标签，也可切换标签静音或响应用户的标签排序操作。",
                .@"tabs.manage" => "此插件可复制触发命令的标签或将网址写入剪贴板，也可关闭未固定且未受保护的其他标签。",
                .@"search.manage" => "此插件可查看和修改默认搜索引擎、搜索网址和关键词。修改会影响之后主动提交的搜索。",
                .@"tabs.session.manage" => "此插件可恢复上次正常退出时的普通网页、修改启动选项或清除已保存的会话。",
                .@"privacy.privateWindow" => "此插件可在执行用户命令时打开独立的隐私浏览窗口。",
            };
            var body: [768]u8 = undefined;
            const message = std.fmt.bufPrintSentinel(&body,"{s}（{s}）\n{s}",
                .{ std.mem.sliceTo(&plugin.label,0),idAt(index),disclosure },0) catch return .unavailable;
            if (!native.moon_shell_confirm("授予插件权限？", message.ptr)) return .cancelled;
            plugin.grants.insert(scope);
        }
    } else {
        if (!enabled) {
            var body: [4700]u8 = undefined;
            const name = std.mem.sliceTo(&plugin.label,0);
            const message = if (plugin.default_grants.contains(.@"network.filter"))
                std.fmt.bufPrintSentinel(&body,"「{s}」将立即拦截匹配规则的网页请求。你可以在它的设置中为单个站点暂停过滤。",.{name},0)
            else if (plugin.bundled)
                std.fmt.bufPrintSentinel(&body,"启用「{s}」及其默认权限。",.{name},0)
            else
                std.fmt.bufPrintSentinel(&body,"「{s}」将按当前 Windows 用户权限运行。\n{s}",.{name,std.mem.sliceTo(&plugin.executable,0)},0);
            const disclosure = message catch return .unavailable;
            if (!native.moon_shell_confirm("启用插件？",disclosure.ptr)) return .cancelled;
        }
        plugin.enabled = !plugin.enabled;
        plugin.grants = if (plugin.enabled) plugin.default_grants else .empty;
    }
    if (!canContribute(plugin)) {
        plugin.hotkey = null;
        for (plugin.actions[0..plugin.action_count]) |*action_entry| {
            if (!plugin.enabled or action_entry.menu_override == .hidden) action_entry.menu_override = .default;
        }
    }
    if (!persist()) {
        plugin.enabled = enabled;
        plugin.grants = grants;
        plugin.hotkey = old_key;
        for (plugin.actions[0..plugin.action_count],old_menu[0..plugin.action_count]) |*entry,menu| entry.menu_override = menu;
        return .unavailable;
    }
    if (plugin.hotkey==null) if (old_key) |key| {
        if (key.slot) |slot| native.moon_shell_unregister_hotkey(globalId(index,slot));
    };
    _ = plugin.epoch.fetchAdd(1, .acq_rel);
    plugin.queued_change = false;
    plugin.pending_command = null;
    plugin.pending_drop = null;
    return .saved;
}

pub fn count() usize {
    return len;
}
pub fn idAt(index: usize) []const u8 {
    return std.mem.sliceTo(&all[index].id,0);
}
pub fn indexOf(id: []const u8) ?usize {
    for (0..len) |index| if (std.mem.eql(u8,id,idAt(index))) return index;
    return null;
}
pub fn isBundled(index: usize) bool {
    return all[index].bundled;
}
pub fn label(index: usize) [*:0]const u8 {
    return &all[index].label;
}
pub fn actionCount(index: usize) usize {
    return all[index].action_count;
}
pub fn action(index: usize, command_index: usize) [*:0]const u8 {
    return &all[index].actions[command_index].label;
}
pub fn actionId(index: usize, command_index: usize) []const u8 {
    return std.mem.sliceTo(&all[index].actions[command_index].id,0);
}
pub fn userShortcut(index: usize, command_index: usize) ?[*:0]const u8 {
    if (all[index].actions[command_index].user_shortcut) |*key| return &key.text;
    return null;
}
pub fn pluginGlobalShortcut(index: usize, command_index: usize) ?[*:0]const u8 {
    if (all[index].hotkey) |key| {
        if (key.scope==.global) return registeredShortcut(index,command_index);
    }
    return null;
}
pub fn actionShortcut(index: usize, command_index: usize) ?sdk.Shortcut {
    return all[index].actions[command_index].shortcut;
}
pub fn registeredShortcut(index: usize, command_index: usize) ?[*:0]const u8 {
    if (all[index].hotkey) |*key| {
        if (key.action==command_index and (key.scope==.browser or key.slot!=null)) return &key.text;
    }
    return null;
}
pub fn isEnabled(index: usize) bool {
    return all[index].enabled;
}

pub fn permissionFlags(index: usize, permission: sdk.Permission) c_uint {
    const plugin = &all[index];
    return @as(c_uint,@intFromBool(plugin.requests.contains(permission))) |
        (@as(c_uint,@intFromBool(plugin.grants.contains(permission))) << 1);
}

pub fn hasSettings(index: usize) bool {
    return index < len and all[index].settings_page[0] != 0;
}

pub fn settingsAddress(index: usize, buffer: []u8) ?[:0]u8 {
    if (!hasSettings(index) or !all[index].enabled) return null;
    const plugin = &all[index];
    return std.fmt.bufPrintSentinel(buffer,"extension://{s}/{s}",.{ std.mem.sliceTo(&plugin.id,0),std.mem.sliceTo(&plugin.settings_page,0) },0) catch null;
}

pub fn listSettings(offset: usize, entries: []native.MoonSettingsEntry, next: *usize) usize {
    var count_entries: usize = 0;
    for (all[@min(offset,len)..len],offset..) |*plugin,index| {
        if (!plugin.enabled) continue;
        const entry = plugin.settings_entry orelse continue;
        if (count_entries==entries.len) {
            next.* = index;
            break;
        }
        entries[count_entries] = entry;
        count_entries += 1;
    }
    return count_entries;
}

pub fn contributedSettings(id: []const u8, buffer: []u8) ?[:0]u8 {
    for (all[0..len],0..) |*plugin,index| {
        if (plugin.settings_entry!=null and std.mem.eql(u8,std.mem.sliceTo(&plugin.id,0),id))
            return settingsAddress(index,buffer);
    }
    return null;
}

fn enabledPlugin(id: []const u8) ?*const Plugin {
    for (all[0..len]) |*plugin| {
        if (plugin.enabled and std.mem.eql(u8,std.mem.sliceTo(&plugin.id,0),id)) return plugin;
    }
    return null;
}

pub fn pageGrants(id: []const u8) ?Permissions {
    const plugin = enabledPlugin(id) orelse return null;
    return if (plugin.settings_page[0] != 0) plugin.grants else null;
}

pub fn hasGrant(id: []const u8, permission: sdk.Permission) bool {
    const plugin = enabledPlugin(id) orelse return false;
    return plugin.grants.contains(permission);
}

fn canContribute(plugin: *const Plugin) bool {
    return plugin.enabled and plugin.grants.contains(.@"ui.commands");
}

fn findAction(plugin: *const Plugin, id: []const u8) ?usize {
    for (plugin.actions[0..plugin.action_count],0..) |*action_entry,index| {
        if (std.mem.eql(u8,std.mem.sliceTo(&action_entry.id,0),id)) return index;
    }
    return null;
}

fn contributor(id: []const u8) ?usize {
    for (all[0..len],0..) |*plugin,index| {
        if (canContribute(plugin) and std.mem.eql(u8,std.mem.sliceTo(&plugin.id,0),id)) return index;
    }
    return null;
}

fn menuSize() usize {
    var count_entries: usize = 0;
    for (all[0..len]) |*plugin| for (plugin.actions[0..plugin.action_count]) |*entry| {
        if (entry.menu_override==.pinned) count_entries += 1;
    };
    return count_entries;
}

fn groupLocation(group: ?sdk.MenuGroup) c_uint {
    return switch (group orelse return native.MOON_MENU_NONE) {
        .page => native.MOON_MENU_PAGE,
        .library => native.MOON_MENU_LIBRARY,
        .privacy => native.MOON_MENU_PRIVACY,
        .developer => native.MOON_MENU_DEVELOPER,
        .extensions => native.MOON_MENU_EXTENSIONS,
    };
}

pub fn menuLocation(index: usize, command_index: usize) c_uint {
    const plugin = &all[index];
    if (!plugin.enabled) return native.MOON_MENU_NONE;
    const entry = &plugin.actions[command_index];
    return switch (entry.menu_override) {
        .pinned => native.MOON_MENU_PINNED,
        .hidden => native.MOON_MENU_NONE,
        .unpinned => if (plugin.bundled or canContribute(plugin)) groupLocation(entry.menu_group) else native.MOON_MENU_NONE,
        .default => if (entry.default_pinned) native.MOON_MENU_PINNED
            else if (plugin.bundled or canContribute(plugin)) groupLocation(entry.menu_group)
            else native.MOON_MENU_NONE,
    };
}

pub fn isMenuPinned(index: usize, command_index: usize) bool {
    return menuLocation(index, command_index) == native.MOON_MENU_PINNED;
}

pub fn setUserMenuPin(index: usize, id: []const u8, pinned: bool) sdk.UiRegistration {
    if (changing_state or index >= len) return .unavailable;
    const plugin = &all[index];
    if (!plugin.enabled) return .unavailable;
    const command_index = findAction(plugin, id) orelse return .notFound;
    const entry = &plugin.actions[command_index];
    if (entry.bound()) return .unavailable;
    const before = entry.menu_override;
    const after: MenuOverride = if (pinned)
        (if (entry.default_pinned) .default else .pinned)
    else
        (if (entry.default_pinned) .unpinned else .default);
    if (before == after) return .saved;
    if (after == .pinned and menuSize() >= menu_limit) return .limitReached;
    entry.menu_override = after;
    if (!persist()) {
        entry.menu_override = before;
        return .unavailable;
    }
    return .saved;
}

pub fn siteMenuVisible(index: usize, command_index: usize) bool {
    if (index >= len) return false;
    const plugin = &all[index];
    if (!plugin.enabled or command_index >= plugin.action_count) return false;
    return plugin.actions[command_index].site_menu and (plugin.bundled or canContribute(plugin));
}

pub fn linkOnly(index: usize, command_index: usize) bool {
    return all[index].actions[command_index].link_menu != null;
}

pub fn tabDropOnly(index: usize, command_index: usize) bool {
    return all[index].actions[command_index].tab_drop;
}

pub fn boundOnly(index: usize, command_index: usize) bool {
    return all[index].actions[command_index].bound();
}

pub fn tabDropProvider() ?struct { plugin: usize, command: usize } {
    for (all[0..len],0..) |*plugin,index| {
        if (!plugin.enabled or !plugin.grants.contains(.@"tabs.organize") or
            (!plugin.bundled and !canContribute(plugin))) continue;
        for (plugin.actions[0..plugin.action_count],0..) |entry,command_index| {
            if (entry.tab_drop) return .{ .plugin=index,.command=command_index };
        }
    }
    return null;
}

pub fn inspectElementLabel() ?[*:0]const u8 {
    return contextLabel(.@"page.inspect",.inspect_element);
}

pub fn highlightLinkLabel() ?[*:0]const u8 {
    return contextLabel(.@"tabs.manage",.highlight_link);
}

fn contextLabel(permission: sdk.Permission, kind: WebContextAction) ?[*:0]const u8 {
    for (all[0..len]) |*plugin| {
        if (!plugin.enabled or !plugin.grants.contains(permission) or
            (!plugin.bundled and !canContribute(plugin))) continue;
        for (plugin.actions[0..plugin.action_count]) |*entry| {
            if (entry.web_context_action==kind) return &entry.web_context_label;
        }
    }
    return null;
}

pub fn linkAction(index: usize, command_index: usize) ?sdk.LinkMenuAction {
    if (index>=len) return null;
    const plugin = &all[index];
    if (!plugin.enabled or command_index>=plugin.action_count or (!plugin.bundled and !canContribute(plugin))) return null;
    const operation = plugin.actions[command_index].link_menu orelse return null;
    const permission: sdk.Permission = if (operation==.bookmark) .@"bookmarks.manage" else .@"tabs.manage";
    return if (plugin.grants.contains(permission)) operation else null;
}

pub fn setMenu(owner: []const u8, id: []const u8, add: bool) sdk.UiRegistration {
    if (changing_state) return .unavailable;
    const index = contributor(owner) orelse return .unavailable;
    const plugin = &all[index];
    const command_index = findAction(plugin,id) orelse return .notFound;
    const entry = &plugin.actions[command_index];
    if (entry.bound()) return .unavailable;
    const before = entry.menu_override;
    const after: MenuOverride = if (add) .pinned else if (entry.menu_group!=null) .hidden else .default;
    if (before==after) return .saved;
    if (add and menuSize()>=menu_limit) return .limitReached;
    entry.menu_override = after;
    if (!persist()) {
        entry.menu_override = before;
        return .unavailable;
    }
    return .saved;
}

fn globalId(index: usize, slot: u1) c_uint {
    return hotkey_id+@as(c_uint,@intCast(index))*2+slot;
}

fn parseHotkey(action_index: usize, text: []const u8, scope: sdk.ShortcutScope) ?Hotkey {
    const prefix = if (std.mem.startsWith(u8,text,"Ctrl+Shift+")) "Ctrl+Shift+"
        else if (std.mem.startsWith(u8,text,"Alt+Shift+")) "Alt+Shift+" else return null;
    if (text.len!=prefix.len+1) return null;
    const vk = text[prefix.len];
    if (!std.ascii.isUpper(vk) and !std.ascii.isDigit(vk)) return null;
    var key: Hotkey = .{ .action=action_index,.mods=if (text[0]=='C') 0x0006 else 0x0005,.key=vk,.scope=scope };
    if (!copy(&key.text,text)) return null;
    return key;
}

fn sameChord(left: Hotkey, right: Hotkey) bool {
    return left.mods==right.mods and left.key==right.key;
}

fn hotkeyReserved(key: Hotkey) bool {
    const text = std.mem.sliceTo(&key.text,0);
    if (std.meta.stringToEnum(sdk.Shortcut,text)) |shortcut| {
        if (shortcut!=.@"Ctrl+Shift+C" and shortcut!=.@"Ctrl+Shift+A" and shortcut!=.@"Ctrl+Shift+E") return true;
    }
    if (key.mods!=0x0006) return false;
    return switch (key.key) {
        'B','K','L','R','W' => true,
        else => false,
    };
}

fn hotkeyConflict(candidate: Hotkey, exclude: *const Plugin) bool {
    for (all[0..len]) |*plugin| {
        for (plugin.actions[0..plugin.action_count],0..) |*entry,command_index| {
            const key = entry.user_shortcut orelse continue;
            if (plugin == exclude and candidate.scope == .browser and command_index == candidate.action) continue;
            if (sameChord(key,candidate)) return true;
        }
        if (plugin==exclude or !canContribute(plugin)) continue;
        if (plugin.hotkey) |key| if (sameChord(key,candidate)) return true;
    }
    return false;
}

fn userShortcutConflict(plugin: *const Plugin, candidate: Hotkey) bool {
    if (plugin.hotkey) |existing| {
        if (sameChord(existing,candidate) and (existing.scope != .browser or existing.action != candidate.action))
            return true;
    }
    return hotkeyConflict(candidate,plugin);
}

fn loadUserShortcuts() void {
    const capacity = 96 * 1024;
    const raw = allocator.alloc(u8, capacity) catch return;
    defer allocator.free(raw);
    if (!native.moon_read_text(&shortcut_path,raw.ptr,raw.len)) return;
    const saved = std.json.parseFromSlice([]UserShortcut,allocator,std.mem.sliceTo(raw,0),.{}) catch return;
    defer saved.deinit();
    for (saved.value) |item| {
        const plugin = &all[indexOf(item.plugin) orelse continue];
        const action_index = findAction(plugin,item.command) orelse continue;
        if (plugin.actions[action_index].user_shortcut != null or plugin.actions[action_index].bound()) continue;
        const key = parseHotkey(action_index,item.shortcut,.browser) orelse continue;
        if (hotkeyReserved(key) or userShortcutConflict(plugin,key)) continue;
        plugin.actions[action_index].user_shortcut = key;
    }
}

fn persistUserShortcuts() bool {
    var entries: [all.len * sdk.command_limit]UserShortcut = undefined;
    var used: usize = 0;
    for (all[0..len],0..) |*plugin,index| {
        for (plugin.actions[0..plugin.action_count],0..) |*entry,command_index| {
            const key = if (entry.user_shortcut) |*value| value else continue;
            entries[used] = .{ .plugin=idAt(index), .command=actionId(index,command_index), .shortcut=std.mem.sliceTo(&key.text,0) };
            used += 1;
        }
    }
    const json = std.json.Stringify.valueAlloc(allocator,entries[0..used],.{}) catch return false;
    defer allocator.free(json);
    const document = allocator.dupeSentinel(u8,json,0) catch return false;
    defer allocator.free(document);
    return native.moon_write_text(&shortcut_path,document.ptr);
}

pub fn setUserShortcut(index: usize, id: []const u8, text: ?[]const u8) sdk.UiRegistration {
    if (changing_state or confirming_hotkey or index >= len) return .unavailable;
    const plugin = &all[index];
    if (!plugin.enabled) return .unavailable;
    const action_index = findAction(plugin,id) orelse return .notFound;
    const entry = &plugin.actions[action_index];
    if (entry.bound()) return .unavailable;
    const previous = entry.user_shortcut;
    const key: ?Hotkey = if (text) |value| blk: {
        const candidate = parseHotkey(action_index,value,.browser) orelse return .invalidShortcut;
        if (hotkeyReserved(candidate)) return .reserved;
        if (userShortcutConflict(plugin,candidate)) return .conflict;
        break :blk candidate;
    } else null;
    entry.user_shortcut = key;
    if (!persistUserShortcuts()) {
        entry.user_shortcut = previous;
        return .unavailable;
    }
    return .saved;
}

pub fn setHotkey(owner: []const u8, id: []const u8, text: ?[]const u8, scope: sdk.ShortcutScope, consent: userscripts.Consent) sdk.UiRegistration {
    if (changing_state or confirming_hotkey) return .unavailable;
    const index = contributor(owner) orelse return .unavailable;
    const plugin = &all[index];
    const command_index = findAction(plugin,id) orelse return .notFound;
    if (plugin.actions[command_index].bound()) return .unavailable;
    const previous = plugin.hotkey;
    const old_slot = if (previous) |key| key.slot else null;
    var replacement: ?Hotkey = null;
    if (text) |value| {
        var key = parseHotkey(command_index,value,scope) orelse return .invalidShortcut;
        if (hotkeyReserved(key)) return .reserved;
        if (hotkeyConflict(key,plugin)) return .conflict;
        if (previous) |old| {
            if (sameChord(key,old) and old.scope==scope and old.action==command_index and
                (scope==.browser or old_slot!=null)) return .saved;
        }
        if (scope==.global) {
            var buffer: [680]u8 = undefined;
            const body = std.fmt.bufPrintSentinel(&buffer,"允许插件「{s}」在浏览器位于后台时使用 {s} 启动「{s}」？",
                .{ std.mem.sliceTo(&plugin.label,0),value,std.mem.sliceTo(&plugin.actions[command_index].label,0) },0) catch return .unavailable;
            confirming_hotkey = true;
            defer confirming_hotkey = false;
            if (!native.moon_shell_confirm("注册全局快捷键？",body.ptr)) return .cancelled;
            if (!consent.valid(consent.context) or !canContribute(plugin)) return .unavailable;
            if (hotkeyConflict(key,plugin)) return .conflict;
            if (previous!=null and old_slot!=null and sameChord(key,previous.?)) {
                key.slot = old_slot;
            } else {
                const slot: u1 = if (old_slot) |current| current^1 else 0;
                if (!native.moon_shell_register_hotkey(globalId(index,slot),key.mods,key.key)) return .conflict;
                key.slot = slot;
            }
        }
        replacement = key;
    } else if (previous==null or previous.?.action!=command_index) {
        return .saved;
    }
    const new_slot = if (replacement) |key| key.slot else null;
    plugin.hotkey = replacement;
    if (!persist()) {
        plugin.hotkey = previous;
        if (new_slot!=old_slot) if (new_slot) |slot| native.moon_shell_unregister_hotkey(globalId(index,slot));
        return .unavailable;
    }
    if (new_slot!=old_slot) if (old_slot) |slot| native.moon_shell_unregister_hotkey(globalId(index,slot));
    return .saved;
}

// Win32 MOD_* and VK_* values. Retain the numeric keypad alternatives for zoom.
fn defaultShortcut(mods: c_uint, vk: c_uint) ?sdk.Shortcut {
    const ctrl = 0x0002;
    const ctrl_shift = ctrl | 0x0004;
    const plus = vk==0xbb or vk==0x6b; // VK_OEM_PLUS, VK_ADD
    if (plus and (mods==ctrl or mods==ctrl_shift)) return .@"Ctrl++";
    if (mods==0x0004 and vk==0x74) return .@"Ctrl+Shift+R"; // Shift+F5
    return switch (mods) {
        0 => switch (vk) { 0x78 => .F9, 0x7a => .F11, 0x7b => .F12, else => null },
        ctrl => switch (vk) {
            'B' => .@"Ctrl+B",
            'H' => .@"Ctrl+H",
            'J' => .@"Ctrl+J",
            'D' => .@"Ctrl+D",
            'F' => .@"Ctrl+F",
            'U' => .@"Ctrl+U",
            'S' => .@"Ctrl+S",
            0xbc => .@"Ctrl+,",
            0xbd, 0x6d => .@"Ctrl+-",
            '0', 0x60 => .@"Ctrl+0",
            else => null,
        },
        ctrl_shift => switch (vk) {
            'A' => .@"Ctrl+Shift+A",
            'B' => .@"Ctrl+Shift+B",
            'C' => .@"Ctrl+Shift+C",
            'E' => .@"Ctrl+Shift+E",
            'I' => .F12,
            'J' => .@"Ctrl+Shift+J",
            'L' => .@"Ctrl+Shift+L",
            'R' => .@"Ctrl+Shift+R",
            'O' => .@"Ctrl+Shift+O",
            'T' => .@"Ctrl+Shift+T",
            'M' => .@"Ctrl+Shift+M",
            'N' => .@"Ctrl+Shift+N",
            0x2e => .@"Ctrl+Shift+Delete",
            else => null,
        },
        else => null,
    };
}

fn runShortcut(index: usize, command_index: usize, snapshot: ?Snapshot, repeated: bool) void {
    const plugin = &all[index];
    if (plugin.work==null) {
        _ = launch(index,command_index,.command,snapshot);
    } else if (!repeated) {
        const tab = snapshot orelse return;
        plugin.pending_command = .{ .action=command_index,.tab=tab.id,.navigation=tab.navigation };
    }
}

pub fn browserShortcut(mods: c_uint, vk: c_uint, repeated: bool, snapshot: ?Snapshot) bool {
    for (all[0..len],0..) |*plugin,index| {
        if (!plugin.enabled) continue;
        for (plugin.actions[0..plugin.action_count]) |entry| {
            const key = entry.user_shortcut orelse continue;
            if (key.mods != mods or key.key != vk) continue;
            if (!repeated) runShortcut(index,key.action,snapshot,false);
            return true;
        }
    }
    for (all[0..len],0..) |*plugin,index| {
        const key = plugin.hotkey orelse continue;
        if (!canContribute(plugin) or key.scope!=.browser or key.mods!=mods or key.key!=vk) continue;
        if (plugin.actions[key.action].user_shortcut != null) continue;
        if (!repeated) runShortcut(index,key.action,snapshot,false);
        return true;
    }
    const key = defaultShortcut(mods,vk) orelse return false;
    for (all[0..len],0..) |*plugin,index| {
        if (!plugin.enabled) continue;
        for (plugin.actions[0..plugin.action_count],0..) |entry,command_index| {
            if (entry.shortcut!=key or entry.user_shortcut!=null or registeredShortcut(index,command_index)!=null) continue;
            if (key==.F11 and ((!plugin.bundled and !canContribute(plugin)) or
                !plugin.grants.contains(.@"window.fullscreen"))) continue;
            const developer_control=key==.@"Ctrl+Shift+R" or key==.@"Ctrl+Shift+E";
            if (developer_control and (!plugin.grants.contains(.@"page.inspect") or
                (!plugin.bundled and !canContribute(plugin)))) continue;
            if (key==.@"Ctrl+Shift+A" and !plugin.grants.contains(.@"tabs.manage")) continue;
            const appearance = key==.@"Ctrl+B" or key==.@"Ctrl+Shift+L";
            if (appearance and (!plugin.grants.contains(.@"window.appearance") or
                (!plugin.bundled and !canContribute(plugin)))) continue;
            if (!repeated or (!appearance and !developer_control and key!=.F9 and key!=.F11 and key!=.F12 and
                key!=.@"Ctrl+Shift+C" and key!=.@"Ctrl+S" and key!=.@"Ctrl+Shift+A"))
                runShortcut(index,command_index,snapshot,repeated);
            return true;
        }
    }
    return false;
}

pub fn globalShortcut(id: c_uint, mods: c_uint, vk: c_uint, snapshot: ?Snapshot) bool {
    if (id<hotkey_id) return false;
    const index = (id-hotkey_id)/2;
    if (index>=len) return false;
    const plugin = &all[index];
    const key = plugin.hotkey orelse return false;
    const slot = key.slot orelse return false;
    if (!canContribute(plugin) or id!=globalId(index,slot) or key.mods!=mods or key.key!=vk) return false;
    native.moon_shell_wake();
    if (plugin.work==null) _ = launch(index,key.action,.command,snapshot);
    return true;
}

pub fn systemEnabled(permission: sdk.Permission) bool {
    for (all[0..len]) |*plugin| {
        if (plugin.default_grants.contains(permission)) return plugin.enabled and plugin.grants.contains(permission);
    }
    return false;
}

pub fn networkSource() ?network.Source {
    for (all[0..len]) |*plugin| {
        if (plugin.enabled and plugin.grants.contains(.@"network.filter") and plugin.network_rules[0] != 0)
            return .{ .id=std.mem.sliceTo(&plugin.id,0),.executable=std.mem.sliceTo(&plugin.executable,0),.filename=std.mem.sliceTo(&plugin.network_rules,0) };
    }
    return null;
}

pub fn addressForId(id: []const u8, buffer: []u8) ?[:0]u8 {
    for (all[0..len],0..) |*plugin,index| {
        if (std.mem.eql(u8,std.mem.sliceTo(&plugin.id,0),id)) return settingsAddress(index,buffer);
    }
    return null;
}

pub fn readSettingsPage(address: []const u8, body: []u8) ?[:0]const u8 {
    if (!std.mem.startsWith(u8,address,"extension://")) return null;
    const route = address["extension://".len..];
    const slash = std.mem.indexOfScalar(u8,route,'/') orelse return null;
    const id = route[0..slash];
    const page = route[slash+1..];
    for (all[0..len]) |*plugin| {
        if (!plugin.enabled or plugin.settings_page[0] == 0 or
            !std.ascii.eqlIgnoreCase(std.mem.sliceTo(&plugin.id,0),id) or
            !std.mem.eql(u8,std.mem.sliceTo(&plugin.settings_page,0),page)) continue;
        const executable = std.mem.sliceTo(&plugin.executable,0);
        const folder_end = std.mem.lastIndexOfScalar(u8,executable,'\\') orelse return null;
        var filename: [4096]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&filename,"{s}\\{s}",.{ executable[0..folder_end],page },0) catch return null;
        if (!native.moon_read_plain_text(path.ptr,body.ptr,body.len)) return null;
        return &plugin.id;
    }
    return null;
}

fn launch(index: usize, command_index: usize, trigger: Trigger, snapshot: ?Snapshot) bool {
    return launchBound(index,command_index,trigger,snapshot,.{});
}

const Invocation = struct {
    link: ?*api.LinkInvocation = null,
    drop: ?api.TabDropInvocation = null,
    group_selection: ?sdk.TabGroupSelection = null,
    mute_selection: ?bool = null,
};

fn launchBound(index: usize, command_index: usize, trigger: Trigger, snapshot: ?Snapshot, binding: Invocation) bool {
    if (index >= len) return false;
    const plugin = &all[index];
    if (!plugin.enabled or plugin.work != null or command_index >= plugin.action_count) return false;
    if (linkOnly(index,command_index) != (binding.link!=null) or tabDropOnly(index,command_index) != (binding.drop!=null)) return false;
    const task = allocator.create(Task) catch return false;
    const rpc = if (plugin.protocol == .v2) allocator.create(Rpc) catch {
        allocator.destroy(task);
        return false;
    } else null;
    if (rpc) |state| state.* = .{};
    task.* = .{
        .executable = &plugin.executable,
        .epoch = &plugin.epoch,
        .expected_epoch = plugin.epoch.load(.acquire),
        .snapshot = if (plugin.grants.contains(.@"tabs.read") or plugin.grants.contains(.@"bookmarks.manage") or
            plugin.grants.contains(.@"siteData.read") or plugin.grants.contains(.@"page.source")) snapshot else null,
        .target_tab_id = if (snapshot) |tab| tab.id else 0,
        .target_navigation = if (snapshot) |tab| tab.navigation else 0,
        .selection_epoch = if (trigger == .command and plugin.grants.contains(.@"tabs.manage")) native.moon_tab_selection_epoch() else 0,
        .group_selection = binding.group_selection,
        .mute_selection = binding.mute_selection,
        .trigger = trigger,
        .plugin_id = &plugin.id,
        .command_id = &plugin.actions[command_index].id,
        .interactive = plugin.actions[command_index].interactive,
        .owner = native.moon_shell_window_handle(),
        .dark = native.moon_shell_dark_mode(),
        .grants = plugin.grants,
        .rpc = rpc,
        .link = binding.link,
        .drop = binding.drop,
    };
    plugin.work = task;
    if (!native.moon_plugin_thread(task)) {
        plugin.work = null;
        if (rpc) |state| allocator.destroy(state);
        allocator.destroy(task);
        return false;
    }
    return true;
}

pub fn linkCommand(index: usize, command_index: usize, snapshot: ?Snapshot, context: *const native.MoonLinkContext) void {
    const operation = linkAction(index,command_index) orelse return;
    const invocation = allocator.create(api.LinkInvocation) catch return;
    invocation.* = .{ .context=context.*, .operation=operation };
    if (!launchBound(index,command_index,.command,snapshot,.{ .link=invocation })) allocator.destroy(invocation);
}

pub fn tabDropCommand(drop: native.MoonTabDrop, snapshot: Snapshot) bool {
    const provider = tabDropProvider() orelse return false;
    const plugin = &all[provider.plugin];
    if (plugin.work!=null) {
        plugin.pending_drop = drop;
        return true;
    }
    return launchBound(provider.plugin,provider.command,.command,snapshot,.{ .drop=.{ .context=drop } });
}

pub fn command(index: usize, command_index: usize, snapshot: ?Snapshot) void {
    if (index<len and snapshot!=null) {
        const plugin = &all[index];
        if (plugin.bundled and plugin.enabled and plugin.work!=null and command_index<plugin.action_count and
            std.mem.eql(u8,idAt(index),"moon.devtools")) {
            const tab = snapshot.?;
            plugin.pending_command = .{ .action=command_index,.tab=tab.id,.navigation=tab.navigation };
            return;
        }
    }
    if (!launch(index, command_index, .command, snapshot))
        native.moon_shell_info("Plugin", "This plugin is disabled, busy, or could not start.");
}

pub fn namedCommand(id: []const u8, action_id: []const u8, snapshot: ?Snapshot) bool {
    for (all[0..len],0..) |*plugin,index| {
        if (!plugin.enabled or !std.mem.eql(u8,std.mem.sliceTo(&plugin.id,0),id)) continue;
        const command_index = findAction(plugin,action_id) orelse return false;
        if (plugin.work==null) command(index,command_index,snapshot);
        return true;
    }
    return false;
}

pub fn launchSystemCommand(id: []const u8, action_id: []const u8, snapshot: Snapshot) bool {
    return launchBundled(id,action_id,snapshot,.{});
}

fn launchBundled(id: []const u8, action_id: []const u8, snapshot: Snapshot, binding: Invocation) bool {
    for (all[0..len],0..) |*plugin,index| {
        if (!plugin.bundled or !plugin.enabled or !std.mem.eql(u8,idAt(index),id)) continue;
        const command_index = findAction(plugin,action_id) orelse return false;
        return launchBound(index,command_index,.command,snapshot,binding);
    }
    return false;
}
pub fn launchTabGroupSelection(selection: sdk.TabGroupSelection, snapshot: Snapshot) bool {
    return launchBundled("moon.tab-tools","groupCreate",snapshot,.{ .group_selection=selection });
}
pub fn launchTabMuteSelection(muted: bool, snapshot: Snapshot) bool {
    return launchBundled("moon.tab-tools","mute",snapshot,.{ .mute_selection=muted });
}
pub fn changed(snapshot: ?Snapshot) void {
    for (all[0..len], 0..) |*plugin, index| {
        if (!plugin.enabled or !plugin.subscribes) continue;
        if (plugin.protocol == .v2 and !plugin.grants.contains(.@"tabs.read")) continue;
        if (!launch(index, 0, .changed, snapshot)) plugin.queued_change = true;
    }
}

fn invocationActive(context: ?*const anyopaque) callconv(.c) bool {
    const task: *const Task = @ptrCast(@alignCast(context orelse return false));
    return !task.done.load(.acquire) and task.epoch.load(.acquire) == task.expected_epoch and
        native.moon_clock() < task.rpc.?.deadline;
}

fn serviceRpc(task: *Task, rpc: *Rpc) void {
    if (rpc.state.load(.acquire) != .queued) return;
    rpc.state.store(.serving, .release);
    defer rpc.state.store(.ready, .release);
    serving_rpc = true;
    defer serving_rpc = false;
    const reply = api.dispatch(allocator, rpc.buffer[0..rpc.size], .{
        .grants = task.grants,
        .plugin_id = std.mem.span(task.plugin_id),
        .target_tab_id = task.target_tab_id,
        .target_navigation = task.target_navigation,
        .selection_epoch = task.selection_epoch,
        .group_selection = task.group_selection,
        .mute_selection = task.mute_selection,
        .tab = if (task.snapshot) |*snapshot| snapshot else null,
        .consent = .{ .context = task, .valid = invocationActive },
        .user_command = task.trigger == .command,
        .link = task.link,
        .drop = if (task.drop) |*drop| drop else null,
    }) catch {
        rpc.size = 0;
        return;
    };
    defer allocator.free(reply);
    @memcpy(rpc.buffer[0..reply.len], reply);
    rpc.size = reply.len;
}

pub fn tick(snapshot: ?Snapshot, smoking: bool) void {
    if (serving_rpc) return;
    for (all[0..len], 0..) |*plugin, index| {
        const task = plugin.work orelse continue;
        if (task.rpc) |rpc| if (!task.done.load(.acquire)) serviceRpc(task, rpc);
        if (!task.done.load(.acquire)) continue;
        plugin.work = null;
        if (smoking) {
            smoke_outcome = task.outcome;
            smoke_message = task.message;
        } else if (task.trigger == .command and task.outcome == .ok and task.toast and task.message[0] != 0) {
            native.moon_shell_toast(&plugin.label,&task.message);
        } else if (task.trigger == .command and (task.rpc == null or task.outcome != .ok or task.message[0] != 0)) {
            native.moon_shell_info(&plugin.label, switch (task.outcome) {
                .ok => &task.message,
                .timed_out => "The plugin timed out.",
                .crashed => "The plugin exited unexpectedly.",
                .failed => "Could not start the plugin or read its response.",
            });
        }
        if (task.rpc) |rpc| allocator.destroy(rpc);
        if (task.link) |link| allocator.destroy(link);
        allocator.destroy(task);
        if (plugin.pending_drop) |drop| {
            plugin.pending_drop = null;
            native.moon_tab_drop_run(&drop);
            if (plugin.work!=null) continue;
        }
        if (plugin.pending_command) |pending| {
            plugin.pending_command = null;
            if (snapshot) |tab| {
                if (tab.id==pending.tab and tab.navigation==pending.navigation and launch(index,pending.action,.command,snapshot)) continue;
            }
        }
        if (plugin.queued_change) {
            plugin.queued_change = false;
            _ = launch(index, 0, .changed, snapshot);
        }
    }
}

const WireTab = struct { id: u64, title: []const u8, url: []const u8 };
fn permitted(task: *const Task) ?WireTab {
    if (task.epoch.load(.acquire) != task.expected_epoch) return null;
    if (task.snapshot) |*tab| return .{ .id = tab.id, .title = std.mem.sliceTo(&tab.title, 0), .url = std.mem.sliceTo(&tab.url, 0) };
    return null;
}
fn send(pipe: *native.MoonPipe, message: anytype) bool {
    const json = std.json.Stringify.valueAlloc(allocator, message, .{}) catch return false;
    defer allocator.free(json);
    var frame: [16384]u8 = undefined;
    const line = std.fmt.bufPrintSentinel(&frame, "{s}\n", .{json}, 0) catch return false;
    return native.moon_pipe_send(pipe, line.ptr);
}
fn exchangeLegacy(task: *Task, pipe: *native.MoonPipe) Outcome {
    const method: []const u8 = switch (task.trigger) {
        .command => "plugin.command",
        .changed => "tabs.changed",
        .timeout_test => "test.timeout",
        .crash_test => "test.crash",
    };
    if (task.epoch.load(.acquire) != task.expected_epoch) return .failed;
    if (!send(pipe, .{ .jsonrpc = "2.0", .id = @as(u32, 1), .method = method, .params = .{
        .version = @as(u32, 1),
        .tab = if (task.trigger == .changed) permitted(task) else null,
    } })) return .failed;
    var frame: [16384]u8 = undefined;
    var answered = false;
    for (0..2) |_| {
        const read = native.moon_pipe_read(pipe, &frame, frame.len);
        if (read == -2) return .timed_out;
        if (read == -3) return .crashed;
        if (read <= 0) return .failed;
        const message = std.json.parseFromSlice(std.json.Value, allocator, frame[0..@intCast(read)], .{}) catch return .failed;
        defer message.deinit();
        if (message.value != .object) return .failed;
        const version = message.value.object.get("jsonrpc") orelse return .failed;
        const id = message.value.object.get("id") orelse return .failed;
        if (version != .string or !std.mem.eql(u8, version.string, "2.0") or id != .integer) return .failed;
        if (id.integer == 1) {
            const result = message.value.object.get("result") orelse return .failed;
            if (result != .string or !copy(&task.message, result.string)) return .failed;
            return .ok;
        }
        if (id.integer != 2 or answered) return .failed;
        const request = message.value.object.get("method") orelse return .failed;
        if (request != .string or !std.mem.eql(u8, request.string, "tabs.getActive")) return .failed;
        answered = true;
        if (permitted(task)) |tab| {
            if (!send(pipe, .{ .jsonrpc = "2.0", .id = @as(u32, 2), .result = tab })) return .failed;
        } else if (!send(pipe, .{ .jsonrpc = "2.0", .id = @as(u32, 2), .@"error" = .{
            .code = @as(i32, -32001),
            .message = "tabs.read denied",
        } })) return .failed;
    }
    return .failed;
}

fn sendRpc(rpc: *Rpc, pipe: *native.MoonPipe, bytes: []const u8) bool {
    // The anonymous pipe has 64 KiB of capacity. Bound cumulative output so
    // a client that writes requests without draining replies cannot block us.
    const total = bytes.len + 1;
    if (total >= sdk.frame_limit or rpc.sent + total > 48 * 1024) return false;
    rpc.sent += total;
    var line: [sdk.frame_limit]u8 = undefined;
    @memcpy(line[0..bytes.len], bytes);
    line[bytes.len] = '\n';
    line[total] = 0;
    return native.moon_pipe_send(pipe, line[0..total :0].ptr);
}

fn exchangeV2(task: *Task, pipe: *native.MoonPipe, rpc: *Rpc) Outcome {
    if (task.epoch.load(.acquire) != task.expected_epoch) return .failed;
    var grants: [@typeInfo(sdk.Permission).@"enum".field_names.len]sdk.Permission = undefined;
    var count_grants: usize = 0;
    var iterator = task.grants.iterator();
    while (iterator.next()) |scope| {
        grants[count_grants] = scope;
        count_grants += 1;
    }
    const request_limit: u32 = if (task.trigger == .command and task.interactive) sdk.interactive_request_limit else sdk.request_limit;
    const hello = sdk.request(allocator, "h:1", "plugin.initialize", sdk.Initialization{
        .apiVersion = sdk.api_version, .pluginId = std.mem.span(task.plugin_id), .permissions = grants[0..count_grants],
        .browserWindow = task.owner, .darkMode = task.dark, .requestLimit = request_limit,
    }) catch return .failed;
    defer allocator.free(hello);
    if (!sendRpc(rpc, pipe, hello)) return .failed;

    var frame: [sdk.frame_limit]u8 = undefined;
    const handshake = native.moon_pipe_read(pipe, &frame, frame.len);
    if (handshake <= 0) return pipeOutcome(handshake);
    {
        const decoded = std.json.parseFromSlice(std.json.Value, allocator, frame[0..@intCast(handshake)], .{}) catch return .failed;
        defer decoded.deinit();
        const ack = sdk.envelope(decoded.value) orelse return .failed;
        if (!std.mem.eql(u8, sdk.string(ack.get("id")) orelse return .failed, "h:1")) return .failed;
        if (ack.contains("method") or ack.contains("error") or (ack.get("result") orelse return .failed) != .null) return .failed;
    }
    if (task.epoch.load(.acquire) != task.expected_epoch) return .failed;
    const budget: c_uint = if (task.trigger != .command) 2000 else if (task.interactive) 30*60*1000 else 120000;
    rpc.deadline = native.moon_clock() + budget;
    native.moon_pipe_set_budget(pipe, budget);
    const event = task.trigger == .changed;
    var tab_buffer: [24]u8 = undefined;
    const command_id = std.mem.span(task.command_id);
    const invocation = if (event) sdk.serialize(allocator, .{
        .jsonrpc = sdk.rpc_version, .method = "tabs.changed", .params = sdk.TabChange{
            .tabId = if (task.snapshot) |tab| api.tabId(tab.id, &tab_buffer) else null,
        },
    }) catch return .failed else if (task.group_selection) |group| sdk.request(allocator, "h:2", "commands.run", .{
        .id = command_id, .groupSelection = group,
    }) catch return .failed else if (task.mute_selection) |muted| sdk.request(allocator, "h:2", "commands.run", .{
        .id = command_id, .muteSelection = muted,
    }) catch return .failed else sdk.request(allocator, "h:2", "commands.run", .{ .id = command_id }) catch return .failed;
    defer allocator.free(invocation);
    if (!sendRpc(rpc, pipe, invocation)) return .failed;

    var sequence: u32 = 0;
    for (0..request_limit + 1) |_| {
        if (!invocationActive(task)) return .timed_out;
        const read = native.moon_pipe_read_active(pipe, &frame, frame.len, invocationActive, task);
        if (event and read == -3) return .ok;
        if (read <= 0) return pipeOutcome(read);
        const bytes = frame[0..@intCast(read)];
        const decoded = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return .failed;
        defer decoded.deinit();
        const message = sdk.envelope(decoded.value) orelse return .failed;
        const id = sdk.string(message.get("id")) orelse return .failed;
        if (!event and std.mem.eql(u8, id, "h:2")) {
            if (message.contains("method") or message.contains("error")) return .failed;
            const reply = std.json.parseFromValue(sdk.CommandResult, allocator, message.get("result") orelse return .failed, .{}) catch return .failed;
            defer reply.deinit();
            if (!copy(&task.message, reply.value.message orelse "")) return .failed;
            task.toast = reply.value.toast;
            return .ok;
        }
        if (!std.mem.startsWith(u8, id, "p:") or id.len > 11) return .failed;
        for (id[2..]) |ch| if (!std.ascii.isDigit(ch)) return .failed;
        const next = std.fmt.parseUnsigned(u32, id[2..], 10) catch return .failed;
        if (next != sequence + 1 or sequence >= request_limit) return .failed;
        sequence = next;
        if (!invocationActive(task)) return .timed_out;
        @memcpy(rpc.buffer[0..bytes.len], bytes);
        rpc.size = bytes.len;
        rpc.state.store(.queued, .release);
        while (rpc.state.load(.acquire) != .ready) {
            if (!invocationActive(task)) return .timed_out;
            native.moon_plugin_wait();
        }
        if (rpc.size == 0 or !sendRpc(rpc, pipe, rpc.buffer[0..rpc.size])) return .failed;
        rpc.state.store(.idle, .release);
    }
    return .failed;
}

fn pipeOutcome(code: c_int) Outcome {
    return switch (code) {
        -2 => .timed_out,
        -3 => .crashed,
        else => .failed,
    };
}

pub fn worker(opaque_task: ?*anyopaque) void {
    const task: *Task = @ptrCast(@alignCast(opaque_task orelse return));
    defer task.done.store(true, .release);
    var win_error: u32 = 0;
    const pipe = native.moon_pipe_open(task.executable, &win_error) orelse {
        _ = std.fmt.bufPrintSentinel(&task.message, "Could not launch plugin (Windows error {d}).", .{win_error}, 0) catch {};
        return;
    };
    task.outcome = if (task.rpc) |rpc| exchangeV2(task, pipe, rpc) else exchangeLegacy(task, pipe);
    const exited_cleanly = native.moon_pipe_close(pipe);
    if (task.outcome == .ok and !exited_cleanly) task.outcome = .crashed;
}

fn smokePlugin(step: usize) ?usize {
    const id = if (step < 5) "moon.legacy-contract" else if (step < 9) "moon.api-contract" else "moon.example";
    const index = indexOf(id) orelse return null;
    const protocol: Protocol = if (step < 5) .legacy else .v2;
    return if (all[index].protocol == protocol) index else null;
}

pub fn smokeNextStep(from: usize) ?usize {
    for (from..12) |step| if (smokePlugin(step) != null) return step;
    return null;
}

pub fn smokeStart(step: usize, snapshot: ?Snapshot) bool {
    const index = smokePlugin(step) orelse return false;
    const plugin = &all[index];
    _ = plugin.epoch.fetchAdd(1, .acq_rel);
    plugin.enabled = true;
    plugin.grants = switch (step) {
        1...4, 10, 11 => .initOne(.@"tabs.read"),
        6, 7 => .initMany(&.{ .@"tabs.read", .@"lua.scripts.manage" }),
        else => .empty,
    };
    const trigger: Trigger = switch (step) {
        2, 7, 11 => .changed,
        3 => .timeout_test,
        4 => .crash_test,
        else => .command,
    };
    smoke_outcome = null;
    return launch(index, if (step == 6) 1 else 0, trigger, snapshot);
}

pub fn smokeStatus(step: usize, title: []const u8) ?bool {
    const outcome = smoke_outcome orelse return null;
    const message = std.mem.sliceTo(&smoke_message, 0);
    return switch (step) {
        0 => outcome == .ok and std.mem.eql(u8, message, "No access to active tab details"),
        1, 10 => outcome == .ok and std.mem.eql(u8, message, title),
        2 => outcome == .ok and std.mem.eql(u8, message, "Tab change received"),
        3 => outcome == .timed_out,
        4 => outcome == .crashed,
        5, 8 => outcome == .ok and std.mem.eql(u8, message, "V2 consent denied"),
        6 => outcome == .ok and std.mem.eql(u8, message, "V2 contract passed"),
        7, 11 => outcome == .ok,
        9 => outcome == .ok and std.mem.eql(u8, message, "请在插件管理中授予读取标签权限。"),
        else => false,
    };
}

pub fn smokeDetail() struct { outcome: []const u8, message: []const u8 } {
    return .{ .outcome = if (smoke_outcome) |value| @tagName(value) else "pending", .message = std.mem.sliceTo(&smoke_message, 0) };
}
