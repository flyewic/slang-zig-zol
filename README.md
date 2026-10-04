# Slang-zig

Zig bindings for the [Slang shading language](https://shader-slang.org/) providing access to its compilation and reflection APIs.

> **Fork notice (flyewic/slang-zig-zol).** Forked from
> [raugl/slang-zig](https://github.com/raugl/slang-zig) to track **Slang
> 2026.14**. The changes are small and ABI-only:
>
> - `IGlobalSession::getDownstreamCompilerVersion`,
>   `ISession::getDeclSourceLocation` and
>   `IComponentType2::getTargetHostCallable` are new pure virtuals appended at
>   the end of their interfaces (no existing vtable slot shifts).
> - `IComponentType::linkWithOptions` now takes a `const` option array.
> - The test seed uses a fixed value (Zig 0.16 removed `std.posix.getrandom`).
> - An explicit SDK can be supplied with `-Dslang-include` / `-Dslang-lib` so a
>   consumer with Slang already installed (e.g. a distro package under `/opt`)
>   skips the lazy SDK download.
>
> The upstream ABI test (`src/abi_test.cpp`) passes against 2026.14, so the
> vtable order is verified against the real headers rather than assumed.

## Getting started

Fetch the library

```sh
zig fetch --save git+https://github.com/flyewic/slang-zig-zol
```

then use it in your `build.zig`:

```zig
const slang_dep = b.dependency("slang-zig-zol", .{
    .target = target,
    .optimize = optimize,
    // Automatically log any slang diagnostics using `std.log` when providing
    // null as the blob pointer (this is the default)
    .log_diagnostics = .only_for_null,
    // Optional: use an already-installed SDK instead of fetching one.
    .@"slang-include" = "/opt/shader-slang/include",
    .@"slang-lib" = "/opt/shader-slang/lib",
});
exe.root_module.addImport("slang", slang_dep.module("slang"));
```

> **Header collision gotcha.** The SDK's `slang.h` must be found *before* the
> system `/usr/include/slang.h` (the unrelated S-Lang interpreter). The build
> adds the SDK include directory with `-I` (not `-isystem`); a consumer that
> links this module by other means must do the same.


## Compilation API example

```zig
const slang = @import("slang");

const shortest_shader =
    \\ RWStructuredBuffer<float> result;
    \\ [shader("compute")]
    \\ [numthreads(1,1,1)]
    \\ void computeMain(uint3 threadId : SV_DispatchThreadID)
    \\ {
    \\     result[threadId.x] = threadId.x;
    \\ }
;

pub fn main() !void {
    const global_session = try slang.createGlobalSession(.{});
    defer global_session.release();

    const target_desc = slang.TargetDesc{
        .format = .spirv,
        .profile = global_session.findProfile("spirv_1_5"),
    };
    const session_desc = slang.SessionDesc{
        .targets = &.{target_desc},
        .search_paths = &.{"shaders"},
        .compiler_option_entries = &.{
            .macro_define("FOO", "1"),
            .optimization(.high),
        },
        .default_matrix_layout_mode = .row_major,
    };
    const session = try global_session.createSession(session_desc);
    defer session.release();

    const module = session.loadModuleFromSourceString("shortest", "shortest.slang", shortest_shader, null) orelse return error.ModuleLoadFailed;
    const entry_point = try module.findEntryPointByName("computeMain");
    defer entry_point.release();

    const component_types = [_]*slang.IComponentType{
        // @ptrCast is safe because `IModule` and `IEntryPointReflection` are both
        // derived from `IComponentType`, so it is always valid to upcast them
        @ptrCast(module), @ptrCast(entry_point),
    };
    const program = try session.createCompositeComponentType(&component_types, null);
    defer program.release();

    const linked_program = try program.link(null);
    defer linked_program.release();

    const reflection = linked_program.getLayout(0, null) orelse return error.ReflectionFailed;
    std.debug.assert(reflection.getEntryPointCount() == 1);
    std.debug.assert(reflection.getParameterCount() == 3);

    const spirv_code = try linked_program.getEntryPointCode(0, 0, null);
    defer spirv_code.release();
    std.debug.print("Compiled {} bytes of SPIR-V\n", .{spirv_code.getBufferSize()});
}
```

## A note on ComPtr
There is no need for it in Zig. The only place where you might want to use it as for retrieving diagnostic information through out-params, as if you tried to blindly `defer diag.release()`, you'd be calling a virtual function through an uninitialized pointer. For this reason, we provide a `.init` member for the `IBlob` class only which has a valid pointer to a noop vtable that is safe to call release on. This makes it safe to always release the blob. If you can come up with additional usecases for ComPtr that the current bindings don't support, feel free to open an issue.

```zig
pub fn main() !void {
    var diag: *slang.IBlob = .init;
    defer diag.release();

    const linked_program = program.link(&diag) catch |err| {
        std.log("[slang] Link error: {s}\n", .{diag.getBuffer()});
        std.debug.print("[slang] Link error: {s}\n", .{diag.getBuffer()});
        return err;
    };
    defer linked_program.release();
}
```

You can find more info on slang at the [official documentation](https://docs.shader-slang.org/en/latest/index.html).
