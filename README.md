# azure.zig

[![CI](https://github.com/kmoneil/azure.zig/actions/workflows/ci.yml/badge.svg?branch=main&event=push)](https://github.com/kmoneil/azure.zig/actions/workflows/ci.yml)
[![Zig 0.17.1](https://img.shields.io/badge/zig-0.17.1-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/download/)
[![License: MIT](https://img.shields.io/badge/license-MIT-0078D4)](LICENSE)

**Azure clients for Zig 0.17.1, written against the REST APIs.**
One package, `azure`, with a module per service over a shared core: an
application compiles only the modules it imports. Its one dependency is
[rest-core](https://github.com/kmoneil/rest-core.zig), the cloud-neutral
half of a REST client, which itself needs nothing beyond the Zig standard
library.

**Status: pre-release, nothing usable yet.** The modules below are planned,
and land one at a time, each with its tests, its docs, and an in-memory
fake for testing code that uses it.

## What's inside

| Module | Covers | Status |
| --- | --- | --- |
| `core` | What every module shares: rest-core's HTTP transport with a per-request time limit, retries with jittered backoff that honour the delay Azure asks for, and the seam through which credentials reach each service; and Azure's own side of it, ARM's error bodies, retried set, pages and long-running operations | planned |
| `auth` | Microsoft Entra ID credentials: a client secret, the Azure CLI's login, managed identity on a VM or App Service, a certificate, workload identity, and a default chain that finds whichever is there | planned |
| `storage` | Blob Storage: blobs read and written under ETag conditions, Shared Key and SAS signing, large streamed transfers, leases and append blobs; tested against Azurite and Azure | planned |
| `compute` | Virtual machines, their sizes, zones and operations, and spot VMs created and deleted | planned |
| `imds` | The Instance Metadata Service, on the VM itself: what the VM is, and Scheduled Events, the notice before a spot eviction | planned |
| [`resources`](docs/resources/README.md) | Subscriptions; resource groups made, read, listed by tag and deleted; providers' registration; an in-memory Resource Manager for your own tests | in progress |
| [`prices`](docs/prices/README.md) | The Retail Prices API: Linux VM prices by region and size, spot or on demand, every amount exact; an in-memory Retail Prices API for your own tests | in progress |
| [`network`](docs/network/README.md) | Virtual networks, their subnets (private by default, with service endpoints) and network security groups, made, read and deleted; an in-memory Microsoft.Network for your own tests | in progress |

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
