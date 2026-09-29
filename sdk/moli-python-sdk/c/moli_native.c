/*
 * moli_native.c — the CPython extension over libmoli (the C ABI).
 *
 * Design contract this file implements:
 *  - the extension LINKS libmoli (link-time symbol checking, not
 *    dlopen) and verifies the ABI layout mirror against
 *    moli_abi_check() at import time: a mismatch fails the import
 *    with a plain message, never the first tokenize;
 *  - `Analyzer` and `CancelToken` are C types with a closed flag and
 *    a finaliser. String-shaped results (wakachi, wakati, parse,
 *    spans) are built eagerly and the native result is freed before
 *    the call returns. tokenize() returns a `Morphemes` view that
 *    keeps the native result box alive and materializes Morpheme
 *    values on access; the box is standalone memory (never part of
 *    the calling thread's analysis scratch), so the view has no
 *    invalidation semantics and no analyzer coupling, and it is
 *    released when the last morpheme materializes or the view dies;
 *  - the GIL is released around every ABI call and every lock wait:
 *    the load family, the tokenize family (constrained included),
 *    classify_locale, stats, add_user_entries, save/snapshot/clone,
 *    close's drain, and the frees (moli_free in close and dealloc,
 *    the result and snapshot frees — a freed dictionary or blob must
 *    not stall every thread), and the morphemes build lock. It is
 *    held for argument parsing, for materialization (pure C reads of
 *    a read-only box), and for the Python-object assembly after each
 *    call;
 *  - error kinds cross as codes only; each domain+code maps to one
 *    exception class, with payload fields attached to the instance.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <pythread.h>
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* The drain primitives (close's wait for in-flight calls): POSIX
 * pthreads or Win32 SRWLOCK + CONDITION VARIABLE. */
#if defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
#endif

#include "moli_abi.h"

/* --- module-level state (single-phase init; internal module) ------ */

static PyObject *MoliError;
static PyObject *LoadError;
static PyObject *SchemaMismatchError;
static PyObject *OutOfMemoryError;
static PyObject *UnavailableError;
static PyObject *MalformedInputError;
static PyObject *CancelledError;
static PyObject *ConstraintError;
static PyObject *UnsatisfiableError;
static PyObject *SaveError;

/* Value/enum types registered by the Python layer right after import;
 * NULL fall back to plain ints/tuples (the raw ABI shapes). */
static PyObject *MorphemeType;
static PyObject *SpanType;
static PyObject *NBestPathType;
static PyObject *AnalyzerStatsType;
static PyObject *LocaleType;
static PyObject *CharClassType;

/* Enum member singletons, materialized once when the classes are
 * registered: hot paths then INCREF a cached instance instead of
 * running the class's Python-level __call__ per morpheme. NULL until
 * _set_value_types ran (ordinal_py's plain-int fallback covers the
 * raw-ABI window); the class call is the only constructor, so each
 * entry is the identical instance the class would have returned. */
static PyObject *LocaleMembers[MOLI_LOCALE_COUNT];
static PyObject *CharClassMembers[MOLI_CHARCLASS_COUNT];

/* Morpheme._tuple_new — collections.namedtuple's `tuple.__new__` —
 * fetched at registration: building the 12-tuple first and calling it
 * directly skips the generated Python-level __new__ frame per
 * morpheme. NULL when absent; the class-call path stays. */
static PyObject *MorphemeTupleNew;

/* Interned keyword names for the tokenize family's FASTCALL entry
 * (Python-level keyword literals arrive interned, so the common match
 * is a pointer compare). */
static PyObject *KwText, *KwK, *KwBias, *KwPerRune, *KwNfc, *KwStrict, *KwCancel,
                 *KwTokens, *KwBoundaries;

/* --- import-time ABI layout verification --------------------------- */

static int verify_abi_layout(void)
{
    /* Slot layout mirrors moli_abi_check: [version, every mirrored
     * struct's size + field offsets, enum member counts, then every
     * enum's per-member ordinals]. Layouts are derived from this
     * header's own types and the ordinals from this header's own
     * defines, so a drift on either side fails here at import: a
     * field reorder, a width change, or an inside-enum reshuffle that
     * keeps the counts but moves the members. */
    const int64_t want[MOLI_ABI_CHECK_LEN] = {
        MOLI_ABI_VERSION,
        (int64_t)sizeof(Moli_Morpheme),
        (int64_t)offsetof(Moli_Morpheme, start),
        (int64_t)offsetof(Moli_Morpheme, end),
        (int64_t)offsetof(Moli_Morpheme, surf_off),
        (int64_t)offsetof(Moli_Morpheme, surf_len),
        (int64_t)offsetof(Moli_Morpheme, pos_off),
        (int64_t)offsetof(Moli_Morpheme, pos_len),
        (int64_t)offsetof(Moli_Morpheme, lemma_off),
        (int64_t)offsetof(Moli_Morpheme, lemma_len),
        (int64_t)offsetof(Moli_Morpheme, reading_off),
        (int64_t)offsetof(Moli_Morpheme, reading_len),
        (int64_t)offsetof(Moli_Morpheme, jyutping_off),
        (int64_t)offsetof(Moli_Morpheme, jyutping_len),
        (int64_t)offsetof(Moli_Morpheme, entry_id),
        (int64_t)offsetof(Moli_Morpheme, cost),
        (int64_t)offsetof(Moli_Morpheme, locale),
        (int64_t)offsetof(Moli_Morpheme, char_class),
        (int64_t)offsetof(Moli_Morpheme, is_unknown),
        (int64_t)sizeof(Moli_Err),
        (int64_t)offsetof(Moli_Err, domain),
        (int64_t)offsetof(Moli_Err, code),
        (int64_t)offsetof(Moli_Err, a),
        (int64_t)offsetof(Moli_Err, b),
        (int64_t)offsetof(Moli_Err, c),
        (int64_t)offsetof(Moli_Err, message),
        (int64_t)offsetof(Moli_Err, d),
        (int64_t)sizeof(Moli_Path),
        (int64_t)offsetof(Moli_Path, cost),
        (int64_t)offsetof(Moli_Path, first),
        (int64_t)offsetof(Moli_Path, count),
        (int64_t)sizeof(Moli_Load_Options),
        (int64_t)offsetof(Moli_Load_Options, unk_def_path),
        (int64_t)offsetof(Moli_Load_Options, char_def_path),
        (int64_t)offsetof(Moli_Load_Options, matrix_def_path),
        (int64_t)offsetof(Moli_Load_Options, qpat_path),
        (int64_t)offsetof(Moli_Load_Options, jyutping_csv_path),
        (int64_t)offsetof(Moli_Load_Options, threads),
        (int64_t)offsetof(Moli_Load_Options, mode),
        (int64_t)offsetof(Moli_Load_Options, lemma_locale),
        (int64_t)offsetof(Moli_Load_Options, flat_char_class),
        (int64_t)sizeof(Moli_Tokenize_Options),
        (int64_t)offsetof(Moli_Tokenize_Options, cancel),
        (int64_t)offsetof(Moli_Tokenize_Options, unk_cost_bias),
        (int64_t)offsetof(Moli_Tokenize_Options, unk_cost_per_rune),
        (int64_t)offsetof(Moli_Tokenize_Options, normalize_nfc),
        (int64_t)offsetof(Moli_Tokenize_Options, strict_utf8),
        (int64_t)sizeof(Moli_User_Entry),
        (int64_t)offsetof(Moli_User_Entry, surface),
        (int64_t)offsetof(Moli_User_Entry, pos),
        (int64_t)offsetof(Moli_User_Entry, lemma),
        (int64_t)offsetof(Moli_User_Entry, reading),
        (int64_t)offsetof(Moli_User_Entry, reading_jyutping),
        (int64_t)offsetof(Moli_User_Entry, left_id),
        (int64_t)offsetof(Moli_User_Entry, right_id),
        (int64_t)offsetof(Moli_User_Entry, cost),
        (int64_t)sizeof(Moli_Stats),
        (int64_t)offsetof(Moli_Stats, entries),
        (int64_t)offsetof(Moli_Stats, terminals),
        (int64_t)offsetof(Moli_Stats, cedar_nodes),
        (int64_t)offsetof(Moli_Stats, unk_rules),
        (int64_t)offsetof(Moli_Stats, unk_patterns),
        (int64_t)offsetof(Moli_Stats, matrix_left),
        (int64_t)offsetof(Moli_Stats, matrix_right),
        (int64_t)offsetof(Moli_Stats, matrix_cells),
        (int64_t)offsetof(Moli_Stats, matrix_explicit),
        (int64_t)offsetof(Moli_Stats, matrix_density),
        (int64_t)offsetof(Moli_Stats, entries_hash),
        (int64_t)offsetof(Moli_Stats, skipped),
        (int64_t)offsetof(Moli_Stats, skipped_count),
        (int64_t)sizeof(Moli_Token_Constraint),
        (int64_t)offsetof(Moli_Token_Constraint, start),
        (int64_t)offsetof(Moli_Token_Constraint, end),
        (int64_t)offsetof(Moli_Token_Constraint, pos),
        (int64_t)sizeof(Moli_Boundary_Constraint),
        (int64_t)offsetof(Moli_Boundary_Constraint, at),
        (int64_t)offsetof(Moli_Boundary_Constraint, must_exist),
        MOLI_LANGUAGE_COUNT,
        MOLI_LOCALE_COUNT,
        MOLI_MODE_COUNT,
        MOLI_CHARCLASS_COUNT,
        MOLI_DOMAIN_COUNT,
        MOLI_LOAD_CODE_COUNT,
        MOLI_TOK_CODE_COUNT,
        MOLI_SAVE_CODE_COUNT,
        /* Per-member ordinals, declaration order — the same block the
         * library appends after the counts. */
        MOLI_LANG_JAPANESE, MOLI_LANG_CHINESE_CN, MOLI_LANG_CHINESE_TW,
        MOLI_LANG_CHINESE_HK, MOLI_LANG_ENGLISH_GB, MOLI_LANG_ENGLISH_US,
        MOLI_LANG_GERMAN,
        MOLI_LOCALE_NONE, MOLI_LOCALE_CN, MOLI_LOCALE_TW, MOLI_LOCALE_HK,
        MOLI_LOCALE_GB, MOLI_LOCALE_US,
        MOLI_MODE_VITERBI, MOLI_MODE_LONGESTMATCH,
        MOLI_CLASS_UNKNOWN, MOLI_CLASS_HIRAGANA, MOLI_CLASS_KATAKANA,
        MOLI_CLASS_KANJI, MOLI_CLASS_HANZI, MOLI_CLASS_HALFWIDTH_KATAKANA,
        MOLI_CLASS_BOPOMOFO, MOLI_CLASS_ASCII_LETTER, MOLI_CLASS_DIGIT,
        MOLI_CLASS_PUNCT, MOLI_CLASS_SPACE, MOLI_CLASS_SYMBOL,
        MOLI_CLASS_EMOJI,
        MOLI_DOMAIN_LOAD, MOLI_DOMAIN_TOKENIZE, MOLI_DOMAIN_SAVE,
        MOLI_LOAD_FILE_NOT_FOUND, MOLI_LOAD_INVALID_FORMAT,
        MOLI_LOAD_OUT_OF_MEMORY, MOLI_LOAD_SCHEMA_MISMATCH,
        MOLI_LOAD_IO_READ,
        MOLI_TOK_OUT_OF_MEMORY, MOLI_TOK_UNAVAILABLE, MOLI_TOK_MALFORMED,
        MOLI_TOK_CANCELLED, MOLI_TOK_BAD_CONSTRAINT,
        MOLI_TOK_UNSATISFIABLE,
        MOLI_SAVE_IO_WRITE, MOLI_SAVE_OUT_OF_MEMORY,
        MOLI_SAVE_UNAVAILABLE, MOLI_SAVE_FORMAT_LIMIT,
        MOLI_REASON_OUT_OF_BOUNDS, MOLI_REASON_EMPTY_SPAN,
        MOLI_REASON_NOT_RUNE_BOUNDARY, MOLI_REASON_TOKEN_OVERLAP,
        MOLI_REASON_BOUNDARY_INSIDE_TOKEN,
        MOLI_REASON_BOUNDARY_AT_TOKEN_EDGE,
        MOLI_REASON_CONFLICTING_BOUNDARIES, MOLI_REASON_BAD_POS_PATTERN,
        MOLI_REASON_NORMALIZATION_RESCALED,
    };
    int64_t got[MOLI_ABI_CHECK_LEN];
    int32_t n = moli_abi_check(got, MOLI_ABI_CHECK_LEN);
    if (n != MOLI_ABI_CHECK_LEN) {
        PyErr_Format(PyExc_ImportError,
                     "moli ABI check failed: library wrote %d values, expected %d "
                     "(the extension and libmoli disagree; rebuild both together)",
                     (int)n, MOLI_ABI_CHECK_LEN);
        return -1;
    }
    for (int i = 0; i < MOLI_ABI_CHECK_LEN; i++) {
        if (got[i] != want[i]) {
            PyErr_Format(PyExc_ImportError,
                         "moli ABI layout mismatch at slot %d: library reports "
                         "%lld, this extension was built for %lld "
                         "(the extension and libmoli disagree; rebuild both together)",
                         i, (long long)got[i], (long long)want[i]);
            return -1;
        }
    }
    if (moli_abi_version() != MOLI_ABI_VERSION) {
        PyErr_Format(PyExc_ImportError,
                     "moli ABI version mismatch: library %u, extension %d",
                     (unsigned)moli_abi_version(), MOLI_ABI_VERSION);
        return -1;
    }
    return 0;
}

/* --- error mapping (codes only; never string matching) ------------- */

static void set_attr_long(PyObject *obj, const char *name, long long v)
{
    PyObject *val = PyLong_FromLongLong(v);
    if (val != NULL) {
        PyObject_SetAttrString(obj, name, val);
        Py_DECREF(val);
    }
}

