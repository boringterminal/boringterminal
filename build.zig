const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const portable_system_goldens = b.option(
        bool,
        "portable-system-goldens",
        "Keep geometry/content checks but omit hashes of OS-owned font pixels",
    ) orelse false;
    const zg = b.dependency("zg", .{});
    const display_width = zg.module("DisplayWidth");
    const graphemes = zg.module("Graphemes");
    const caseless_match = zg.module("CaselessMatch");

    // The app: vt core + Metal renderer + AppKit shell. macOS only, by design.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("DisplayWidth", display_width);
    exe_mod.addImport("Graphemes", graphemes);
    exe_mod.addImport("CaselessMatch", caseless_match);
    linkMacFrameworks(exe_mod);
    const exe = b.addExecutable(.{ .name = "boringterminal", .root_module = exe_mod });

    const app_name = "Boring Terminal.app";
    const app_contents = app_name ++ "/Contents";
    const app_executable = app_contents ++ "/MacOS/boringterminal";
    const daemon_executable = app_contents ++ "/MacOS/boringterminald";
    const app_resources = app_contents ++ "/Resources";

    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = app_executable,
    });
    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    daemon_mod.addImport("DisplayWidth", display_width);
    daemon_mod.addImport("Graphemes", graphemes);
    daemon_mod.addImport("CaselessMatch", caseless_match);
    linkImageFrameworks(daemon_mod);
    const daemon_exe = b.addExecutable(.{ .name = "boringterminald", .root_module = daemon_mod });
    const install_daemon = b.addInstallArtifact(daemon_exe, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = daemon_executable,
    });
    const install_plist = b.addInstallFile(
        b.path("assets/Info.plist"),
        app_contents ++ "/Info.plist",
    );

    const iconutil = b.addSystemCommand(&.{ "/usr/bin/iconutil", "-c", "icns", "-o" });
    const app_icon = iconutil.addOutputFileArg("AppIcon.icns");
    iconutil.addDirectoryArg(b.path("assets/AppIcon.iconset"));
    for ([_][]const u8{
        "icon_16x16.png",
        "icon_16x16@2x.png",
        "icon_32x32.png",
        "icon_32x32@2x.png",
        "icon_128x128.png",
        "icon_128x128@2x.png",
        "icon_256x256.png",
        "icon_256x256@2x.png",
        "icon_512x512.png",
        "icon_512x512@2x.png",
    }) |icon_name| {
        iconutil.addFileInput(b.path(b.pathJoin(&.{ "assets/AppIcon.iconset", icon_name })));
    }
    const install_icon = b.addInstallFile(app_icon, app_resources ++ "/AppIcon.icns");

    const app_path = b.getInstallPath(.prefix, app_name);
    const codesign_exe = b.addSystemCommand(&.{
        "/usr/bin/codesign",
        "--force",
        "--sign",
        "-",
        "--timestamp=none",
        b.getInstallPath(.prefix, app_executable),
    });
    codesign_exe.setName("ad-hoc sign boringterminal");
    codesign_exe.step.dependOn(&install_exe.step);
    const codesign_daemon = b.addSystemCommand(&.{
        "/usr/bin/codesign",
        "--force",
        "--sign",
        "-",
        "--timestamp=none",
        b.getInstallPath(.prefix, daemon_executable),
    });
    codesign_daemon.setName("ad-hoc sign boringterminald");
    codesign_daemon.step.dependOn(&install_daemon.step);
    // Both binaries live in one bundle. codesign may inspect sibling nested
    // code while signing the GUI path, so signing them concurrently is a
    // race: the GUI command can observe an as-yet unsigned daemon.
    codesign_exe.step.dependOn(&codesign_daemon.step);
    const codesign = b.addSystemCommand(&.{
        "/usr/bin/codesign",
        "--force",
        "--sign",
        "-",
        "--timestamp=none",
        app_path,
    });
    codesign.setName("ad-hoc sign Boring Terminal.app");
    codesign.step.dependOn(&codesign_exe.step);
    codesign.step.dependOn(&codesign_daemon.step);
    codesign.step.dependOn(&install_plist.step);
    codesign.step.dependOn(&install_icon.step);
    b.getInstallStep().dependOn(&codesign.step);

    const app_step = b.step("app", "Build the Boring Terminal.app bundle");
    app_step.dependOn(&codesign.step);

    // A terminal must inherit user color policy unchanged. Disable Zig's own
    // Run-step color environment rewriting, then clean the private variables
    // of the automation harness only at this development-launch boundary.
    const run_cmd = b.addSystemCommand(&.{b.getInstallPath(.prefix, app_executable)});
    run_cmd.color = .manual;
    if (b.graph.environ_map.get("CODEX_CI") != null) {
        run_cmd.removeEnvironmentVariable("CODEX_CI");
        run_cmd.removeEnvironmentVariable("CODEX_THREAD_ID");
        run_cmd.removeEnvironmentVariable("NO_COLOR");
    }
    run_cmd.step.dependOn(&codesign.step);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run Boring Terminal");
    run_step.dependOn(&run_cmd.step);

    // Tests are windowless. Font contract tests use CoreText/AppKit, while no
    // Metal layer or visible application is created.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("DisplayWidth", display_width);
    test_mod.addImport("Graphemes", graphemes);
    test_mod.addImport("CaselessMatch", caseless_match);
    linkMacFrameworks(test_mod);
    const test_options = b.addOptions();
    test_options.addOptionPath("daemon_path", daemon_exe.getEmittedBin());
    test_options.addOption(bool, "portable_system_goldens", portable_system_goldens);
    test_mod.addImport("test_options", test_options.createModule());
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run the vt/pty test suite");
    test_step.dependOn(&run_tests.step);

    // Dedicated source-independent Kitty keyboard corpus. This is a hermetic test
    // executable: it uses the public protocol-derived fixtures and production
    // VT/daemon codec APIs, and never launches or downloads Kitty.
    const kitty_keyboard_mod = b.createModule(.{
        .root_source_file = b.path("src/kitty_keyboard_conformance.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    kitty_keyboard_mod.addImport("DisplayWidth", display_width);
    kitty_keyboard_mod.addImport("Graphemes", graphemes);
    kitty_keyboard_mod.addImport("CaselessMatch", caseless_match);
    const kitty_keyboard_runner = b.addExecutable(.{
        .name = "kitty-keyboard-conformance",
        .root_module = kitty_keyboard_mod,
    });
    const run_kitty_keyboard = b.addRunArtifact(kitty_keyboard_runner);
    run_kitty_keyboard.setCwd(b.path("."));
    const kitty_keyboard_step = b.step(
        "kitty-keyboard-conformance",
        "Run the hermetic Kitty keyboard protocol ratchet",
    );
    kitty_keyboard_step.dependOn(&run_kitty_keyboard.step);
    test_step.dependOn(&run_kitty_keyboard.step);

    // vtdiff: byte stream in, grid text out (RFC 0008 debugging story).
    // The vt core is its own module so the tool can't reach outside it.
    const vt_mod = b.createModule(.{
        .root_source_file = b.path("src/vt.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vt_mod.addImport("DisplayWidth", display_width);
    vt_mod.addImport("Graphemes", graphemes);
    vt_mod.addImport("CaselessMatch", caseless_match);
    const vtdiff_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/vtdiff.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vtdiff_mod.addImport("vt", vt_mod);
    const vtdiff = b.addExecutable(.{ .name = "vtdiff", .root_module = vtdiff_mod });
    const vtdiff_step = b.step("vtdiff", "Build the vtdiff debug tool");
    vtdiff_step.dependOn(&b.addInstallArtifact(vtdiff, .{}).step);

    // RFC 0022's local Metal transport laboratory. Performance figures are
    // never CI thresholds because GPU and runner topology vary; exact pixel
    // equivalence for all paths is part of the ordinary test suite.
    const graphics_transport_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/graphics_transport_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const graphics_transport_probe = b.createModule(.{
        .root_source_file = b.path("src/render/graphics_transport.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    graphics_transport_mod.addImport("graphics_transport", graphics_transport_probe);
    linkMacFrameworks(graphics_transport_mod);
    const graphics_transport_bench = b.addExecutable(.{
        .name = "graphics-transport-bench",
        .root_module = graphics_transport_mod,
    });
    const run_graphics_transport_bench = b.addRunArtifact(graphics_transport_bench);
    if (b.args) |args| run_graphics_transport_bench.addArgs(args);
    const graphics_transport_step = b.step(
        "graphics-transport-bench",
        "Benchmark RFC 0022 Metal transport candidates",
    );
    graphics_transport_step.dependOn(&run_graphics_transport_bench.step);

    // esctest harness: vendored esctest2 driven against the headless vt
    // over a PTY (milestone 2a; docs/references/conformance-testing.md).
    // Root at src/ so vt and pty stay one module tree (no file/module
    // ownership collisions with the vt module used by vtdiff).
    const esctest_mod = b.createModule(.{
        .root_source_file = b.path("src/esctest_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    esctest_mod.addImport("DisplayWidth", display_width);
    esctest_mod.addImport("Graphemes", graphemes);
    esctest_mod.addImport("CaselessMatch", caseless_match);
    const esctest_host = b.addExecutable(.{ .name = "esctest-host", .root_module = esctest_mod });
    const esctest_run = b.addRunArtifact(esctest_host);
    esctest_run.setCwd(b.path("."));
    if (b.args) |args| esctest_run.addArgs(args);
    const esctest_step = b.step("esctest", "Run the esctest conformance suite against the headless vt");
    esctest_step.dependOn(&esctest_run.step);
}

fn linkMacFrameworks(mod: *std.Build.Module) void {
    linkImageFrameworks(mod);
    mod.linkFramework("AppKit", .{});
    mod.linkFramework("Metal", .{});
    mod.linkFramework("QuartzCore", .{});
    mod.linkFramework("CoreVideo", .{});
    mod.linkFramework("CoreText", .{});
    mod.linkFramework("Foundation", .{});
    mod.linkFramework("UniformTypeIdentifiers", .{});
}

fn linkImageFrameworks(mod: *std.Build.Module) void {
    // Zig 0.16 does not infer the SDK framework search path when an explicit
    // cross-architecture macOS target and --sysroot are supplied. Native
    // development builds need no override; universal release builds do.
    if (mod.owner.sysroot) |sysroot| {
        mod.addSystemFrameworkPath(.{ .cwd_relative = mod.owner.pathJoin(&.{
            sysroot,
            "System/Library/Frameworks",
        }) });
    }
    mod.linkFramework("CoreGraphics", .{});
    mod.linkFramework("CoreFoundation", .{});
    mod.linkFramework("ImageIO", .{});
}
