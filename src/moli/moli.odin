// moli - morphological analysis for Japanese, Chinese, and English from
// MeCab-format CSV dictionaries: a deterministic, core-library-only
// backend for concurrent services.
//
// Embedding model: one Analyzer per (language, dictionary) pair, loaded
// once and shared; the tokenize-family procs run concurrently on the
// shared analyzer while each caller brings its own arena. free drains
// in-flight calls before destroying anything, so embedders never need
// to prove "nobody holds it now".
package moli

import "base:intrinsics"
import "core:mem"
import "core:time"

// Language selects the dictionary schema, the character classification
// table, and the unknown-word fallback POS. Fixed at load time; an
// Analyzer never changes language.
Language :: enum {
	Japanese,
	ChineseCN,
	ChineseTW,
	ChineseHK,
	EnglishGB,
	EnglishUS,
	German,
}

// Locale tags the variant a morpheme belongs to, for languages that
// have variants. None means "no variant information": Japanese
// morphemes carry it, and so does anything classification could not
// decide. (The sentinel lives in the enum because this toolchain has
// no optional-type sugar - .None follows the core os.Error
// convention.)
Locale :: enum {
	None,
	CN, TW, HK,
	GB, US,
}

// Mode selects the tokenizer. Viterbi (the default) builds a candidate
// lattice and takes the minimum-cost path through the connection
// matrix; LongestMatch is the greedy fast path. Both are deterministic.
Mode :: enum {
	Viterbi,
	LongestMatch,
}

// Load_Options parameterizes load. The zero value is the recommended
// load: Viterbi mode (the enum's zero member) and, for each optional
// resource, an empty path meaning "look for the canonical sibling file
// next to the dictionary CSV".
Load_Options :: struct {
	mode:            Mode,
	unk_def_path:    string,
	char_def_path:   string,
	matrix_def_path: string,
	// qpat_path names the surface-pattern file (canonical sibling:
	// patterns.qpat) whose rows refine unknown-word labels ahead of the
	// unk.def walk.
	qpat_path:       string,
	flat_char_class: bool,
	// lemma_locale rewrites entry lemmas toward a variant at load:
	// .US/.GB for English dictionaries, .CN for traditional Chinese
	// (character-level). The zero member (.None) keeps dictionary
	// values verbatim. A save_qdct after a normalized load bakes the
	// rewrites in - the option itself is not serialized.
	lemma_locale:    Locale,
	// jyutping_csv_path names the HK-variant CSV of the ZH two-file
	// flow: its col-5 jyutping joins onto the loaded entries by surface
	// and populates reading_jyutping. Explicit-only - there is no
	// sibling discovery; empty (the zero value) is no merge.
	jyutping_csv_path: string,
	// threads parallelizes the matrix.def parse with up to min(N, 64)
	// workers; <= 1 (the zero value) scans serially. Importer edge
	// only - the analysis core never links core:thread. The option
	// changes no output: the analyzer, its stats, and its snapshot
	// bytes are identical at any value.
	threads:           int,
}

// FALLBACK_POS is the per-language unknown POS, keyed by Language: what
// an unknown run carries when no unk.def rule matches its char_class.
FALLBACK_POS :: [Language]string{
	.Japanese    = "名詞,普通名詞",
	.ChineseCN   = "n",
	.ChineseTW   = "n",
	.ChineseHK   = "n",
	.EnglishGB   = "NOUN",
	.EnglishUS   = "NOUN",
	.German      = "NOUN",
}

// fallback_pos returns the per-language unknown POS used when no
// unk.def rule matches the run's char_class (see FALLBACK_POS). An
// out-of-range ordinal answers "*" - the historical switch fell through
// the same way, and raw enum casts (the snapshot edge) must not trap.
fallback_pos :: proc(lang: Language, allocator: mem.Allocator) -> (string, Load_Err) {
	pos := FALLBACK_POS // materialized: constants refuse variable indexing
	if int(lang) < 0 || int(lang) >= len(pos) { return clone_str("*", allocator) }
	return clone_str(pos[lang], allocator)
}