static void raise_moli_err(const Moli_Err *e)
{
    PyObject *cls;
    if (e->domain == MOLI_DOMAIN_LOAD) {
        switch (e->code) {
        case MOLI_LOAD_FILE_NOT_FOUND:  cls = LoadError; break;
        case MOLI_LOAD_OUT_OF_MEMORY:   cls = OutOfMemoryError; break;
        case MOLI_LOAD_SCHEMA_MISMATCH: cls = SchemaMismatchError; break;
        case MOLI_LOAD_IO_READ:         cls = LoadError; break;
        default:                         cls = LoadError; break;
        }
    } else if (e->domain == MOLI_DOMAIN_TOKENIZE) {
        switch (e->code) {
        case MOLI_TOK_OUT_OF_MEMORY: cls = OutOfMemoryError; break;
        case MOLI_TOK_MALFORMED:     cls = MalformedInputError; break;
        case MOLI_TOK_CANCELLED:     cls = CancelledError; break;
        case MOLI_TOK_BAD_CONSTRAINT: cls = ConstraintError; break;
        case MOLI_TOK_UNSATISFIABLE:  cls = UnsatisfiableError; break;
        default:                     cls = UnavailableError; break;
        }
    } else {
        switch (e->code) {
        case MOLI_SAVE_IO_WRITE:       cls = SaveError; break;
        case MOLI_SAVE_OUT_OF_MEMORY:  cls = OutOfMemoryError; break;
        case MOLI_SAVE_FORMAT_LIMIT:   cls = SaveError; break;
        default:                       cls = UnavailableError; break;
        }
    }

    /* The message can carry non-UTF-8 bytes — bytes paths are
     * accepted and echoed into load failures, and the wire buffer's
     * truncation can split a multibyte sequence. surrogateescape
     * round-trips those instead of failing the decode, so the mapped
     * exception class always wins over a UnicodeDecodeError. */
    PyObject *msg = PyUnicode_DecodeUTF8(e->message, strlen(e->message),
                                         "surrogateescape");
    if (msg == NULL) {
        return;
    }
    PyObject *inst = PyObject_CallOneArg(cls, msg);
    Py_DECREF(msg);
    if (inst == NULL) {
        return;
    }
    if (cls == SchemaMismatchError) {
        set_attr_long(inst, "line", e->a);
        set_attr_long(inst, "expected", e->b);
        set_attr_long(inst, "got", e->c);
    } else if (cls == MalformedInputError || cls == CancelledError) {
        set_attr_long(inst, "byte_offset", e->a);
    } else if (cls == ConstraintError) {
        set_attr_long(inst, "index", e->a);
        set_attr_long(inst, "start", e->b);
        set_attr_long(inst, "end", e->c);
        /* d is the MOLI_REASON_* ordinal — the vocabulary crosses the
         * ABI as code, so the Python side compares it against its
         * ConstraintReason enum instead of matching message text. */
        set_attr_long(inst, "reason", e->d);
    } else if (cls == UnsatisfiableError) {
        set_attr_long(inst, "byte_offset", e->a);
    }
    PyErr_SetObject(cls, inst);
    Py_DECREF(inst);
}

static PyObject *closed_guard_failed(void)
{
    PyErr_SetString(UnavailableError, "analyser is closed");
    return NULL;
}

/* --- small helpers -------------------------------------------------- */

/* Text input: str is encoded UTF-8 once (the cache rides on the
 * object, which the caller keeps alive through the call); bytes pass
 * through untouched so strict-UTF-8 probing can feed raw buffers. */
static int text_arg(PyObject *obj, const uint8_t **out, int64_t *out_len)
{
    if (PyUnicode_Check(obj)) {
        Py_ssize_t n = 0;
        const char *s = PyUnicode_AsUTF8AndSize(obj, &n);
        if (s == NULL) {
            return -1;
        }
        *out = (const uint8_t *)s;
        *out_len = (int64_t)n;
        return 0;
    }
    if (PyBytes_Check(obj)) {
        *out = (const uint8_t *)PyBytes_AS_STRING(obj);
        *out_len = (int64_t)PyBytes_GET_SIZE(obj);
        return 0;
    }
    PyErr_SetString(PyExc_TypeError, "text must be str or bytes");
    return -1;
}

/* Path-ish argument: None -> NULL, str/bytes -> C string (borrowed
 * from the object, which the caller keeps alive). An embedded NUL
 * would silently truncate the path the library sees, so it is an
 * error instead. */
static const char *path_arg(PyObject *obj)
{
    if (obj == Py_None) {
        return NULL;
    }
    const char *s = NULL;
    Py_ssize_t len = 0;
    if (PyUnicode_Check(obj)) {
        s = PyUnicode_AsUTF8AndSize(obj, &len);
        if (s == NULL) {
            return NULL;
        }
    } else if (PyBytes_Check(obj)) {
        s = PyBytes_AS_STRING(obj);
        len = PyBytes_GET_SIZE(obj);
    } else {
        PyErr_SetString(PyExc_TypeError, "path must be str, bytes, or None");
        return NULL;
    }
    if (memchr(s, '\0', (size_t)len) != NULL) {
        PyErr_SetString(PyExc_ValueError, "path must not contain embedded NUL bytes");
        return NULL;
    }
    return s;
}

/* NULL return with an exception set means a conversion error; NULL
 * with no exception means None. */
static const char *checked_path_arg(PyObject *obj)
{
    const char *p = path_arg(obj);
    if (p == NULL && obj != Py_None && PyErr_Occurred()) {
        return NULL;
    }
    return p;
}

/* --- call-duration strong references ---------------------------------
 *
 * Attribute reads and constraint parsing hand the ABI `const char *`
 * UTF-8 views of str objects that may be freshly built (@property
 * results, materialized sequence items): such an object dies with its
 * last reference, so the pointer must not outlive the owner's. The
 * holder keeps every converted object alive for the whole call; the
 * one release point is after the ABI call that consumed the bytes
 * (and on every failure path before it). */
typedef struct {
    PyObject **items; /* strong references, PyMem array */
    Py_ssize_t n;
    Py_ssize_t cap;
} RefHold;

static int refhold_init(RefHold *h, Py_ssize_t cap)
{
    if (cap < 4) {
        cap = 4;
    }
    h->items = PyMem_Malloc((size_t)cap * sizeof(PyObject *));
    if (h->items == NULL) {
        PyErr_NoMemory();
        return -1;
    }
    h->n = 0;
    h->cap = cap;
    return 0;
}

/* Takes over the caller's reference (no extra INCREF); on failure the
 * reference is dropped here. NULL objects are skipped so optional
 * conversions share the tail. Allocation failures raise MemoryError —
 * the hold helpers own their error reporting, callers only propagate
 * the NULL. */
static int refhold_add(RefHold *h, PyObject *o)
{
    if (o == NULL) {
        return 0;
    }
    if (h->n == h->cap) {
        Py_ssize_t cap = h->cap * 2;
        PyObject **items = PyMem_Resize(h->items, PyObject *, (size_t)cap);
        if (items == NULL) {
            PyErr_NoMemory();
            Py_DECREF(o);
            return -1;
        }
        h->items = items;
        h->cap = cap;
    }
    h->items[h->n++] = o;
    return 0;
}

static void refhold_fini(RefHold *h)
{
    while (h->n > 0) {
        Py_DECREF(h->items[--h->n]);
    }
    PyMem_Free(h->items);
    h->items = NULL;
    h->cap = 0;
}

/* Borrowed UTF-8 from a str whose object moves into the hold: rejects
 * non-str input (a clear TypeError, not the converter's internal one)
 * and embedded NULs (the ABI takes C strings; a NUL would silently
 * truncate what the library sees). NULL + exception on rejection. */
static const char *held_utf8(PyObject *v, RefHold *hold, const char *what)
{
    if (!PyUnicode_Check(v)) {
        PyErr_Format(PyExc_TypeError, "%s must be str", what);
        return NULL;
    }
    Py_ssize_t len = 0;
    const char *s = PyUnicode_AsUTF8AndSize(v, &len);
    if (s == NULL) {
        return NULL;
    }
    if (memchr(s, '\0', (size_t)len) != NULL) {
        PyErr_Format(PyExc_ValueError, "%s must not contain embedded NUL bytes", what);
        return NULL;
    }
    Py_INCREF(v);
    if (refhold_add(hold, v) < 0) {
        return NULL; /* refhold_add dropped the held reference */
    }
    return s;
}

static PyObject *ordinal_py(int v, PyObject *cls)
{
    if (cls != NULL) {
        PyObject *args = Py_BuildValue("(i)", v);
        if (args == NULL) {
            return NULL;
        }
        PyObject *res = PyObject_CallObject(cls, args);
        Py_DECREF(args);
        return res;
    }
    return PyLong_FromLong(v);
}

/* Cached enum member: INCREF of the materialized singleton, falling
 * back to the class call (or plain int) outside the cache. */
static PyObject *cached_enum_py(int v, PyObject **members, int count,
                                PyObject *cls)
{
    if (v >= 0 && v < count && members[v] != NULL) {
        Py_INCREF(members[v]);
        return members[v];
    }
    return ordinal_py(v, cls);
}

/* Strings coming back from native memory may hold invalid UTF-8 (the
 * default tokenize degrades bad bytes into unknown morphemes);
 * surrogateescape keeps them round-trippable. */
static PyObject *decode_field(const uint8_t *p, int32_t len)
{
    return PyUnicode_DecodeUTF8((const char *)p, (Py_ssize_t)len, "surrogateescape");
}

/* Per-result intern table for the dictionary-side string fields (pos,
 * lemma, reading, reading_jyutping): within one result these repeat
 * heavily while surface is essentially unique, so a hit replaces a
 * decode+allocation with an INCREF. Open addressing over FNV-1a of
 * the blob bytes with the slot count sized to the result (power of
 * two, capped); once the table fills, later fields simply decode
 * without caching. Owned by one view / build_nbest call — no string
 * escapes it.
 *
 * Malformed input decodes with surrogateescape, whose re-encoded UTF-8
 * form differs from the raw bytes; such strings never insert (the
 * insert condition is the re-encoded form byte-equaling the blob
 * range), so bad bytes keep the exact per-field decode they always
 * had instead of piling up as never-matching duplicates. */
#define STRCACHE_SLOTS_MAX 2048 /* power-of-two ceiling */
#define STRCACHE_SLOTS_MIN 16   /* power-of-two floor */

typedef struct {
    PyObject **str;
    uint32_t *hash;
    uint32_t mask; /* slots - 1 */
    int fill;
    int max_fill;  /* 75% of slots: probe chains stay short, empties remain */
} StrCache;

/* Sizing rule: twice the expected distinct strings (morphemes in the
 * result), clamped. Returns 0/-1; on failure everything is NULL. */
static int strcache_init(StrCache *c, int64_t hint)
{
    uint32_t slots = STRCACHE_SLOTS_MIN;
    while (slots < STRCACHE_SLOTS_MAX && (int64_t)slots < hint * 2) {
        slots <<= 1;
    }
    c->str = PyMem_Calloc(slots, sizeof(PyObject *));
    c->hash = PyMem_Calloc(slots, sizeof(uint32_t));
    if (c->str == NULL || c->hash == NULL) {
        PyMem_Free(c->str);
        PyMem_Free(c->hash);
        c->str = NULL;
        c->hash = NULL;
        return -1;
    }
    c->mask = slots - 1;
    c->fill = 0;
    c->max_fill = (int)(slots - slots / 4);
    return 0;
}

static void strcache_clear(StrCache *c)
{
    if (c->str == NULL) {
        return;
    }
    for (uint32_t i = 0; i <= c->mask; i++) {
        Py_CLEAR(c->str[i]);
    }
    c->fill = 0;
}

static void strcache_fini(StrCache *c)
{
    strcache_clear(c);
    PyMem_Free(c->str);
    PyMem_Free(c->hash);
    c->str = NULL;
    c->hash = NULL;
}

static uint32_t fnv1a(const uint8_t *p, int32_t len)
{
    uint32_t h = 2166136261u;
    for (int32_t i = 0; i < len; i++) {
        h ^= p[i];
        h *= 16777619u;
    }
    return h;
}

/* Returns a new reference to the field's string: the cached instance
 * when this result already produced an equal one, otherwise a fresh
 * decode (inserted only when its UTF-8 form round-trips the blob
 * bytes and the table has room). */
static PyObject *interned_field(StrCache *c, const uint8_t *p, int32_t len)
{
    uint32_t h = fnv1a(p, len);
    uint32_t i = h & c->mask;
    /* max_fill < slots keeps empty slots in every chain, so probing
     * always terminates. */
    while (c->str[i] != NULL) {
        if (c->hash[i] == h) {
            PyObject *hit = c->str[i];
            Py_ssize_t n = -1;
            const char *u = PyUnicode_AsUTF8AndSize(hit, &n);
            if (u == NULL) {
                PyErr_Clear(); /* byte comparison needs the UTF-8 view */
            } else if (n == (Py_ssize_t)len &&
                       (len == 0 || memcmp(u, p, (size_t)len) == 0)) {
                Py_INCREF(hit);
                return hit;
            }
        }
        i = (i + 1) & c->mask;
    }
    PyObject *s = decode_field(p, len);
    if (s == NULL) {
        return NULL;
    }
    Py_ssize_t n = -1;
    const char *u = PyUnicode_AsUTF8AndSize(s, &n);
    if (u == NULL) {
        /* Surrogate-bearing strings (malformed input) have no UTF-8
         * view: leave them uncached and clear the encode error —
         * returning a value with an exception set poisons the next
         * C call (SystemError: "returned a result with an exception
         * set"). */
        PyErr_Clear();
    } else if (n == (Py_ssize_t)len &&
               (len == 0 || memcmp(u, p, (size_t)len) == 0) &&
               c->fill < c->max_fill) {
        c->str[i] = s; /* slot i is the chain's first empty position */
        c->hash[i] = h;
        c->fill++;
        Py_INCREF(s); /* the table's own reference */
    }
    return s;
}

static PyObject *morph_field(StrCache *cache, const uint8_t *p, int32_t len)
{
    return cache->str != NULL ? interned_field(cache, p, len)
                              : decode_field(p, len);
}

/* --- result building (eager; the native result dies before return) - */

/* Morpheme field order: surface, pos, lemma, reading, reading_jyutping,
 * cost, start, end, locale, char_class, is_unknown, entry_id.
 * `cache` NULL (or its arrays NULL) means no interning. */
