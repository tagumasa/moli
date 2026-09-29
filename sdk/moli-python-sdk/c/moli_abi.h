/*
 * moli_abi.h — hand-written C mirror of the libmoli C ABI.
 *
 * There is no header generation on the compiler this library is built
 * with; this mirror is the contract, and moli_abi_check() is its
 * enforcement: verify the constants below against the library at load
 * time (before first use), because a layout mismatch must fail loudly
 * rather than corrupt memory. All ordinals are the library's
 * declaration order and are stable within an ABI version.
 */
#ifndef MOLI_ABI_H
#define MOLI_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MOLI_ABI_VERSION 7

/* Number of int64_t values moli_abi_check fills; the slot layout is
 * [abi version, Morpheme size + 17 field offsets, Err size + 7 field
 * offsets, Path size + 3 field offsets, Load_Options size + 9 field
 * offsets, Tokenize_Options size + 5 field offsets, User_Entry size +
 * 8 field offsets, Stats size + 13 field offsets, Token_Constraint
 * size + 3 field offsets, Boundary_Constraint size + 2 field offsets,
 * member counts of the four core enums and the four error
 * vocabularies, then every enum's per-member ordinals in declaration
 * order] — every mirrored struct is layout-checked and every mirrored
 * ordinal is value-checked (a reorder inside an enum keeps the count
 * but changes these). */
#define MOLI_ABI_CHECK_LEN 140

/* --- failure domains and codes (closed per-domain vocabularies) --- */

#define MOLI_DOMAIN_LOAD     0u
#define MOLI_DOMAIN_TOKENIZE 1u
#define MOLI_DOMAIN_SAVE     2u

#define MOLI_LOAD_FILE_NOT_FOUND  0u
#define MOLI_LOAD_INVALID_FORMAT  1u
#define MOLI_LOAD_OUT_OF_MEMORY   2u
#define MOLI_LOAD_SCHEMA_MISMATCH 3u
#define MOLI_LOAD_IO_READ         4u

#define MOLI_TOK_OUT_OF_MEMORY  0u
#define MOLI_TOK_UNAVAILABLE    1u
#define MOLI_TOK_MALFORMED      2u
#define MOLI_TOK_CANCELLED      3u
#define MOLI_TOK_BAD_CONSTRAINT 4u          /* a=index, b=start, c=end */
#define MOLI_TOK_UNSATISFIABLE  5u          /* a=byte offset */

#define MOLI_SAVE_IO_WRITE     0u
#define MOLI_SAVE_OUT_OF_MEMORY 1u
#define MOLI_SAVE_UNAVAILABLE  2u
#define MOLI_SAVE_FORMAT_LIMIT  3u

/* Constraint rejection reasons (MOLI_TOK_BAD_CONSTRAINT's d payload);
 * library declaration order. */
#define MOLI_REASON_OUT_OF_BOUNDS          0
#define MOLI_REASON_EMPTY_SPAN             1
#define MOLI_REASON_NOT_RUNE_BOUNDARY      2
#define MOLI_REASON_TOKEN_OVERLAP          3
#define MOLI_REASON_BOUNDARY_INSIDE_TOKEN  4
#define MOLI_REASON_BOUNDARY_AT_TOKEN_EDGE 5
#define MOLI_REASON_CONFLICTING_BOUNDARIES 6
#define MOLI_REASON_BAD_POS_PATTERN        7
#define MOLI_REASON_NORMALIZATION_RESCALED 8

/* --- enum ordinals (library declaration order) --- */

#define MOLI_LANG_JAPANESE  0
#define MOLI_LANG_CHINESE_CN 1
#define MOLI_LANG_CHINESE_TW 2
#define MOLI_LANG_CHINESE_HK 3
#define MOLI_LANG_ENGLISH_GB 4
#define MOLI_LANG_ENGLISH_US 5
#define MOLI_LANG_GERMAN     6

#define MOLI_LOCALE_NONE 0
#define MOLI_LOCALE_CN   1
#define MOLI_LOCALE_TW   2
#define MOLI_LOCALE_HK   3
#define MOLI_LOCALE_GB   4
#define MOLI_LOCALE_US   5

#define MOLI_MODE_VITERBI      0
#define MOLI_MODE_LONGESTMATCH 1