// clone_str clones s into allocator, mapping allocation failure to the
// load-boundary fault.
clone_str :: proc(s: string, allocator: mem.Allocator) -> (string, Load_Err) {
	b, err := mem.alloc_bytes(len(s), 1, allocator)
	if err != nil { return "", .OutOfMemory }
	copy(b, s)
	return string(b), nil
}

// DICT_LOCALE is the Locale a dictionary of that language tags its
// morphemes with, keyed by Language (.None when the language carries no
// variants).
DICT_LOCALE :: [Language]Locale{
	.Japanese  = .None,
	.ChineseCN = .CN,
	.ChineseTW = .TW,
	.ChineseHK = .HK,
	.EnglishGB = .GB,
	.EnglishUS = .US,
	.German    = .None,
}

// dict_locale_for returns the Locale to tag morphemes with given the
// loaded language (see DICT_LOCALE). An out-of-range ordinal answers
// .None - the historical switch fell through the same way, and raw
// enum casts (the snapshot edge) must not trap.
dict_locale_for :: proc(lang: Language) -> Locale {
	locales := DICT_LOCALE // materialized: constants refuse variable indexing
	if int(lang) < 0 || int(lang) >= len(locales) { return .None }
	return locales[lang]
}

// record_skipped appends name to the analyzer's skipped-resources list
// (the optional resources that were absent); a failed clone answers the
// fault and the caller unwinds the partial analyzer.
record_skipped :: proc(a: ^Analyzer, name: string, allocator: mem.Allocator) -> Load_Err {
	s, err := clone_str(name, allocator)
	if err != nil { return err }
	append(&a.skipped_resources, s)
	return nil
}

// load reads a MeCab-format CSV dictionary for lang from path and
// returns a ready Analyzer.
//
// Only the CSV format is supported: there is no binary or memory-mapped
// dictionary format.
//
// Optional resources: an empty path in opts means "look for the
// canonical sibling file next to the dictionary CSV" - unk.def,
// char.def, matrix.def, patterns.qpat. A sibling that is absent is
// degradation, not an error: it is recorded in
// Analyzer.skipped_resources for the embedder to surface. A missing
// dictionary CSV itself is a hard .File_Not_Found.
//
// allocator owns everything the analyzer retains after load returns (entry
// strings, joined POS, unk rules, cedar arrays, char map, char class
// table, matrix cells). For a long-lived analyzer use the default heap
// or a tracking allocator.
//
// On any error the partially-built state is fully released - every
// entry cloned so far is destroyed field by field and the load scratch
// is freed - and no partial Analyzer escapes.
//
// Not thread-safe: load mutates builder state; build one analyzer at a
// time.
load :: proc(lang: Language, path: string, opts: Load_Options, allocator: mem.Allocator) -> (Analyzer, Load_Err) {
	src: Csv_Source = path
	return load_from(lang, src, opts, allocator)
}

// load_bytes loads from an in-memory CSV image instead of a file
// path. The bytes are borrowed for the parse only - every string is
// cloned into the analyzer's allocator, and the caller keeps the
// buffer. There is no sibling filesystem to consult: resource paths
// configured explicitly in opts are honored, and each remaining
// optional resource degrades to its built-in default with a record in
// skipped_resources - never silently. Same errors and thread-safety
// as load.
load_bytes :: proc(lang: Language, data: []u8, opts: Load_Options, allocator: mem.Allocator) -> (Analyzer, Load_Err) {
	src: Csv_Source = data
	return load_from(lang, src, opts, allocator)
}

