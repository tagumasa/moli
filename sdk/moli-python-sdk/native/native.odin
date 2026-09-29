// libmoli — the C ABI over the moli analysis library.
//
// One shared library, no host-side start-up contract: every export is a
// `proc "c"` that establishes its own runtime context, so the library
// works under plain link/dlopen with no init call. The C header mirror
// (c/moli_abi.h in the SDK) is hand-written on both sides; bindings
// verify their mirror against moli_abi_check at load time so a layout
// mismatch fails loudly instead of corrupting memory.
//
// Ownership at a glance: input paths/text/option strings are borrowed
// for the duration of a call only; everything a caller receives
// (results, snapshot bytes) is owned by the caller and released with
// the matching moli_*_free export.
package native

import "base:runtime"

import "core:fmt"
import "core:mem"

import "moli:moli"

// ABI_VERSION guards the struct layouts, code numbering, and export
// signatures below. Bump it on any layout change, code renumbering, or
// signature/semantic change. Additive exports bump the minor half
// (major*100 + minor). Version 3 added Stats_FFI.entries_hash.
// Version 4 added the constraint wire structs, the two constraint
// codes, and moli_tokenize_constrained. Version 5 appended the four
// error-vocabulary member counts to the check vector's tail - the
// codes the C side switches on were the one mirrored vocabulary the
// machine check did not carry. Version 6 added Save_Code.Format_Limit
// (the qdct builder now refuses analyzers past the record forms'
// representational limits instead of narrowing fields). Version 7 gave
// Err_FFI a fourth payload field d (Constraint_Reason crosses the ABI
// as data), rejected negative constraint counts at the export, and
// appended every enum's per-member ordinals to the check vector - a
// reorder inside an enum keeps the count but changes these, which is
// what the header's re-verification claim needed.
ABI_VERSION :: 7

// LIBRARY_VERSION is the moli version string returned by moli_version.
LIBRARY_VERSION :: "0.1.0"

// Failure domains; the code vocabulary is closed per domain and
// mirrors the library's error model one-to-one: each `*_Code` enum is
// the ABI-flattened form of the matching core failure enum
// (`Load_Code` ← `Load_Fault`, `Tokenize_Code` ← `Tokenize_Fault`,
// `Save_Code` ← `Save_Fault`), with the union's context members folded
// into plain codes. Wire structs carry the `_FFI` suffix; the C-side
// `Moli_*` names in moli_abi.h map to them by concept.
Domain :: enum u32 {
	Load,
	Tokenize,
	Save,
}

Load_Code :: enum u32 {
	File_Not_Found,
	Invalid_Format,
	OutOfMemory,
	Schema_Mismatch,
	IO_Read,
}

Tokenize_Code :: enum u32 {
	OutOfMemory,
	Unavailable,
	Malformed_Input,
	Cancelled,
	Bad_Constraint,          // constraint set rejected before analysis; a=index, b=start, c=end
	Constraint_Unsatisfiable, // constraint mask left no path; a=byte offset
}

Save_Code :: enum u32 {
	IO_Write,
	OutOfMemory,
	Unavailable,
	Format_Limit,
}

// Err_FFI is the detail a caller may receive through the trailing
// `err` out-parameter of a fallible export (NULL = caller declines).
// Codes carry the payload; `message` is human context only — never a
// matching key. a/b/c/d are the four payload slots (d: the constraint
// rejection's reason ordinal).
Err_FFI :: struct {
	domain:  u32,
	code:    u32,
	a:       i64,
	b:       i64,
	c:       i64,
	message: [192]u8,
	d:       i64,
}

// Morpheme_FFI is the flat morpheme layout (72 bytes, natural
// alignment: 17 fields, is_unknown at 64, padded to the 8-byte
// stride). All strings are byte ranges into the result blob; the
// blob lives until moli_result_free.
Morpheme_FFI :: struct {
	start:           i64,
	end:             i64,
	surf_off:        i32,
	surf_len:        i32,
	pos_off:         i32,
	pos_len:         i32,
	lemma_off:       i32,
	lemma_len:       i32,
	reading_off:     i32,
	reading_len:     i32,
	jyutping_off:    i32,
	jyutping_len:    i32,
	entry_id:        i32,
	cost:            i16,
	locale:          u8,
	char_class:      u8,
	is_unknown:      u8,
}

// Path_FFI is one n-best path: a cost plus a contiguous range in the
// result's morpheme array.
Path_FFI :: struct {
	cost:  i64,
	first: i32,
	count: i32,
}

// Load_Options_FFI mirrors the library's load options at the ABI
// (NULL path fields mean discover/omit; the zero struct is the
// library's default load).
Load_Options_FFI :: struct {
	unk_def_path:      cstring,
	char_def_path:     cstring,
	matrix_def_path:   cstring,
	qpat_path:         cstring,
	jyutping_csv_path: cstring,
	threads:           i32,
	mode:              u8,
	lemma_locale:      u8,
	flat_char_class:   u8,
}

// Tokenize_Options_FFI mirrors the per-call tokenize options (NULL
// pointer = all defaults; NULL cancel = no cancellation).
Tokenize_Options_FFI :: struct {
	cancel:            rawptr,
	unk_cost_bias:     i32,
	unk_cost_per_rune: i32,
	normalize_nfc:     u8,
	strict_utf8:       u8,
}

// User_Entry_FFI is one caller-supplied dictionary row, borrowed for
// the duration of moli_add_user_entries (the library clones what it
// keeps). Empty strings are expressed as NULL.
User_Entry_FFI :: struct {
	surface:           cstring,
	pos:               cstring,
	lemma:             cstring,
	reading:           cstring,
	reading_jyutping:  cstring,
	left_id:           i16,
	right_id:          i16,
	cost:              i16,
}

// Token_Constraint_FFI is one borrowed pin for the constrained
// tokenize export: text[start:end] must surface as exactly one
// morpheme whose joined POS sits under pos as whole columns; NULL pos
// accepts any POS. Borrowed for the call's duration only.
Token_Constraint_FFI :: struct {
	start: i64,
	end:   i64,
	pos:   cstring,
}

// Boundary_Constraint_FFI is one borrowed boundary pin: at is a byte
// offset strictly inside the text; must_exist 1 drops candidates
// spanning it (a boundary is forced), 0 drops candidates ending on it
// (the winning path crosses inside a morpheme).
Boundary_Constraint_FFI :: struct {
	at:        i64,
	must_exist: u8,
}

// SKIPPED_CAP bounds the wire struct's skipped[] pointers and the
// handle's scratch they borrow - one definition for both sides of the
// mirror (the C header carries the same count; moli_stats clamps to
// the scratch side).
SKIPPED_CAP :: 8

// SKIPPED_NAME_CAP is each skipped name's slot in that scratch:
// longer names truncate at the NUL, the same on both sides of the
// mirror.
SKIPPED_NAME_CAP :: 256

// Stats_FFI mirrors the analyzer inventory. The skipped[] pointers
// borrow a per-handle scratch buffer that each moli_stats call on that
// handle rewrites (every name NUL-terminated in its row); the wrapper
// serializes stats calls per handle (its mut lock) so one call's
// strings are copied out before the next call rewrites the scratch.
Stats_FFI :: struct {
	entries:         i64,
	terminals:       i64,
	cedar_nodes:     i64,
	unk_rules:       i64,
	unk_patterns:    i64,
	matrix_left:     i64,
	matrix_right:    i64,
	matrix_cells:    i64,
	matrix_explicit: i64,
	matrix_density:  f64,
	entries_hash:    u64,
	skipped:         [SKIPPED_CAP]cstring,
	skipped_count:   i64,
}

