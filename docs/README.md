[azure.zig](../README.md) › Docs

# azure.zig documentation

Start with [Essentials](essentials.md), which every module shares; then
the guide for the service at hand, each added with its module.

| Guide | What's in it |
| --- | --- |
| [Essentials](essentials.md) | What every module shares: clients, endpoints and clouds, results and memory, errors, retries, logging, and testing |
| [Development](development.md) | Build steps, testing, coverage, and where carried code came from |

## Credentials

| Guide | What's in it |
| --- | --- |
| [Auth](auth/README.md) | A client secret and the Azure CLI's login as token providers, cached per scope, Entra's refusals in Diagnostics, and FakeEntra |

## Resource Manager

| Guide | What's in it |
| --- | --- |
| [Resources](resources/README.md) | Subscriptions, resource groups made, read, listed by tag and deleted, providers' registration, and FakeResources |
| [Network](network/README.md) | Virtual networks and their subnets, private by default, with service endpoints; network security groups and their rules; every write long-running; FakeNetwork |

## Storage

| Guide | What's in it |
| --- | --- |
| [Storage](storage/README.md) | Blob Storage: containers, blobs written, read whole or in part, listed and deleted under ETag conditions, Shared Key or a token, and FakeBlob |

## Prices

| Guide | What's in it |
| --- | --- |
| [Prices](prices/README.md) | Linux VM prices, spot or on demand, by region and size; which of the API's rows count; exact amounts; FakePrices |
