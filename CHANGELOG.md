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