// load_from is the load core shared by the file and bytes entries.
// Everything past the dictionary source is one ladder - the import
// run, the builder, the optional resources - so neither entry can
// drift. A file entry discovers optional resources as siblings of
// the CSV path; a bytes entry has no filesystem to consult, so only
// explicitly configured opts paths apply.
load_from :: proc(lang: Language, src: Csv_Source, opts: Load_Options, allocator: mem.Allocator) -> (Analyzer, Load_Err) {
	a: Analyzer
	a.lang = lang
	a.mode = opts.mode
	a.dict_locale = dict_locale_for(lang)
	a.allocator = allocator
	a.drain_wait = drain_wait_sleep

	imp: Importer
	imp.lang = lang
	imp.allocator = allocator
	// The arena is initialized before the collections so a make failure
	// can run load_release_partial (its arena destroy requires an
	// initialized arena). Both arena allocators ride the load's
	// explicit allocator - never the ambient context.
	mem.dynamic_arena_init(&imp.scratch, block_allocator = allocator, array_allocator = allocator)

	// The three long-lived collections are made with their errors
	// checked: a failed make would leave a zero-value collection whose
	// first append grows through the ambient allocator. Every failure
	// here runs load_release_partial, whose deletes are nil-safe over
	// the not-yet-made prefix.
	merr: mem.Allocator_Error
	a.skipped_resources, merr = make([dynamic]string, 0, 4, allocator)
	if merr != nil { load_release_partial(&imp, &a); return Analyzer{}, .OutOfMemory }
	imp.entries, merr = make([dynamic]Dictionary_Entry, 0, 1024, allocator)
	if merr != nil { load_release_partial(&imp, &a); return Analyzer{}, .OutOfMemory }
	imp.unk_def, merr = make([dynamic]Unk_Rule, 0, 16, allocator)
	if merr != nil { load_release_partial(&imp, &a); return Analyzer{}, .OutOfMemory }
	imp.unk_patterns, merr = make([dynamic]Unk_Pattern, 0, 4, allocator)
	if merr != nil { load_release_partial(&imp, &a); return Analyzer{}, .OutOfMemory }

	// Discover optional resource paths (the strings live in the load
	// scratch: they are used for opens within load only). A bytes
	// entry passes an empty base: discover_sibling_path honors an
	// explicit opts path first and answers not-found for an empty
	// base, so bytes mode degrades per resource, recorded below.
	scratch_allocator := mem.dynamic_arena_allocator(&imp.scratch)
	base := ""
	switch s in src {
	case string: base = s
	case []u8:
	}
	unk_path,   unk_ok,   derr1 := discover_sibling_path(base, opts.unk_def_path, "unk.def", scratch_allocator)
	if derr1 != nil { load_release_partial(&imp, &a); return Analyzer{}, derr1 }
	char_path,  char_ok,  derr2 := discover_sibling_path(base, opts.char_def_path, "char.def", scratch_allocator)
	if derr2 != nil { load_release_partial(&imp, &a); return Analyzer{}, derr2 }
	matrix_path, mat_ok,  derr3 := discover_sibling_path(base, opts.matrix_def_path, "matrix.def", scratch_allocator)
	if derr3 != nil { load_release_partial(&imp, &a); return Analyzer{}, derr3 }
	qpat_path,  qpat_ok,  derr4 := discover_sibling_path(base, opts.qpat_path, "patterns.qpat", scratch_allocator)
	if derr4 != nil { load_release_partial(&imp, &a); return Analyzer{}, derr4 }

	// Initialize Cedar_Builder before parsing anything: the builder
	// owns the four cedar arrays and the char map. The matrix is loaded
	// after the builder exists because conn_matrix storage lives on
	// the importer.
	builder: Cedar_Builder
	builder.cedar = &a.cedar
	builder.allocator = allocator
	builder.scratch_allocator = mem.dynamic_arena_allocator(&imp.scratch)
	imp.builder = &builder

	// Read the dictionary CSV (file or in-memory bytes).
	if err := importer_read_csv(&imp, src); err != nil {
		load_release_partial(&imp, &a)
		return Analyzer{}, err
	}

	// The builder indexes the importer's entries directly; cedar_build
	// reorders them into surface order, and the sorted position becomes
	// the entry id (imp.entries hands over already sorted).
	builder.entries = imp.entries[:]

	// Build the cedar before parsing optional resources, so a char-map
	// overflow or allocation failure aborts with a clear error. The
	// char map may already be built when a later builder step fails;
	// it lives on the builder (the analyzer has not received it yet),
	// so it is released here - load_release_partial would miss it.
	if err := cedar_build(&builder); err != nil {
		delete(builder.char_map.forward)
		delete(builder.char_map.inverse)
		delete(builder.char_map.bmp, builder.allocator)
		load_release_partial(&imp, &a)
		return Analyzer{}, err
	}

	// Hand entries + char_map + cedar over to the analyzer. The imp
	// side is nil'd at hand-over so the failure path can never free a
	// handed-over buffer twice.
	a.entries = imp.entries
	imp.entries = nil
	a.char_map = builder.char_map

	// Optional: char.def. char_flags starts at the built-in default
	// either way; a present char.def overrides the classes its
	// category rows name.
	a.char_flags = char_flags_default()
	if char_ok {
		ranges, cerr := import_char_def(&imp, char_path, &a.char_flags)
		if cerr != nil {
			load_release_partial(&imp, &a)
			return Analyzer{}, cerr
		}
		table, berr := char_class_build(lang, ranges, opts.flat_char_class, allocator)
		if berr != nil {
			load_release_partial(&imp, &a)
			return Analyzer{}, berr
		}
		a.char_class = table
	} else {
		if err := record_skipped(&a, "char.def", allocator); err != nil {
			load_release_partial(&imp, &a)
			return Analyzer{}, err
		}
		table, berr := char_class_build(lang, nil, opts.flat_char_class, allocator)
		if berr != nil {
			load_release_partial(&imp, &a)
			return Analyzer{}, berr
		}
		a.char_class = table
	}

	// Optional: unk.def.
	if unk_ok {
		if err := import_unk_def(&imp, unk_path); err != nil {
			load_release_partial(&imp, &a)
			return Analyzer{}, err
		}
	} else {
		if err := record_skipped(&a, "unk.def", allocator); err != nil {
			load_release_partial(&imp, &a)
			return Analyzer{}, err
		}
	}
	// Hand the unk rules over with the same one-owner discipline.
	a.unk_def = imp.unk_def
	imp.unk_def = nil

	// Optional: matrix.def.
	if mat_ok {
		if err := import_matrix_def(&imp, matrix_path, opts.threads); err != nil {
			load_release_partial(&imp, &a)
			return Analyzer{}, err
		}
	} else {
		if err := record_skipped(&a, "matrix.def", allocator); err != nil {
			load_release_partial(&imp, &a)
			return Analyzer{}, err
		}
	}
	a.conn_matrix = imp.conn_matrix

	// Optional: patterns.qpat, after unk.def so the two rule sets load
	// in the order the resolution ladder consults them.
	if qpat_ok {
		if err := import_qpat(&imp, qpat_path); err != nil {
			load_release_partial(&imp, &a)
			return Analyzer{}, err
		}
	} else {
		if err := record_skipped(&a, "patterns.qpat", allocator); err != nil {
			load_release_partial(&imp, &a)
			return Analyzer{}, err
		}
	}
	// Hand the patterns over with the same one-owner discipline.
	a.unk_patterns = imp.unk_patterns
	imp.unk_patterns = nil

	// Optional: the jyutping donor CSV, joined by surface through the
	// built trie (homograph chains patch as a group) - a dictionary
	// content step, placed before the other content rewriter below.
	if opts.jyutping_csv_path != "" {
		if err := import_jyutping_csv(&imp, &a, opts.jyutping_csv_path); err != nil {
			load_release_partial(&imp, &a)
			return Analyzer{}, err
		}
	}

	// Fallback POS.
	fpos, ferr := fallback_pos(lang, allocator)
	if ferr != nil {
		load_release_partial(&imp, &a)
		return Analyzer{}, ferr
	}
	a.unknown_fallback_pos = fpos

	// Optional: lemma normalization toward a target variant. Applied
	// after everything is handed over - a failure here runs the same
	// partial-teardown path as any other (the re-cloned lemmas and the
	// released originals both clean up under dictionary_entry_destroy).
	if opts.lemma_locale != .None {
		if lerr := normalize_lemmas(&a, opts.lemma_locale, allocator); lerr != nil {
			load_release_partial(&imp, &a)
			return Analyzer{}, lerr
		}
	}

	// Build done. The dynamic arena is the only transient state; the
	// importer's imp.entries / imp.unk_def / imp.unk_patterns have
	// already been handed over to a (their allocator is the analyzer
	// allocator).
	mem.dynamic_arena_destroy(&imp.scratch)
	a.entries_hash = entries_fingerprint(&a)

	return a, nil
}