// Shim_Handle is the ABI's analyzer handle (opaque void* to C): the
// library analyzer plus the stats scratch the ABI owns.
Shim_Handle :: struct {
	a:           ^moli.Analyzer,
	skipped_buf: [SKIPPED_CAP][SKIPPED_NAME_CAP]u8,
}

// ABI_BLOB_MAX bounds a result blob: every offset and per-field
// length in the wire structs is i32, so a blob past the i32 limit
// would wrap mid-fill and trap the bounds check inside a proc "c"
// export. Producers refuse it - never a crash, never a silent
// truncation.
ABI_BLOB_MAX :: int(max(i32))

// Result_Box is the ABI's result handle. It owns exactly three
// allocations in the runtime default allocator (plus itself); the
// caller frees the whole set with moli_result_free. The library never
// touches a result after the producing call returns.
Result_Box :: struct {
	morphemes: []Morpheme_FFI,
	paths:     []Path_FFI,
	blob:      []u8,
}

// TOKENIZE_STACK_BYTES sizes the per-call stack arena_allocator; inputs whose
// output overflows it retry once on a heap arena_allocator sized from the input
// length before surfacing OutOfMemory.
TOKENIZE_STACK_BYTES :: 64 * 1024

// TOKENIZE_RETAIN_MAX bounds the per-calling-thread retained scratch.
// Request arenas at or below it stay mapped on the calling thread
// across calls (reset per call), so request-sized calls stop paying a
// fresh map's first-touch page faults on every entry — the measured
// ~5x distance between the SDK and the engine on repeated calls. The
// full-margin block sizing (len*1024 plus the stack base) keeps the
// cap covering single calls up to just under 64 KiB of input; the
// tight tier below extends retained coverage to just under 128 KiB.
// Past both, the rare unchunked-huge call allocates and releases per
// call: no thread pins unbounded memory for the shape the docs say to
// chunk. The cap is the per-thread worst-case resident cost — 64 MiB,
// reached only by a thread that actually tokenized an input of that
// size class.
TOKENIZE_RETAIN_MAX :: 64 << 20

// TOKENIZE_TIGHT_PER_INPUT sizes the first-attempt request arena for
// inputs whose full-margin block (len*1024 + the stack base) exceeds
// TOKENIZE_RETAIN_MAX: the measured transient peak is ~415 arena bytes
// per input byte (ipadic Viterbi under a tracking allocator), so 512
// keeps a ~1.24x margin while fitting inputs up to ~128 KiB under the
// cap the full margin would push onto the per-call fresh-map path. A
// refusal on the tight tier retries once at the full margin, so a
// density above the margin costs one discarded analysis — never an
// OutOfMemory the full-margin sizing alone would not also return.
TOKENIZE_TIGHT_PER_INPUT :: 512

// TOKENIZE_FULL_MARGIN_PER_INPUT sizes the full-margin request arena:
// len*TOKENIZE_FULL_MARGIN_PER_INPUT plus the stack base. It is the
// tier inputs under the retain cap run on directly and the one the
// tight tier's refusal retries at.
TOKENIZE_FULL_MARGIN_PER_INPUT :: 1024

// retained_scratch is the calling thread's tokenize arena backing.
// Thread-private by construction, so the shared-analyzer concurrency
// contract is untouched; the core never sees it. It dies with the
// thread (or the process) — there is no release call by design.
@(thread_local)
retained_scratch: []u8

// ensure_retained grows the calling thread's retained scratch to at
// least min_len bytes, releasing the current backing first; false is
// the allocation failure the callers surface as OutOfMemory. Both
// retained tiers (full margin, tight) grow through this one proc.
ensure_retained :: proc(min_len: int) -> bool {
	if len(retained_scratch) >= min_len { return true }
	if len(retained_scratch) > 0 {
		delete(retained_scratch, context.allocator)
	}
	block, aerr := make([]u8, min_len, context.allocator)
	if aerr != nil { return false }
	retained_scratch = block
	return true
}

// ABI_CHECK_LEN is the number of i64 values moli_abi_check fills:
// [abi version, Morpheme_FFI size + 17 field offsets, Err_FFI size +
// 7 field offsets, Path_FFI size + 3 field offsets, Load_Options_FFI
// size + 9 field offsets, Tokenize_Options_FFI size + 5 field offsets,
// User_Entry_FFI size + 8 field offsets, Stats_FFI size + 13 field
// offsets, Token_Constraint_FFI size + 3 field offsets,
// Boundary_Constraint_FFI size + 2 field offsets, member counts of
// the four core enums and the four error vocabularies, then every
// enum's per-member ordinals in declaration order (a reorder inside
// an enum keeps the count but changes these)]. Every mirrored
// struct's layout and every mirrored ordinal is machine-checked, so a
// field reorder, a width change, or an enum reshuffle on either side
// fails the import-time verification.
ABI_CHECK_LEN :: 140

@(export) moli_abi_version :: proc "c" () -> u32 {
	return ABI_VERSION
}

@(export) moli_version :: proc "c" () -> cstring {
	return cstring(LIBRARY_VERSION)
}