static PyObject *build_morpheme(const Moli_Morpheme *m, const uint8_t *blob,
                                StrCache *cache)
{
    PyObject *surf = decode_field(blob + m->surf_off, m->surf_len);
    PyObject *pos = NULL, *lemma = NULL, *reading = NULL, *jyutping = NULL;
    PyObject *locale = NULL, *char_class = NULL;
    PyObject *cost = NULL, *start = NULL, *end = NULL, *unknown = NULL;
    PyObject *entry_id = NULL;
    PyObject *res = NULL;
    if (surf == NULL) {
        goto fail;
    }
    pos = morph_field(cache, blob + m->pos_off, m->pos_len);
    if (pos == NULL) {
        goto fail;
    }
    lemma = morph_field(cache, blob + m->lemma_off, m->lemma_len);
    if (lemma == NULL) {
        goto fail;
    }
    reading = morph_field(cache, blob + m->reading_off, m->reading_len);
    if (reading == NULL) {
        goto fail;
    }
    jyutping = morph_field(cache, blob + m->jyutping_off, m->jyutping_len);
    if (jyutping == NULL) {
        goto fail;
    }
    locale = cached_enum_py((int)m->locale, LocaleMembers,
                            MOLI_LOCALE_COUNT, LocaleType);
    if (locale == NULL) {
        goto fail;
    }
    char_class = cached_enum_py((int)m->char_class, CharClassMembers,
                                MOLI_CHARCLASS_COUNT, CharClassType);
    if (char_class == NULL) {
        goto fail;
    }
    cost = PyLong_FromLong((long)m->cost);
    start = PyLong_FromLongLong(m->start);
    end = PyLong_FromLongLong(m->end);
    unknown = PyBool_FromLong(m->is_unknown);
    entry_id = PyLong_FromLong((long)m->entry_id);
    if (cost == NULL || start == NULL || end == NULL || unknown == NULL ||
        entry_id == NULL) {
        goto fail;
    }
    if (MorphemeType != NULL) {
        /* The twelve-field order is stated once, as one tuple; the
         * fast tuple-new path and the type's own positional
         * constructor are two consumers of it, and the typeless
         * fallback packs it directly. */
        PyObject *t = PyTuple_New(12);
        if (t != NULL) {
            PyTuple_SET_ITEM(t, 0, surf);
            PyTuple_SET_ITEM(t, 1, pos);
            PyTuple_SET_ITEM(t, 2, lemma);
            PyTuple_SET_ITEM(t, 3, reading);
            PyTuple_SET_ITEM(t, 4, jyutping);
            PyTuple_SET_ITEM(t, 5, cost);
            PyTuple_SET_ITEM(t, 6, start);
            PyTuple_SET_ITEM(t, 7, end);
            PyTuple_SET_ITEM(t, 8, locale);
            PyTuple_SET_ITEM(t, 9, char_class);
            PyTuple_SET_ITEM(t, 10, unknown);
            PyTuple_SET_ITEM(t, 11, entry_id);
            if (MorphemeTupleNew != NULL) {
                res = PyObject_CallFunctionObjArgs(MorphemeTupleNew,
                                                   MorphemeType, t, NULL);
            } else {
                res = PyObject_CallObject(MorphemeType, t);
            }
            Py_DECREF(t);
            /* the tuple consumed the twelve field references */
            surf = pos = lemma = reading = jyutping = NULL;
            locale = char_class = cost = start = end = NULL;
            unknown = entry_id = NULL;
        }
    } else {
        res = PyTuple_Pack(12, surf, pos, lemma, reading, jyutping,
                           cost, start, end, locale, char_class, unknown,
                           entry_id);
    }
fail:
    Py_XDECREF(surf);
    Py_XDECREF(pos);
    Py_XDECREF(lemma);
    Py_XDECREF(reading);
    Py_XDECREF(jyutping);
    Py_XDECREF(locale);
    Py_XDECREF(char_class);
    Py_XDECREF(cost);
    Py_XDECREF(start);
    Py_XDECREF(end);
    Py_XDECREF(unknown);
    Py_XDECREF(entry_id);
    return res;
}

/* --- Morphemes: the lazy tokenize result ---------------------------- */

/* tokenize() hands back this view instead of a materialized list.
 * The result box is standalone memory (allocated from the default
 * allocator; the calling thread's analysis scratch is not part of it),
 * so the view carries no invalidation semantics and no analyzer
 * coupling — it simply outlives both the analyzer and later calls.
 * len() reads the box count; each index touched builds one Morpheme
 * and caches it (identity is stable, repeated dictionary fields share
 * objects exactly as an eager build would share them); when the last
 * index materializes the box is released, because every field the
 * caller can read then lives in Python objects. A partially-read view
 * frees its box at dealloc — untouched morphemes are never built. */
typedef struct {
    PyObject_HEAD
    Moli_Result r;      /* owned; NULL once the cache is complete */
    const Moli_Morpheme *ms;
    const uint8_t *blob;
    int64_t count;
    PyObject **cache;   /* entry i: materialized Morpheme or NULL */
    int64_t fill;
    StrCache fields;
    /* Guards the once-per-view state below materialize (cache
     * allocation, slot fills, the box release): two threads
     * indexing the same view must not both build. Allocated with the
     * object, freed in dealloc. */
    PyThread_type_lock build_lock;
} MorphemesObject;

static PyTypeObject MorphemesType;

static void morphemes_release_box(MorphemesObject *v)
{
    if (v->r != NULL) {
        /* The blob can be large; release the GIL around the free (the
         * callers hold either the build lock or exclusivity by
         * refcount 0, so the pause is safe). */
        Py_BEGIN_ALLOW_THREADS
        moli_result_free(v->r);
        Py_END_ALLOW_THREADS
        v->r = NULL;
        v->ms = NULL;
        v->blob = NULL;
    }
}

static int morphemes_reserve(MorphemesObject *v)
{
    if (v->cache != NULL) {
        return 0;
    }
    v->cache = PyMem_Calloc((size_t)v->count, sizeof(PyObject *));
    if (v->cache == NULL || strcache_init(&v->fields, v->count) < 0) {
        PyMem_Free(v->cache);
        v->cache = NULL;
        PyErr_NoMemory();
        return -1;
    }
    return 0;
}

static PyObject *morphemes_materialize(MorphemesObject *v, int64_t i)
{
    /* Hit path lock-free: every cache-slot write and the box release
     * happen under the GIL, so a materialized slot read here is
     * stable. Only the first materialization of a slot (or the view)
     * takes the lock. */
    if (v->cache != NULL) {
        PyObject *hit = v->cache[i];
        if (hit != NULL) {
            Py_INCREF(hit);
            return hit;
        }
    }
    Py_BEGIN_ALLOW_THREADS
    PyThread_acquire_lock(v->build_lock, 1);
    Py_END_ALLOW_THREADS
    if (v->cache == NULL && morphemes_reserve(v) < 0) {
        PyThread_release_lock(v->build_lock);
        return NULL;
    }
    PyObject *m = v->cache[i];
    if (m == NULL) {
        m = build_morpheme(&v->ms[i], v->blob, &v->fields);
        if (m == NULL) {
            PyThread_release_lock(v->build_lock);
            return NULL;
        }
        v->cache[i] = m; /* the cache's own reference */
        v->fill++;
        if (v->fill == v->count) {
            /* Nothing left to serve from the box. */
            strcache_fini(&v->fields);
            morphemes_release_box(v);
        }
    }
    PyThread_release_lock(v->build_lock);
    Py_INCREF(m);
    return m;
}

static Py_ssize_t Morphemes_length(MorphemesObject *v)
{
    return (Py_ssize_t)v->count;
}

static PyObject *Morphemes_item(MorphemesObject *v, Py_ssize_t i)
{
    if (i < 0) {
        i += (Py_ssize_t)v->count;
    }
    if (i < 0 || (int64_t)i >= v->count) {
        PyErr_SetString(PyExc_IndexError, "morpheme index out of range");
        return NULL;
    }
    return morphemes_materialize(v, (int64_t)i);
}

static PyObject *Morphemes_subscript(MorphemesObject *v, PyObject *key)
{
    if (PyIndex_Check(key)) {
        Py_ssize_t i = PyNumber_AsSsize_t(key, PyExc_IndexError);
        if (i == -1 && PyErr_Occurred()) {
            return NULL;
        }
        return Morphemes_item(v, i);
    }
    if (PySlice_Check(key)) {
        Py_ssize_t start, stop, step;
        if (PySlice_Unpack(key, &start, &stop, &step) < 0) {
            return NULL;
        }
        Py_ssize_t n = PySlice_AdjustIndices((Py_ssize_t)v->count,
                                             &start, &stop, step);
        PyObject *list = PyList_New(n);
        if (list == NULL) {
            return NULL;
        }
        for (Py_ssize_t k = 0; k < n; k++) {
            PyObject *m = morphemes_materialize(v, (int64_t)(start + k * step));
            if (m == NULL) {
                Py_DECREF(list);
                return NULL;
            }
            PyList_SET_ITEM(list, k, m); /* steals materialize's reference */
        }
        return list;
    }
    PyErr_SetString(PyExc_TypeError,
                    "morphemes indices must be integers or slices");
    return NULL;
}

static int Morphemes_traverse(MorphemesObject *v, visitproc visit, void *arg)
{
    if (v->cache != NULL) {
        for (int64_t i = 0; i < v->count; i++) {
            Py_VISIT(v->cache[i]);
        }
    }
    return 0;
}

static int Morphemes_clear(MorphemesObject *v)
{
    /* While the box is alive the view is re-materializable: drop the
     * built objects and the intern table and restart from the box.
     * After the box's release the cache IS the result — the GC may
     * not discard it (no cycle can involve a view anyway: nothing a
     * view holds can reference back). The build lock is not taken:
     * clear only runs on unreachable views, and no thread can be
     * inside materialize on a view it holds no reference to. */
    if (v->r != NULL) {
        if (v->cache != NULL) {
            for (int64_t i = 0; i < v->count; i++) {
                Py_CLEAR(v->cache[i]);
            }
            v->fill = 0;
        }
        strcache_fini(&v->fields);
    }
    return 0;
}

static void Morphemes_dealloc(MorphemesObject *v)
{
    PyObject_GC_UnTrack(v);
    if (v->cache != NULL) {
        for (int64_t i = 0; i < v->count; i++) {
            Py_XDECREF(v->cache[i]);
        }
        PyMem_Free(v->cache);
    }
    strcache_fini(&v->fields);
    morphemes_release_box(v); /* a partially-read view's untouched remainder */
    if (v->build_lock != NULL) {
        PyThread_free_lock(v->build_lock);
        v->build_lock = NULL;
    }
    Py_TYPE(v)->tp_free((PyObject *)v);
}

static PyObject *Morphemes_repr(MorphemesObject *v)
{
    return PyUnicode_FromFormat("<moli.Morphemes len=%lld materialized=%lld>",
                                (long long)v->count, (long long)v->fill);
}

/* A dedicated iterator over the view: materializes directly instead
 * of round-tripping every index through the subscript protocol, so a
 * full iteration costs the same per-morpheme work as the eager build
 * plus one pointer store. */
typedef struct {
    PyObject_HEAD
    MorphemesObject *v;
    int64_t i;
} MorphemesIterObject;

static PyTypeObject MorphemesIterType;

static void MorphemesIter_dealloc(MorphemesIterObject *it)
{
    PyObject_GC_UnTrack(it);
    Py_XDECREF(it->v);
    Py_TYPE(it)->tp_free((PyObject *)it);
}

static int MorphemesIter_traverse(MorphemesIterObject *it, visitproc visit,
                                  void *arg)
{
    Py_VISIT(it->v);
    return 0;
}

static PyObject *MorphemesIter_next(MorphemesIterObject *it)
{
    if (it->v == NULL || it->i >= it->v->count) {
        return NULL;
    }
    return morphemes_materialize(it->v, it->i++);
}

static PyObject *MorphemesIter_self(MorphemesIterObject *it)
{
    Py_INCREF(it);
    return (PyObject *)it;
}

static PyTypeObject MorphemesIterType = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name = "moli._native.MorphemesIterator",
    .tp_basicsize = sizeof(MorphemesIterObject),
    .tp_dealloc = (destructor)MorphemesIter_dealloc,
    .tp_flags = Py_TPFLAGS_DEFAULT | Py_TPFLAGS_HAVE_GC,
    .tp_doc = "Iterator over moli.Morphemes",
    .tp_traverse = (traverseproc)MorphemesIter_traverse,
    .tp_iter = (getiterfunc)MorphemesIter_self,
    .tp_iternext = (iternextfunc)MorphemesIter_next,
};

static PyObject *Morphemes_iter(MorphemesObject *v)
{
    MorphemesIterObject *it = (MorphemesIterObject *)PyType_GenericAlloc(&MorphemesIterType, 0);
    if (it == NULL) {
        return NULL;
    }
    Py_INCREF(v);
    it->v = v;
    it->i = 0;
    return (PyObject *)it;
}

static PySequenceMethods Morphemes_as_sequence = {
    .sq_length = (lenfunc)Morphemes_length,
    .sq_item = (ssizeargfunc)Morphemes_item,
};

static PyMappingMethods Morphemes_as_mapping = {
    .mp_subscript = (binaryfunc)Morphemes_subscript,
};

static PyTypeObject MorphemesType = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name = "moli._native.Morphemes",
    .tp_basicsize = sizeof(MorphemesObject),
    .tp_dealloc = (destructor)Morphemes_dealloc,
    .tp_repr = (reprfunc)Morphemes_repr,
    .tp_as_sequence = &Morphemes_as_sequence,
    .tp_as_mapping = &Morphemes_as_mapping,
    .tp_flags = Py_TPFLAGS_DEFAULT | Py_TPFLAGS_HAVE_GC |
                Py_TPFLAGS_DISALLOW_INSTANTIATION,
    .tp_doc = "Lazy immutable Sequence[Morpheme] over one tokenize result:\n"
              "len() is free, indices and slices materialize Morpheme values\n"
              "on access (cached, identity-stable), full materialization\n"
              "releases the native result. Views are standalone: no lifetime\n"
              "coupling to the analyzer or to later calls.",
    .tp_traverse = (traverseproc)Morphemes_traverse,
    .tp_clear = (inquiry)Morphemes_clear,
    .tp_iter = (getiterfunc)Morphemes_iter,
};

/* Takes ownership of r (released here or when the last morpheme
 * materializes). */
static PyObject *build_morph_view(Moli_Result r)
{
    MorphemesObject *v = (MorphemesObject *)PyType_GenericAlloc(&MorphemesType, 0);
    if (v == NULL) {
        moli_result_free(r);
        return NULL;
    }
    /* With the object, never at use time: materialize's locking must
     * not depend on a late allocation succeeding. */
    v->build_lock = PyThread_allocate_lock();
    if (v->build_lock == NULL) {
        moli_result_free(r);
        Py_DECREF(v);
        return PyErr_NoMemory();
    }
    v->r = r;
    v->count = moli_result_count(r);
    v->ms = moli_result_morphemes(r);
    v->blob = moli_result_blob(r);
    if (v->count == 0) {
        /* Nothing can ever materialize: release the box now. */
        morphemes_release_box(v);
    }
    return (PyObject *)v;
}

/* Wakachi: only the surface is meaningful. */
static PyObject *build_surface_list(Moli_Result r)
{
    int64_t n = moli_result_count(r);
    const Moli_Morpheme *ms = moli_result_morphemes(r);
    const uint8_t *blob = moli_result_blob(r);
    PyObject *list = PyList_New((Py_ssize_t)n);
    if (list == NULL) {
        return NULL;
    }
    for (int64_t i = 0; i < n; i++) {
        PyObject *s = decode_field(blob + ms[i].surf_off, ms[i].surf_len);
        if (s == NULL) {
            Py_DECREF(list);
            return NULL;
        }
        PyList_SET_ITEM(list, (Py_ssize_t)i, s);
    }
    return list;
}