// load_release_partial tears down the partial state when load aborts
// halfway: release all entries the importer built, free the cedar
// arrays and char_map, and free the scratch arena.
load_release_partial :: proc(imp: ^Importer, a: ^Analyzer) {
	for entry in imp.entries {
		e := entry
		dictionary_entry_destroy(&e, imp.allocator)
	}
	delete(imp.entries)
	for rule in imp.unk_def {
		r := rule
		unk_rule_destroy(&r, imp.allocator)
	}
	delete(imp.unk_def)
	for pattern in imp.unk_patterns {
		p := pattern
		unk_pattern_destroy(&p, imp.allocator)
	}
	delete(imp.unk_patterns)
	if imp.conn_matrix.n_left > 0 {
		delete(imp.conn_matrix.costs)
	}
	// Free whatever was already attached to the analyzer.
	for entry in a.entries {
		e := entry
		dictionary_entry_destroy(&e, a.allocator)
	}
	delete(a.entries)
	for rule in a.unk_def {
		r := rule
		unk_rule_destroy(&r, a.allocator)
	}
	delete(a.unk_def)
	for pattern in a.unk_patterns {
		p := pattern
		unk_pattern_destroy(&p, a.allocator)
	}
	delete(a.unk_patterns)
	for s in a.skipped_resources {
		delete(s, a.allocator)
	}
	delete(a.skipped_resources)
	char_class_destroy(&a.char_class, a.allocator)
	cedar_destroy(&a.cedar)
	char_map_destroy(&a.char_map, a.allocator)
	if a.unknown_fallback_pos != "" { delete(a.unknown_fallback_pos, a.allocator) }
	mem.dynamic_arena_destroy(&imp.scratch)
}