@(export) moli_abi_check :: proc "c" (out_values: ^i64, cap: i32) -> i32 {
	values := [ABI_CHECK_LEN]i64{
		ABI_VERSION,
		size_of(Morpheme_FFI),
		i64(offset_of(Morpheme_FFI, start)),
		i64(offset_of(Morpheme_FFI, end)),
		i64(offset_of(Morpheme_FFI, surf_off)),
		i64(offset_of(Morpheme_FFI, surf_len)),
		i64(offset_of(Morpheme_FFI, pos_off)),
		i64(offset_of(Morpheme_FFI, pos_len)),
		i64(offset_of(Morpheme_FFI, lemma_off)),
		i64(offset_of(Morpheme_FFI, lemma_len)),
		i64(offset_of(Morpheme_FFI, reading_off)),
		i64(offset_of(Morpheme_FFI, reading_len)),
		i64(offset_of(Morpheme_FFI, jyutping_off)),
		i64(offset_of(Morpheme_FFI, jyutping_len)),
		i64(offset_of(Morpheme_FFI, entry_id)),
		i64(offset_of(Morpheme_FFI, cost)),
		i64(offset_of(Morpheme_FFI, locale)),
		i64(offset_of(Morpheme_FFI, char_class)),
		i64(offset_of(Morpheme_FFI, is_unknown)),
		size_of(Err_FFI),
		i64(offset_of(Err_FFI, domain)),
		i64(offset_of(Err_FFI, code)),
		i64(offset_of(Err_FFI, a)),
		i64(offset_of(Err_FFI, b)),
		i64(offset_of(Err_FFI, c)),
		i64(offset_of(Err_FFI, message)),
		i64(offset_of(Err_FFI, d)),
		size_of(Path_FFI),
		i64(offset_of(Path_FFI, cost)),
		i64(offset_of(Path_FFI, first)),
		i64(offset_of(Path_FFI, count)),
		size_of(Load_Options_FFI),
		i64(offset_of(Load_Options_FFI, unk_def_path)),
		i64(offset_of(Load_Options_FFI, char_def_path)),
		i64(offset_of(Load_Options_FFI, matrix_def_path)),
		i64(offset_of(Load_Options_FFI, qpat_path)),
		i64(offset_of(Load_Options_FFI, jyutping_csv_path)),
		i64(offset_of(Load_Options_FFI, threads)),
		i64(offset_of(Load_Options_FFI, mode)),
		i64(offset_of(Load_Options_FFI, lemma_locale)),
		i64(offset_of(Load_Options_FFI, flat_char_class)),
		size_of(Tokenize_Options_FFI),
		i64(offset_of(Tokenize_Options_FFI, cancel)),
		i64(offset_of(Tokenize_Options_FFI, unk_cost_bias)),
		i64(offset_of(Tokenize_Options_FFI, unk_cost_per_rune)),
		i64(offset_of(Tokenize_Options_FFI, normalize_nfc)),
		i64(offset_of(Tokenize_Options_FFI, strict_utf8)),
		size_of(User_Entry_FFI),
		i64(offset_of(User_Entry_FFI, surface)),
		i64(offset_of(User_Entry_FFI, pos)),
		i64(offset_of(User_Entry_FFI, lemma)),
		i64(offset_of(User_Entry_FFI, reading)),
		i64(offset_of(User_Entry_FFI, reading_jyutping)),
		i64(offset_of(User_Entry_FFI, left_id)),
		i64(offset_of(User_Entry_FFI, right_id)),
		i64(offset_of(User_Entry_FFI, cost)),
		size_of(Stats_FFI),
		i64(offset_of(Stats_FFI, entries)),
		i64(offset_of(Stats_FFI, terminals)),
		i64(offset_of(Stats_FFI, cedar_nodes)),
		i64(offset_of(Stats_FFI, unk_rules)),
		i64(offset_of(Stats_FFI, unk_patterns)),
		i64(offset_of(Stats_FFI, matrix_left)),
		i64(offset_of(Stats_FFI, matrix_right)),
		i64(offset_of(Stats_FFI, matrix_cells)),
		i64(offset_of(Stats_FFI, matrix_explicit)),
		i64(offset_of(Stats_FFI, matrix_density)),
		i64(offset_of(Stats_FFI, entries_hash)),
		i64(offset_of(Stats_FFI, skipped)),
		i64(offset_of(Stats_FFI, skipped_count)),
		size_of(Token_Constraint_FFI),
		i64(offset_of(Token_Constraint_FFI, start)),
		i64(offset_of(Token_Constraint_FFI, end)),
		i64(offset_of(Token_Constraint_FFI, pos)),
		size_of(Boundary_Constraint_FFI),
		i64(offset_of(Boundary_Constraint_FFI, at)),
		i64(offset_of(Boundary_Constraint_FFI, must_exist)),
		len(moli.Language),
		len(moli.Locale),
		len(moli.Mode),
		len(moli.Char_Class),
		len(Domain),
		len(Load_Code),
		len(Tokenize_Code),
		len(Save_Code),
		// Per-member ordinals, in declaration order: the core enums,
		// the vocabularies, and the constraint reasons.
		i64(moli.Language.Japanese), i64(moli.Language.ChineseCN), i64(moli.Language.ChineseTW),
		i64(moli.Language.ChineseHK), i64(moli.Language.EnglishGB), i64(moli.Language.EnglishUS),
		i64(moli.Language.German),
		i64(moli.Locale.None), i64(moli.Locale.CN), i64(moli.Locale.TW), i64(moli.Locale.HK),
		i64(moli.Locale.GB), i64(moli.Locale.US),
		i64(moli.Mode.Viterbi), i64(moli.Mode.LongestMatch),
		i64(moli.Char_Class.Unknown), i64(moli.Char_Class.Hiragana), i64(moli.Char_Class.Katakana),
		i64(moli.Char_Class.Kanji), i64(moli.Char_Class.Hanzi), i64(moli.Char_Class.HalfwidthKatakana),
		i64(moli.Char_Class.Bopomofo), i64(moli.Char_Class.ASCIILetter), i64(moli.Char_Class.Digit),
		i64(moli.Char_Class.Punct), i64(moli.Char_Class.Space), i64(moli.Char_Class.Symbol),
		i64(moli.Char_Class.Emoji),
		i64(Domain.Load), i64(Domain.Tokenize), i64(Domain.Save),
		i64(Load_Code.File_Not_Found), i64(Load_Code.Invalid_Format), i64(Load_Code.OutOfMemory),
		i64(Load_Code.Schema_Mismatch), i64(Load_Code.IO_Read),
		i64(Tokenize_Code.OutOfMemory), i64(Tokenize_Code.Unavailable), i64(Tokenize_Code.Malformed_Input),
		i64(Tokenize_Code.Cancelled), i64(Tokenize_Code.Bad_Constraint), i64(Tokenize_Code.Constraint_Unsatisfiable),
		i64(Save_Code.IO_Write), i64(Save_Code.OutOfMemory), i64(Save_Code.Unavailable),
		i64(Save_Code.Format_Limit),
		i64(moli.Constraint_Reason.Out_Of_Bounds), i64(moli.Constraint_Reason.Empty_Span),
		i64(moli.Constraint_Reason.Not_Rune_Boundary), i64(moli.Constraint_Reason.Token_Overlap),
		i64(moli.Constraint_Reason.Boundary_Inside_Token), i64(moli.Constraint_Reason.Boundary_At_Token_Edge),
		i64(moli.Constraint_Reason.Conflicting_Boundaries), i64(moli.Constraint_Reason.Bad_Pos_Pattern),
		i64(moli.Constraint_Reason.Normalization_Rescaled),
	}
	n := i32(ABI_CHECK_LEN)
	if cap < n { n = cap }
	if out_values != nil {
		dst := cast([^]i64)(out_values)
		for i in 0..<n {
			dst[i] = values[i]
		}
	}
	return n
}

// --- error filling -------------------------------------------------
// Every writer is nil-safe: a NULL err out-parameter means the caller
// declined the detail, and failure reporting must not crash on it.

set_msg :: proc(err: ^Err_FFI, format: string, args: ..any) {
	if err == nil { return }
	written := fmt.bprintf(err.message[:], format, ..args)
	n := len(written)
	if n >= len(err.message) { n = len(err.message) - 1 }
	err.message[n] = 0
}

fail_load :: proc(err: ^Err_FFI, code: Load_Code, format: string, args: ..any) {
	if err == nil { return }
	err^ = {}
	err.domain = u32(Domain.Load)
	err.code = u32(code)
	set_msg(err, format, ..args)
}

fail_token :: proc(err: ^Err_FFI, code: Tokenize_Code, format: string, args: ..any) {
	if err == nil { return }
	err^ = {}
	err.domain = u32(Domain.Tokenize)
	err.code = u32(code)
	set_msg(err, format, ..args)
}

fail_save :: proc(err: ^Err_FFI, code: Save_Code, format: string, args: ..any) {
	if err == nil { return }
	err^ = {}
	err.domain = u32(Domain.Save)
	err.code = u32(code)
	set_msg(err, format, ..args)
}

