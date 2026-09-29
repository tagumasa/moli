# Contributing to moli

## Bug fixes

Bug fixes are always welcome. If you find a bug, please open an issue
with a minimal reproduction, or submit a pull request with a fix. When
a reproduction needs dictionary data, build it from a few hand-written
CSV rows or the committed fixtures under `tests/fixtures/` — the real
lexicons (ipadic, UniDic, mecab-jieba) and the corpora are licensed,
and their rows must not be pasted into issues, tests, or commits.

## New features and specification changes

moli depends on the Odin compiler, which is actively evolving, and its
behavior is governed by written specifications: the Analyzer contract
([docs/contract.md](docs/contract.md)) and the options and input
formats ([docs/options.md](docs/options.md)). New features, dictionary
or snapshot format additions, or changes that follow Odin's own
specification updates require prior discussion — please open an issue
before starting work on a pull request. This helps us align on scope
and avoids duplicated or misplaced effort.

## Development setup

The suite runs on the small committed fixtures alone — no dictionary
download is needed to contribute:

```
just check       # odin check src/moli + the SDK shim, -vet -strict-style
just test        # core suite under the tracking allocator
just sdk-test    # SDK: shim ABI tests under the same gate + pytest
```

The Odin toolchain is pinned to a specific nightly; AGENTS.md records
the hash and CI rejects any other compiler. Tests must run leak-free:
the suites are judged from their logs (`tmp/test.log`,
`tmp/sdk-test.log`), and any leak block or WARN line fails review.

The real dictionaries are fetched into gitignored `dict/`
(`just dict-fetch`) and never committed or distributed — the same rule
covers corpus text anywhere in the tree.

## Quick clarifications

Typo fixes, documentation improvements, and test coverage gaps are
welcome as direct pull requests without prior discussion.
