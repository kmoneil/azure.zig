# Changelog

Until 1.0, minor versions may break the API; each entry says how.

## 0.1.0 (unreleased)

- The repository: the build, gcp.zig's test runner, and an empty `core`
  module.
- `zig build test` runs the unit tests, `zig fmt --check`, zigvet, and
  gnarl (0.7.0, named in `complexity.zon`): a zigvet finding, or a
  function newly over its complexity limit or worse than
  `complexity.baseline`, fails it.
- `core` builds on rest-core v0.1.0, pinned by hash: its transport, request
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
- `resources`: subscriptions listed; resource groups made (201, or 200 with
  the spec's tags), read, listed by tag through ARM's OData filter, and
  deleted as a long-running operation, with `force_vms`; providers read
  and registered on request, never on their own. Names are checked before
  sending. `resources.testing.FakeResources` is Resource Manager in memory
  for these calls. Not yet run against Azure.
