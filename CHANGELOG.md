# Changelog

Until 1.0, minor versions may break the API; each entry says how.

## 0.1.0 (unreleased)

- The repository: the build, gcp.zig's test runner, and an empty `core`
  module.
- `zig build test` runs the unit tests, `zig fmt --check`, zigvet, and
  gnarl (0.7.0, named in `complexity.zon`): a zigvet finding, or a
  function newly over its complexity limit or worse than
  `complexity.baseline`, fails it.