/* One string from every surface joined with single spaces — the
 * wakati presentation. Assembled as raw UTF-8 and decoded once with
 * the same surrogateescape rule as the per-field decoders, so
 * malformed input yields exactly what ' '.join(wakachi(text)) builds
 * piecewise. */
static PyObject *build_joined(Moli_Result r)
{
    int64_t n = moli_result_count(r);
    const Moli_Morpheme *ms = moli_result_morphemes(r);
    const uint8_t *blob = moli_result_blob(r);
    int64_t total = 0;
    for (int64_t i = 0; i < n; i++) {
        total += ms[i].surf_len;
    }
    if (n > 1) {
        total += n - 1; /* spaces */
    }
    char *buf = (char *)PyMem_Malloc((Py_ssize_t)(total > 0 ? total : 1));
    if (buf == NULL) {
        return PyErr_NoMemory();
    }
    int64_t off = 0;
    for (int64_t i = 0; i < n; i++) {
        if (i > 0) {
            buf[off++] = ' ';
        }
        if (ms[i].surf_len > 0) {
            memcpy(buf + off, blob + ms[i].surf_off, (size_t)ms[i].surf_len);
            off += ms[i].surf_len;
        }
    }
    PyObject *res = PyUnicode_DecodeUTF8(buf, (Py_ssize_t)off, "surrogateescape");
    PyMem_Free(buf);
    return res;
}

/* One TSV string in the MeCab dump shape: per morpheme surface, pos,
 * lemma, reading, reading_jyutping joined by tabs, lines joined by
 * newlines, no trailing newline. Same assemble-then-decode-once rule
 * as build_joined. */
static PyObject *build_parse(Moli_Result r)
{
    int64_t n = moli_result_count(r);
    const Moli_Morpheme *ms = moli_result_morphemes(r);
    const uint8_t *blob = moli_result_blob(r);
    int64_t total = 0;
    for (int64_t i = 0; i < n; i++) {
        total += ms[i].surf_len + ms[i].pos_len + ms[i].lemma_len +
                 ms[i].reading_len + ms[i].jyutping_len + 4; /* tabs */
    }
    if (n > 1) {
        total += n - 1; /* newlines */
    }
    char *buf = (char *)PyMem_Malloc((Py_ssize_t)(total > 0 ? total : 1));
    if (buf == NULL) {
        return PyErr_NoMemory();
    }
    int64_t off = 0;
    for (int64_t i = 0; i < n; i++) {
        if (i > 0) {
            buf[off++] = '\n';
        }
        const int32_t field_off[5] = {ms[i].surf_off, ms[i].pos_off,
                                      ms[i].lemma_off, ms[i].reading_off,
                                      ms[i].jyutping_off};
        const int32_t field_len[5] = {ms[i].surf_len, ms[i].pos_len,
                                      ms[i].lemma_len, ms[i].reading_len,
                                      ms[i].jyutping_len};
        for (int k = 0; k < 5; k++) {
            if (k > 0) {
                buf[off++] = '\t';
            }
            if (field_len[k] > 0) {
                memcpy(buf + off, blob + field_off[k], (size_t)field_len[k]);
                off += field_len[k];
            }
        }
    }
    PyObject *res = PyUnicode_DecodeUTF8(buf, (Py_ssize_t)off, "surrogateescape");
    PyMem_Free(buf);
    return res;
}

/* Spans: surface + byte offsets. Span field order: surface, start, end. */
static PyObject *build_span_list(Moli_Result r)
{
    int64_t n = moli_result_count(r);
    const Moli_Morpheme *ms = moli_result_morphemes(r);
    const uint8_t *blob = moli_result_blob(r);
    PyObject *list = PyList_New((Py_ssize_t)n);
    if (list == NULL) {
        return NULL;
    }
    for (int64_t i = 0; i < n; i++) {
        PyObject *s = decode_field(blob + ms[i].surf_off, ms[i].surf_len);
        PyObject *start = NULL, *end = NULL, *span = NULL;
        if (s == NULL) {
            Py_DECREF(list);
            return NULL;
        }
        start = PyLong_FromLongLong(ms[i].start);
        end = PyLong_FromLongLong(ms[i].end);
        if (start == NULL || end == NULL) {
            Py_DECREF(s);
            Py_XDECREF(start);
            Py_XDECREF(end);
            Py_DECREF(list);
            return NULL;
        }
        if (SpanType != NULL) {
            span = PyObject_CallFunctionObjArgs(SpanType, s, start, end, NULL);
        } else {
            span = PyTuple_Pack(3, s, start, end);
        }
        Py_DECREF(s);
        Py_DECREF(start);
        Py_DECREF(end);
        if (span == NULL) {
            Py_DECREF(list);
            return NULL;
        }
        PyList_SET_ITEM(list, (Py_ssize_t)i, span);
    }
    return list;
}

/* N-best: each path is (cost, morphemes[first : first+count]).
 * NBestPath field order: cost, morphemes. */
static PyObject *build_nbest(Moli_Result r)
{
    int64_t n_paths = moli_result_paths_count(r);
    const Moli_Path *paths = moli_result_paths(r);
    const Moli_Morpheme *ms = moli_result_morphemes(r);
    int64_t n_morphs = moli_result_count(r);
    const uint8_t *blob = moli_result_blob(r);
    PyObject *list = PyList_New((Py_ssize_t)n_paths);
    if (list == NULL) {
        return NULL;
    }
    StrCache cache;
    if (strcache_init(&cache, n_morphs) < 0) {
        Py_DECREF(list);
        return PyErr_NoMemory();
    }
    for (int64_t i = 0; i < n_paths; i++) {
        const Moli_Path *p = &paths[i];
        if (p->first < 0 || (int64_t)p->first + (int64_t)p->count > n_morphs) {
            PyErr_SetString(PyExc_RuntimeError, "nbest path range out of bounds");
            goto fail;
        }
        PyObject *morphs = PyList_New((Py_ssize_t)p->count);
        if (morphs == NULL) {
            goto fail;
        }
        for (int32_t j = 0; j < p->count; j++) {
            PyObject *m = build_morpheme(&ms[p->first + j], blob, &cache);
            if (m == NULL) {
                Py_DECREF(morphs);
                goto fail;
            }
            PyList_SET_ITEM(morphs, (Py_ssize_t)j, m);
        }
        PyObject *cost = PyLong_FromLongLong(p->cost);
        PyObject *path = NULL;
        if (cost == NULL) {
            Py_DECREF(morphs);
            goto fail;
        }
        if (NBestPathType != NULL) {
            path = PyObject_CallFunctionObjArgs(NBestPathType, cost, morphs, NULL);
        } else {
            path = PyTuple_Pack(2, cost, morphs);
        }
        Py_DECREF(cost);
        Py_DECREF(morphs);
        if (path == NULL) {
            goto fail;
        }
        PyList_SET_ITEM(list, (Py_ssize_t)i, path);
    }
    strcache_fini(&cache);
    return list;
fail:
    strcache_fini(&cache);
    Py_DECREF(list);
    return NULL;
}

/* --- CancelToken C type (defined first: the tokenize option parser
 *     needs the type check) ------------------------------------------ */

typedef struct {
    PyObject_HEAD
    Moli_Cancel c;
} CancelObject;

static PyTypeObject CancelType;

static int Cancel_traverse(CancelObject *self, visitproc visit, void *arg)
{
    return 0; /* no Python references held */
}

static int Cancel_clear(CancelObject *self)
{
    return 0;
}

static void Cancel_dealloc(CancelObject *self)
{
    PyObject_GC_UnTrack(self);
    if (self->c != NULL) {
        moli_cancel_free(self->c);
        self->c = NULL;
    }
    Py_TYPE(self)->tp_free((PyObject *)self);
}

static PyObject *Cancel_cancel(CancelObject *self, PyObject *Py_UNUSED(ignored))
{
    if (self->c != NULL) {
        moli_cancel(self->c);
    }
    Py_RETURN_NONE;
}

static PyObject *Cancel_repr(CancelObject *self)
{
    if (self->c != NULL) {
        return PyUnicode_FromString("<moli.CancelToken>");
    }
    return PyUnicode_FromString("<moli.CancelToken (freed)>");
}

static PyMethodDef Cancel_methods[] = {
    {"cancel", (PyCFunction)Cancel_cancel, METH_NOARGS,
     "cancel() -> None (one-way; a spent token keeps working)"},
    {NULL, NULL, 0, NULL},
};

static PyTypeObject CancelType = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name = "moli._native.CancelToken",
    .tp_basicsize = sizeof(CancelObject),
    .tp_dealloc = (destructor)Cancel_dealloc,
    .tp_repr = (reprfunc)Cancel_repr,
    /* GC is required for the managed-weakref pre-header in 3.12. */
    .tp_flags = Py_TPFLAGS_DEFAULT | Py_TPFLAGS_HAVE_GC | Py_TPFLAGS_MANAGED_WEAKREF,
    .tp_doc = "One-way cancellation token",
    .tp_traverse = (traverseproc)Cancel_traverse,
    .tp_clear = (inquiry)Cancel_clear,
    .tp_methods = Cancel_methods,
};

/* --- Analyzer C type ------------------------------------------------ */

/* The drain: a mutex + condition variable guarding closing/in_flight
 * and letting close sleep until every in-flight call has exited.
 * in_flight transitions happen while the caller holds the GIL, but
 * close reads the pair with no interpreter lock held, so the mutex —
 * not the GIL — is what makes them atomic. */
#if defined(_WIN32)
typedef struct {
    SRWLOCK mutex;
    CONDITION_VARIABLE cond;
} Drain;

static int drain_init(Drain *d)
{
    InitializeSRWLock(&d->mutex);
    InitializeConditionVariable(&d->cond);
    return 0;
}

static void drain_destroy(Drain *d)
{
    /* SRWLOCK and CONDITION VARIABLE need no explicit destroy. */
    (void)d;
}

static void drain_lock(Drain *d)   { AcquireSRWLockExclusive(&d->mutex); }
static void drain_unlock(Drain *d) { ReleaseSRWLockExclusive(&d->mutex); }
/* Returns with the mutex held; spurious wakeups are re-checked by the
 * caller's loop. */
static void drain_wait(Drain *d)   { SleepConditionVariableSRW(&d->cond, &d->mutex, INFINITE, 0); }
static void drain_signal(Drain *d) { WakeConditionVariable(&d->cond); }
#else
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} Drain;

static int drain_init(Drain *d)
{
    if (pthread_mutex_init(&d->mutex, NULL) != 0) {
        return -1;
    }
    if (pthread_cond_init(&d->cond, NULL) != 0) {
        pthread_mutex_destroy(&d->mutex);
        return -1;
    }
    return 0;
}

static void drain_destroy(Drain *d)
{
    pthread_mutex_destroy(&d->mutex);
    pthread_cond_destroy(&d->cond);
}

static void drain_lock(Drain *d)   { pthread_mutex_lock(&d->mutex); }
static void drain_unlock(Drain *d) { pthread_mutex_unlock(&d->mutex); }
static void drain_wait(Drain *d)   { pthread_cond_wait(&d->cond, &d->mutex); }
static void drain_signal(Drain *d) { pthread_cond_signal(&d->cond); }
#endif

typedef struct {
    PyObject_HEAD
    Moli_Handle h;
    int closed;
    /* Wrapper-side drain: the library's own free drains calls that
     * reached it, but a call that released the GIL before entering
     * the ABI would touch freed handle memory if free completed
     * first. `closing` fences new entries; `in_flight` lets close
     * wait out the calls already inside. Both live under the drain
     * mutex (closing is also only ever set with the GIL held), and
     * close nulls h under the same mutex, so !closing implies a live
     * handle — the bracket hands each call the handle it captures
     * there, and no call site reads the field after releasing the
     * GIL. */
    int closing;
    Py_ssize_t in_flight;
    Drain drain;
    int drain_ready; /* drain_init succeeded; only free_locks destroys */
    /* Allocated with the object (never NULL afterwards): the mut lock
     * serializes stats and add_user_entries, the calls that rewrite
     * per-handle scratch or mutate the analyzer (the core's swap
     * protocol assumes a single mutating caller). */
    PyThread_type_lock mut_lock;
} AnalyzerObject;

static PyTypeObject AnalyzerType;

static int analyzer_is_open(AnalyzerObject *self)
{
    return self->h != NULL && !self->closed && !self->closing;
}

/* Allocate the wrapper's drain and mut lock with the object, before
 * any handle is attached: close()'s wait must never face an
 * uninitialized drain, and a failure here raises while cleanup is
 * still trivial. */
static int analyzer_alloc_locks(AnalyzerObject *a)
{
    if (drain_init(&a->drain) < 0) {
        PyErr_NoMemory();
        return -1;
    }
    a->drain_ready = 1;
    a->mut_lock = PyThread_allocate_lock();
    if (a->mut_lock == NULL) {
        PyErr_NoMemory();
        return -1;
    }
    return 0;
}

/* The single owner of the drain destroy (drain_ready): a failed
 * analyzer_alloc_locks must not leave a second destroy behind —
 * drain_init's rollback and this pair are the whole lifecycle. */
static void analyzer_free_locks(AnalyzerObject *a)
{
    if (a->drain_ready) {
        drain_destroy(&a->drain);
        a->drain_ready = 0;
    }
    if (a->mut_lock != NULL) {
        PyThread_free_lock(a->mut_lock);
        a->mut_lock = NULL;
    }
}

/* Every handle call brackets its ABI call with this pair (one
 * definition instead of per-site in_flight edits): enter refuses once
 * close has claimed the handle (raising the closed exception) and
 * hands the call the handle it captured under the drain mutex — the
 * one point where the handle is guaranteed unclaimed, so a close
 * claiming while the caller is GIL-released can never turn an
 * admitted call into a nil-handle call. exit decrements and wakes
 * close's wait. NULL = refused, exception already raised. */
static Moli_Handle analyzer_call_enter(AnalyzerObject *a)
{
    drain_lock(&a->drain);
    if (a->closing) {
        drain_unlock(&a->drain);
        closed_guard_failed();
        return NULL;
    }
    a->in_flight++;
    Moli_Handle h = a->h;
    drain_unlock(&a->drain);
    return h;
}

static void analyzer_call_exit(AnalyzerObject *a)
{
    drain_lock(&a->drain);
    a->in_flight--;
    drain_signal(&a->drain);
    drain_unlock(&a->drain);
}