#define MOLI_CLASS_UNKNOWN            0
#define MOLI_CLASS_HIRAGANA           1
#define MOLI_CLASS_KATAKANA           2
#define MOLI_CLASS_KANJI              3
#define MOLI_CLASS_HANZI              4
#define MOLI_CLASS_HALFWIDTH_KATAKANA 5
#define MOLI_CLASS_BOPOMOFO           6
#define MOLI_CLASS_ASCII_LETTER       7
#define MOLI_CLASS_DIGIT              8
#define MOLI_CLASS_PUNCT              9
#define MOLI_CLASS_SPACE             10
#define MOLI_CLASS_SYMBOL            11
#define MOLI_CLASS_EMOJI             12

/* Member counts of the mirrored enums; the per-member ordinal block
 * behind them in the check vector is what makes the header's ordinal
 * tables machine-verified: an inside-enum reorder keeps these counts
 * but changes the ordinals, and the import-time check compares every
 * one. The error vocabularies ride the same mechanism: the codes the
 * C side switches on (raise_moli_err) are mirrored ordinals, so a
 * code added, removed, or reshuffled on the library side fails the
 * import-time check. */
#define MOLI_LANGUAGE_COUNT  7
#define MOLI_LOCALE_COUNT    6
#define MOLI_MODE_COUNT      2
#define MOLI_CHARCLASS_COUNT 13
#define MOLI_DOMAIN_COUNT    3
#define MOLI_LOAD_CODE_COUNT 5
#define MOLI_TOK_CODE_COUNT  6
#define MOLI_SAVE_CODE_COUNT 4

/* --- handles (opaque; owned by the caller between create and free) --- */

typedef struct Moli_HandleRec *Moli_Handle;    /* an analyzer */
typedef struct Moli_ResultRec *Moli_Result;    /* one call's output */
typedef struct Moli_CancelRec  *Moli_Cancel;   /* one-way cancel flag */

/* --- structs (sizes and field offsets re-verified by moli_abi_check) --- */

typedef struct {                 /* natural alignment; 72 bytes */
    int64_t start, end;          /* byte offsets into the input text */
    int32_t surf_off, surf_len;
    int32_t pos_off,  pos_len;
    int32_t lemma_off, lemma_len;
    int32_t reading_off, reading_len;
    int32_t jyutping_off, jyutping_len;
    int32_t entry_id;            /* index into the dictionary rows, -1 unknown */
    int16_t cost;
    uint8_t locale, char_class, is_unknown;
} Moli_Morpheme;

typedef struct {
    int64_t cost;
    int32_t first, count;        /* range in the shared morpheme array */
} Moli_Path;

typedef struct {
    uint32_t domain;
    uint32_t code;
    int64_t  a, b, c;            /* payload; schema line/expected/got or
                                    malformed/cancelled byte offset (a) */
    char     message[192];       /* NUL-terminated human context */
    int64_t  d;                  /* fourth payload slot: the constraint
                                    rejection's MOLI_REASON_* ordinal */
} Moli_Err;

typedef struct {
    const char *unk_def_path, *char_def_path, *matrix_def_path,
               *qpat_path, *jyutping_csv_path;   /* NULL = discover/omit */
    int32_t    threads;                          /* 0/1 = serial */
    uint8_t    mode;                             /* MOLI_MODE_* */
    uint8_t    lemma_locale;                     /* MOLI_LOCALE_* */
    uint8_t    flat_char_class;
} Moli_Load_Options;

typedef struct {
    void    *cancel;             /* Moli_Cancel or NULL */
    int32_t  unk_cost_bias, unk_cost_per_rune;
    uint8_t  normalize_nfc, strict_utf8;
} Moli_Tokenize_Options;

typedef struct {
    const char *surface, *pos, *lemma, *reading, *reading_jyutping;
    int16_t left_id, right_id, cost;
} Moli_User_Entry;

/* constrained analysis (borrowed for the call's duration; NULL pos =
 * any POS). start/end are byte offsets into the input text; pos is a
 * comma-separated POS-column prefix matched against whole columns. */
typedef struct {
    int64_t     start, end;
    const char *pos;
} Moli_Token_Constraint;

/* at is a byte offset strictly inside the text; must_exist drops
 * candidates spanning it (a boundary is forced), 0 drops candidates
 * ending on it (the winning path crosses inside a morpheme). */
typedef struct {
    int64_t at;
    uint8_t must_exist;
} Moli_Boundary_Constraint;

