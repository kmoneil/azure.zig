[Docs](README.md) › Development

# Development

Building, testing and measuring coverage. How changes are made is in
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Build steps

```sh
zig build test                         # unit, property and fuzz-corpus tests, zig fmt --check, lint and complexity
zig build test --seed=0x1234           # the same, with other pseudo-random inputs
zig build test -Doptimize=ReleaseFast  # the same, optimized; also ReleaseSafe
zig build test -Dmodule=storage        # one module's unit tests: core, auth, resources, network, prices or storage
zig build test -Dfuzz-runner --fuzz    # coverage-guided fuzzing, LLVM backend
zig build test -Dtest-filter=fuzz      # only the tests whose names match
zig build test-unit                    # the unit tests alone, compiling nothing else
zig build test-integration             # against Azurite: storage (below)
zig build test-integration-azure       # against Azure: auth, prices, resources, network, storage (below)
zig build coverage                     # line coverage; needs kcov
zig build bench-crc64                  # how fast this machine computes CRC-64/NVME
zig build example-prices_spot          # an example, one step per examples/<name>.zig
python3 -I tools/check_docs.py         # the docs' links, anchors and snippets
zig build fmt                          # format the Zig
zig build lint                         # zigvet: code that compiles but is wrong
zig build complexity                   # gnarl --check: complexity against complexity.baseline
```

A code block a guide shows follows `<!-- snippet: examples/<name>.zig -->`
or `<!-- snippet: tests/docs_examples.zig#<name> -->`, and
`tools/check_docs.py` (gcp.zig's, carried unchanged) holds it to that
file, which `zig build test` compiles and, for tests/docs_examples.zig,
runs: change the code and the guide together. It also checks every
relative link and anchor, and that every page is linked from another.

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
report attached to each run; and storage's suite against Azurite, the
`azurite` job, its image pinned by digest. Nightly fuzzing joins with the
first module that has fuzz properties.

## Integration tests

Each suite skips cleanly when what it needs is not configured.

### Against Azurite

`zig build test-integration` runs storage's suite against Azurite,
Blob Storage's emulator, which checks every Shared Key signature, when
`AZURITE_TEST=1`; `AZURITE_BLOB_URL` names another endpoint than
`http://127.0.0.1:10000`. Azurite runs from npm, in memory:

```sh
npx azurite@3.37.0 --silent --inMemoryPersistence --blobHost 127.0.0.1 &
AZURITE_TEST=1 zig build test-integration
```

It runs `tests/storage_scenario.zig`, as the live suite does (below),
where Azurite answers otherwise than production: a conditional read of a
blob not there is 412, not 404, and a range from a blob's end reads no
bytes rather than 416.

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
| auth | `AZURE_TEST_KEY_FILE` (the test principal's key file): tokens for Resource Manager and Storage from one `ClientSecret`, the subscriptions it sees, and a wrong secret's refusal; `AZURE_TEST_CLI=1`: the Azure CLI's login through the real `az`, its subscriptions, and an unknown resource's refusal | nothing; seconds |
| prices | `PRICES_TEST=1` and no credentials: Standard_D2as_v5 spot in every region, eastus2's whole on-demand list over its pages, prices in euros, and the API's refusal of `not` | nothing; seconds, five requests |
| resources | Sweeps; lists subscriptions and the providers azure.zig uses (each must be registered); makes `azzig-resources-<run>` in `AZURE_TEST_LOCATION` (eastus2 when unset), makes it again, reads it, finds it by its tag, deletes it and waits | nothing; a minute or two |
| network | Sweeps; in `azzig-network-<run>`, a security group, a network with a private subnet behind it (Storage endpoint), the network made again, a subnet on its own; then what Network refuses (overlap, outside the range, a group in use, a reference not there, another location, no network) and what a delete of nothing answers, each printed as a `fact:`; then every delete | nothing; a few minutes |
| storage | `AZURE_TEST_STORAGE_ACCOUNT`, and `AZURE_TEST_STORAGE_KEY` (Shared Key) or `AZURE_TEST_STORAGE_TOKEN` (a token for `https://storage.azure.com/.default`), each run once: in the kept container `azzig-test`, blobs under the run's prefix written, read whole and in part, held to conditions, listed over pages and deleted, and a container `azzig-test-<run>` made and deleted; blobs there a day old are deleted first | under a cent; seconds |

The storage suite's key is the test account's (kb/azure-resources),
from ARM's `listKeys`, which the test principal may call; pass it in the
environment and never print it. Its token is the principal's, which has
Storage Blob Data Contributor there:

```sh
AZURE_TEST_STORAGE_ACCOUNT=<account> AZURE_TEST_STORAGE_KEY=<key> \
AZURE_TEST_STORAGE_TOKEN=$(AZURE_SCOPE=https://storage.azure.com/.default tools/azure-token.sh) \
    zig build test-integration-azure -Dtest-filter=storage
```

## rest-core

`core` builds on [rest-core](https://github.com/kmoneil/rest-core.zig),
pinned in `build.zig.zon` by its content hash. To move to another
release, fetch its tag and check what Zig resolved:

```sh
zig fetch --save=rest_core "git+https://github.com/kmoneil/rest-core.zig#v0.4.0"
git ls-remote https://github.com/kmoneil/rest-core.zig 'refs/tags/v0.4.0^{}'
```

The fetch must say `resolved ref "v0.4.0"`, and the commit it names must
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
| tools/check_docs.py | tools/check_docs.py | eae944c |
| src/storage/xml.zig | src/storage/xml.zig (changed: a byte order mark skipped, attributes kept) | eae944c |
| src/auth/form.zig | src/auth/form.zig | 323aa61 |
| src/auth/Cache.zig | src/auth/Cache.zig (after it: a token per scope, azcore's refresh times) | 323aa61 |
