# Changelog

Until 1.0, minor versions may break the API; each entry says how.

## 0.1.0 (unreleased)

- The repository: the build, gcp.zig's test runner, and an empty `core`
  module.
- `zig build test` runs the unit tests, `zig fmt --check`, zigvet, and
  gnarl (0.7.0, named in `complexity.zon`): a zigvet finding, or a
  function newly over its complexity limit or worse than
  `complexity.baseline`, fails it.
- `core` builds on rest-core v0.4.0 (90b1169), pinned by hash; 0.2.0 came
  from azure.zig's trial of 0.1.0 and brings HEAD, a success's status and
  headers through `execute`, and ARM's correlation id, which ARM's hook now
  keeps in `Diagnostics` beside the request id, both logged escaped at
  debug level; 0.3.0 and 0.4.0 are the fixes from an audit of all of
  rest-core, a cloud's hook checked when the engine binds it among them.
  Its transport, request
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
- A link a server gives (ARM's next pages and operation URLs, the Retail
  Prices API's next pages) is followed when it names the client's origin
  as origins compare, the default port written out or not and the host in
  any case: rest-core 0.2.1's `loop.pathOnOrigin`, fixed for the prices
  API's `:443` links that azure.zig found.
- `core.crc64`: CRC-64/NVME, Blob Storage's `x-ms-content-crc64`: a
  carry-less fold of four lanes where the CPU multiplies without carries
  (PCLMULQDQ with AVX, PMULL), eight tables elsewhere; `Hasher`, `combine`
  for parts hashed apart, and the header's base64 both ways, refusing any
  but the canonical twelve characters. 13 GiB/s on an Apple M5 in
  ReleaseFast (std's one table, 533 MiB/s); `zig build bench-crc64`.
- The guides' code is code: each first program is an example
  (`zig build example-prices_spot`, `example-resources_subscriptions`),
  the snippets on testing with the fakes run in `tests/docs_examples.zig`,
  and `tools/check_docs.py` (gcp.zig's) holds every marked block to its
  source, beside the links and anchors; CI runs it.
- `resources`: subscriptions listed; resource groups made (201, or 200 with
  the spec's tags), read, listed by tag through ARM's OData filter, and
  deleted as a long-running operation, with `force_vms`; providers read
  and registered on request, never on their own. Names are checked before
  sending. `resources.testing.FakeResources` is Resource Manager in memory
  for these calls. Run against Azure on 2026-11-07, answering as the fake
  does.
- `core.names`: ARM's naming rules (subscription ids, resource group names,
  locations, tags), and `core.arm.Tag`, shared by every module that writes
  to ARM; `resources` keeps its own names for them. `core.isRetryable`:
  which transport failures are worth another attempt.
- `network`: virtual networks with their subnets, subnets alone, and
  network security groups with their rules, on Microsoft.Network at
  2026-03-01, each create and delete a long-running operation. A network's
  PUT always carries its subnets; a subnet's always carries
  `defaultOutboundAccess`, false unless asked, and takes service endpoints
  and a security group or NAT gateway by ARM id (`network.ids`). A rule
  sends one address or port singular and more plural. Names, CIDRs and
  priorities are checked before sending. `network.testing.FakeNetwork`
  refuses what Network refuses, with its codes and statuses. Run against
  Azure on 2026-11-07; the first run corrected two of the fake's answers.
- `auth`: `ClientSecret`, an app's sign-in at Entra ID's v2 token endpoint
  with a client secret, and `AzureCli`, the Azure CLI's login (`az account
  get-access-token`, 10 s, az 2.54.0 or later), each a `TokenProvider`
  whose tokens are cached per scope: refreshed five minutes before expiry
  or at Entra's `refresh_in`, one fetch at a time, a failed early refresh
  keeping the valid token, everything secret wiped when freed. Entra's
  refusals, with their AADSTS codes and ids, go to `Diagnostics`.
  `auth.testing.FakeEntra` answers as Entra did when measured; the cache
  is after gcp.zig's, and its form encoder is gcp.zig's. Run against Entra
  ID and az 2.92.0 on 2026-11-07.
- `storage`: Blob Storage at x-ms-version 2026-04-06: containers made,
  read and deleted; block blobs written in one request, read whole or in
  part, read for their properties, listed over every page (a prefix,
  `after` a name, a delimiter, metadata) and deleted. Shared Key, signed
  once per call within a ten-minute retry window, or an Entra token.
  Opaque ETags and the write and read conditions, a lost conditional
  write settled by a token in its metadata, accounts with a hierarchical
  namespace refused, the account read once for a client and every
  `sibling` made from it. `storage.testing.FakeBlob` answers as production
  does. Its XML reader is gcp.zig's. Run against Azurite 3.37.0 (CI's
  `azurite` job) and against Azure on 2026-11-07, with Shared Key and a
  token.
- `prices`: Linux VM prices from the Retail Prices API, spot or on demand,
  by region and size, every page read through the API's `:443` links; the
  Windows, Dev/Test, reservation, Low Priority and Cloud Services rows left
  out by the filter and again row by row. `Amount` holds a price exactly,
  from the number's digits. `prices.testing.FakePrices` is the API in
  memory. Run against the API: 66 regions for Standard_D2as_v5 spot, 1743
  on-demand sizes in eastus2 over two pages.