static PyObject *Analyzer_close(AnalyzerObject *self, PyObject *Py_UNUSED(ignored))
{
    Moli_Handle h = self->h;
    if (h != NULL) {
        /* Claim the handle and fence new calls under the drain mutex
         * (with the GIL also held): a concurrent close sees h == NULL
         * and becomes a no-op instead of a second free. Then wait out
         * the in-flight calls on the condition variable — signals,
         * not polling, no interpreter lock held — and free. The
         * library's own drain covers calls that reached it; this
         * bracket covers the window between a call releasing the GIL
         * and entering the ABI. */
        drain_lock(&self->drain);
        self->closing = 1;
        self->h = NULL;
        drain_unlock(&self->drain);
        Py_BEGIN_ALLOW_THREADS
        drain_lock(&self->drain);
        while (self->in_flight > 0) {
            drain_wait(&self->drain);
        }
        drain_unlock(&self->drain);
        moli_free(h);
        Py_END_ALLOW_THREADS
        self->closed = 1;
    }
    Py_RETURN_NONE;
}

static int Analyzer_traverse(AnalyzerObject *self, visitproc visit, void *arg)
{
    return 0; /* no Python references held */
}

static int Analyzer_clear(AnalyzerObject *self)
{
    return 0;
}

static void Analyzer_dealloc(AnalyzerObject *self)
{
    PyObject_GC_UnTrack(self);
    if (self->h != NULL) {
        /* No in-flight calls can exist at refcount 0, but the free is
         * dictionary-scale — the same GIL-release the policy grants
         * close's drain applies here. */
        Py_BEGIN_ALLOW_THREADS
        moli_free(self->h);
        Py_END_ALLOW_THREADS
        self->h = NULL;
    }
    analyzer_free_locks(self);
    Py_TYPE(self)->tp_free((PyObject *)self);
}

static PyObject *Analyzer_repr(AnalyzerObject *self)
{
    if (analyzer_is_open(self)) {
        return PyUnicode_FromString("<moli.Analyzer (open)>");
    }
    return PyUnicode_FromString("<moli.Analyzer (closed)>");
}

static PyObject *Analyzer_enter(AnalyzerObject *self, PyObject *Py_UNUSED(ignored))
{
    if (!analyzer_is_open(self)) {
        return closed_guard_failed();
    }
    Py_INCREF(self);
    return (PyObject *)self;
}

static PyObject *Analyzer_exit(AnalyzerObject *self, PyObject *Py_UNUSED(ignored))
{
    return Analyzer_close(self, NULL);
}

enum { KIND_MORPHS = 0, KIND_WAKACHI = 1, KIND_SPANS = 2, KIND_NBEST = 3,
       KIND_WAKATI = 4, KIND_PARSE = 5, KIND_CONSTRAINED = 6 };

/* Fills the tokenize options from already-parsed values; the cancel
 * object's type is validated here so every method shares one rule. */
static int fill_tok_opts(Moli_Tokenize_Options *opts, PyObject *cancel,
                         int bias, int per_rune, int nfc, int strict)
{
    memset(opts, 0, sizeof(*opts));
    opts->unk_cost_bias = (int32_t)bias;
    opts->unk_cost_per_rune = (int32_t)per_rune;
    opts->normalize_nfc = (uint8_t)(nfc != 0);
    opts->strict_utf8 = (uint8_t)(strict != 0);
    if (cancel != Py_None) {
        if (!PyObject_TypeCheck(cancel, &CancelType)) {
            PyErr_SetString(PyExc_TypeError, "cancel must be a moli.CancelToken");
            return -1;
        }
        opts->cancel = ((CancelObject *)cancel)->c;
    }
    return 0;
}

/* Per-kind result assembly: which builder turns the result box into a
 * Python object, and whether the view keeps the box (the morpheme
 * view is lazy over it; every other shape copies out and the box dies
 * in the worker). The ownership rule rides the same row as the
 * builder, as data. KIND_CONSTRAINED never reaches this table -
 * analyze_method routes it to constrained_worker - and its row is
 * only there so the array covers the kind enum. */
typedef struct {
    PyObject *(*build)(Moli_Result r);
    int keeps_result;
} Kind_Build;

static const Kind_Build kind_build[] = {
    [KIND_MORPHS]      = {build_morph_view, 1},
    [KIND_WAKACHI]     = {build_surface_list, 0},
    [KIND_SPANS]       = {build_span_list, 0},
    [KIND_NBEST]       = {build_nbest, 0},
    [KIND_WAKATI]      = {build_joined, 0},
    [KIND_PARSE]       = {build_parse, 0},
    [KIND_CONSTRAINED] = {build_morph_view, 0},
};

static PyObject *tokenize_worker(AnalyzerObject *self, PyObject *text_obj,
                                 Moli_Tokenize_Options *opts, int kind, int k)
{
    const uint8_t *text = NULL;
    int64_t text_len = 0;
    if (text_arg(text_obj, &text, &text_len) < 0) {
        return NULL;
    }

    Moli_Err err;
    memset(&err, 0, sizeof(err));
    Moli_Result r = NULL;
    Moli_Handle h = analyzer_call_enter(self);
    if (h == NULL) {
        return NULL;
    }
    Py_BEGIN_ALLOW_THREADS
    switch (kind) {
    case KIND_MORPHS:   r = moli_tokenize(h, text, text_len, opts, &err); break;
    case KIND_WAKACHI:  r = moli_wakachi(h, text, text_len, opts, &err); break;
    case KIND_WAKATI:   r = moli_wakachi(h, text, text_len, opts, &err); break;
    case KIND_SPANS:    r = moli_spans(h, text, text_len, opts, &err); break;
    case KIND_PARSE:    r = moli_tokenize(h, text, text_len, opts, &err); break;
    default:            r = moli_nbest(h, text, text_len, (int32_t)k, opts, &err); break;
    }
    Py_END_ALLOW_THREADS
    analyzer_call_exit(self);

    if (r == NULL) {
        raise_moli_err(&err);
        return NULL;
    }

    PyObject *res = kind_build[kind].build(r);
    if (!kind_build[kind].keeps_result) {
        /* The blob can be large; the policy releases the GIL around
         * this ABI free like every other. */
        Py_BEGIN_ALLOW_THREADS
        moli_result_free(r);
        Py_END_ALLOW_THREADS
    }
    return res;
}

/* The tokenize family shares one keyword surface, parsed here from
 * the FASTCALL convention (args[nargs ..] pair with the kwnames
 * entries) instead of an args tuple + kwargs dict + format string. */
typedef struct {
    PyObject *text;
    PyObject *cancel;
    PyObject *tokens;      /* KIND_CONSTRAINED only; NULL = none */
    PyObject *boundaries;  /* KIND_CONSTRAINED only; NULL = none */
    int k, bias, per_rune, nfc, strict;
} TokArgs;

static int tok_arg_int(PyObject *v, int *out)
{
    long n = PyLong_AsLong(v);
    if (n == -1 && PyErr_Occurred()) {
        return -1;
    }
    if (n < INT_MIN || n > INT_MAX) {
        PyErr_SetString(PyExc_OverflowError, "int argument out of range");
        return -1;
    }
    *out = (int)n;
    return 0;
}

static int parse_tok_args(int kind, PyObject *const *args, Py_ssize_t nargs,
                          PyObject *kwnames, TokArgs *out)
{
    PyObject *names[8];
    PyObject *slots[8];
    unsigned char given[8];
    int nparams;

    if (kind == KIND_NBEST) {
        nparams = 7;
        names[0] = KwText;    names[1] = KwK;      names[2] = KwBias;
        names[3] = KwPerRune; names[4] = KwNfc;    names[5] = KwStrict;
        names[6] = KwCancel;
    } else if (kind == KIND_CONSTRAINED) {
        nparams = 8;
        names[0] = KwText;      names[1] = KwTokens;    names[2] = KwBoundaries;
        names[3] = KwBias;      names[4] = KwPerRune;   names[5] = KwNfc;
        names[6] = KwStrict;    names[7] = KwCancel;
    } else {
        nparams = 6;
        names[0] = KwText;    names[1] = KwBias;   names[2] = KwPerRune;
        names[3] = KwNfc;     names[4] = KwStrict; names[5] = KwCancel;
    }
    Py_ssize_t nkw = (kwnames == NULL) ? 0 : PyTuple_GET_SIZE(kwnames);
    /* The docstrings pin the option parameters as keyword-only; the
     * parser enforces the same line: only the parameters before the
     * '*' in each signature may arrive positionally. */
    int npos = (kind == KIND_CONSTRAINED) ? 3 : (kind == KIND_NBEST) ? 2 : 1;
    if (nargs > npos) {
        PyErr_Format(PyExc_TypeError,
                     "takes at most %d positional argument%s "
                     "(the remaining parameters are keyword-only)",
                     npos, npos == 1 ? "" : "s");
        return -1;
    }
    if (nargs + nkw > nparams) {
        PyErr_Format(PyExc_TypeError,
                     "function takes at most %d argument%s (%zd given)",
                     nparams, nparams == 1 ? "" : "s", nargs + nkw);
        return -1;
    }
    memset(given, 0, sizeof(given));
    for (Py_ssize_t i = 0; i < nargs; i++) {
        slots[i] = args[i];
        given[i] = 1;
    }
    for (Py_ssize_t j = 0; j < nkw; j++) {
        PyObject *name = PyTuple_GET_ITEM(kwnames, j);
        int slot = -1;
        for (int s = 0; s < nparams; s++) {
            if (name == names[s]) {
                slot = s;
                break;
            }
        }
        if (slot < 0) {
            /* Equal-but-not-interned keyword names are possible via
             * **kwargs; a content match covers them. */
            for (int s = 0; s < nparams; s++) {
                if (names[s] != NULL && PyUnicode_Compare(name, names[s]) == 0) {
                    slot = s;
                    break;
                }
            }
        }
        if (slot < 0) {
            PyErr_Format(PyExc_TypeError,
                         "got an unexpected keyword argument '%S'", name);
            return -1;
        }
        if (given[slot]) {
            PyErr_Format(PyExc_TypeError,
                         "argument '%S' given by name and position", name);
            return -1;
        }
        slots[slot] = args[nargs + j];
        given[slot] = 1;
    }
    if (!given[0]) {
        PyErr_Format(PyExc_TypeError, "missing required argument '%S'",
                     names[0] != NULL ? names[0] : Py_None);
        return -1;
    }
    out->text = slots[0];
    out->cancel = Py_None;
    out->tokens = NULL;
    out->boundaries = NULL;
    out->k = 1;
    out->bias = 0;
    out->per_rune = 0;
    out->nfc = 0;
    out->strict = 0;
    int i_bias = (kind == KIND_CONSTRAINED) ? 3 : (kind == KIND_NBEST) ? 2 : 1;
    if (kind == KIND_CONSTRAINED) {
        if (given[1] && slots[1] != Py_None) {
            out->tokens = slots[1];
        }
        if (given[2] && slots[2] != Py_None) {
            out->boundaries = slots[2];
        }
    }
    if (kind == KIND_NBEST && given[1] && tok_arg_int(slots[1], &out->k) < 0) {
        return -1;
    }
    if (given[i_bias] && tok_arg_int(slots[i_bias], &out->bias) < 0) {
        return -1;
    }
    if (given[i_bias + 1] && tok_arg_int(slots[i_bias + 1], &out->per_rune) < 0) {
        return -1;
    }
    if (given[i_bias + 2]) {
        int b = PyObject_IsTrue(slots[i_bias + 2]);
        if (b < 0) {
            return -1;
        }
        out->nfc = b;
    }
    if (given[i_bias + 3]) {
        int b = PyObject_IsTrue(slots[i_bias + 3]);
        if (b < 0) {
            return -1;
        }
        out->strict = b;
    }
    if (given[i_bias + 4]) {
        out->cancel = slots[i_bias + 4];
    }
    return 0;
}

/* Constrained analysis: same keyword surface as tokenize plus the two
 * constraint sequences. tokens items are (start, end[, pos]) with pos
 * a str POS-column prefix ("" or None = any POS); boundaries items are
 * (at, must_exist). Offsets are values copied into the arrays; the pos
 * strings are held strongly until the call returns (a materialized
 * parts list would otherwise free a fresh str with its last
 * reference, mid-loop). */
