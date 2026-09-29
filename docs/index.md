# moli documentation

- [README](../README.md) — overview, the Odin quick start, dictionary acquisition, licences
- [The Analyzer contract](contract.md) — immutability and concurrency, zero-copy morphemes, allocation and teardown, identifier lifetimes, input-validation boundaries
- [Options and input formats](options.md) — every load/tokenize option with its default; the CSV schemas and the unk.def / char.def / matrix.def / patterns.qpat grammar, shown on committed fixture rows
- [Embedding from C](abi.md) — building `libmoli.so`, the ABI version check, the call map with per-call thread safety, a compilable example program
- [Benchmarks](benchmarks.md) — the single home for measured numbers; [bench/README.md](../bench/README.md) maps every number to the harness that produced it
- [Test fixtures](../tests/fixtures/README.md) — committed fixture provenance, sampling seeds, and licences
- [Python SDK](../sdk/moli-python-sdk/README.md) — the Python layer over the same ABI, and its threading and lifetime rules
- [Contributing](../CONTRIBUTING.md) — bug reports, feature discussion, and the development setup; issue templates live under `.github/ISSUE_TEMPLATE/`
