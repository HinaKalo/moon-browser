const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const optimize = b.standardOptimizeOption(.{});
    const app = b.addExecutable(.{
        .name = "MoonBrowser",
        .win32_manifest = b.path("src/moon-browser.manifest"),
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
    });
    app.subsystem = .windows;
    const bridge = b.addTranslateC(.{ .root_source_file = b.path("src/bridge.h"), .target = target, .optimize = optimize });
    const plugin_sdk = b.createModule(.{ .root_source_file = b.path("sdk/moon_plugin.zig") });
    app.root_module.addImport("native", bridge.createModule());
    app.root_module.addImport("moon_plugin", plugin_sdk);
    app.root_module.addWin32ResourceFile(.{ .file=b.path("src/moon-browser.rc") });
    app.root_module.addIncludePath(b.path("third_party"));
    app.root_module.addCSourceFiles(.{ .files = &.{ "src/win.c", "src/win_dialog.c", "src/win_find.c", "src/webkit.c", "src/plugin_io.c", "src/update_win.c", "src/lua_runtime.c" }, .flags = &.{ "-std=c17", "-DUNICODE", "-D_UNICODE" } });
    app.root_module.addCSourceFiles(.{ .root = b.path("third_party/Lua"), .files = &.{
        "lapi.c", "lauxlib.c", "lbaselib.c", "lcode.c", "lctype.c", "ldebug.c", "ldo.c", "ldump.c",
        "lfunc.c", "lgc.c", "llex.c", "lmathlib.c", "lmem.c", "lobject.c", "lopcodes.c", "lparser.c",
        "lstate.c", "lstring.c", "ltable.c", "ltablib.c", "ltm.c", "lundump.c", "lutf8lib.c", "lvm.c", "lzio.c",
    }, .flags = &.{"-std=c17"} });
    for ([_][]const u8{ "user32", "gdi32", "d2d1", "dwrite", "gdiplus", "shlwapi", "shell32", "ole32", "comdlg32", "advapi32", "psapi", "imm32", "comctl32", "winhttp", "bcrypt" }) |library|
        app.root_module.linkSystemLibrary(library, .{});
    b.installArtifact(app);
    const request_filter = b.addLibrary(.{
        .name = "MoonRequestFilter",
        .linkage = .dynamic,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    request_filter.root_module.addIncludePath(b.path("third_party"));
    request_filter.root_module.addCSourceFiles(.{ .files = &.{ "src/request_filter.c","src/site_snapshot.c" }, .flags = &.{"-std=c17"} });
    b.installArtifact(request_filter);

    const example = b.addExecutable(.{
        .name = "MoonExamplePlugin",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/plugin.zig"), .target = target, .optimize = optimize, .link_libc = true }),
    });
    b.installArtifact(example);
    const manager = b.addExecutable(.{
        .name = "MoonLuaManager",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/lua-manager/main.zig"), .target = target, .optimize = optimize, .link_libc = true }),
    });
    manager.root_module.addImport("moon_plugin",plugin_sdk);
    manager.root_module.addCSourceFile(.{ .file = b.path("examples/lua-manager/window.c"), .flags = &.{ "-std=c17","-DUNICODE","-D_UNICODE" } });
    for ([_][]const u8{ "user32","gdi32","comdlg32" }) |library| manager.root_module.linkSystemLibrary(library,.{});
    b.installArtifact(manager);
    const devtools = b.addExecutable(.{
        .name = "MoonDevTools",
        .root_module = b.createModule(.{ .root_source_file=b.path("examples/devtools/main.zig"), .target=target, .optimize=optimize, .link_libc=true }),
    });
    devtools.root_module.addImport("moon_plugin",plugin_sdk);
    b.installArtifact(devtools);
    const page_source = b.addExecutable(.{
        .name = "MoonPageSource",
        .root_module = b.createModule(.{ .root_source_file=b.path("examples/page-source/main.zig"), .target=target, .optimize=optimize, .link_libc=true }),
    });
    page_source.root_module.addImport("moon_plugin",plugin_sdk);
    b.installArtifact(page_source);
    const popups = b.addExecutable(.{
        .name = "MoonPopups",
        .root_module = b.createModule(.{ .root_source_file=b.path("examples/popups/main.zig"), .target=target, .optimize=optimize, .link_libc=true }),
    });
    popups.root_module.addImport("moon_plugin",plugin_sdk);
    b.installArtifact(popups);
    for ([_][]const u8{ "MoonHistory", "MoonBlocker", "MoonDownloads", "MoonPrivacy", "MoonTaskManager", "MoonSearch" }) |name| {
        const opener = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{ .root_source_file=b.path("examples/open_plugin_page.zig"), .target=target, .optimize=optimize, .link_libc=true }),
        });
        opener.root_module.addImport("moon_plugin",plugin_sdk);
        b.installArtifact(opener);
    }
    const bookmarks = b.addExecutable(.{
        .name = "MoonBookmarks",
        .root_module = b.createModule(.{ .root_source_file=b.path("examples/bookmarks/main.zig"),.target=target,.optimize=optimize,.link_libc=true }),
    });
    bookmarks.root_module.addImport("moon_plugin",plugin_sdk);
    b.installArtifact(bookmarks);
    const site_data = b.addExecutable(.{
        .name = "MoonSiteData",
        .root_module = b.createModule(.{ .root_source_file=b.path("examples/site-data/main.zig"),.target=target,.optimize=optimize,.link_libc=true }),
    });
    site_data.root_module.addImport("moon_plugin",plugin_sdk);
    b.installArtifact(site_data);
    const reading = b.addExecutable(.{
        .name = "MoonReading",
        .root_module = b.createModule(.{ .root_source_file=b.path("examples/reading/main.zig"),.target=target,.optimize=optimize,.link_libc=true }),
    });
    reading.root_module.addImport("moon_plugin",plugin_sdk);
    b.installArtifact(reading);
    const command_example = b.addExecutable(.{
        .name = "MoonCommandExample",
        .root_module = b.createModule(.{ .root_source_file=b.path("examples/ui-commands/main.zig"),.target=target,.optimize=optimize,.link_libc=true }),
    });
    command_example.root_module.addImport("moon_plugin",plugin_sdk);
    b.installArtifact(command_example);
    const recent_tabs = b.addExecutable(.{
        .name = "MoonRecentTabs",
        .root_module = b.createModule(.{ .root_source_file=b.path("examples/recent-tabs/main.zig"),.target=target,.optimize=optimize,.link_libc=true }),
    });
    recent_tabs.root_module.addImport("moon_plugin",plugin_sdk);
    b.installArtifact(recent_tabs);
    const session = b.addExecutable(.{
        .name = "MoonSession",
        .root_module = b.createModule(.{ .root_source_file=b.path("examples/session/main.zig"),.target=target,.optimize=optimize,.link_libc=true }),
    });
    session.root_module.addImport("moon_plugin",plugin_sdk);
    b.installArtifact(session);
    const tab_tools = b.addExecutable(.{
        .name = "MoonTabTools",
        .root_module = b.createModule(.{ .root_source_file=b.path("examples/tab-tools/main.zig"),.target=target,.optimize=optimize,.link_libc=true }),
    });
    tab_tools.root_module.addImport("moon_plugin",plugin_sdk);
    b.installArtifact(tab_tools);
    const private_window = b.addExecutable(.{
        .name = "MoonPrivateWindow",
        .root_module = b.createModule(.{ .root_source_file=b.path("examples/private-window/main.zig"),.target=target,.optimize=optimize,.link_libc=true }),
    });
    private_window.root_module.addImport("moon_plugin",plugin_sdk);
    b.installArtifact(private_window);
    const fixture = b.addExecutable(.{
        .name = "MoonPluginContractClient",
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/plugin_contract_client.zig"), .target = target, .optimize = optimize, .link_libc = true }),
    });
    fixture.root_module.addImport("moon_plugin", plugin_sdk);
    b.installArtifact(fixture);
    const test_step = b.step("test", "Run browser policy and update verification tests");
    for ([_][]const u8{ "src/policy_test.zig", "src/update_manifest_test.zig" }) |file| {
        const unit_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}
