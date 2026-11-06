const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests whose names do not match any filter",
    ) orelse &.{};

    // What the service modules share. It imports nothing but std.
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The service modules join here as each lands: auth, storage, compute,
    // imds, resources, prices and network, each at src/<name>/root.zig.
    // Each imports core alone, never auth or another service: credentials
    // reach a service through core's TokenProvider seam.

    // Every test build runs under std's test runner with one fix, which
    // keeps std.debug from swallowing a task's cancel (see the top of
    // tools/test_runner.zig).
    const test_runner: std.Build.Step.Compile.TestRunner = .{ .path = b.path("tools/test_runner.zig"), .mode = .server };

    // Fuzzing needs the LLVM backend. The self-hosted x86_64 backend, the
    // Debug default there, emits no coverage instrumentation, so the fuzzer
    // would run blind.
    const fuzz_runner = b.option(
        bool,
        "fuzz-runner",
        "Build the unit tests for `zig build test --fuzz`: LLVM backend",
    ) orelse false;

    // Unit, property and fuzz-corpus tests, one run per module. No network: a
    // fake transport and a fake clock drive everything.
    // `zig build test -Dfuzz-runner --fuzz` fuzzes the same tests.
    const unit_modules = [_]UnitModule{
        .{ "core", core },
    };
    // One module's tests alone, for a fuzzing job that gives one module the
    // whole time budget.
    const only_module = b.option([]const u8, "module", "Run only this module's unit tests: core");
    if (only_module) |name| checkModule(&unit_modules, name);

    const test_step = b.step("test", "Run unit, property and fuzz-corpus tests, zig fmt --check, zigvet and gnarl");
    // The same tests without what `test` compiles and checks beside them,
    // for CI's optimized jobs.
    const unit_step = b.step("test-unit", "Run unit, property and fuzz-corpus tests, compiling nothing else");
    test_step.dependOn(unit_step);
    for (unit_modules) |entry| {
        if (only_module) |name| if (!std.mem.eql(u8, entry[0], name)) continue;
        const unit_tests = b.addTest(.{
            .name = entry[0],
            .root_module = entry[1],
            .filters = test_filters,
            .test_runner = test_runner,
            .use_llvm = if (fuzz_runner) true else null,
        });
        unit_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    // Line coverage of the unit tests, measured by kcov, which must be on
    // PATH. Each module's tests run under kcov, and the merged report is
    // installed to zig-out/coverage: index.html, plus coverage.json and
    // cobertura.xml in kcov-merged/.
    const coverage_step = b.step("coverage", "Measure the unit tests' line coverage with kcov");
    const merge = b.addSystemCommand(&.{ "kcov", "--merge" });
    const merged = merge.addOutputDirectoryArg2("coverage", .{});
    for (unit_modules) |entry| {
        const coverage_tests = b.addTest(.{
            .name = entry[0],
            .root_module = entry[1],
            .filters = test_filters,
            .test_runner = test_runner,
            // kcov maps addresses to lines through DWARF, which LLVM emits in full.
            .use_llvm = true,
        });
        const kcov = b.addSystemCommand(&.{"kcov"});
        kcov.addDirectoryArg2(b.path("src"), .{ .prefix = "--include-path=", .make_absolute = true });
        merge.addDirectoryArg2(kcov.addOutputDirectoryArg2(entry[0], .{}), .{});
        kcov.addArtifactArg2(coverage_tests, .{});
        // The tests' progress output is captured: the build shows it only
        // when they fail, which kcov reports by exiting as they did.
        _ = kcov.captureStdErr(.{});
    }
    coverage_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = merged,
        .install_dir = .prefix,
        .install_subdir = "coverage",
    }).step);

    // Integration suites, each under tests/ and each skipping cleanly when
    // what it needs is not configured. Against Azurite, the local Blob
    // emulator, which CI can run:
    _ = b.step(
        "test-integration",
        "Run the integration suites against Azurite (none yet)",
    );
    // And against Azure itself, with credentials CI does not have, so a step
    // of its own, never part of `test-integration`. `zig build test` will
    // compile these suites, as it does the examples, so none can rot
    // between runs.
    _ = b.step(
        "test-integration-azure",
        "Run the integration suites against Azure; each skips without its variables (none yet)",
    );

    // Examples, one `example-<name>` step per examples/<name>.zig, join with
    // the first module that has one; `zig build test` compiles them all.

    // zigvet (github.com/kmoneil/zigvet) reports code the compiler accepts
    // that is almost certainly wrong, such as a pointer to stack memory that
    // leaves its function. A program on the PATH, not a package. Quiet on a
    // clean tree, and run every time: a command whose output is not captured
    // has side effects, so the build never caches it. tests/ and examples/
    // join the list when they exist.
    const lint = b.addSystemCommand(&.{ "zigvet", "build.zig", "src", "tools" });
    lint.setCwd(b.path("."));
    b.step("lint", "Report code that compiles but is wrong (zigvet, from the PATH; test runs it too)").dependOn(&lint.step);
    test_step.dependOn(&lint.step);

    // gnarl (github.com/kmoneil/gnarl), also on the PATH, holds each function
    // to the complexity limits of its class in complexity.zon, which also
    // names the gnarl release the code is judged by: another release refuses
    // to judge it. complexity.baseline holds what is over a limit today, so
    // `--check` fails only what is new or worse. A pass prints nothing; a
    // failure names the `gnarl --explain` to run. `.` from the repository's
    // root, where gnarl finds both files. Run every time: what gnarl reads is
    // not among the step's inputs, so a cached pass would let a regression
    // through.
    const complexity = b.addSystemCommand(&.{ "gnarl", "--check", "." });
    complexity.setCwd(b.path("."));
    complexity.has_side_effects = true;
    b.step("complexity", "Fail a function newly over its complexity limit, or worse than complexity.baseline (gnarl, from the PATH; test runs it too)").dependOn(&complexity.step);
    test_step.dependOn(&complexity.step);

    const fmt_paths = b.pathList(&.{ "build.zig", "build.zig.zon", "complexity.zon", "src", "tools" });
    test_step.dependOn(&b.addFmt(.{ .paths = fmt_paths, .check = true }).step);
    b.step("fmt", "Format the Zig in build.zig, complexity.zon, src/ and tools/").dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);
}

/// A module's name, as `-Dmodule` takes it, and the module.
const UnitModule = struct { []const u8, *std.Build.Module };

/// Ends the build, naming every module there is, when `name` is none of them.
fn checkModule(modules: []const UnitModule, name: []const u8) void {
    for (modules) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return;
    }
    std.debug.print("error: -Dmodule={s} names no module; use one of:", .{name});
    for (modules) |entry| std.debug.print(" {s}", .{entry[0]});
    std.debug.print("\n", .{});
    std.process.exit(1);
}