// add_user_entries merges user dictionary rows into a loaded
// analyzer: the merged entry list is rebuilt in surface order, so
// entry ids are renumbered - Morpheme.entry_id values taken before
// the merge are stale after it (Analyzer_Stats.entries_hash is the
// change detector). The cedar arrays and char map are rebuilt over
// the merged surfaces - a user row may introduce runes the original
// dictionary never carried. The rebuild runs on locals; the analyzer
// is untouched until the swap, so every failure path returns with the
// analyzer exactly as it was. A row whose surface is empty is
// rejected with .Invalid_Format before anything is touched: an empty
// surface has no trie path - no terminal can ever point at it - so
// accepting one would silently drop it from every segmentation (the
// CSV importer enforces the same rule in parse_entry).
//
// Concurrency: the swap drains in-flight tokenize calls with the same
// protocol as free - calls finishing during the rebuild keep reading
// the old arrays (untouched until the swap), and calls arriving in
// the brief swap window bounce with .Unavailable. add_user_entries
// and free are mutually exclusive, like two frees: serialize them in
// the caller. A save_qdct after a merge serializes the merged state
// naturally.
add_user_entries :: proc(a: ^Analyzer, entries: []User_Entry) -> Load_Err {
	if a == nil { return .Nil_Handle }
	if len(entries) == 0 { return nil }
	// An empty surface has no trie path: every terminal sits at
	// parent + rune offset from its node, so a zero-length surface
	// could never be matched. Reject the batch up front rather than
	// accept a row and silently drop it.
	for ue in entries {
		if ue.surface == "" { return .Invalid_Format }
	}
	allocator := a.allocator
	n_old := len(a.entries)

	// Drain under the mutating flag; see drain_in_use for the wait.
	intrinsics.atomic_store_explicit(&a.mutating, true, .Release)
	defer intrinsics.atomic_store_explicit(&a.mutating, false, .Release)
	drain_in_use(a)

	// Merged entry list. The user rows are cloned into their own array
	// first: cedar_build sorts the merged list in place, so ownership
	// must never depend on a row's position. user_rows owns the cloned
	// strings until the swap; merged carries shallow copies of the old
	// rows (their strings stay owned by whichever backing outlives -
	// the old array's backing dies string-less below) and of the user
	// rows (strings_owned travels with the copy, so free() releases
	// them through a.entries afterwards).
	user_rows, merr := make([dynamic]Dictionary_Entry, 0, len(entries), allocator)
	if merr != nil { return .OutOfMemory }

	// One flag-guarded release covers every failure between here and
	// the swap: the user rows - including a row whose clone ladder died
	// mid-way - and both backings. The old analyzer state is never on
	// this path: merged's copies of the old rows own nothing, wherever
	// a partially completed build's sort left them.
	merged: [dynamic]Dictionary_Entry
	committed := false
	defer if !committed {
		user_entries_release(user_rows[:], allocator)
		delete(user_rows)
		delete(merged)
	}

	// The row joins user_rows BEFORE its strings are cloned, so the
	// release path above owns a half-cloned row outright (the
	// parse_entry ladder idiom). The capacity reserved at make keeps
	// every append growth-free, so the row pointer stays put across
	// the iteration.
	for ue in entries {
		append(&user_rows, Dictionary_Entry{
			left_id        = ue.left_id,
			right_id       = ue.right_id,
			cost           = ue.cost,
			strings_owned  = true,
		})
		e := &user_rows[len(user_rows) - 1]
		failed: Load_Err
		e.surface, failed = clone_str(ue.surface, allocator)
		if failed == nil { e.joined_pos, failed = clone_str(ue.pos, allocator) }
		if failed == nil { e.lemma, failed = clone_str(ue.lemma, allocator) }
		if failed == nil { e.reading, failed = clone_str(ue.reading, allocator) }
		if failed == nil { e.reading_jyutping, failed = clone_str(ue.reading_jyutping, allocator) }
		if failed != nil { return .OutOfMemory }
	}

	merged, merr = make([dynamic]Dictionary_Entry, 0, n_old + len(entries), allocator)
	if merr != nil { return .OutOfMemory }
	append(&merged, ..a.entries[:])
	append(&merged, ..user_rows[:])

	// Rebuild the cedar + char map over the merged surfaces. The
	// scratch arena rides the analyzer allocator explicitly.
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, block_allocator = allocator, array_allocator = allocator)
	defer mem.dynamic_arena_destroy(&scratch)

	cedar: Cedar
	builder: Cedar_Builder
	builder.cedar = &cedar
	builder.allocator = allocator
	builder.scratch_allocator = mem.dynamic_arena_allocator(&scratch)
	builder.entries = merged[:]
	if berr := cedar_build(&builder); berr != nil {
		// The failed rebuild leaves its partial arrays and char map on
		// the locals - release them or every load-time OOM leaks. (The
		// user rows and both backings go through the flag defer, whose
		// ownership no longer depends on where the build's sort left
		// each row.)
		cedar_destroy(&cedar)
		char_map_destroy(&builder.char_map, builder.allocator)
		return berr
	}

	// Swap, then release only what the old state uniquely owned: the
	// four cedar arrays, the old char map, and the old entry array's
	// BACKING (its strings live on in merged). user_rows' backing dies
	// here too - its rows' strings survive as merged's copies, and the
	// strings_owned flag makes free() release them through a.entries.
	old_cedar := a.cedar
	old_map := a.char_map
	old_entries := a.entries
	a.cedar = cedar
	a.char_map = builder.char_map
	a.entries = merged
	committed = true
	delete(user_rows)
	cedar_destroy(&old_cedar)
	char_map_destroy(&old_map, allocator)
	delete(old_entries)
	a.entries_hash = entries_fingerprint(a)
	return nil
}

