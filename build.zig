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
    app.root_module.addImport("native", bridge.createModule());
    app.root_module.addIncludePath(b.path("third_party"));
    app.root_module.addCSourceFiles(.{ .files = &.{ "src/win.c", "src/webkit.c", "src/plugin_io.c", "src/update_win.c", "src/lua_runtime.c" }, .flags = &.{ "-std=c17", "-DUNICODE", "-D_UNICODE" } });
    app.root_module.addCSourceFiles(.{ .root = b.path("third_party/Lua"), .files = &.{
        "lapi.c", "lauxlib.c", "lbaselib.c", "lcode.c", "lctype.c", "ldebug.c", "ldo.c", "ldump.c",
        "lfunc.c", "lgc.c", "llex.c", "lmathlib.c", "lmem.c", "lobject.c", "lopcodes.c", "lparser.c",
        "lstate.c", "lstring.c", "ltable.c", "ltablib.c", "ltm.c", "lundump.c", "lutf8lib.c", "lvm.c", "lzio.c",
    }, .flags = &.{"-std=c17"} });
    for ([_][]const u8{ "user32", "gdi32", "d2d1", "dwrite", "gdiplus", "shlwapi", "shell32", "ole32", "comdlg32", "advapi32", "psapi", "imm32", "comctl32", "winhttp", "bcrypt" }) |library|
        app.root_module.linkSystemLibrary(library, .{});
    b.installArtifact(app);

    const example = b.addExecutable(.{
        .name = "MoonExamplePlugin",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/plugin.zig"), .target = target, .optimize = optimize, .link_libc = true }),
    });
    b.installArtifact(example);
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