// fill_load_err translates a core load failure into the ABI result.
// The fault tag and message text come from the core's classifier and
// canonical renderer; this edge only maps the code, keeps the
// schema-mismatch payload fields, and appends the path where the
// fault names a file.
fill_load_err :: proc(err: ^Err_FFI, e: moli.Load_Err, path: string) {
	if err == nil || e == nil { return }
	fault := moli.load_fault(e)

	code: Load_Code
	switch fault {
	case .File_Not_Found: code = .File_Not_Found
	case .Invalid_Format: code = .Invalid_Format
	case .OutOfMemory:    code = .OutOfMemory
	case .Nil_Handle:     code = .Invalid_Format // unreachable through this ABI: the wrapper rejects a nil handle first
	case .IO_Read:        code = .IO_Read
	}

	err^ = {}
	err.domain = u32(Domain.Load)
	err.code = u32(code)
	switch v in e {
	case moli.Schema_Mismatch_Error:
		err.code = u32(Load_Code.Schema_Mismatch)
		err.a = i64(v.line)
		err.b = i64(v.expected)
		err.c = i64(v.got)
	case moli.Load_Fault: // no payload
	}

	msg := moli.load_error_message(e, context.temp_allocator)
	defer delete(msg, context.temp_allocator)
	names_file := fault == .File_Not_Found || fault == .IO_Read || fault == .Invalid_Format
	if path != "" && names_file {
		set_msg(err, "load: {}: {}", msg, path)
	} else {
		set_msg(err, "load: {}", msg)
	}
}

// fill_token_err translates a core tokenize failure into the ABI
// result; codes and text come from the core vocabulary, the byte
// offset rides the payload field. One switch names the variant, its
// code, and its payload together - a new variant extends one arm, not
// two parallel switches.
fill_token_err :: proc(err: ^Err_FFI, e: moli.Tokenize_Err) {
	if err == nil || e == nil { return }

	err^ = {}
	err.domain = u32(Domain.Tokenize)
	switch v in e {
	case moli.Malformed_Input_Error:
		err.code = u32(Tokenize_Code.Malformed_Input)
		err.a = i64(v.byte_offset)
	case moli.Cancelled_Error:
		err.code = u32(Tokenize_Code.Cancelled)
		err.a = i64(v.byte_offset)
	case moli.Bad_Constraint_Error:
		err.code = u32(Tokenize_Code.Bad_Constraint)
		err.a = i64(v.index)
		err.b = i64(v.start)
		err.c = i64(v.end)
		err.d = i64(v.reason)
	case moli.Unsatisfiable_Error:
		err.code = u32(Tokenize_Code.Constraint_Unsatisfiable)
		err.a = i64(v.byte_offset)
	case moli.Tokenize_Fault:
		switch v {
		case .OutOfMemory: err.code = u32(Tokenize_Code.OutOfMemory)
		case .Unavailable: err.code = u32(Tokenize_Code.Unavailable)
		}
	}

	msg := moli.tokenize_error_message(e, context.temp_allocator)
	defer delete(msg, context.temp_allocator)
	set_msg(err, "tokenize: {}", msg)
}

// fill_save_err translates a core save failure into the ABI result;
// what (the operation name) is this edge's context, not the core's.
fill_save_err :: proc(err: ^Err_FFI, e: moli.Save_Err, what: string) {
	if err == nil || e == nil { return }

	code: Save_Code
	switch moli.save_fault(e) {
	case .IO_Write:     code = .IO_Write
	case .OutOfMemory:  code = .OutOfMemory
	case .Unavailable:  code = .Unavailable
	case .Format_Limit: code = .Format_Limit
	}

	msg := moli.save_error_message(e, context.temp_allocator)
	defer delete(msg, context.temp_allocator)
	fail_save(err, code, "{}: {}", what, msg)
}

// --- option mapping ------------------------------------------------

cview :: proc(p: cstring) -> string {
	if p == nil { return "" }
	return string(p)
}

bytes_of :: proc(p: ^u8, n: i64) -> []u8 {
	if p == nil || n <= 0 { return nil }
	mp := cast([^]u8)(p)
	return mp[:int(n)]
}

load_opts :: proc(p: ^Load_Options_FFI) -> moli.Load_Options {
	o: moli.Load_Options
	if p == nil { return o }
	o.unk_def_path = cview(p.unk_def_path)
	o.char_def_path = cview(p.char_def_path)
	o.matrix_def_path = cview(p.matrix_def_path)
	o.qpat_path = cview(p.qpat_path)
	o.jyutping_csv_path = cview(p.jyutping_csv_path)
	o.threads = int(p.threads)
	o.mode = moli.Mode(p.mode)
	o.lemma_locale = moli.Locale(p.lemma_locale)
	o.flat_char_class = p.flat_char_class != 0
	return o
}

tok_opts :: proc(p: ^Tokenize_Options_FFI) -> moli.Tokenize_Options {
	o: moli.Tokenize_Options
	if p == nil { return o }
	o.unk_cost_bias = p.unk_cost_bias
	o.unk_cost_per_rune = p.unk_cost_per_rune
	o.normalize_nfc = p.normalize_nfc != 0
	o.strict_utf8 = p.strict_utf8 != 0
	if p.cancel != nil {
		o.cancel_token = cast(^moli.Cancel_Token)p.cancel
	}
	return o
}

// new_handle wraps a loaded analyzer value into a fresh ABI handle.
// The zero Analyzer is a safe half-built state for the library's own
// failure paths to unwind through.
new_handle :: proc() -> ^Shim_Handle {
	h := new(Shim_Handle)
	h^ = {}
	h.a = new(moli.Analyzer)
	return h
}

// --- lifecycle -----------------------------------------------------

@(export) moli_load :: proc "c" (lang: u8, csv_path: cstring, opts_p: ^Load_Options_FFI, err: ^Err_FFI) -> ^Shim_Handle {
	context = runtime.default_context()
	if lang >= len(moli.Language) {
		fail_load(err, .Invalid_Format, "load: language ordinal {} out of range", lang)
		return nil
	}
	if opts_p != nil && (opts_p.mode >= len(moli.Mode) || opts_p.lemma_locale >= len(moli.Locale)) {
		fail_load(err, .Invalid_Format, "load: invalid enum ordinal in options")
		return nil
	}
	h := new_handle()
	a_val, lerr := moli.load(moli.Language(lang), cview(csv_path), load_opts(opts_p), context.allocator)
	if lerr != nil {
		mem.free(h.a)
		mem.free(h)
		fill_load_err(err, lerr, cview(csv_path))
		return nil
	}
	h.a^ = a_val
	return h
}

@(export) moli_load_bytes :: proc "c" (lang: u8, csv: ^u8, csv_len: i64, opts_p: ^Load_Options_FFI, err: ^Err_FFI) -> ^Shim_Handle {
	context = runtime.default_context()
	if lang >= len(moli.Language) {
		fail_load(err, .Invalid_Format, "load: language ordinal {} out of range", lang)
		return nil
	}
	if opts_p != nil && (opts_p.mode >= len(moli.Mode) || opts_p.lemma_locale >= len(moli.Locale)) {
		fail_load(err, .Invalid_Format, "load: invalid enum ordinal in options")
		return nil
	}
	h := new_handle()
	// The CSV bytes are borrowed: the library only reads them during
	// the parse, so no copy is made at this boundary.
	a_val, lerr := moli.load_bytes(moli.Language(lang), bytes_of(csv, csv_len), load_opts(opts_p), context.allocator)
	if lerr != nil {
		mem.free(h.a)
		mem.free(h)
		fill_load_err(err, lerr, "")
		return nil
	}
	h.a^ = a_val
	return h
}

