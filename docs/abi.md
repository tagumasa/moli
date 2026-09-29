# Embedding from C

The C ABI is the library's durable asset — the Python SDK is only its
first consumer, and other language bindings are meant to consume the
ABI directly rather than go through Python. The header,
[sdk/moli-python-sdk/c/moli_abi.h](../sdk/moli-python-sdk/c/moli_abi.h),
is a **hand-written mirror** of the library's export surface (the
Odin compiler here has no header generation), and `moli_abi_check()`
is its enforcement: verify against the library at load time, before
first use, because a layout mismatch must fail loudly rather than
corrupt memory.

## Building the library

```
just sdk-lib
```

which runs (from the justfile, Linux spelling):

```
odin build sdk/moli-python-sdk/native -build-mode:static -collection:moli=src -o:speed \
    -vet -strict-style -out:sdk/moli-python-sdk/src/moli/lib/libmoli.a
clang -shared -Wl,-z,now -Wl,-z,relro -Wl,--whole-archive sdk/moli-python-sdk/src/moli/lib/libmoli.a \
    -Wl,--no-whole-archive -lpthread -lm -o sdk/moli-python-sdk/src/moli/lib/libmoli.so
```

Not odin's own `-build-mode:shared`: the pinned toolchain passes the
init symbol to the linker wrapped in literal single quotes, which the
macOS ld rejects outright while GNU ld silently ignores it, so the
recipe takes the archive from odin and owns the final link itself —
force-loading the archive, because a bare shared link over an `.a`
pulls no members. The justfile's `sdk-lib` recipe carries the platform
spellings (`-all_load` and an `@rpath` install name on macOS).
`-o:speed` is load-bearing — the note in the same recipe records what
ships without it. The current ABI version is `MOLI_ABI_VERSION` in the
header; a layout change on either side moves the shim structs, the
header, and the extension's `verify_abi_layout` together, and bumps
that version.

## The version check

```c
int64_t v[MOLI_ABI_CHECK_LEN];
int32_t n = moli_abi_check(v, MOLI_ABI_CHECK_LEN);
/* n is the count of values the library wrote; slot 0 is its ABI
   version. The full vector is every mirrored struct's size and field
   offsets plus every mirrored enum ordinal — the Python extension
   compares all of them at import (verify_abi_layout in
   sdk/moli-python-sdk/c/moli_native.c). */
```

## Call map

| Function | Lane | Notes |
|---|---|---|
| `moli_abi_version`, `moli_version`, `moli_abi_check` | pure | No state touched |
| `moli_load`, `moli_load_bytes`, `moli_load_qdct`, `moli_load_qdct_mmap`, `moli_load_qdct_bytes`, `moli_clone` | constructing | Each returns an independent handle; clone a shared base for variant dictionaries, not per-thread copies |
| `moli_free` | exactly once | Drains in-flight calls on that handle first |
| `moli_save_qdct`, `moli_snapshot` + `moli_snapshot_free` | read-only | Run under the same acquire bracket as tokenize; a teardown racing them answers `MOLI_SAVE_UNAVAILABLE` |
| `moli_stats` | read-only, **serialise per handle** | `skipped[]` borrows a per-handle scratch every call rewrites — copy the strings out before the next call |
| `moli_add_user_entries` | mutating, **serialise** | Entries are borrowed for the call's duration; `NULL` in a string field is the empty optional. The merge invalidates earlier entry ids — see [contract.md](contract.md) |
| `moli_tokenize`, `moli_wakachi`, `moli_spans`, `moli_nbest`, `moli_tokenize_constrained` | concurrent on a shared handle | `opts` NULL = defaults |
| `moli_classify_locale` | read-only | Scans the loaded rows |
| `moli_result_*` | caller-owned result | See below |
| `moli_cancel_new`, `moli_cancel`, `moli_cancel_free` | as owned | `moli_cancel` fires the one-way flag, safe from any thread — including before the call it is meant to stop |

## Results and errors

