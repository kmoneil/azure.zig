# azure.zig

**Azure clients for Zig 0.17.1, written against the REST APIs.**
One package, `azure`, with a module per service over a shared core, and no
dependencies beyond the Zig standard library: an application compiles only
the modules it imports.

**Status: pre-release, nothing usable yet.** The modules below are planned,
and land one at a time, each with its tests, its docs, and an in-memory
fake for testing code that uses it.

## What's inside

| Module | Covers | Status |
| --- | --- | --- |
| `core` | What every module shares: an HTTP transport with a per-request time limit, retries with jittered backoff that honour the delay Azure asks for, ARM's error bodies, pages and long-running operations, and the seam through which credentials reach each service | planned |
| `auth` | Microsoft Entra ID credentials: a client secret, the Azure CLI's login, managed identity on a VM or App Service, a certificate, workload identity, and a default chain that finds whichever is there | planned |
| `storage` | Blob Storage: blobs read and written under ETag conditions, Shared Key and SAS signing, large streamed transfers, leases and append blobs; tested against Azurite and Azure | planned |
| `compute` | Virtual machines, their sizes, zones and operations, and spot VMs created and deleted | planned |
| `imds` | The Instance Metadata Service, on the VM itself: what the VM is, and Scheduled Events, the notice before a spot eviction | planned |
| `resources` | Subscriptions and resource groups | planned |
| `prices` | The Retail Prices API: VM prices by region and size, spot or on demand | planned |
| `network` | A virtual network and subnet for spot workers | planned |

Service modules import `core` alone, never `auth` or one another:
credentials reach a client through core's token-provider seam, so a
program that brings its own token needs no `auth`.

## Install

Not released yet. Once it is, a consumer pins it in `build.zig.zon` and
imports the modules it uses:

```zig
const azure = b.dependency("azure", .{});
exe.root_module.addImport("storage", azure.module("storage"));
exe.root_module.addImport("auth", azure.module("auth"));
```

## Quick start

None yet: the first module to land brings one.

## Documentation

[docs/README.md](docs/README.md) indexes the guides.
[CONTRIBUTING.md](CONTRIBUTING.md) says how to build and test, and
[SECURITY.md](SECURITY.md) how to report a vulnerability.

## License

MIT; see [LICENSE](LICENSE).