@(export) moli_load_qdct :: proc "c" (path: cstring, err: ^Err_FFI) -> ^Shim_Handle {
	context = runtime.default_context()
	h := new_handle()
	a_val, lerr := moli.load_qdct(cview(path), context.allocator)
	if lerr != nil {
		mem.free(h.a)
		mem.free(h)
		fill_load_err(err, lerr, cview(path))
		return nil
	}
	h.a^ = a_val
	return h
}

@(export) moli_load_qdct_mmap :: proc "c" (path: cstring, err: ^Err_FFI) -> ^Shim_Handle {
	context = runtime.default_context()
	h := new_handle()
	a_val, lerr := moli.load_qdct_mmap(cview(path), context.allocator)
	if lerr != nil {
		mem.free(h.a)
		mem.free(h)
		fill_load_err(err, lerr, cview(path))
		return nil
	}
	h.a^ = a_val
	return h
}

@(export) moli_load_qdct_bytes :: proc "c" (data: ^u8, data_len: i64, err: ^Err_FFI) -> ^Shim_Handle {
	context = runtime.default_context()
	src := bytes_of(data, data_len)
	// The image bytes must be copied once here: the library takes
	// ownership of the buffer it is handed (and releases it on every
	// failure path itself), and a host cannot hand an immutable host
	// buffer to an ownership-transfer call.
	image, aerr := make([]u8, len(src), context.allocator)
	if aerr != nil {
		fail_load(err, .OutOfMemory, "load: out of memory")
		return nil
	}
	copy(image, src)
	h := new_handle()
	a_val, lerr := moli.load_qdct_bytes(image, context.allocator)
	if lerr != nil {
		// load_qdct_bytes consumed the copy (failure paths included);
		// only the handle shells remain ours to release.
		mem.free(h.a)
		mem.free(h)
		fill_load_err(err, lerr, "")
		return nil
	}
	h.a^ = a_val
	return h
}

@(export) moli_clone :: proc "c" (h: ^Shim_Handle, err: ^Err_FFI) -> ^Shim_Handle {
	context = runtime.default_context()
	if h == nil {
		fail_save(err, .Unavailable, "clone: nil handle")
		return nil
	}
	clone_out := new_handle()
	a_val, serr := moli.clone(h.a, context.allocator)
	if serr != nil {
		mem.free(clone_out.a)
		mem.free(clone_out)
		fill_save_err(err, serr, "clone")
		return nil
	}
	clone_out.a^ = a_val
	return clone_out
}

@(export) moli_free :: proc "c" (h: ^Shim_Handle) {
	context = runtime.default_context()
	if h == nil { return }
	moli.free(h.a)
	mem.free(h.a)
	mem.free(h)
}

// --- snapshot ------------------------------------------------------

@(export) moli_save_qdct :: proc "c" (h: ^Shim_Handle, path: cstring, err: ^Err_FFI) -> i32 {
	context = runtime.default_context()
	if h == nil {
		fail_save(err, .Unavailable, "save: nil handle")
		return 1
	}
	if serr := moli.save_qdct(h.a, cview(path), context.allocator); serr != nil {
		fill_save_err(err, serr, "save")
		return 1
	}
	return 0
}

// SNAPSHOT_LEN_PREFIX is the native-endian i64 length the snapshot
// block carries in front of the image bytes, so the paired free can
// size the single heap block it releases. The pointer never leaves the
// process, so no cross-endian contract is implied.
SNAPSHOT_LEN_PREFIX :: 8

@(export) moli_snapshot :: proc "c" (h: ^Shim_Handle, out_len: ^i64, err: ^Err_FFI) -> ^u8 {
	context = runtime.default_context()
	if h == nil {
		fail_save(err, .Unavailable, "snapshot: nil handle")
		return nil
	}
	image, serr := moli.snapshot(h.a, context.allocator)
	if serr != nil {
		fill_save_err(err, serr, "snapshot")
		return nil
	}
	if len(image) == 0 {
		delete(image, context.allocator)
		if out_len != nil { out_len^ = 0 }
		return nil
	}
	block, aerr := make([]u8, SNAPSHOT_LEN_PREFIX + len(image), context.allocator)
	if aerr != nil {
		delete(image, context.allocator)
		fail_save(err, .OutOfMemory, "snapshot: out of memory")
		return nil
	}
	len_slot := cast(^i64)(&block[0])
	len_slot^ = i64(len(image))
	copy(block[SNAPSHOT_LEN_PREFIX:], image)
	delete(image, context.allocator)
	if out_len != nil { out_len^ = i64(len(image)) }
	return &block[SNAPSHOT_LEN_PREFIX]
}

@(export) moli_snapshot_free :: proc "c" (p: ^u8) {
	context = runtime.default_context()
	if p == nil { return }
	base := cast(^u8)(cast(uintptr)(p) - SNAPSHOT_LEN_PREFIX)
	len_slot := cast(^i64)(base)
	n := int(len_slot^)
	block := cast([^]u8)(base)
	delete(block[:n + SNAPSHOT_LEN_PREFIX], context.allocator)
}

// --- statistics ----------------------------------------------------

@(export) moli_stats :: proc "c" (h: ^Shim_Handle, out_s: ^Stats_FFI, err: ^Err_FFI) -> i32 {
	context = runtime.default_context()
	if h == nil || out_s == nil {
		fail_save(err, .Unavailable, "stats: nil handle")
		return 1
	}
	s, serr := moli.stats(h.a)
	if serr != nil {
		fill_save_err(err, serr, "stats")
		return 1
	}
	out_s^ = {}
	out_s.entries = i64(s.entries)
	out_s.terminals = i64(s.terminals)
	out_s.cedar_nodes = i64(s.cedar_nodes)
	out_s.unk_rules = i64(s.unk_rules)
	out_s.unk_patterns = i64(s.unk_patterns)
	out_s.matrix_left = i64(s.matrix_left)
	out_s.matrix_right = i64(s.matrix_right)
	out_s.matrix_cells = i64(s.matrix_cells)
	out_s.matrix_explicit = i64(s.matrix_explicit)
	out_s.matrix_density = s.matrix_density
	out_s.entries_hash = s.entries_hash
	// skipped[] borrows the handle's scratch: rewritten by every stats
	// call on this handle, released with the handle. Copy before the
	// next call.
	n := len(s.skipped)
	if n > len(h.skipped_buf) { n = len(h.skipped_buf) }
	for i in 0..<n {
		name := s.skipped[i]
		dst := h.skipped_buf[i][:]
		l := len(name)
		if l > len(dst) - 1 { l = len(dst) - 1 }
		copy(dst[:l], transmute([]u8)name[:l])
		dst[l] = 0
		out_s.skipped[i] = cast(cstring)&h.skipped_buf[i][0]
	}
	out_s.skipped_count = i64(n)
	return 0
}

// --- user entries --------------------------------------------------

