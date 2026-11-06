# Changelog

Until 1.0, minor versions may break the API; each entry says how.

## 0.1.0 (unreleased)

- The repository: the build, gcp.zig's test runner, and an empty `core`
  module.
- `zig build test` runs the unit tests, `zig fmt --check`, zigvet, and
  gnarl (0.7.0, named in `complexity.zon`): a zigvet finding, or a
  function newly over its complexity limit or worse than
  `complexity.baseline`, fails it.
- `core` builds on rest-core v0.2.0 (21dace6), pinned by hash; 0.2.0 came
  from azure.zig's trial of 0.1.0 and brings HEAD, a success's status and
  headers through `execute`, and ARM's correlation id, which ARM's hook now
  keeps in `Diagnostics` beside the request id, both logged escaped at
  debug level. Its transport, request
  loop, token seam, RSA signing and fakes. `core.arm` is Resource
  Manager's side of the loop: ARM's error body read into `Diagnostics`
  with the provider's request id, Azure's retried set (408, 429, 500, 502,
  503, 504), an unregistered provider as an error of its own, next pages
  and operation URLs followed only on ARM's origin, and operation states.
- `core.Cloud`: the public, China and US Government clouds, each with its
  authority host, ARM endpoint and scope, and storage suffix.
- `core.arm.retry_policy` (four attempts, from 800 ms, a server's delay
  honoured up to a minute), `engine_headers`, and `clientRequestId`, a
  version 4 UUID for one call's every attempt.
- `core.operation`: long-running ARM writes begun, polled, waited on with
  a time limit, and read, through `Azure-AsyncOperation`,
  `Operation-Location`, `Location` or the resource's `provisioningState`,
  each poll waiting what the last answer asked. A failed operation is an
  answer, with the error its body carried.
- `core.testing`: rest-core's fakes, ARM's error bodies and refusals, and a
  long-running operation scripted as ARM answers one.
- `core.origin.pathOnOrigin`: a link a server gives is followed when it
  names the client's origin as origins compare, the default port written
  out or not and the host in any case; ARM's next pages and operation URLs
  use it.
- `core.crc64`: CRC-64/NVME, Blob Storage's `x-ms-content-crc64`: a
  carry-less fold of four lanes where the CPU multiplies without carries
  (PCLMULQDQ with AVX, PMULL), eight tables elsewhere; `Hasher`, `combine`
  for parts hashed apart, and the header's base64 both ways, refusing any
  but the canonical twelve characters. 13 GiB/s on an Apple M5 in
  ReleaseFast (std's one table, 533 MiB/s); `zig build bench-crc64`.
- `resources`: subscriptions listed; resource groups made (201, or 200 with
  the spec's tags), read, listed by tag through ARM's OData filter, and
  deleted as a long-running operation, with `force_vms`; providers read
  and registered on request, never on their own. Names are checked before
  sending. `resources.testing.FakeResources` is Resource Manager in memory
  for these calls. Not yet run against Azure.
- `prices`: Linux VM prices from the Retail Prices API, spot or on demand,
  by region and size, every page read through the API's `:443` links; the
  Windows, Dev/Test, reservation, Low Priority and Cloud Services rows left
  out by the filter and again row by row. `Amount` holds a price exactly,
  from the number's digits. `prices.testing.FakePrices` is the API in
  memory. Run against the API: 66 regions for Standard_D2as_v5 spot, 1743
  on-demand sizes in eastus2 over two pages.