static PyObject *constrained_worker(AnalyzerObject *self, TokArgs *ta)
{
    const uint8_t *text = NULL;
    int64_t text_len = 0;
    if (text_arg(ta->text, &text, &text_len) < 0) {
        return NULL;
    }

    PyObject *tok_fast = NULL, *bnd_fast = NULL;
    Moli_Token_Constraint *toks = NULL;
    Moli_Boundary_Constraint *bounds = NULL;
    Py_ssize_t n_toks = 0, n_bounds = 0;
    RefHold pos_hold;
    if (refhold_init(&pos_hold, 8) < 0) {
        return NULL;
    }

    if (ta->tokens != NULL) {
        tok_fast = PySequence_Fast(ta->tokens, "tokens must be a sequence");
        if (tok_fast == NULL) {
            goto fail;
        }
        n_toks = PySequence_Fast_GET_SIZE(tok_fast);
        if (n_toks > 0) {
            toks = PyMem_Malloc(sizeof(Moli_Token_Constraint) * (size_t)n_toks);
            if (toks == NULL) {
                PyErr_NoMemory();
                goto fail;
            }
            for (Py_ssize_t i = 0; i < n_toks; i++) {
                PyObject *item = PySequence_Fast_GET_ITEM(tok_fast, i);
                PyObject *parts = PySequence_Fast(item, "token constraints must be (start, end[, pos])");
                if (parts == NULL) {
                    goto fail;
                }
                Py_ssize_t np = PySequence_Fast_GET_SIZE(parts);
                if (np < 2 || np > 3) {
                    Py_DECREF(parts);
                    PyErr_SetString(PyExc_ValueError, "token constraints must be (start, end[, pos])");
                    goto fail;
                }
                long long start = PyLong_AsLongLong(PySequence_Fast_GET_ITEM(parts, 0));
                long long end = PyLong_AsLongLong(PySequence_Fast_GET_ITEM(parts, 1));
                if (PyErr_Occurred()) {
                    Py_DECREF(parts);
                    goto fail;
                }
                const char *pos = NULL;
                if (np == 3) {
                    PyObject *pobj = PySequence_Fast_GET_ITEM(parts, 2);
                    if (pobj != Py_None) {
                        pos = held_utf8(pobj, &pos_hold, "token constraint pos");
                        if (pos == NULL) {
                            Py_DECREF(parts);
                            goto fail;
                        }
                    }
                }
                toks[i].start = (int64_t)start;
                toks[i].end = (int64_t)end;
                toks[i].pos = pos;
                Py_DECREF(parts);
            }
        }
    }
    if (ta->boundaries != NULL) {
        bnd_fast = PySequence_Fast(ta->boundaries, "boundaries must be a sequence");
        if (bnd_fast == NULL) {
            goto fail;
        }
        n_bounds = PySequence_Fast_GET_SIZE(bnd_fast);
        if (n_bounds > 0) {
            bounds = PyMem_Malloc(sizeof(Moli_Boundary_Constraint) * (size_t)n_bounds);
            if (bounds == NULL) {
                PyErr_NoMemory();
                goto fail;
            }
            for (Py_ssize_t i = 0; i < n_bounds; i++) {
                PyObject *item = PySequence_Fast_GET_ITEM(bnd_fast, i);
                PyObject *parts = PySequence_Fast(item, "boundary constraints must be (at, must_exist)");
                if (parts == NULL) {
                    goto fail;
                }
                if (PySequence_Fast_GET_SIZE(parts) != 2) {
                    Py_DECREF(parts);
                    PyErr_SetString(PyExc_ValueError, "boundary constraints must be (at, must_exist)");
                    goto fail;
                }
                long long at = PyLong_AsLongLong(PySequence_Fast_GET_ITEM(parts, 0));
                if (PyErr_Occurred()) {
                    Py_DECREF(parts);
                    goto fail;
                }
                int must = PyObject_IsTrue(PySequence_Fast_GET_ITEM(parts, 1));
                if (must < 0) {
                    Py_DECREF(parts);
                    goto fail;
                }
                bounds[i].at = (int64_t)at;
                bounds[i].must_exist = (uint8_t)(must != 0);
                Py_DECREF(parts);
            }
        }
    }

    Moli_Tokenize_Options opts;
    if (fill_tok_opts(&opts, ta->cancel, ta->bias, ta->per_rune, ta->nfc, ta->strict) < 0) {
        goto fail;
    }

    Moli_Err err;
    memset(&err, 0, sizeof(err));
    Moli_Result r = NULL;
    Moli_Handle h = analyzer_call_enter(self);
    if (h == NULL) {
        goto fail;
    }
    Py_BEGIN_ALLOW_THREADS
    r = moli_tokenize_constrained(h, text, text_len,
                                  toks, (int64_t)n_toks,
                                  bounds, (int64_t)n_bounds, &opts, &err);
    Py_END_ALLOW_THREADS
    analyzer_call_exit(self);

    PyMem_Free(toks);
    PyMem_Free(bounds);
    Py_XDECREF(tok_fast);
    Py_XDECREF(bnd_fast);
    refhold_fini(&pos_hold);
    if (r == NULL) {
        raise_moli_err(&err);
        return NULL;
    }
    return build_morph_view(r); /* owns r from here */

fail:
    PyMem_Free(toks);
    PyMem_Free(bounds);
    Py_XDECREF(tok_fast);
    Py_XDECREF(bnd_fast);
    refhold_fini(&pos_hold);
    return NULL;
}

static PyObject *analyze_method(AnalyzerObject *self, PyObject *const *args,
                                Py_ssize_t nargs, PyObject *kwnames, int kind)
{
    if (!analyzer_is_open(self)) {
        return closed_guard_failed();
    }
    TokArgs ta;
    if (parse_tok_args(kind, args, nargs, kwnames, &ta) < 0) {
        return NULL;
    }
    if (kind == KIND_NBEST && ta.k < 1) {
        ta.k = 1;
    }
    if (kind == KIND_CONSTRAINED) {
        return constrained_worker(self, &ta);
    }
    Moli_Tokenize_Options opts;
    if (fill_tok_opts(&opts, ta.cancel, ta.bias, ta.per_rune, ta.nfc, ta.strict) < 0) {
        return NULL;
    }
    return tokenize_worker(self, ta.text, &opts, kind, ta.k);
}

static PyObject *Analyzer_tokenize_constrained(AnalyzerObject *self, PyObject *const *args,
                                               Py_ssize_t nargs, PyObject *kwnames)
{
    return analyze_method(self, args, nargs, kwnames, KIND_CONSTRAINED);
}

static PyObject *Analyzer_tokenize(AnalyzerObject *self, PyObject *const *args,
                                   Py_ssize_t nargs, PyObject *kwnames)
{
    return analyze_method(self, args, nargs, kwnames, KIND_MORPHS);
}

static PyObject *Analyzer_wakachi(AnalyzerObject *self, PyObject *const *args,
                                  Py_ssize_t nargs, PyObject *kwnames)
{
    return analyze_method(self, args, nargs, kwnames, KIND_WAKACHI);
}

static PyObject *Analyzer_wakati(AnalyzerObject *self, PyObject *const *args,
                                 Py_ssize_t nargs, PyObject *kwnames)
{
    return analyze_method(self, args, nargs, kwnames, KIND_WAKATI);
}

static PyObject *Analyzer_parse(AnalyzerObject *self, PyObject *const *args,
                                Py_ssize_t nargs, PyObject *kwnames)
{
    return analyze_method(self, args, nargs, kwnames, KIND_PARSE);
}

static PyObject *Analyzer_spans(AnalyzerObject *self, PyObject *const *args,
                                Py_ssize_t nargs, PyObject *kwnames)
{
    return analyze_method(self, args, nargs, kwnames, KIND_SPANS);
}

static PyObject *Analyzer_nbest(AnalyzerObject *self, PyObject *const *args,
                                Py_ssize_t nargs, PyObject *kwnames)
{
    return analyze_method(self, args, nargs, kwnames, KIND_NBEST);
}

static PyObject *Analyzer_classify_locale(AnalyzerObject *self, PyObject *args)
{
    if (!analyzer_is_open(self)) {
        return closed_guard_failed();
    }
    PyObject *text = NULL;
    if (!PyArg_ParseTuple(args, "O", &text)) {
        return NULL;
    }
    const uint8_t *p = NULL;
    int64_t n = 0;
    if (text_arg(text, &p, &n) < 0) {
        return NULL;
    }
    /* Classification scans the whole text (one contains_ci per
     * spelling variant, one rune pass for Chinese), so it takes the
     * same GIL-release bracket as the tokenize family. */
    uint8_t loc;
    Moli_Handle h = analyzer_call_enter(self);
    if (h == NULL) {
        return NULL;
    }
    Py_BEGIN_ALLOW_THREADS
    loc = moli_classify_locale(h, p, n);
    Py_END_ALLOW_THREADS
    analyzer_call_exit(self);
    return cached_enum_py((int)loc, LocaleMembers, MOLI_LOCALE_COUNT, LocaleType);
}