@(export) moli_add_user_entries :: proc "c" (h: ^Shim_Handle, entries: ^User_Entry_FFI, count: i64, err: ^Err_FFI) -> i32 {
	context = runtime.default_context()
	if h == nil || count < 0 || (entries == nil && count > 0) {
		fail_load(err, .Invalid_Format, "add_user_entries: invalid arguments")
		return 1
	}
	if count == 0 { return 0 }
	list, aerr := make([dynamic]moli.User_Entry, 0, int(count), context.allocator)
	if aerr != nil {
		fail_load(err, .OutOfMemory, "add_user_entries: out of memory")
		return 1
	}
	entries_mp := cast([^]User_Entry_FFI)(entries)
	for i in 0..<int(count) {
		f := &entries_mp[i]
		if _, werr := append(&list, moli.User_Entry{
			surface           = cview(f.surface),
			left_id           = f.left_id,
			right_id          = f.right_id,
			cost              = f.cost,
			pos               = cview(f.pos),
			lemma             = cview(f.lemma),
			reading           = cview(f.reading),
			reading_jyutping  = cview(f.reading_jyutping),
		}); werr != nil {
			delete(list)
			fail_load(err, .OutOfMemory, "add_user_entries: out of memory")
			return 1
		}
	}
	lerr := moli.add_user_entries(h.a, list[:])
	delete(list)
	if lerr != nil {
		fill_load_err(err, lerr, "")
		return 1
	}
	return 0
}

// --- tokenize family -----------------------------------------------

Run_Kind :: enum {
	Morphs,
	Wakachi,
	Spans,
	Nbest,
}

Run_Out :: struct {
	morphs:  []moli.Morpheme,
	wakachi: []string,
	spans:   []moli.Surface_Span,
	// nbest keeps its dynamic array alive: the boxed copies are made
	// by the caller after this returns, so the backing must survive
	// run_tokenize. Deleted by the caller after boxing.
	nbest:   [dynamic]moli.NBest_Path,
}

run_tokenize :: proc(kind: Run_Kind, a: ^moli.Analyzer, text: string, k: int, opts: moli.Tokenize_Options, cons: moli.Constraints, arena_allocator: mem.Allocator) -> (Run_Out, moli.Tokenize_Err) {
	switch kind {
	case .Morphs:
		// An active set routes through the constrained entry (the
		// search, whatever the analyzer's mode); an empty one keeps
		// the plain path so LongestMatch analyzers stay greedy.
		if moli.constraints_active(cons) {
			ms, e := moli.tokenize_constrained(a, text, cons, opts, arena_allocator)
			return Run_Out{morphs = ms}, e
		}
		ms, e := moli.tokenize_opt(a, text, opts, arena_allocator)
		return Run_Out{morphs = ms}, e
	case .Wakachi:
		ss, e := moli.tokenize_wakachi_opt(a, text, opts, arena_allocator)
		return Run_Out{wakachi = ss}, e
	case .Spans:
		ss, e := moli.tokenize_surfaces_with_offsets(a, text, opts, arena_allocator)
		return Run_Out{spans = ss}, e
	case .Nbest:
		paths: [dynamic]moli.NBest_Path
		e := moli.tokenize_nbest(a, text, k, opts, moli.Constraints{}, &paths, arena_allocator)
		if e != nil {
			delete(paths)
			return Run_Out{}, e
		}
		return Run_Out{nbest = paths}, e
	}
	return Run_Out{}, nil
}

@(export) moli_tokenize :: proc "c" (h: ^Shim_Handle, text: ^u8, text_len: i64, opts_p: ^Tokenize_Options_FFI, err: ^Err_FFI) -> ^Result_Box {
	context = runtime.default_context()
	return tokenize_export(h, text, text_len, 0, opts_p, err, .Morphs, moli.Constraints{})
}

@(export) moli_wakachi :: proc "c" (h: ^Shim_Handle, text: ^u8, text_len: i64, opts_p: ^Tokenize_Options_FFI, err: ^Err_FFI) -> ^Result_Box {
	context = runtime.default_context()
	return tokenize_export(h, text, text_len, 0, opts_p, err, .Wakachi, moli.Constraints{})
}

@(export) moli_spans :: proc "c" (h: ^Shim_Handle, text: ^u8, text_len: i64, opts_p: ^Tokenize_Options_FFI, err: ^Err_FFI) -> ^Result_Box {
	context = runtime.default_context()
	return tokenize_export(h, text, text_len, 0, opts_p, err, .Spans, moli.Constraints{})
}

@(export) moli_nbest :: proc "c" (h: ^Shim_Handle, text: ^u8, text_len: i64, k: i32, opts_p: ^Tokenize_Options_FFI, err: ^Err_FFI) -> ^Result_Box {
	context = runtime.default_context()
	return tokenize_export(h, text, text_len, int(k), opts_p, err, .Nbest, moli.Constraints{})
}

// moli_tokenize_constrained is tokenize under a constraint set: the
// FFI arrays are converted into borrowed core slices for the call's
// duration (the strings stay in the caller's memory; the slices
// themselves live on the default heap for the call and are released
// before returning - the boxed result copies everything it keeps).
@(export) moli_tokenize_constrained :: proc "c" (h: ^Shim_Handle, text: ^u8, text_len: i64, tokens: ^Token_Constraint_FFI, n_tokens: i64, boundaries: ^Boundary_Constraint_FFI, n_boundaries: i64, opts_p: ^Tokenize_Options_FFI, err: ^Err_FFI) -> ^Result_Box {
	context = runtime.default_context()

	// A negative or dangling count is a malformed call, not "no
	// constraints" - the same rejection moli_add_user_entries applies
	// to the same caller mistake.
	if n_tokens < 0 || n_boundaries < 0 || (tokens == nil && n_tokens > 0) || (boundaries == nil && n_boundaries > 0) {
		fail_token(err, .Bad_Constraint, "tokenize_constrained: invalid arguments")
		return nil
	}

	// The converted slices must outlive the call (the borrowed strings
	// they point at stay in the caller's memory; the slices themselves
	// are ours). Defer inside the conversion blocks would fire at block
	// exit - before the call - so the releases sit after it, through
	// the slices cons carries.
	cons := moli.Constraints{}
	if n_tokens > 0 && tokens != nil {
		toks, aerr := make([]moli.Token_Constraint, int(n_tokens), context.allocator)
		if aerr != nil {
			fail_token(err, .OutOfMemory, "tokenize_constrained: out of memory")
			return nil
		}
		src := cast([^]Token_Constraint_FFI)(tokens)
		for i in 0 ..< int(n_tokens) {
			toks[i] = moli.Token_Constraint{start = int(src[i].start), end = int(src[i].end), pos = cview(src[i].pos)}
		}
		cons.tokens = toks
	}
	if n_boundaries > 0 && boundaries != nil {
		bs, aerr := make([]moli.Boundary_Constraint, int(n_boundaries), context.allocator)
		if aerr != nil {
			if cons.tokens != nil { delete(cons.tokens, context.allocator) }
			fail_token(err, .OutOfMemory, "tokenize_constrained: out of memory")
			return nil
		}
		src := cast([^]Boundary_Constraint_FFI)(boundaries)
		for i in 0 ..< int(n_boundaries) {
			bs[i] = moli.Boundary_Constraint{at = int(src[i].at), must_exist = src[i].must_exist != 0}
		}
		cons.boundaries = bs
	}

	box := tokenize_export(h, text, text_len, 0, opts_p, err, .Morphs, cons)
	if cons.tokens != nil { delete(cons.tokens, context.allocator) }
	if cons.boundaries != nil { delete(cons.boundaries, context.allocator) }
	return box
}