// user_entries_release destroys the user-appended tail of a merged
// entry list that failed before the swap.
user_entries_release :: proc(entries: []Dictionary_Entry, allocator: mem.Allocator) {
	for e in entries {
		x := e
		dictionary_entry_destroy(&x, allocator)
	}
}

// drain_in_use waits for every in-flight tokenize-family call to
// unregister. The wait between polls goes through the analyzer's
// drain_wait hook - drain_wait_sleep (100µs) as loaded: in-flight
// calls are CPU-bound tokenizes, and a bare spin would burn a whole
// core while they finish. A test hook may release the held call
// itself, advancing the loop without any sleeping; a zero-value
// analyzer without a hook still drains over the plain sleep.
drain_in_use :: proc(a: ^Analyzer) {
	polls := 0
	for intrinsics.atomic_load_explicit(&a.in_use, .Acquire) != 0 {
		if a.drain_wait != nil {
			a.drain_wait(a, polls)
		} else {
			time.sleep(DRAIN_POLL)
		}
		polls += 1
	}
}

//
// Concurrent teardown contract: free marks the analyzer for teardown,
// then waits for all in-flight tokenize-family calls to finish before
// destroying anything. Calls that arrive after teardown began return
// .Unavailable instead of touching freed memory. When swapping
// dictionaries, load the replacement first and switch the serving
// pointer before freeing the old analyzer - bounces stop the moment
// the pointer moves. free on an idle analyzer returns immediately.
//
// free releases every resource owned by a: entry strings and joined
// POS, unk rules, cedar arrays, char map, char class ranges and flat
// table, matrix cells, fallback POS, skipped-resource names. It
// consults a.allocator internally; the caller passes no allocator.
//
// free is a single-call contract: exactly one caller, exactly once.
// Two concurrent frees would race the destroy sequence; that is a
// caller bug the library does not detect. It takes the analyzer by
// pointer because the drain protocol coordinates on the caller's copy.
// After free returns the Analyzer value is invalid - call nothing on
// it.
//
// Storage lifetime: free drains calls that are already inside the
// library, but a thread can sit between acquire's first teardown check
// and its in_use increment while free finishes underneath; both touches
// land on the Analyzer struct itself. So releasing the struct's STORAGE
// (the memory it lives in) additionally needs entry-level quiescence on
// the embedder's side: stop routing new calls (switch the serving
// pointer), let threads already entering a call drain at the request
// level, then free, then release the storage. A wrapper that brackets
// every handle call with its own in-flight count (the C/Python SDK's
// pattern) provides exactly that quiescence.
free :: proc(a: ^Analyzer) {
	if a == nil { return }

	// Mark for teardown and drain in-flight tokenize calls; see
	// drain_in_use for the wait.
	intrinsics.atomic_store_explicit(&a.teardown, true, .Release)
	drain_in_use(a)

	// Entry-string ownership splits per row (Dictionary_Entry
	// .strings_owned): a CSV load or an add_user_entries merge cloned
	// that row's strings into a.allocator (delete each), while a
	// snapshot load keeps the file image in a.image and its rows'
	// strings are views into it (release the image once — unmap when it
	// is a mapping — skipping those strings' frees). The [dynamic]
	// collections always own their buffers separately. The image is
	// keyed on a non-nil slice, not a positive length: a zero-length
	// caller buffer that load_qdct_bytes rejected still owns its
	// storage, and the transfer contract releases it.
	image_owned := a.image != nil

	for entry in a.entries {
		e := entry
		if e.strings_owned {
			dictionary_entry_destroy(&e, a.allocator)
		} else if len(e.extra) > 0 {
			delete(e.extra)
		}
	}
	delete(a.entries)

	if !image_owned {
		for rule in a.unk_def {
			r := rule
			unk_rule_destroy(&r, a.allocator)
		}
		for pattern in a.unk_patterns {
			p := pattern
			unk_pattern_destroy(&p, a.allocator)
		}
	}
	delete(a.unk_def)
	delete(a.unk_patterns)

	if !image_owned {
		for s in a.skipped_resources {
			delete(s, a.allocator)
		}
	}
	delete(a.skipped_resources)

	if !image_owned && a.unknown_fallback_pos != "" { delete(a.unknown_fallback_pos, a.allocator) }
	char_class_destroy(&a.char_class, a.allocator)
	cedar_destroy(&a.cedar)
	char_map_destroy(&a.char_map, a.allocator)
	if a.conn_matrix.n_left > 0 {
		delete(a.conn_matrix.costs)
	}
	if image_owned {
		if a.image_mapped { qdct_unmap(a.image) } else { delete(a.image, a.allocator) }
	}
}
