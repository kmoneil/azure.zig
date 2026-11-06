# Contributing

Bug reports, fixes and improvements are welcome. For anything larger than a
small fix, open an issue first so the approach can be agreed on.

## Setup

You need Zig 0.17.1, and two programs on the PATH that `zig build test`
runs: [zigvet](https://github.com/kmoneil/zigvet), which reports code the
compiler accepts that is almost certainly wrong, and
[gnarl](https://github.com/kmoneil/gnarl), which holds each function to
its complexity limits (`brew install kmoneil/tap/zigvet
kmoneil/tap/gnarl`, or a binary from either's releases). gnarl must be
the release `complexity.zon` names in `.gnarl`: two releases can count the
same function differently, and another release refuses to judge the code.
`zig build coverage` also needs [kcov](https://github.com/SimonKagstrom/kcov).

```
zig build test          # unit, property and fuzz-corpus tests, zig fmt --check, zigvet, gnarl
zig build fmt           # format the Zig
zig build coverage      # line coverage, into zig-out/coverage
```

[docs/development.md](docs/development.md) lists every build step.

## Before a commit

- `zig build test` passes, and prints nothing from zigvet or gnarl.
- `python3 -I tools/check_docs.py` passes: a guide's code block marked as a
  snippet is the code in `examples/` or `tests/docs_examples.zig`.
- `gnarl --diff HEAD` shows no function newly over its limit. A new
  function over a critical limit is refactored, not added to
  `complexity.baseline`.
- A file that runs per request, response or byte on a caller's path joins
  `complexity.zon`'s `hot` list in the change that adds it.
- A file carried from another library (gcp.zig, say) keeps a first line
  naming the file and commit it came from, and has a row in
  [docs/development.md](docs/development.md#where-the-code-came-from), so a
  fix made in either can be carried to the other.