/* The wire cap on skipped[]: the library's scratch slots and the
 * header's array size are the same number, stated once here and
 * consumed wherever the list is sized or clamped. */
#define MOLI_STATS_SKIPPED_CAP 8

/* skipped[] borrows a per-handle scratch that every moli_stats call on
 * that handle rewrites; serialize stats calls per handle and copy the
 * strings (NUL-terminated) before the next call. entries_hash
 * fingerprints the resolved dictionary rows — the dictionary-version
 * detector (any add_user_entries merge changes it). */
typedef struct {
    int64_t     entries, terminals, cedar_nodes, unk_rules, unk_patterns;
    int64_t     matrix_left, matrix_right, matrix_cells, matrix_explicit;
    double      matrix_density;
    uint64_t    entries_hash;
    const char *skipped[MOLI_STATS_SKIPPED_CAP];
    int64_t     skipped_count;
} Moli_Stats;

/* --- export table --- */

/* introspection */
uint32_t    moli_abi_version(void);
const char *moli_version(void);
int32_t     moli_abi_check(int64_t *out_values, int32_t cap);

/* lifecycle */
Moli_Handle moli_load(uint8_t lang, const char *csv_path,
                      const Moli_Load_Options *opts, Moli_Err *err);
Moli_Handle moli_load_bytes(uint8_t lang, const uint8_t *csv, int64_t len,
                            const Moli_Load_Options *opts, Moli_Err *err);
Moli_Handle moli_load_qdct(const char *path, Moli_Err *err);
Moli_Handle moli_load_qdct_mmap(const char *path, Moli_Err *err);
Moli_Handle moli_load_qdct_bytes(const uint8_t *data, int64_t len, Moli_Err *err);
Moli_Handle moli_clone(Moli_Handle h, Moli_Err *err);
void        moli_free(Moli_Handle h);   /* exactly once; drains in-flight calls */

/* snapshot */
int32_t  moli_save_qdct(Moli_Handle h, const char *path, Moli_Err *err);
uint8_t *moli_snapshot(Moli_Handle h, int64_t *out_len, Moli_Err *err);
void     moli_snapshot_free(uint8_t *p);

/* statistics */
int32_t  moli_stats(Moli_Handle h, Moli_Stats *out, Moli_Err *err);

/* user entries (borrowed for the call; NULL = empty optional string) */
int32_t  moli_add_user_entries(Moli_Handle h,
                               const Moli_User_Entry *entries, int64_t count,
                               Moli_Err *err);

/* tokenize family; opts NULL = default */
Moli_Result moli_tokenize(Moli_Handle h, const uint8_t *text, int64_t len,
                          const Moli_Tokenize_Options *opts, Moli_Err *err);
Moli_Result moli_wakachi(Moli_Handle h, const uint8_t *text, int64_t len,
                         const Moli_Tokenize_Options *opts, Moli_Err *err);
Moli_Result moli_spans(Moli_Handle h, const uint8_t *text, int64_t len,
                       const Moli_Tokenize_Options *opts, Moli_Err *err);
Moli_Result moli_nbest(Moli_Handle h, const uint8_t *text, int64_t len, int32_t k,
                       const Moli_Tokenize_Options *opts, Moli_Err *err);
Moli_Result moli_tokenize_constrained(Moli_Handle h, const uint8_t *text, int64_t len,
                                      const Moli_Token_Constraint *tokens, int64_t n_tokens,
                                      const Moli_Boundary_Constraint *boundaries, int64_t n_boundaries,
                                      const Moli_Tokenize_Options *opts, Moli_Err *err);
uint8_t     moli_classify_locale(Moli_Handle h, const uint8_t *text, int64_t len);

/* results */
int64_t                 moli_result_count(Moli_Result r);
const Moli_Morpheme    *moli_result_morphemes(Moli_Result r);
const Moli_Path        *moli_result_paths(Moli_Result r);
int64_t                 moli_result_paths_count(Moli_Result r);
const uint8_t          *moli_result_blob(Moli_Result r);
int64_t                 moli_result_blob_len(Moli_Result r);
void                    moli_result_free(Moli_Result r);

/* cancellation */
Moli_Cancel moli_cancel_new(void);
void        moli_cancel(Moli_Cancel c);
void        moli_cancel_free(Moli_Cancel c);

#ifdef __cplusplus
}
#endif

#endif /* MOLI_ABI_H */
