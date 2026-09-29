# moli build tasks. The library lives in src/ (package moli); the test
# suite is a separate package in tests/ that imports it through the
# collection below. The Python SDK lives under sdk/moli-python-sdk.

# Show available tasks
default:
    @just --list

# Type-check the library and the SDK's C-ABI shim package with vet and
# strict style. (tests/ is not checked here: core:testing only exists
# in test builds, which is what `just test` compiles.)
check:
    odin check src/moli -vet -strict-style -no-entry-point
    odin check sdk/moli-python-sdk/native -collection:moli=src -vet -strict-style -no-entry-point

# Run the test suite serially, then gate on the log: verdicts come from
# the log, never the exit status alone, and the leak discipline is zero
# leak lines — not "fewer than before".
test:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p tmp
    odin test tests -collection:moli=src -define:ODIN_TEST_THREADS=1 2>&1 | tee tmp/test.log
    pattern='\[ERROR\]|\[FATAL\]|\[WARN \]|\[WARN\]|\+\+\+ leak|bad free|out of range'
    if grep -a -q -E "$pattern" tmp/test.log; then
        grep -a -E "$pattern" tmp/test.log
        echo 'FAIL: errors or leak blocks in the test log (above)'
        exit 1
    fi

# Fetch the open-license source dictionaries into dict/ (gitignored)
dict-fetch:
    ./scripts/fetch_dicts.sh

# Regenerate the sampled test fixtures (seeded, byte-identical; run
# dict-fetch first). The fixtures are committed, so regeneration shows
# up as a reviewable diff.
fixtures:
    #!/usr/bin/env bash
    set -euo pipefail
    ./scripts/sample_fixture.sh dict/unidic-mecab-2.1.2_src/lex.csv 50 20260825 tests/fixtures/unidic_sample.csv
    ./scripts/sample_fixture.sh dict/mecab-jieba-0.1.1/jieba.csv 100 20260825 tests/fixtures/jieba_sample.csv
    head -n 10 tests/fixtures/jieba_sample.csv | sed 's/$/\r/' > tests/fixtures/jieba_sample_crlf.csv

# --- Python SDK (sdk/moli-python-sdk) ---------------------------------

SDK := 'sdk/moli-python-sdk'

# The .so link in sdk-lib is ours (see that recipe). The archive must
# be force-loaded - a bare shared link over an .a pulls no members,
# because nothing references them yet. GNU ld and the macOS ld spell
# that differently; the macOS ld also has no RELRO/NOW hardening.
so_link_args     := if os() == "macos" { "-Wl,-all_load -Wl,-install_name,@rpath/libmoli.so" } else { "-Wl,-z,now -Wl,-z,relro -Wl,--whole-archive" }
so_link_args_end := if os() == "macos" { "" }                     else { "-Wl,--no-whole-archive" }

# The extension resolves the Python C API at load time against the
# interpreter: GNU ld allows undefined symbols in a shared library by
# default, but the macOS ld refuses them unless told to look them up
# dynamically. $ORIGIN is likewise an ELF convention - the macOS rpath
# anchor is @loader_path, and the libmoli dependency finds it through
# the @rpath install name stamped in sdk-lib.
ext_link_args := if os() == "macos" { "-Wl,-undefined,dynamic_lookup -Wl,-rpath,@loader_path/lib" } else { "-Wl,-rpath,'$ORIGIN/lib'" }

# Bootstrap the SDK's virtual environment (pytest; the SDK itself has
# zero runtime dependencies). First run needs the network.
sdk-venv:
    #!/usr/bin/env bash
    set -euo pipefail
    python3 -m venv {{ SDK }}/.venv
    {{ SDK }}/.venv/bin/pip install pytest

# Build libmoli.so (the C ABI over the analysis library). odin's own
# -build-mode:shared link is broken on the pinned toolchain
# (dev-2026-09): it passes the init symbol to the linker wrapped in
# literal single quotes (-Wl,-init,'__odin_entry_point'), which the
# macOS ld rejects as an undefined symbol while GNU ld silently
# ignores it - so odin's shared build passes on Linux and cannot link
# on macOS at all. Building the archive skips that link path entirely
# (plain ar), and the final link below is ours; the runtime's
# load-time init rides the objects' .init_array / __mod_init_func
# sections either way, not -init.
sdk-lib:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{ SDK }}/src/moli/lib
    # -o:speed: without it the shared library ships the engine at
    # -o:minimal (bounds checks and no inlining) and every SDK rate
    # lands ~5x over the engine's own speed-build numbers.
    odin build {{ SDK }}/native -build-mode:static -collection:moli=src -o:speed \
        -vet -strict-style -out:{{ SDK }}/src/moli/lib/libmoli.a
    clang -shared {{ so_link_args }} {{ SDK }}/src/moli/lib/libmoli.a {{ so_link_args_end }} \
        -lpthread -lm -o {{ SDK }}/src/moli/lib/libmoli.so

# Compile the CPython extension against libmoli (Odin first, C second:
# the extension links the shared library at build time).
sdk-build: sdk-lib
    #!/usr/bin/env bash
    set -euo pipefail
    ext=$(python3 -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')
    gcc -O2 -Wall -shared -fPIC \
        -I{{ SDK }}/c $(python3-config --includes) \
        {{ SDK }}/c/moli_native.c \
        -L{{ SDK }}/src/moli/lib -lmoli {{ ext_link_args }} \
        -o {{ SDK }}/src/moli/_native$ext

# Run both SDK test layers under the same discipline as the library
# suite: the shim package's Odin tests under the zero-leak grep gate,
# then the pytest suite. Both passes byte-compare their snapshot of
# the ipadic fixture against the committed golden
# (tests/fixtures/qdct_ref_snapshot.qdct) — no run-order coupling.
sdk-test: sdk-build
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p tmp
    odin test {{ SDK }}/native -collection:moli=src -define:ODIN_TEST_THREADS=1 2>&1 | tee tmp/sdk-test.log
    pattern='\[ERROR\]|\[FATAL\]|\[WARN \]|\[WARN\]|\+\+\+ leak|bad free|out of range'
    if grep -a -q -E "$pattern" tmp/sdk-test.log; then
        grep -a -E "$pattern" tmp/sdk-test.log
        echo 'FAIL: errors or leak blocks in the SDK test log (above)'
        exit 1
    fi
    if ! test -x {{ SDK }}/.venv/bin/python; then
        echo 'FAIL: no SDK venv (run: just sdk-venv)'
        exit 1
    fi
    PYTHONPATH={{ SDK }}/src {{ SDK }}/.venv/bin/python -m pytest {{ SDK }}/tests -q

# FFI overhead probe: per-call Python-side timings against one held
# analyser (memory-polite, sequential). Results are recorded by hand in
# docs/benchmarks.md; this prints them.
sdk-probe: sdk-build
    #!/usr/bin/env bash
    set -euo pipefail
    PYTHONPATH={{ SDK }}/src python3 {{ SDK }}/probe.py

# Produce the qdct snapshots the bench harnesses load (the sink probe's
# mode pair and the SDK A/B battery's input) and print their
# entries_hash fingerprints - the consumers assert those against a
# fresh load before measuring, so a stale snapshot fails loudly.
bench-snapshots:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p tmp/sdk_ab
    odin run bench/snapshots.odin -file -collection:moli=$(pwd)/src -o:speed