A `Moli_Result` owns its allocations outright — the library never
touches a result after the producing call returns, so results have no
lifetime coupling to the analyser or to later calls, and
`moli_result_free` releases the whole set. Morpheme strings are not
pointers: each field is an `(offset, len)` pair into
`moli_result_blob(r)`, valid until `moli_result_free(r)`.

`Moli_Err` may be `NULL` anywhere it appears (failure reporting never
crashes on a declined out-parameter). When filled, it carries a
`domain`/`code` pair (the `MOLI_*` constants in the header — the ABI
mirror of the fault vocabularies in
[errors.odin](../src/moli/errors.odin)), payload slots `a`/`b`/`c`
(schema line/expected/got, or a byte offset), `d` for a constraint
rejection reason, and a NUL-terminated human-readable `message`.

## A complete program

This program is the verification record for this page — it compiled
with the command below against the committed fixture and printed the
output shown. Save as `abi_example.c` in the repository root:

```c
#include <stdio.h>
#include <string.h>
#include "moli_abi.h"

int main(void)
{
    Moli_Err err;

    /* 1. the version check - before first real use */
    int64_t v[MOLI_ABI_CHECK_LEN];
    int32_t n = moli_abi_check(v, MOLI_ABI_CHECK_LEN);
    if (n < 1 || v[0] != MOLI_ABI_VERSION) {
        fprintf(stderr, "abi mismatch: header %u, library %lld\n",
                (unsigned)MOLI_ABI_VERSION, (long long)v[0]);
        return 1;
    }

    /* 2. load - zeroed options = the recommended load (sibling discovery) */
    Moli_Load_Options opts = {0};
    Moli_Handle a = moli_load(MOLI_LANG_JAPANESE,
                              "tests/fixtures/ipadic_sample.csv", &opts, &err);
    if (a == NULL) {
        fprintf(stderr, "load: %s\n", err.message);
        return 1;
    }

    /* 3. tokenize - NULL opts = defaults; concurrent on a shared handle */
    const char *text = "犬が歩く";
    Moli_Result r = moli_tokenize(a, (const uint8_t *)text,
                                  (int64_t)strlen(text), NULL, &err);
    if (r == NULL) {
        fprintf(stderr, "tokenize: %s\n", err.message);
        moli_free(a);
        return 1;
    }

    /* 4. read the result - strings are (offset, len) into the result blob */
    const Moli_Morpheme *ms = moli_result_morphemes(r);
    const uint8_t *blob = moli_result_blob(r);
    int64_t count = moli_result_count(r);
    for (int64_t i = 0; i < count; i++) {
        printf("%.*s\t%.*s\n",
               (int)ms[i].surf_len, blob + ms[i].surf_off,
               (int)ms[i].pos_len, blob + ms[i].pos_off);
    }

    /* 5. teardown - the result has no lifetime coupling to the handle */
    moli_result_free(r);
    moli_free(a);
    return 0;
}
```

Build and run (the rpath must resolve to the absolute directory of
`libmoli.so` at run time):

```
gcc -O2 -Wall -Wextra -Isdk/moli-python-sdk/c abi_example.c \
    -Lsdk/moli-python-sdk/src/moli/lib -lmoli \
    -Wl,-rpath,$PWD/sdk/moli-python-sdk/src/moli/lib -o abi_example
./abi_example
犬	名詞,一般
が	助詞,格助詞,一般
歩く	動詞,自立,五段・カ行,基本形
```

The fixture loads standalone — the optional resources are absent
beside it, the load degrades and records the skips (try
`moli_stats` to see them). With a real dictionary directory the same
program picks up `unk.def` / `char.def` / `matrix.def` /
`patterns.qpat` by sibling discovery.

## The reference consumer

`sdk/moli-python-sdk/c/moli_native.c` is the worked example of every
rule on this page, plus the embedding-level ones an integrator
re-derives for their own runtime: bracketing every handle call with an
in-flight count so `close` can drain (the storage-quiescence rule in
[contract.md](contract.md)), releasing the interpreter lock around
every real call, and claiming the handle under the lock before
releasing it so two racing closes cannot double-free. The SDK's
[README](../sdk/moli-python-sdk/README.md) documents the same rules in
Python terms.