static PyObject *Analyzer_save_qdct(AnalyzerObject *self, PyObject *args)
{
    if (!analyzer_is_open(self)) {
        return closed_guard_failed();
    }
    PyObject *path_obj = NULL;
    if (!PyArg_ParseTuple(args, "O", &path_obj)) {
        return NULL;
    }
    const char *path = checked_path_arg(path_obj);
    if (path == NULL) {
        if (PyErr_Occurred()) {
            return NULL;
        }
        /* save has no path-less mode; a None argument is a call-shape
         * mistake, not a library failure. */
        PyErr_SetString(PyExc_TypeError, "path is required for save_qdct()");
        return NULL;
    }
    Moli_Err err;
    memset(&err, 0, sizeof(err));
    int32_t rc;
    Moli_Handle h = analyzer_call_enter(self);
    if (h == NULL) {
        return NULL;
    }
    Py_BEGIN_ALLOW_THREADS
    rc = moli_save_qdct(h, path, &err);
    Py_END_ALLOW_THREADS
    analyzer_call_exit(self);
    if (rc != 0) {
        raise_moli_err(&err);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *Analyzer_snapshot(AnalyzerObject *self, PyObject *Py_UNUSED(ignored))
{
    if (!analyzer_is_open(self)) {
        return closed_guard_failed();
    }
    Moli_Err err;
    memset(&err, 0, sizeof(err));
    int64_t len = 0;
    uint8_t *p;
    Moli_Handle h = analyzer_call_enter(self);
    if (h == NULL) {
        return NULL;
    }
    Py_BEGIN_ALLOW_THREADS
    p = moli_snapshot(h, &len, &err);
    Py_END_ALLOW_THREADS
    analyzer_call_exit(self);
    if (p == NULL && err.domain != 0) {
        raise_moli_err(&err);
        return NULL;
    }
    PyObject *res = PyBytes_FromStringAndSize((const char *)p, (Py_ssize_t)len);
    Py_BEGIN_ALLOW_THREADS
    moli_snapshot_free(p);
    Py_END_ALLOW_THREADS
    return res;
}

static PyObject *wrap_handle(Moli_Handle h);

static PyObject *Analyzer_clone(AnalyzerObject *self, PyObject *Py_UNUSED(ignored))
{
    if (!analyzer_is_open(self)) {
        return closed_guard_failed();
    }
    Moli_Err err;
    memset(&err, 0, sizeof(err));
    Moli_Handle nh;
    Moli_Handle h = analyzer_call_enter(self);
    if (h == NULL) {
        return NULL;
    }
    Py_BEGIN_ALLOW_THREADS
    nh = moli_clone(h, &err);
    Py_END_ALLOW_THREADS
    analyzer_call_exit(self);
    if (nh == NULL) {
        raise_moli_err(&err);
        return NULL;
    }
    /* The finish (typed alloc, lock pair, the handle hand-off) is
     * wrap_handle's - one owner of the sequence instead of two copies
     * ordering their failure cleanup independently. */
    return wrap_handle(nh);
}

static PyObject *Analyzer_stats(AnalyzerObject *self, PyObject *Py_UNUSED(ignored))
{
    if (!analyzer_is_open(self)) {
        return closed_guard_failed();
    }
    Moli_Err err;
    Moli_Stats st;
    int32_t rc;
    memset(&err, 0, sizeof(err));
    /* Serialize with other stats/add_user_entries calls (the handle's
     * skipped scratch is rewritten per call), waiting with the GIL
     * released; release the GIL around the call itself too — the core
     * fingerprints every entry row, which is dictionary-scale work,
     * not a microsecond. */
    Py_BEGIN_ALLOW_THREADS
    PyThread_acquire_lock(self->mut_lock, 1);
    Py_END_ALLOW_THREADS
    Moli_Handle h = analyzer_call_enter(self);
    if (h == NULL) {
        PyThread_release_lock(self->mut_lock);
        return NULL;
    }
    Py_BEGIN_ALLOW_THREADS
    rc = moli_stats(h, &st, &err);
    Py_END_ALLOW_THREADS
    /* Consume the borrowed skipped[] while BOTH serializations still
     * hold: the bracket fences close's moli_free, the mut lock fences
     * the next stats call's scratch rewrite. Plain C copies only —
     * PyMem never runs Python code, so no GC pass can re-enter stats
     * on this handle's mut lock. The names are NUL-terminated in the
     * scratch (the shim truncates and terminates each row). */
    int64_t n_skipped = 0;
    char *snap = NULL;
    const char *snap_at[MOLI_STATS_SKIPPED_CAP];
    int oom = 0;
    if (rc == 0) {
        n_skipped = st.skipped_count;
        if (n_skipped > MOLI_STATS_SKIPPED_CAP) {
            n_skipped = MOLI_STATS_SKIPPED_CAP;
        }
        if (n_skipped > 0) {
            int64_t total = 0;
            for (int64_t i = 0; i < n_skipped; i++) {
                total += (int64_t)strlen(st.skipped[i] != NULL ? st.skipped[i] : "") + 1;
            }
            snap = (char *)PyMem_Malloc((size_t)total);
            oom = (snap == NULL);
        }
    }
    if (snap != NULL) {
        char *w = snap;
        for (int64_t i = 0; i < n_skipped; i++) {
            const char *s = st.skipped[i] != NULL ? st.skipped[i] : "";
            size_t len = strlen(s) + 1;
            memcpy(w, s, len);
            snap_at[i] = w;
            w += len;
        }
    }
    analyzer_call_exit(self);
    PyThread_release_lock(self->mut_lock);
    if (rc != 0) {
        raise_moli_err(&err);
        return NULL;
    }
    if (oom) {
        PyErr_NoMemory();
        return NULL;
    }
    PyObject *skipped = PyList_New((Py_ssize_t)n_skipped);
    if (skipped == NULL) {
        PyMem_Free(snap);
        return NULL;
    }
    for (int64_t i = 0; i < n_skipped; i++) {
        PyObject *s = PyUnicode_FromString(snap_at[i]);
        if (s == NULL || PyList_SetItem(skipped, (Py_ssize_t)i, s) < 0) {
            Py_XDECREF(s);
            Py_DECREF(skipped);
            PyMem_Free(snap);
            return NULL;
        }
    }
    PyMem_Free(snap);
    if (AnalyzerStatsType != NULL) {
        PyObject *args = Py_BuildValue("(LLLLLLLLLdKO)",
                                       (long long)st.entries, (long long)st.terminals,
                                       (long long)st.cedar_nodes, (long long)st.unk_rules,
                                       (long long)st.unk_patterns,
                                       (long long)st.matrix_left, (long long)st.matrix_right,
                                       (long long)st.matrix_cells,
                                       (long long)st.matrix_explicit,
                                       st.matrix_density,
                                       (unsigned long long)st.entries_hash,
                                       skipped);
        PyObject *res = NULL;
        if (args != NULL) {
            res = PyObject_CallObject(AnalyzerStatsType, args);
            Py_DECREF(args);
        }
        Py_DECREF(skipped);
        return res;
    }
    PyObject *res = Py_BuildValue("{s:L,s:L,s:L,s:L,s:L,s:L,s:L,s:L,s:L,s:d,s:K,s:N}",
                                  "entries", (long long)st.entries,
                                  "terminals", (long long)st.terminals,
                                  "cedar_nodes", (long long)st.cedar_nodes,
                                  "unk_rules", (long long)st.unk_rules,
                                  "unk_patterns", (long long)st.unk_patterns,
                                  "matrix_left", (long long)st.matrix_left,
                                  "matrix_right", (long long)st.matrix_right,
                                  "matrix_cells", (long long)st.matrix_cells,
                                  "matrix_explicit", (long long)st.matrix_explicit,
                                  "matrix_density", st.matrix_density,
                                  "entries_hash", (unsigned long long)st.entries_hash,
                                  "skipped", skipped);
    /* The N unit consumed the list's only reference into the dict. */
    return res;
}

/* Attribute-driven field reads: a UserEntry is any object with the
 * eight fields (the SDK's namedtuple is the canonical shape). The
 * returned pointer borrows the hold, which keeps the attribute object
 * — possibly a fresh @property result — alive for the whole call. */
static const char *entry_attr_str(PyObject *item, const char *name, RefHold *hold)
{
    PyObject *v = PyObject_GetAttrString(item, name);
    if (v == NULL) {
        return NULL;
    }
    if (v == Py_None) {
        Py_DECREF(v);
        return "";
    }
    char what[48];
    snprintf(what, sizeof(what), "UserEntry.%s", name);
    const char *s = held_utf8(v, hold, what);
    Py_DECREF(v);
    return s;
}

static int entry_attr_i16(PyObject *item, const char *name, int16_t *out)
{
    PyObject *v = PyObject_GetAttrString(item, name);
    if (v == NULL) {
        return -1;
    }
    if (v == Py_None) {
        Py_DECREF(v);
        *out = 0;
        return 0;
    }
    long n = PyLong_AsLong(v);
    Py_DECREF(v);
    if (n == -1 && PyErr_Occurred()) {
        return -1;
    }
    if (n < -32768 || n > 32767) {
        PyErr_Format(PyExc_ValueError, "UserEntry.%s must be in [-32768, 32767], got %ld", name, n);
        return -1;
    }
    *out = (int16_t)n;
    return 0;
}

static PyObject *Analyzer_add_user_entries(AnalyzerObject *self, PyObject *args)
{
    if (!analyzer_is_open(self)) {
        return closed_guard_failed();
    }
    PyObject *seq_obj = NULL;
    if (!PyArg_ParseTuple(args, "O", &seq_obj)) {
        return NULL;
    }
    PyObject *seq = PySequence_Fast(seq_obj, "entries must be a sequence of UserEntry");
    if (seq == NULL) {
        return NULL;
    }
    Py_ssize_t n = PySequence_Fast_GET_SIZE(seq);
    Moli_User_Entry *entries = NULL;
    RefHold hold = {NULL, 0, 0};
    if (n > 0) {
        entries = (Moli_User_Entry *)PyMem_Malloc((size_t)n * sizeof(*entries));
        if (entries == NULL) {
            Py_DECREF(seq);
            return PyErr_NoMemory();
        }
        /* Five string attributes per entry, all held until the ABI
         * call returns: the attribute objects may be fresh (@property
         * results), alive only while these references exist. */
        if (refhold_init(&hold, n * 5) < 0) {
            PyMem_Free(entries);
            Py_DECREF(seq);
            return NULL;
        }
    }
    for (Py_ssize_t i = 0; i < n; i++) {
        PyObject *item = PySequence_Fast_GET_ITEM(seq, i);
        memset(&entries[i], 0, sizeof(entries[i]));
        entries[i].surface = entry_attr_str(item, "surface", &hold);
        if (entries[i].surface == NULL ||
            PyErr_Occurred()) {
            goto fail;
        }
        entries[i].pos = entry_attr_str(item, "pos", &hold);
        if (entries[i].pos == NULL) {
            goto fail;
        }
        entries[i].lemma = entry_attr_str(item, "lemma", &hold);
        if (entries[i].lemma == NULL) {
            goto fail;
        }
        entries[i].reading = entry_attr_str(item, "reading", &hold);
        if (entries[i].reading == NULL) {
            goto fail;
        }
        entries[i].reading_jyutping = entry_attr_str(item, "reading_jyutping", &hold);
        if (entries[i].reading_jyutping == NULL) {
            goto fail;
        }
        if (entry_attr_i16(item, "left_id", &entries[i].left_id) < 0 ||
            entry_attr_i16(item, "right_id", &entries[i].right_id) < 0 ||
            entry_attr_i16(item, "cost", &entries[i].cost) < 0) {
            goto fail;
        }
    }
    {
        Moli_Err err;
        memset(&err, 0, sizeof(err));
        int32_t rc;
        /* The mut lock serializes mutating calls (the core's swap
         * protocol assumes a single mutating caller), waiting with
         * the GIL released. The attribute reads above may have run
         * arbitrary Python and dropped the GIL, so enter re-checks
         * the bracket's entry conditions here — with no user code
         * between its check and the in_flight increment, and the
         * handle captured under the same mutex. */
        Py_BEGIN_ALLOW_THREADS
        PyThread_acquire_lock(self->mut_lock, 1);
        Py_END_ALLOW_THREADS
        Moli_Handle h = analyzer_call_enter(self);
        if (h == NULL) {
            PyThread_release_lock(self->mut_lock);
            if (n > 0) {
                PyMem_Free(entries);
                refhold_fini(&hold);
            }
            Py_DECREF(seq);
            return NULL;
        }
        Py_BEGIN_ALLOW_THREADS
        rc = moli_add_user_entries(h, entries, (int64_t)n, &err);
        Py_END_ALLOW_THREADS
        analyzer_call_exit(self);
        PyThread_release_lock(self->mut_lock);
        if (n > 0) {
            PyMem_Free(entries);
            refhold_fini(&hold);
        }
        Py_DECREF(seq);
        if (rc != 0) {
            raise_moli_err(&err);
            return NULL;
        }
    }
    Py_RETURN_NONE;
fail:
    if (n > 0) {
        PyMem_Free(entries);
        refhold_fini(&hold);
    }
    Py_DECREF(seq);
    return NULL;
}

static PyMethodDef Analyzer_methods[] = {
    {"tokenize", (PyCFunction)Analyzer_tokenize, METH_FASTCALL | METH_KEYWORDS,
     "tokenize(text, *, unk_cost_bias=0, unk_cost_per_rune=0, normalize_nfc=False, strict_utf8=False, cancel=None) -> Morphemes\n\n"
     "A lazy Sequence[Morpheme]: len() is free, indexing and slicing\n"
     "materialize Morpheme values on access (list(t) for the eager list)."},
    {"tokenize_constrained", (PyCFunction)Analyzer_tokenize_constrained, METH_FASTCALL | METH_KEYWORDS,
     "tokenize_constrained(text, tokens=(), boundaries=(), *, unk_cost_bias=0, unk_cost_per_rune=0, normalize_nfc=False, strict_utf8=False, cancel=None) -> Morphemes\n\n"
     "The Viterbi search under a constraint set: tokens are (start, end[, pos])\n"
     "byte-offset spans that must surface as exactly one morpheme (pos a\n"
     "POS-column prefix, '' or None for any POS); boundaries are (at,\n"
     "must_exist) byte offsets where a morpheme boundary is forced or\n"
     "forbidden. Raises ConstraintError for a rejected set and\n"
     "UnsatisfiableError (byte_offset = the earliest blocked position) when\n"
     "the mask leaves no path."},
    {"wakachi", (PyCFunction)Analyzer_wakachi, METH_FASTCALL | METH_KEYWORDS,
     "wakachi(text, *, ...) -> list[str]"},
    {"wakati", (PyCFunction)Analyzer_wakati, METH_FASTCALL | METH_KEYWORDS,
     "wakati(text, *, ...) -> str\n\n"
     "Surfaces joined with single spaces - the MeCab -Owakati shape,\n"
     "identical to ' '.join(wakachi(text))."},
    {"parse", (PyCFunction)Analyzer_parse, METH_FASTCALL | METH_KEYWORDS,
     "parse(text, *, ...) -> str\n\n"
     "One TSV line per morpheme (surface, pos, lemma, reading,\n"
     "reading_jyutping joined by tabs, lines by newlines) - the fields\n"
     "tokenize(text) returns."},
    {"spans", (PyCFunction)Analyzer_spans, METH_FASTCALL | METH_KEYWORDS,
     "spans(text, *, ...) -> list[Span]"},
    {"nbest", (PyCFunction)Analyzer_nbest, METH_FASTCALL | METH_KEYWORDS,
     "nbest(text, k=1, *, ...) -> list[NBestPath]"},
    {"classify_locale", (PyCFunction)Analyzer_classify_locale, METH_VARARGS,
     "classify_locale(text) -> Locale"},
    {"add_user_entries", (PyCFunction)Analyzer_add_user_entries, METH_VARARGS,
     "add_user_entries(entries) -> None"},
    {"save_qdct", (PyCFunction)Analyzer_save_qdct, METH_VARARGS,
     "save_qdct(path) -> None"},
    {"snapshot", (PyCFunction)Analyzer_snapshot, METH_NOARGS,
     "snapshot() -> bytes"},
    {"clone", (PyCFunction)Analyzer_clone, METH_NOARGS,
     "clone() -> Analyzer"},
    {"stats", (PyCFunction)Analyzer_stats, METH_NOARGS,
     "stats() -> AnalyzerStats"},
    {"close", (PyCFunction)Analyzer_close, METH_NOARGS,
     "close() -> None (idempotent)"},
    {"__enter__", (PyCFunction)Analyzer_enter, METH_NOARGS, NULL},
    {"__exit__", (PyCFunction)Analyzer_exit, METH_VARARGS, NULL},
    {NULL, NULL, 0, NULL},
};

static PyTypeObject AnalyzerType = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name = "moli._native.Analyzer",
    .tp_basicsize = sizeof(AnalyzerObject),
    .tp_dealloc = (destructor)Analyzer_dealloc,
    .tp_repr = (reprfunc)Analyzer_repr,
    /* GC is required for the managed-weakref pre-header in 3.12. */
    .tp_flags = Py_TPFLAGS_DEFAULT | Py_TPFLAGS_HAVE_GC | Py_TPFLAGS_MANAGED_WEAKREF,
    .tp_doc = "Analyzer handle (closed flag + finaliser)",
    .tp_traverse = (traverseproc)Analyzer_traverse,
    .tp_clear = (inquiry)Analyzer_clear,
    .tp_methods = Analyzer_methods,
};

/* --- module-level constructors -------------------------------------- */

static PyObject *wrap_handle(Moli_Handle h)
{
    /* GenericAlloc (not PyObject_New): the managed-weakref pre-header
     * needs the type's allocation path. */
    AnalyzerObject *a = (AnalyzerObject *)PyType_GenericAlloc(&AnalyzerType, 0);
    if (a == NULL) {
        Py_BEGIN_ALLOW_THREADS
        moli_free(h);
        Py_END_ALLOW_THREADS
        return NULL;
    }
    if (analyzer_alloc_locks(a) < 0) {
        Py_DECREF(a);
        Py_BEGIN_ALLOW_THREADS
        moli_free(h);
        Py_END_ALLOW_THREADS
        return NULL;
    }
    a->h = h;
    a->closed = 0;
    a->closing = 0;
    a->in_flight = 0;
    return (PyObject *)a;
}

static int fill_load_options(Moli_Load_Options *opts, int mode, int threads,
                             int lemma_locale, int flat,
                             PyObject *unk, PyObject *chd, PyObject *mxd,
                             PyObject *qpt, PyObject *jyt)
{
    memset(opts, 0, sizeof(*opts));
    if (mode < 0 || mode > MOLI_MODE_LONGESTMATCH) {
        PyErr_SetString(PyExc_ValueError, "mode ordinal out of range");
        return -1;
    }
    if (lemma_locale < 0 || lemma_locale > MOLI_LOCALE_US) {
        PyErr_SetString(PyExc_ValueError, "lemma_locale ordinal out of range");
        return -1;
    }
    opts->mode = (uint8_t)mode;
    opts->lemma_locale = (uint8_t)lemma_locale;
    opts->flat_char_class = (uint8_t)(flat != 0);
    opts->threads = (int32_t)threads;

    if ((opts->unk_def_path = checked_path_arg(unk)) == NULL && PyErr_Occurred()) {
        return -1;
    }
    if ((opts->char_def_path = checked_path_arg(chd)) == NULL && PyErr_Occurred()) {
        return -1;
    }
    if ((opts->matrix_def_path = checked_path_arg(mxd)) == NULL && PyErr_Occurred()) {
        return -1;
    }
    if ((opts->qpat_path = checked_path_arg(qpt)) == NULL && PyErr_Occurred()) {
        return -1;
    }
    if ((opts->jyutping_csv_path = checked_path_arg(jyt)) == NULL && PyErr_Occurred()) {
        return -1;
    }
    return 0;
}

/* The load family shares one keyword surface after the data argument. */
static PyObject *py_load_common(PyObject *args, PyObject *kwds, int kind)
{
    int lang = 0;
    PyObject *data = NULL;
    int mode = 0, threads = 0, lemma_locale = 0, flat = 0;
    PyObject *unk = Py_None, *chd = Py_None, *mxd = Py_None, *qpt = Py_None, *jyt = Py_None;
    static char *kwlist[] = {"lang", "path", "mode", "threads", "lemma_locale",
                             "unk_def_path", "char_def_path", "matrix_def_path",
                             "qpat_path", "jyutping_csv_path", "flat_char_class", NULL};
    static char *kwlist_bytes[] = {"lang", "data", "mode", "threads", "lemma_locale",
                                   "unk_def_path", "char_def_path", "matrix_def_path",
                                   "qpat_path", "jyutping_csv_path", "flat_char_class", NULL};
    char **kl = kind == 1 ? kwlist_bytes : kwlist;
    /* The five path arguments parse as objects (borrowed references,
     * owned by the args/kwds containers for the whole call) and go
     * through checked_path_arg below; `p` would make the converter
     * write an int through the PyObject* slots. flat_char_class stays
     * `p` — a plain int flag. */
    if (!PyArg_ParseTupleAndKeywords(args, kwds, "iO|iiiOOOOOp", kl,
                                     &lang, &data, &mode, &threads, &lemma_locale,
                                     &unk, &chd, &mxd, &qpt, &jyt, &flat)) {
        return NULL;
    }
    if (lang < 0 || lang > MOLI_LANG_GERMAN) {
        PyErr_SetString(PyExc_ValueError, "language ordinal out of range");
        return NULL;
    }

    Py_buffer view;
    int have_view = 0;
    const char *path = NULL;
    if (kind == 0) {
        path = checked_path_arg(data);
        if (path == NULL) {
            if (PyErr_Occurred()) {
                return NULL;
            }
            PyErr_SetString(PyExc_TypeError, "path is required for load()");
            return NULL;
        }
    } else {
        if (PyObject_GetBuffer(data, &view, PyBUF_CONTIG_RO) < 0) {
            return NULL;
        }
        have_view = 1;
    }

    Moli_Load_Options opts;
    if (fill_load_options(&opts, mode, threads, lemma_locale, flat, unk, chd, mxd, qpt, jyt) < 0) {
        if (have_view) {
            PyBuffer_Release(&view);
        }
        return NULL;
    }

    Moli_Err err;
    memset(&err, 0, sizeof(err));
    Moli_Handle h;
    Py_BEGIN_ALLOW_THREADS
    if (kind == 0) {
        h = moli_load((uint8_t)lang, path, &opts, &err);
    } else {
        h = moli_load_bytes((uint8_t)lang, (const uint8_t *)view.buf,
                            (int64_t)view.len, &opts, &err);
    }
    Py_END_ALLOW_THREADS
    if (have_view) {
        PyBuffer_Release(&view);
    }
    if (h == NULL) {
        raise_moli_err(&err);
        return NULL;
    }
    return wrap_handle(h);
}

static PyObject *py_load(PyObject *Py_UNUSED(m), PyObject *args, PyObject *kwds)
{
    return py_load_common(args, kwds, 0);
}

static PyObject *py_load_bytes(PyObject *Py_UNUSED(m), PyObject *args, PyObject *kwds)
{
    return py_load_common(args, kwds, 1);
}

static PyObject *qdct_path_load(PyObject *args, int use_mmap)
{
    PyObject *path_obj = NULL;
    if (!PyArg_ParseTuple(args, "O", &path_obj)) {
        return NULL;
    }
    const char *path = checked_path_arg(path_obj);
    if (path == NULL) {
        if (PyErr_Occurred()) {
            return NULL;
        }
        PyErr_SetString(PyExc_TypeError, "path is required");
        return NULL;
    }
    Moli_Err err;
    memset(&err, 0, sizeof(err));
    Moli_Handle h;
    Py_BEGIN_ALLOW_THREADS
    h = use_mmap ? moli_load_qdct_mmap(path, &err) : moli_load_qdct(path, &err);
    Py_END_ALLOW_THREADS
    if (h == NULL) {
        raise_moli_err(&err);
        return NULL;
    }
    return wrap_handle(h);
}

static PyObject *py_load_qdct(PyObject *Py_UNUSED(m), PyObject *args)
{
    return qdct_path_load(args, 0);
}

static PyObject *py_load_qdct_mmap(PyObject *Py_UNUSED(m), PyObject *args)
{
    return qdct_path_load(args, 1);
}

static PyObject *py_load_qdct_bytes(PyObject *Py_UNUSED(m), PyObject *args)
{
    PyObject *data = NULL;
    if (!PyArg_ParseTuple(args, "O", &data)) {
        return NULL;
    }
    Py_buffer view;
    if (PyObject_GetBuffer(data, &view, PyBUF_CONTIG_RO) < 0) {
        return NULL;
    }
    Moli_Err err;
    memset(&err, 0, sizeof(err));
    Moli_Handle h;
    Py_BEGIN_ALLOW_THREADS
    h = moli_load_qdct_bytes((const uint8_t *)view.buf, (int64_t)view.len, &err);
    Py_END_ALLOW_THREADS
    PyBuffer_Release(&view);
    if (h == NULL) {
        raise_moli_err(&err);
        return NULL;
    }
    return wrap_handle(h);
}

static PyObject *py_cancel_new(PyObject *Py_UNUSED(m), PyObject *Py_UNUSED(ignored))
{
    Moli_Cancel c = moli_cancel_new();
    if (c == NULL) {
        return PyErr_NoMemory();
    }
    CancelObject *tok = (CancelObject *)PyType_GenericAlloc(&CancelType, 0);
    if (tok == NULL) {
        moli_cancel_free(c);
        return NULL;
    }
    tok->c = c;
    return (PyObject *)tok;
}

static PyObject *py_abi_version(PyObject *Py_UNUSED(m), PyObject *Py_UNUSED(ignored))
{
    return PyLong_FromUnsignedLong((unsigned long)moli_abi_version());
}

static PyObject *py_version(PyObject *Py_UNUSED(m), PyObject *Py_UNUSED(ignored))
{
    return PyUnicode_FromString(moli_version());
}

/* The Python layer hands its value/enum types in right after import;
 * the extension builds instances through them from then on. */
static void clear_value_caches(void)
{
    for (int i = 0; i < MOLI_LOCALE_COUNT; i++) {
        Py_CLEAR(LocaleMembers[i]);
    }
    for (int i = 0; i < MOLI_CHARCLASS_COUNT; i++) {
        Py_CLEAR(CharClassMembers[i]);
    }
    Py_CLEAR(MorphemeTupleNew);
}

static PyObject *py_set_value_types(PyObject *Py_UNUSED(m), PyObject *args)
{
    PyObject *morph, *span, *nbest, *stats, *locale, *charclass;
    if (!PyArg_ParseTuple(args, "OOOOOO", &morph, &span, &nbest, &stats,
                          &locale, &charclass)) {
        return NULL;
    }
    Py_XDECREF(MorphemeType);
    Py_XDECREF(SpanType);
    Py_XDECREF(NBestPathType);
    Py_XDECREF(AnalyzerStatsType);
    Py_XDECREF(LocaleType);
    Py_XDECREF(CharClassType);
    MorphemeType = morph;      Py_INCREF(morph);
    SpanType = span;           Py_INCREF(span);
    NBestPathType = nbest;     Py_INCREF(nbest);
    AnalyzerStatsType = stats; Py_INCREF(stats);
    LocaleType = locale;       Py_INCREF(locale);
    CharClassType = charclass; Py_INCREF(charclass);
    /* Materialize the enum member singletons once (the class call is
     * the only constructor, so every entry is the identical instance
     * the class would have returned per morpheme). */
    clear_value_caches();
    for (int i = 0; i < MOLI_LOCALE_COUNT; i++) {
        LocaleMembers[i] = ordinal_py(i, locale);
        if (LocaleMembers[i] == NULL) {
            clear_value_caches();
            return NULL;
        }
    }
    for (int i = 0; i < MOLI_CHARCLASS_COUNT; i++) {
        CharClassMembers[i] = ordinal_py(i, charclass);
        if (CharClassMembers[i] == NULL) {
            clear_value_caches();
            return NULL;
        }
    }
    MorphemeTupleNew = PyObject_GetAttrString(morph, "_tuple_new");
    if (MorphemeTupleNew == NULL) {
        /* Absent (or unfetchable) on this type: the class-call path
         * covers it. */
        PyErr_Clear();
    }
    Py_RETURN_NONE;
}

static PyMethodDef module_methods[] = {
    {"load", (PyCFunction)py_load, METH_VARARGS | METH_KEYWORDS,
     "load(lang, path, *, mode=Mode.Viterbi, threads=0, lemma_locale=Locale.None, unk_def_path=None, char_def_path=None, matrix_def_path=None, qpat_path=None, jyutping_csv_path=None, flat_char_class=False) -> Analyzer"},
    {"load_bytes", (PyCFunction)py_load_bytes, METH_VARARGS | METH_KEYWORDS,
     "load_bytes(lang, data, *, ...) -> Analyzer (data borrowed, no copy)"},
    {"load_qdct", (PyCFunction)py_load_qdct, METH_VARARGS,
     "load_qdct(path) -> Analyzer"},
    {"load_qdct_mmap", (PyCFunction)py_load_qdct_mmap, METH_VARARGS,
     "load_qdct_mmap(path) -> Analyzer (zero-extra-copy deploy path)"},
    {"load_qdct_bytes", (PyCFunction)py_load_qdct_bytes, METH_VARARGS,
     "load_qdct_bytes(data) -> Analyzer (documented one-copy)"},
    {"CancelToken", (PyCFunction)py_cancel_new, METH_NOARGS,
     "CancelToken() -> one-way cancellation token"},
    {"abi_version", (PyCFunction)py_abi_version, METH_NOARGS, NULL},
    {"version", (PyCFunction)py_version, METH_NOARGS, NULL},
    {"_set_value_types", (PyCFunction)py_set_value_types, METH_VARARGS, NULL},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef moduledef = {
    PyModuleDef_HEAD_INIT,
    "moli._native",
    "CPython extension over the libmoli C ABI (internal; import moli instead).",
    -1,
    module_methods,
    NULL, NULL, NULL, NULL,
};

PyMODINIT_FUNC PyInit__native(void)
{
    if (verify_abi_layout() < 0) {
        return NULL;
    }
    if (PyType_Ready(&AnalyzerType) < 0 || PyType_Ready(&CancelType) < 0 ||
        PyType_Ready(&MorphemesType) < 0 ||
        PyType_Ready(&MorphemesIterType) < 0) {
        return NULL;
    }

    MoliError            = PyErr_NewException("moli._native.MoliError", NULL, NULL);
    LoadError            = PyErr_NewException("moli._native.LoadError", MoliError, NULL);
    SchemaMismatchError  = PyErr_NewException("moli._native.SchemaMismatchError", MoliError, NULL);
    OutOfMemoryError     = PyErr_NewException("moli._native.OutOfMemoryError", MoliError, NULL);
    UnavailableError     = PyErr_NewException("moli._native.UnavailableError", MoliError, NULL);
    MalformedInputError  = PyErr_NewException("moli._native.MalformedInputError", MoliError, NULL);
    CancelledError       = PyErr_NewException("moli._native.CancelledError", MoliError, NULL);
    ConstraintError      = PyErr_NewException("moli._native.ConstraintError", MoliError, NULL);
    UnsatisfiableError   = PyErr_NewException("moli._native.UnsatisfiableError", MoliError, NULL);
    SaveError            = PyErr_NewException("moli._native.SaveError", MoliError, NULL);
    if (MoliError == NULL || LoadError == NULL || SchemaMismatchError == NULL ||
        OutOfMemoryError == NULL || UnavailableError == NULL ||
        MalformedInputError == NULL || CancelledError == NULL || SaveError == NULL ||
        ConstraintError == NULL || UnsatisfiableError == NULL) {
        return NULL;
    }

    PyObject *m = PyModule_Create(&moduledef);
    if (m == NULL) {
        return NULL;
    }

    Py_INCREF(&AnalyzerType);
    if (PyModule_AddObject(m, "Analyzer", (PyObject *)&AnalyzerType) < 0) {
        Py_DECREF(&AnalyzerType);
        Py_DECREF(m);
        return NULL;
    }
    Py_INCREF(&CancelType);
    if (PyModule_AddObject(m, "CancelTokenType", (PyObject *)&CancelType) < 0) {
        Py_DECREF(&CancelType);
        Py_DECREF(m);
        return NULL;
    }
    Py_INCREF(&MorphemesType);
    if (PyModule_AddObject(m, "Morphemes", (PyObject *)&MorphemesType) < 0) {
        Py_DECREF(&MorphemesType);
        Py_DECREF(m);
        return NULL;
    }

    PyObject *exc;
#define ADD_EXC(name)                                       \
    do {                                                    \
        exc = name;                                         \
        Py_INCREF(exc);                                     \
        if (PyModule_AddObject(m, #name, exc) < 0) {        \
            Py_DECREF(exc);                                 \
            goto fail;                                      \
        }                                                   \
    } while (0)
    ADD_EXC(MoliError);
    ADD_EXC(LoadError);
    ADD_EXC(SchemaMismatchError);
    ADD_EXC(OutOfMemoryError);
    ADD_EXC(UnavailableError);
    ADD_EXC(MalformedInputError);
    ADD_EXC(CancelledError);
    ADD_EXC(ConstraintError);
    ADD_EXC(UnsatisfiableError);
    ADD_EXC(SaveError);
#undef ADD_EXC

#define ADD_CONST(name)                                     \
    do {                                                    \
        if (PyModule_AddIntConstant(m, #name, name) < 0) {  \
            goto fail;                                      \
        }                                                   \
    } while (0)
    ADD_CONST(MOLI_LANG_JAPANESE);
    ADD_CONST(MOLI_LANG_CHINESE_CN);
    ADD_CONST(MOLI_LANG_CHINESE_TW);
    ADD_CONST(MOLI_LANG_CHINESE_HK);
    ADD_CONST(MOLI_LANG_ENGLISH_GB);
    ADD_CONST(MOLI_LANG_ENGLISH_US);
    ADD_CONST(MOLI_LANG_GERMAN);
    ADD_CONST(MOLI_LOCALE_NONE);
    ADD_CONST(MOLI_LOCALE_CN);
    ADD_CONST(MOLI_LOCALE_TW);
    ADD_CONST(MOLI_LOCALE_HK);
    ADD_CONST(MOLI_LOCALE_GB);
    ADD_CONST(MOLI_LOCALE_US);
    ADD_CONST(MOLI_MODE_VITERBI);
    ADD_CONST(MOLI_MODE_LONGESTMATCH);
    ADD_CONST(MOLI_CLASS_UNKNOWN);
    ADD_CONST(MOLI_CLASS_HIRAGANA);
    ADD_CONST(MOLI_CLASS_KATAKANA);
    ADD_CONST(MOLI_CLASS_KANJI);
    ADD_CONST(MOLI_CLASS_HANZI);
    ADD_CONST(MOLI_CLASS_HALFWIDTH_KATAKANA);
    ADD_CONST(MOLI_CLASS_BOPOMOFO);
    ADD_CONST(MOLI_CLASS_ASCII_LETTER);
    ADD_CONST(MOLI_CLASS_DIGIT);
    ADD_CONST(MOLI_CLASS_PUNCT);
    ADD_CONST(MOLI_CLASS_SPACE);
    ADD_CONST(MOLI_CLASS_SYMBOL);
    ADD_CONST(MOLI_CLASS_EMOJI);
    ADD_CONST(MOLI_REASON_OUT_OF_BOUNDS);
    ADD_CONST(MOLI_REASON_EMPTY_SPAN);
    ADD_CONST(MOLI_REASON_NOT_RUNE_BOUNDARY);
    ADD_CONST(MOLI_REASON_TOKEN_OVERLAP);
    ADD_CONST(MOLI_REASON_BOUNDARY_INSIDE_TOKEN);
    ADD_CONST(MOLI_REASON_BOUNDARY_AT_TOKEN_EDGE);
    ADD_CONST(MOLI_REASON_CONFLICTING_BOUNDARIES);
    ADD_CONST(MOLI_REASON_BAD_POS_PATTERN);
    ADD_CONST(MOLI_REASON_NORMALIZATION_RESCALED);
    ADD_CONST(MOLI_ABI_VERSION);
#undef ADD_CONST

    /* Interned keyword names for the tokenize family's FASTCALL entry
     * (NULLs fail the module import — the parser would otherwise
     * silently ignore keyword arguments). */
    KwText = PyUnicode_InternFromString("text");
    KwK = PyUnicode_InternFromString("k");
    KwBias = PyUnicode_InternFromString("unk_cost_bias");
    KwPerRune = PyUnicode_InternFromString("unk_cost_per_rune");
    KwNfc = PyUnicode_InternFromString("normalize_nfc");
    KwStrict = PyUnicode_InternFromString("strict_utf8");
    KwCancel = PyUnicode_InternFromString("cancel");
    KwTokens = PyUnicode_InternFromString("tokens");
    KwBoundaries = PyUnicode_InternFromString("boundaries");
    if (KwTokens == NULL || KwBoundaries == NULL ||
        KwText == NULL || KwK == NULL || KwBias == NULL ||
        KwPerRune == NULL || KwNfc == NULL || KwStrict == NULL ||
        KwCancel == NULL) {
        goto fail;
    }

    return m;
fail:
    Py_DECREF(m);
    return NULL;
}