tokenize_export :: proc(h: ^Shim_Handle, text_p: ^u8, text_len: i64, k: int, opts_p: ^Tokenize_Options_FFI, err: ^Err_FFI, kind: Run_Kind, cons: moli.Constraints) -> ^Result_Box {
	context = runtime.default_context()
	if h == nil {
		fail_token(err, .Unavailable, "tokenize: nil handle")
		return nil
	}
	text := string(bytes_of(text_p, text_len))
	opts := tok_opts(opts_p)

	// The heap-arena_allocator retry backing is released at every exit after it
	// exists (procedure-scope defer; the arena_allocator outputs are copied out
	// by box_run before any return). Backing that came from the retained
	// thread-local scratch is not owned here and outlives the call.
	backing: []u8
	backing_owned: bool
	defer if backing_owned { delete(backing, context.allocator) }

	// Output lands in a stack arena_allocator first; a refusal (giant input)
	// retries once on a heap arena_allocator sized from the input length, and a
	// second refusal surfaces as OutOfMemory. Never a crash, never a
	// silent truncation. The stack arena covers the documented ~350
	// arena bytes per input byte only for small inputs, so the attempt
	// is skipped when the input cannot fit it: past the crossover the
	// stack try is a doomed full analysis - the engine's whole walk
	// thrown away - and large inputs go straight to the heap arena.
	out: Run_Out
	terr: moli.Tokenize_Err
	if len(text) <= TOKENIZE_STACK_BYTES / TOKENIZE_TIGHT_PER_INPUT {
		stack_buf: [TOKENIZE_STACK_BYTES]u8
		stack_arena: mem.Arena
		mem.arena_init(&stack_arena, stack_buf[:])
		out, terr = run_tokenize(kind, h.a, text, k, opts, cons, mem.arena_allocator(&stack_arena))
	} else {
		terr = .OutOfMemory
	}
	if terr == .OutOfMemory {
		// Ipadic-density text measures ~350 arena bytes per input byte:
		// the lattice node growth chain abandons ~2x its final size
		// (~2.15 nodes/input byte x 64 B nodes, doubled) plus the boxed
		// morphemes and their strings. The multiple carries headroom over
		// that; a second refusal is still OutOfMemory. At or below
		// TOKENIZE_RETAIN_MAX the backing is the thread's retained
		// scratch (grown to the high-water mark, reset by arena_init
		// here); above it the block is per-call, owned, released by the
		// defer. Inputs the full margin would push past the cap first run
		// on the tight tier (TOKENIZE_TIGHT_PER_INPUT per input byte,
		// still under the cap, still retained); a refusal there retries
		// once at the full margin per-call — the behavior the
		// full-margin-only sizing always gave that input.
		heap_size := len(text) * TOKENIZE_FULL_MARGIN_PER_INPUT + TOKENIZE_STACK_BYTES
		tight_size := len(text) * TOKENIZE_TIGHT_PER_INPUT + TOKENIZE_STACK_BYTES
		tight := false
		if heap_size <= TOKENIZE_RETAIN_MAX {
			if !ensure_retained(heap_size) {
				fill_token_err(err, terr)
				return nil
			}
			backing = retained_scratch
		} else if tight_size <= TOKENIZE_RETAIN_MAX {
			if !ensure_retained(tight_size) {
				fill_token_err(err, terr)
				return nil
			}
			backing = retained_scratch
			tight = true
		} else {
			block, aerr := make([]u8, heap_size, context.allocator)
			if aerr != nil {
				fill_token_err(err, terr)
				return nil
			}
			backing = block
			backing_owned = true
		}
		heap_arena: mem.Arena
		mem.arena_init(&heap_arena, backing[:])
		out, terr = run_tokenize(kind, h.a, text, k, opts, cons, mem.arena_allocator(&heap_arena))
		if terr == .OutOfMemory && tight {
			// The tight tier refused: retry once at the full margin,
			// per-call and owned (heap_size exceeds the retain cap
			// whenever tight is set).
			block, aerr := make([]u8, heap_size, context.allocator)
			if aerr != nil {
				fill_token_err(err, terr)
				return nil
			}
			backing = block
			backing_owned = true
			mem.arena_init(&heap_arena, backing[:])
			out, terr = run_tokenize(kind, h.a, text, k, opts, cons, mem.arena_allocator(&heap_arena))
		}
	}
	if terr != nil {
		if len(out.nbest) > 0 { delete(out.nbest) }
		fill_token_err(err, terr)
		return nil
	}

	// The result blob's offsets and per-field lengths are i32 (the ABI
	// layout): a result over 2 GiB would wrap them mid-fill and trap
	// the bounds check inside a proc "c" export. Refuse it here — never
	// a crash, never a silent truncation. ABI_BLOB_MAX is that i32
	// limit, stated once beside the wire structs.
	if run_blob_len(kind, out) > ABI_BLOB_MAX {
		if len(out.nbest) > 0 { delete(out.nbest) }
		fail_token(err, .OutOfMemory, "tokenize: result blob exceeds the 2 GiB ABI offset range")
		return nil
	}

	box, berr := box_run(kind, out, context.allocator)
	if len(out.nbest) > 0 { delete(out.nbest) }
	if berr != nil {
		fail_token(err, .OutOfMemory, "tokenize: out of memory")
		return nil
	}
	return box
}

// --- result boxing -------------------------------------------------

put_str :: proc(dst_off: ^i32, dst_len: ^i32, s: string, blob: []u8, off: i32) -> i32 {
	dst_off^ = off
	dst_len^ = i32(len(s))
	if len(s) > 0 {
		copy(blob[off:off + i32(len(s))], transmute([]u8)s)
	}
	return off + i32(len(s))
}

fill_morph :: proc(dst: ^Morpheme_FFI, m: moli.Morpheme, blob: []u8, off: i32) -> i32 {
	o := off
	dst.start = i64(m.start)
	dst.end = i64(m.end)
	o = put_str(&dst.surf_off, &dst.surf_len, m.surface, blob, o)
	o = put_str(&dst.pos_off, &dst.pos_len, m.pos, blob, o)
	o = put_str(&dst.lemma_off, &dst.lemma_len, m.lemma, blob, o)
	o = put_str(&dst.reading_off, &dst.reading_len, m.reading, blob, o)
	o = put_str(&dst.jyutping_off, &dst.jyutping_len, m.reading_jyutping, blob, o)
	dst.entry_id = m.entry_id
	dst.cost = m.cost
	dst.locale = u8(m.locale)
	dst.char_class = u8(m.char_class)
	dst.is_unknown = m.is_unknown ? 1 : 0
	return o
}

morphs_blob_len :: proc(morphs: []moli.Morpheme) -> int {
	n := 0
	for m in morphs {
		n += len(m.surface) + len(m.pos) + len(m.lemma) + len(m.reading) + len(m.reading_jyutping)
	}
	return n
}

