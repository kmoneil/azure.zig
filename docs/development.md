[Docs](README.md) › Development

# Development

Building, testing and measuring coverage. How changes are made is in
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Build steps

```sh
zig build test                         # unit, property and fuzz-corpus tests, zig fmt --check, lint and complexity
zig build test --seed=0x1234           # the same, with other pseudo-random inputs
zig build test -Doptimize=ReleaseFast  # the same, optimized; also ReleaseSafe
zig build test -Dmodule=core           # one module's unit tests
zig build test -Dfuzz-runner --fuzz    # coverage-guided fuzzing, LLVM backend
zig build test -Dtest-filter=fuzz      # only the tests whose names match
zig build test-unit                    # the unit tests alone, compiling nothing else
zig build test-integration             # against Azurite (no suites yet)
zig build test-integration-azure       # against Azure (no suites yet)
zig build coverage                     # line coverage; needs kcov
zig build bench-crc64                  # how fast this machine computes CRC-64/NVME
zig build fmt                          # format the Zig
zig build lint                         # zigvet: code that compiles but is wrong
zig build complexity                   # gnarl --check: complexity against complexity.baseline
```

`zig build test` runs `lint` and `complexity` and checks formatting, so a
zigvet finding, a function newly over its complexity limit, or a file
`zig fmt` would change fails it as a failing test does. `lint` and
`complexity` run programs from the PATH
([CONTRIBUTING.md](../CONTRIBUTING.md#setup) says how to install them),
and both print nothing on a clean tree. `zig build test-unit` runs the
same tests and compiles nothing else, for CI's optimized jobs.

gnarl reads `complexity.zon`, which names its classes and the gnarl
release the code is judged by, and `complexity.baseline`, which holds the
functions over a critical limit today at their numbers: for now the two in
`tools/test_runner.zig`, std's runner carried unchanged.

Every test build runs under `tools/test_runner.zig`: Zig 0.17.1's test
runner with `std.debug` waiting uncancelably. On macOS, capturing the
stack trace `std.testing.allocator` records for every allocation can
swallow a task's pending cancel, after which the task can never be
canceled; the top of that file says how, and gcp.zig's
docs/zig-std-workarounds.md where it was found.

The examples, one `zig build example-<name>` per `examples/<name>.zig`,
arrive with the first module that has one; `zig build test` will compile
every one, and every suite that runs against Azure, so none can rot
between runs.

## Coverage

`zig build coverage` runs the unit tests under
[kcov](https://github.com/SimonKagstrom/kcov) and writes the report to
`zig-out/coverage/index.html`, with `coverage.json` and `cobertura.xml`
in `kcov-merged/`. kcov counts lines, not branches, and sees only code the
compiler kept.

## Continuous integration

CI runs `zig build test` on Linux, macOS and Windows, with the zigvet and
gnarl releases `.github/actions/vet-tools` pins (gnarl's is
`complexity.zon`'s `.gnarl`), each checked against its binary's digest;
the unit tests in ReleaseSafe and ReleaseFast on Linux; and coverage, its
report attached to each run. The Azurite job joins with storage's suite,
and nightly fuzzing with the first module that has fuzz properties.

## Integration tests

Each suite skips cleanly when what it needs is not configured. Blob
Storage's suite against Azurite, the local emulator, comes with `storage`.

### Against Azure

The suites against Azure itself run with `zig build test-integration-azure`
and need a subscription and a token for Resource Manager. With the test
principal's key file (`~/.azure-keys/azzig-test.json`, as `az ad sp
create-for-rbac` writes it), `tools/azure-token.sh` mints one, passing the
secret to curl on stdin rather than on a command line:

```sh
AZURE_TEST_SUBSCRIPTION=<guid> AZURE_TEST_TOKEN=$(tools/azure-token.sh) \
    zig build test-integration-azure
```

A token lasts about an hour. Everything a run makes is a resource group
named `azzig-<suite>-<run>`, tagged `azzig-run` and `azzig-created` (Unix
seconds), and deleted as the run ends. A crashed run's groups are deleted
by the next run of any suite once they are a day old: the sweep, in
`tests/sweep.zig`.

| Suite | What it does | Costs |
| --- | --- | --- |
| prices | `PRICES_TEST=1` and no credentials: Standard_D2as_v5 spot in every region, eastus2's whole on-demand list over its pages, prices in euros, and the API's refusal of `not` | nothing; seconds, five requests |
| resources | Sweeps; lists subscriptions and the providers azure.zig uses (each must be registered); makes `azzig-resources-<run>` in `AZURE_TEST_LOCATION` (eastus2 when unset), makes it again, reads it, finds it by its tag, deletes it and waits | nothing; a minute or two |

## rest-core

`core` builds on [rest-core](https://github.com/kmoneil/rest-core.zig),
pinned in `build.zig.zon` by its content hash. To move to another
release, fetch its tag and check what Zig resolved:

```sh
zig fetch --save=rest_core "git+https://github.com/kmoneil/rest-core.zig#v0.2.0"
git ls-remote https://github.com/kmoneil/rest-core.zig 'refs/tags/v0.2.0^{}'
```

The fetch must say `resolved ref "v0.2.0"`, and the commit it names must
be the one `ls-remote` prints. The tag goes after `#`: given as `?ref=`,
`zig fetch` takes the default branch instead and saves a URL that looks
right. Zig unpacks fetched packages into `zig-pkg/`, which git ignores.

`src/core/rest_core_test.zig` holds what azure.zig relies on rest-core
for, so a release that breaks one fails `zig build test` on the bump.
What rest-core lacks for Azure goes on its board, or its issues once it
takes them.

## Where the code came from

Some of this library is carried from
[gcp.zig](https://github.com/kmoneil/gcp.zig). Each file that came from
there starts with a line naming the gcp.zig file and commit, so a fix made
in either can be carried to the other.

| File here | From gcp.zig | At |
| --- | --- | --- |
| tools/test_runner.zig | tools/test_runner.zig | eae944c |
