const std = @import("std");

const LogDiagnostics = enum {
    always,
    only_for_null,
    never,
};

/// Paths to the Slang SDK the module was wired against, exposed to consumers
/// (e.g. to install the runtime shared libraries beside an executable).
pub const SdkPaths = struct {
    include: std.Build.LazyPath,
    lib: std.Build.LazyPath,
    runtime: std.Build.LazyPath,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("slang", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .link_libcpp = true,
    });

    // Options
    const log_diagnostics = b.option(
        LogDiagnostics,
        "log_diagnostics",
        "Should the per function slang diagnostic text be automatically logged using std.log (default: only_for_null)",
    ) orelse .only_for_null;

    const options = b.addOptions();
    options.addOption(LogDiagnostics, "log_diagnostics", log_diagnostics);
    mod.addOptions("options", options);

    // An explicit SDK may be supplied by a consumer that already has Slang
    // installed (e.g. distro package under /opt), avoiding a lazy download.
    const sdk_include = b.option(
        []const u8,
        "slang-include",
        "Path to a Slang SDK include/ directory (skips fetching the SDK)",
    );
    const sdk_lib = b.option(
        []const u8,
        "slang-lib",
        "Path to a Slang SDK lib/ directory (skips fetching the SDK)",
    );

    // Dependencies
    if (sdk_include != null and sdk_lib != null) {
        // `addIncludePath` emits `-I`; `addSystemIncludePath` emits `-isystem`,
        // which loses to the system S-Lang `/usr/include/slang.h` and silently
        // compiles against the wrong header. Keep `-I`.
        mod.addIncludePath(.{ .cwd_relative = sdk_include.? });
        mod.addLibraryPath(.{ .cwd_relative = sdk_lib.? });
        mod.linkSystemLibrary("slang", .{});
    } else {
        const slang_dep_name = b.fmt("slang-{s}-{s}", .{
            @tagName(target.result.os.tag),
            @tagName(target.result.cpu.arch),
        });
        if (b.lazyDependency(slang_dep_name, .{})) |slang| {
            mod.addIncludePath(slang.path("include"));
            mod.addLibraryPath(slang.path("lib"));
            mod.linkSystemLibrary("slang", .{});
        }
    }

    // Tests
    // `use_llvm` works around the Zig 0.16 self-hosted-linker `.sframe`
    // relocation bug on Arch/CachyOS glibc (`crt1.o` R_X86_64_PC64).
    const unit_tests = b.addTest(.{ .root_module = mod, .use_llvm = true });
    unit_tests.root_module.addCSourceFile(.{
        .file = b.path("src/abi_test.cpp"),
        .flags = &.{ "-std=c++17", "-I", "/opt/shader-slang/include" },
    });

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
