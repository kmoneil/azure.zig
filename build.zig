const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests whose names do not match any filter",
    ) orelse &.{};

    // rest-core (github.com/kmoneil/rest-core.zig): the transport, the
    // request loop and the rest of a REST client that no cloud owns.
    const rest_core = b.dependency("rest_core", .{ .target = target, .optimize = optimize }).module("rest_core");

    // What the service modules share: rest-core, and Azure's side of its
    // request loop.
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "rest_core", .module = rest_core }},
    });

    // Credentials for every module, through core's TokenProvider seam.
    const auth = b.addModule("auth", .{
        .root_source_file = b.path("src/auth/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Virtual machines: their state, sizes, zones and quotas.
    const compute = b.addModule("compute", .{
        .root_source_file = b.path("src/compute/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // The service modules, each at src/<name>/root.zig, as each lands:
    // imds to come. Each imports core alone, never
    // auth or another service: credentials reach a service through core's
    // TokenProvider seam.

    // Resource Manager's basics: subscriptions, resource groups, providers.
    const resources = b.addModule("resources", .{
        .root_source_file = b.path("src/resources/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Virtual networks, subnets and network security groups.
    const network = b.addModule("network", .{
        .root_source_file = b.path("src/network/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // VM prices from the Retail Prices API, which needs no credentials.
    const prices = b.addModule("prices", .{
        .root_source_file = b.path("src/prices/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Blob Storage: containers and blobs, with conditions, Shared Key or a
    // token, and a fake.
    const storage = b.addModule("storage", .{
        .root_source_file = b.path("src/storage/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Every test build runs under std's test runner with one fix, which
    // keeps std.debug from swallowing a task's cancel (see the top of
    // tools/test_runner.zig).
    const test_runner: std.Build.Step.Compile.TestRunner = .{ .path = b.path("tools/test_runner.zig"), .mode = .server };

    // Unit, property and fuzz-corpus tests, one run per module. No network: a
    // fake transport and a fake clock drive everything. `zig build fuzz`
    // (below) builds the fuzz properties alone, for the fuzzer.
    const unit_modules = [_]UnitModule{
        .{ "core", core },
        .{ "auth", auth },
        .{ "resources", resources },
        .{ "network", network },
        .{ "prices", prices },
        .{ "storage", storage },
        .{ "compute", compute },
    };
    // One module's tests alone, for a fuzzing job that gives one module the
    // whole time budget.
    const only_module = b.option([]const u8, "module", "Run only this module's unit tests: core, auth, resources, network, prices, storage or compute");
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
        });
        unit_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    // The fuzz properties alone, one binary per module: `zig build fuzz`
    // replays each one's corpus and seeded inputs, and `zig build fuzz
    // --fuzz` (or `--fuzz=N`) runs them under the coverage-guided fuzzer.
    // `-Dfuzz-filter` takes only the properties whose names hold it, and
    // `-Dmodule` one module's. use_llvm: only the LLVM backend emits the
    // fuzzer's instrumentation; the self-hosted backend, x86_64 Linux's
    // Debug default, emits none, and the fuzzer would run blind.
    const fuzz_step = b.step("fuzz", "Replay the fuzz properties' inputs (--fuzz or --fuzz=N to fuzz them; -Dfuzz-filter, -Dmodule)");
    const fuzz_filter = b.option([]const u8, "fuzz-filter", "zig build fuzz: only the fuzz properties whose names hold this") orelse "fuzz ";
    for (unit_modules) |entry| {
        if (only_module) |name| if (!std.mem.eql(u8, entry[0], name)) continue;
        const fuzz_tests = b.addTest(.{
            .name = b.fmt("fuzz-{s}", .{entry[0]}),
            .root_module = entry[1],
            .filters = &.{fuzz_filter},
            .test_runner = test_runner,
            .use_llvm = true,
        });
        fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);
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
    const integration_step = b.step(
        "test-integration",
        "Run the integration suites against Azurite: AZURITE_TEST=1, Azurite on 127.0.0.1:10000 or AZURITE_BLOB_URL",
    );
    // Blob Storage's calls against Azurite, which checks every signature.
    const storage_azurite_tests = b.addTest(.{
        .name = "storage-azurite-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage_azurite_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "storage", .module = storage }},
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    integration_step.dependOn(&streamed(b, storage_azurite_tests).step);
    test_step.dependOn(&storage_azurite_tests.step);
    // And against Azure itself, with credentials CI does not have, so a step
    // of its own, never part of `test-integration`. `zig build test`
    // compiles these suites, as it will the examples, so none can rot
    // between runs. docs/development.md says what each needs.
    const azure_step = b.step(
        "test-integration-azure",
        "Run the suites against Azure: AZURE_TEST_SUBSCRIPTION and AZURE_TEST_TOKEN; AZURE_TEST_STORAGE_ACCOUNT with AZURE_TEST_STORAGE_KEY or _TOKEN; AZURE_TEST_COMPUTE_VMS=1 for spot VMs; PRICES_TEST=1; each skips without its variables",
    );
    // Resource groups made, read, listed by tag and deleted, and the sweep
    // of what crashed runs left.
    const resources_azure_tests = b.addTest(.{
        .name = "resources-azure-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/resources_azure_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "resources", .module = resources },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    azure_step.dependOn(&streamed(b, resources_azure_tests).step);
    test_step.dependOn(&resources_azure_tests.step);
    // A security group, a virtual network and its subnets made, read,
    // refused and deleted, in a group of their own.
    const network_azure_tests = b.addTest(.{
        .name = "network-azure-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/network_azure_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "network", .module = network },
                .{ .name = "resources", .module = resources },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    azure_step.dependOn(&streamed(b, network_azure_tests).step);
    test_step.dependOn(&network_azure_tests.step);
    // The Retail Prices API, which needs no credentials: PRICES_TEST=1.
    const prices_azure_tests = b.addTest(.{
        .name = "prices-azure-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/prices_azure_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "prices", .module = prices }},
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    azure_step.dependOn(&streamed(b, prices_azure_tests).step);
    test_step.dependOn(&prices_azure_tests.step);
    // Entra ID itself: the test principal's secret, and the CLI's login.
    const auth_azure_tests = b.addTest(.{
        .name = "auth-azure-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/auth_azure_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "auth", .module = auth },
                .{ .name = "resources", .module = resources },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    azure_step.dependOn(&streamed(b, auth_azure_tests).step);
    test_step.dependOn(&auth_azure_tests.step);
    // Compute's reads: sizes, zones, quotas and VMs; nothing made.
    const compute_azure_tests = b.addTest(.{
        .name = "compute-azure-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compute_azure_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "compute", .module = compute },
                .{ .name = "network", .module = network },
                .{ .name = "resources", .module = resources },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    azure_step.dependOn(&streamed(b, compute_azure_tests).step);
    test_step.dependOn(&compute_azure_tests.step);
    // Blob Storage in the test account, with Shared Key and with a token.
    const storage_azure_tests = b.addTest(.{
        .name = "storage-azure-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage_azure_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "storage", .module = storage }},
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    azure_step.dependOn(&streamed(b, storage_azure_tests).step);
    test_step.dependOn(&storage_azure_tests.step);

    // The code the guides show, run beside the unit tests so it cannot
    // drift; tools/check_docs.py holds the guides to this file and to the
    // examples.
    const docs_tests = b.addTest(.{
        .name = "docs-examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/docs_examples.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "resources", .module = resources },
                .{ .name = "network", .module = network },
                .{ .name = "prices", .module = prices },
                .{ .name = "storage", .module = storage },
                .{ .name = "auth", .module = auth },
                .{ .name = "compute", .module = compute },
            },
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    if (only_module == null) unit_step.dependOn(&b.addRunArtifact(docs_tests).step);

    // One `example-<name>` step per examples/<name>.zig, each importing the
    // modules it shows; `zig build test` compiles them all, so none rots.
    const examples = [_]struct { []const u8, []const std.Build.Module.Import }{
        .{ "prices_spot", &.{.{ .name = "prices", .module = prices }} },
        .{ "resources_subscriptions", &.{.{ .name = "resources", .module = resources }} },
        .{ "network_workers", &.{.{ .name = "network", .module = network }} },
        .{ "blob_cp", &.{.{ .name = "storage", .module = storage }} },
        .{ "auth_subscriptions", &.{ .{ .name = "auth", .module = auth }, .{ .name = "resources", .module = resources } } },
        .{ "compute_sizes", &.{ .{ .name = "auth", .module = auth }, .{ .name = "compute", .module = compute } } },
        .{ "spot_vm", &.{ .{ .name = "auth", .module = auth }, .{ .name = "compute", .module = compute } } },
    };
    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example[0]})),
                .target = target,
                .optimize = optimize,
                .imports = example[1],
            }),
        });
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step(b.fmt("example-{s}", .{example[0]}), b.fmt("Run examples/{s}.zig", .{example[0]})).dependOn(&run.step);
        test_step.dependOn(&exe.step);
    }

    // How fast this build computes a CRC-64/NVME, always in ReleaseFast: the
    // numbers are about the code the CPU runs, not a debug build's.
    const bench_crc64 = b.addExecutable(.{
        .name = "bench-crc64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench_crc64.zig"),
            .target = target,
            .optimize = .fast,
            .imports = &.{.{ .name = "core", .module = b.createModule(.{
                .root_source_file = b.path("src/core/root.zig"),
                .target = target,
                .optimize = .fast,
                .imports = &.{.{ .name = "rest_core", .module = b.dependency("rest_core", .{ .target = target, .optimize = .fast }).module("rest_core") }},
            }) }},
        }),
    });
    b.step("bench-crc64", "Measure CRC-64/NVME throughput, in ReleaseFast").dependOn(&b.addRunArtifact(bench_crc64).step);
    test_step.dependOn(&bench_crc64.step);

    // zigvet (github.com/kmoneil/zigvet) reports code the compiler accepts
    // that is almost certainly wrong, such as a pointer to stack memory that
    // leaves its function. A program on the PATH, not a package. Quiet on a
    // clean tree, and run every time: a command whose output is not captured
    // has side effects, so the build never caches it.
    const lint = b.addSystemCommand(&.{ "zigvet", "build.zig", "src", "tests", "examples", "tools" });
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

    const fmt_paths = b.pathList(&.{ "build.zig", "build.zig.zon", "complexity.zon", "src", "tests", "examples", "tools" });
    test_step.dependOn(&b.addFmt(.{ .paths = fmt_paths, .check = true }).step);
    b.step("fmt", "Format the Zig in build.zig, complexity.zon, src/ and tools/").dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);
}

/// Runs a suite as a plain program instead of through the build runner's
/// test protocol, which prints nothing until the suite ends: run this way,
/// the test runner prints each test's name as it starts, so a suite that
/// hangs leaves a log saying which test it was. Its output goes straight
/// through, and such a step always runs, since its result depends on a
/// server, never the cache. (gcp.zig's, at eae944c.)
fn streamed(b: *std.Build, tests: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, b.fmt("run {s}", .{tests.name}));
    run.addArtifactArg2(tests, .{});
    run.stdio = .inherit;
    return run;
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