// run_blob_len totals the blob bytes a run's output will need, in int
// (64-bit) arithmetic so the i32-range guard in tokenize_export sees
// the true size before any offset arithmetic runs.
run_blob_len :: proc(kind: Run_Kind, out: Run_Out) -> int {
	switch kind {
	case .Morphs:
		return morphs_blob_len(out.morphs)
	case .Wakachi:
		n := 0
		for s in out.wakachi { n += len(s) }
		return n
	case .Spans:
		n := 0
		for s in out.spans { n += len(s.surface) }
		return n
	case .Nbest:
		n := 0
		for p in out.nbest { n += morphs_blob_len(p.morphemes) }
		return n
	}
	return 0
}

box_run :: proc(kind: Run_Kind, out: Run_Out, allocator: mem.Allocator) -> (^Result_Box, mem.Allocator_Error) {
	switch kind {
	case .Morphs:
		return box_morphs(out.morphs, allocator)
	case .Wakachi:
		return box_surfaces(out.wakachi, nil, allocator)
	case .Spans:
		return box_surfaces(nil, out.spans, allocator)
	case .Nbest:
		return box_nbest(out.nbest[:], allocator)
	}
	return nil, nil
}

box_morphs :: proc(morphs: []moli.Morpheme, allocator: mem.Allocator) -> (^Result_Box, mem.Allocator_Error) {
	box := new(Result_Box)
	box^ = {}
	aerr: mem.Allocator_Error
	if len(morphs) > 0 {
		box.morphemes, aerr = make([]Morpheme_FFI, len(morphs), allocator)
		if aerr != nil {
			mem.free(box)
			return nil, aerr
		}
	}
	blob_len := morphs_blob_len(morphs)
	if blob_len > 0 {
		box.blob, aerr = make([]u8, blob_len, allocator)
		if aerr != nil {
			delete(box.morphemes, allocator)
			mem.free(box)
			return nil, aerr
		}
	}
	off: i32 = 0
	for m, i in morphs {
		off = fill_morph(&box.morphemes[i], m, box.blob, off)
	}
	return box, nil
}

// box_surfaces builds the wakachi/spans result: only surface (and, for
// spans, start/end) fields are meaningful; the rest are zero.
box_surfaces :: proc(surfaces: []string, spans: []moli.Surface_Span, allocator: mem.Allocator) -> (^Result_Box, mem.Allocator_Error) {
	n := len(surfaces)
	if n == 0 { n = len(spans) }
	blob_len := 0
	if len(spans) > 0 {
		for s in spans { blob_len += len(s.surface) }
	} else {
		for s in surfaces { blob_len += len(s) }
	}
	box := new(Result_Box)
	box^ = {}
	aerr: mem.Allocator_Error
	if n > 0 {
		box.morphemes, aerr = make([]Morpheme_FFI, n, allocator)
		if aerr != nil {
			mem.free(box)
			return nil, aerr
		}
	}
	if blob_len > 0 {
		box.blob, aerr = make([]u8, blob_len, allocator)
		if aerr != nil {
			delete(box.morphemes, allocator)
			mem.free(box)
			return nil, aerr
		}
	}
	off: i32 = 0
	for i in 0..<n {
		surface: string
		if len(spans) > 0 {
			surface = spans[i].surface
			box.morphemes[i].start = i64(spans[i].start)
			box.morphemes[i].end = i64(spans[i].end)
		} else {
			surface = surfaces[i]
		}
		off = put_str(&box.morphemes[i].surf_off, &box.morphemes[i].surf_len, surface, box.blob, off)
	}
	return box, nil
}

// box_nbest concatenates every path's morphemes into one array; each
// Path_FFI addresses its range inside it, sharing one blob.
box_nbest :: proc(paths: []moli.NBest_Path, allocator: mem.Allocator) -> (^Result_Box, mem.Allocator_Error) {
	total := 0
	blob_len := 0
	for p in paths {
		total += len(p.morphemes)
		blob_len += morphs_blob_len(p.morphemes)
	}
	box := new(Result_Box)
	box^ = {}
	aerr: mem.Allocator_Error
	if total > 0 {
		box.morphemes, aerr = make([]Morpheme_FFI, total, allocator)
		if aerr != nil {
			mem.free(box)
			return nil, aerr
		}
	}
	if len(paths) > 0 {
		box.paths, aerr = make([]Path_FFI, len(paths), allocator)
		if aerr != nil {
			delete(box.morphemes, allocator)
			mem.free(box)
			return nil, aerr
		}
	}
	if blob_len > 0 {
		box.blob, aerr = make([]u8, blob_len, allocator)
		if aerr != nil {
			delete(box.paths, allocator)
			delete(box.morphemes, allocator)
			mem.free(box)
			return nil, aerr
		}
	}
	off: i32 = 0
	next: i32 = 0
	for p, i in paths {
		first := next
		for m in p.morphemes {
			off = fill_morph(&box.morphemes[next], m, box.blob, off)
			next += 1
		}
		box.paths[i] = Path_FFI{
			cost  = p.cost,
			first = first,
			count = next - first,
		}
	}
	return box, nil
}

@(export) moli_result_count :: proc "c" (r: ^Result_Box) -> i64 {
	if r == nil { return 0 }
	return i64(len(r.morphemes))
}

@(export) moli_result_morphemes :: proc "c" (r: ^Result_Box) -> ^Morpheme_FFI {
	if r == nil || len(r.morphemes) == 0 { return nil }
	return &r.morphemes[0]
}

@(export) moli_result_paths_count :: proc "c" (r: ^Result_Box) -> i64 {
	if r == nil { return 0 }
	return i64(len(r.paths))
}

@(export) moli_result_paths :: proc "c" (r: ^Result_Box) -> ^Path_FFI {
	if r == nil || len(r.paths) == 0 { return nil }
	return &r.paths[0]
}

@(export) moli_result_blob :: proc "c" (r: ^Result_Box) -> ^u8 {
	if r == nil || len(r.blob) == 0 { return nil }
	return &r.blob[0]
}

@(export) moli_result_blob_len :: proc "c" (r: ^Result_Box) -> i64 {
	if r == nil { return 0 }
	return i64(len(r.blob))
}

@(export) moli_result_free :: proc "c" (r: ^Result_Box) {
	context = runtime.default_context()
	if r == nil { return }
	delete(r.morphemes, context.allocator)
	delete(r.paths, context.allocator)
	delete(r.blob, context.allocator)
	mem.free(r)
}

// --- classification and cancellation -------------------------------

// classify_locale reads only the analyzer's immutable language state,
// but it is still a handle call: the handle must outlive it. Unlike
// the tokenize family it carries no in-library acquire/teardown
// bounce, so a direct embedder running it concurrently with
// moli_free races freed memory — entry-level quiescence is the
// embedder's duty here, as the core's free contract names.
@(export) moli_classify_locale :: proc "c" (h: ^Shim_Handle, text: ^u8, text_len: i64) -> u8 {
	context = runtime.default_context()
	if h == nil { return 0 }
	return u8(moli.classify_locale(h.a, string(bytes_of(text, text_len))))
}

@(export) moli_cancel_new :: proc "c" () -> ^moli.Cancel_Token {
	context = runtime.default_context()
	return new(moli.Cancel_Token)
}

@(export) moli_cancel :: proc "c" (c: ^moli.Cancel_Token) {
	context = runtime.default_context()
	if c == nil { return }
	moli.cancel(c)
}

@(export) moli_cancel_free :: proc "c" (c: ^moli.Cancel_Token) {
	context = runtime.default_context()
	if c == nil { return }
	mem.free(c)
}

