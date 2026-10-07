// Analyzer-owned data: the loaded analysis state, the entry and
// unknown-rule types it retains, and the lifecycle counters behind the
// concurrent teardown contract.
package moli

import "base:intrinsics"
import "core:mem"
import "core:time"

// Analyzer is the loaded analysis state. Everything except the
// lifecycle counters and the drain_wait hook is immutable after load
// returns; tokenize-family procs run concurrently on a shared
// ^Analyzer with each caller bringing its own arena.
//
// Ownership: every string field of every entry and unk rule was cloned
// into allocator at load, so teardown deletes them uniformly with
// delete(s, allocator). Every [dynamic] collection and map carries its
// own allocator and is deleted bare.
Analyzer :: struct {
	lang:        Language,
	mode:        Mode,
	cedar:       Cedar,
	char_map:    Char_Map,
	entries:     [dynamic]Dictionary_Entry, // handed over by the importer
	unk_def:     [dynamic]Unk_Rule,
	// unk_patterns carries the patterns.qpat rows (empty when the file
	// was absent): surface-shape labels consulted before the unk.def
	// walk, in declaration order.
	unk_patterns: [dynamic]Unk_Pattern,
	char_class:  Char_Class_Table,
	// char_flags carries the char.def category rows (invoke/group/
	// length per class), indexed by Char_Class. It starts at
	// char_flags_default and a char.def overrides the classes it names;
	// its "DEFAULT" row overrides .Unknown, the class of characters no
	// range covers. The zero value fires no unknown candidates at all.
	char_flags: [len(Char_Class)]Char_Flags,
	conn_matrix: Connection_Matrix, // empty when no matrix.def was supplied
	dict_locale: Locale,           // variant of the loaded dictionary; .None when it has none

	unknown_fallback_pos:  string,          // per-language fallback POS, cloned at load
	skipped_resources: [dynamic]string, // optional resources that were absent

	// intern holds the canonical copies of the entries' repeated field
	// values (the importer's joined POS strings and "*" sentinels);
	// rows borrow them under the interned mask, and teardown releases
	// each canonical once, here. Empty for snapshot restores, whose
	// rows view the image instead.
	intern: map[string]string,

	// entries_hash caches entries_fingerprint's value, stamped at the
	// end of every construction path (load, snapshot restore, the
	// add_user_entries swap window). stats is the only reader; that
	// window is the only post-load writer.
	entries_hash: u64,

	// image is the qdct file image when the analyzer came from a
	// snapshot load (nil after a CSV load). Every entry/unk/fallback/
	// skipped string points into it, so teardown releases the image
	// instead of the individual strings — unmaps it when image_mapped,
	// deletes it otherwise.
	image: []u8,

	// image_mapped is set only when a snapshot load mapped the file
	// (load_qdct_mmap on a platform with a mapping; the Windows fallback
	// keeps it false): the image is a read-only private mapping, and
	// teardown unmaps rather than deletes it.
	image_mapped: bool,

	// Lifecycle counters — the ONLY mutable state after load apart
	// from the drain_wait hook below. Plain fields accessed with
	// base:intrinsics atomic operations carrying explicit
	// .Acquire/.Acq_Rel orderings (the pattern proven on this
	// toolchain). The analysis core never reads them except at proc
	// entry.
	in_use:   i32,  // number of in-flight tokenize-family calls
	teardown: bool, // set by free; new calls bounce off it
	mutating: bool, // set by add_user_entries' swap window; calls bounce off it

	// drain_wait is the wait free and add_user_entries run between
	// in_use polls; polls counts the waits already performed (0 on the
	// first). Both loaders install drain_wait_sleep (100µs); a test
	// replaces the field after load to drive the drain deterministically
	// — the hook may release the held call itself, so the loop advances
	// without sleeping. Written before the analyzer is shared, never
	// during a drain.
	drain_wait: proc(a: ^Analyzer, polls: int),

	allocator: mem.Allocator,
}

// acquire registers an in-flight tokenize-family call. Returns false
// when teardown has begun or an add_user_entries swap is in flight:
// the caller must return .Unavailable without touching analyzer
// state. The load/store orderings pair with free's and
// add_user_entries' drain sequences so a call that increments before
// the flag is either waited for or bounced - never dropped on
// half-swapped memory.
//
// The check-then-increment pair touches the Analyzer struct itself, so
// the struct's storage must outlive every thread that may still be
// ENTERING a call (see free's storage-lifetime note): free drains
// calls that made it inside, but only the embedder can guarantee no
// thread remains between its first check and the increment.
acquire :: proc(a: ^Analyzer) -> bool {
	if intrinsics.atomic_load_explicit(&a.teardown, .Acquire) ||
	   intrinsics.atomic_load_explicit(&a.mutating, .Acquire) {
		return false
	}
	intrinsics.atomic_add_explicit(&a.in_use, 1, .Acq_Rel)
	if intrinsics.atomic_load_explicit(&a.teardown, .Acquire) ||
	   intrinsics.atomic_load_explicit(&a.mutating, .Acquire) {
		intrinsics.atomic_add_explicit(&a.in_use, -1, .Acq_Rel)
		return false
	}
	return true
}

// release deregisters an in-flight call. Paired with acquire at every
// tokenize-family proc exit, including error returns.
release :: proc(a: ^Analyzer) {
	intrinsics.atomic_add_explicit(&a.in_use, -1, .Acq_Rel)
}

// DRAIN_POLL is the default wait between in_use polls while teardown
// drains in-flight tokenize-family calls - one definition for the hook
// and the hook-less fallback.
DRAIN_POLL :: 100 * time.Microsecond

// drain_wait_sleep is the default drain wait: sleep DRAIN_POLL between
// in_use polls. In-flight calls are CPU-bound tokenizes, so a bare
// spin would burn a whole core while they finish.
drain_wait_sleep :: proc(_: ^Analyzer, _: int) {
	time.sleep(DRAIN_POLL)
}

// Dictionary_Entry is one row of a MeCab CSV dictionary. The importer
// appends entries in file order, so the entry id — the cedar's chain
// currency — is the index into Analyzer.entries.
//
// String ownership is per row and per field. strings_owned marks rows
// whose five string fields were cloned into the analyzer allocator (a
// CSV import or an add_user_entries merge), so teardown deletes them;
// a snapshot restore leaves it false because its strings are views
// into the retained image, released with the image instead. Within an
// owned row, the interned mask marks the repeatable fields
// (joined_pos and the "*" sentinels) that borrow the importer's
// intern table instead of owning a private clone - the table owns the
// one canonical copy. A path that replaces such a field (lemma
// normalization, the jyutping donor) clears its bit and owns the
// replacement. The flags travel
// with the row through copies, which is what makes a merged entry
// list's ownership independent of where a surface sort places each
// row. cost is saturated-clamped into i16 on load: values beyond the
// range clamp to the range ends, preserving cost ordering. surface
// and lemma may be empty; "*" is preserved in storage (the surface
// fallback is a Morpheme rule, not an entry rule).
Dictionary_Entry :: struct {
	surface:          string,
	left_id:          i16,              // connection id (matrix row); 0 for id-less schemas
	right_id:         i16,              // connection id (matrix column); 0 for id-less schemas
	cost:             i16,
	joined_pos:       string,           // POS columns prejoined at load
	lemma:            string,
	reading:          string,           // pinyin (ZH) or katakana (JP) or "*"
	reading_jyutping: string,           // jyutping (ZH-HK) or "*"
	extra:            [dynamic]string,  // schema-specific tail columns
	strings_owned:    bool,             // five string fields cloned into allocator (see above)
	interned:         u8,               // borrowed-field mask (see above); surface never borrows
}

// The interned mask's field bits. Surface never interns (surfaces are
// near-unique); the high-cardinality real readings and lemmas do not
// either - interning them would trade their clone rows for a
// comparable mass of map entries. What borrows is what repeats across
// the whole dictionary: the joined POS strings (unidic carries 1,574
// distinct over 756,463 rows) and the "*" sentinels (unidic's reading
// column is "*" on every row).
INTERN_JOINED_POS       :: u8(1 << 0)
INTERN_LEMMA            :: u8(1 << 1)
INTERN_READING          :: u8(1 << 2)
INTERN_READING_JYUTPING :: u8(1 << 3)

// entry_string_fields answers the entry's five owned string fields as
// one array - the single statement of the field set dictionary_entry_destroy
// releases and entries_fingerprint folds (the set Entry_Info exposes,
// which fills its named fields in this same order). A sixth string
// field must land here and in Entry_Info together, or teardown leaks
// it and the entries hash goes stale on it.
entry_string_fields :: #force_inline proc(e: ^Dictionary_Entry) -> [5]string {
	return [5]string{e.surface, e.joined_pos, e.lemma, e.reading, e.reading_jyutping}
}

// dictionary_entry_destroy releases every owned field of one entry
// through the allocator the strings were cloned into; fields under
// the interned mask are the intern table's, released with it. extra
// carries its own allocator and is deleted bare.
dictionary_entry_destroy :: proc(e: ^Dictionary_Entry, allocator: mem.Allocator) {
	delete(e.surface, allocator)
	if e.interned & INTERN_JOINED_POS == 0 { delete(e.joined_pos, allocator) }
	if e.interned & INTERN_LEMMA == 0 { delete(e.lemma, allocator) }
	if e.interned & INTERN_READING == 0 { delete(e.reading, allocator) }
	if e.interned & INTERN_READING_JYUTPING == 0 { delete(e.reading_jyutping, allocator) }
	for s in e.extra {
		delete(s, allocator)
	}
	delete(e.extra)
}

// Unk_Rule is one unknown-word emission rule from unk.def, evaluated in
// declaration order; the first rule whose class matches the run wins.
// The ids and cost ride along so unknown lattice nodes can score
// boundary transitions.
Unk_Rule :: struct {
	class:      Char_Class, // the char.def class named in unk.def column 0
	left_id:    i16,
	right_id:   i16,
	cost:       i16,
	joined_pos: string,    // prejoined at load; cloned into the analyzer allocator
}

// Unk_Pattern_Kind is how one surface-pattern row matches an unknown
// candidate: by prefix, by suffix, or by the class every rune carries.
Unk_Pattern_Kind :: enum {
	Prefix,
	Suffix,
	Charset,
}

// Unk_Pattern is one surface-pattern row from patterns.qpat, checked
// before the unk.def walk in declaration order; the first matching row
// wins. Where an unk rule asks which class the run's first rune
// carries, a pattern asks what the candidate's surface looks like.
Unk_Pattern :: struct {
	kind:       Unk_Pattern_Kind,
	class:      Char_Class, // Charset rows: the class every rune must carry
	pat:        string,    // Prefix/Suffix rows: the literal; never cloned for Charset rows
	left_id:    i16,
	right_id:   i16,
	cost:       i16,
	joined_pos: string,    // prejoined at load; cloned into the analyzer allocator
}

// User_Entry is one dictionary row supplied to add_user_entries:
// a domain term to merge into a loaded analyzer. The connection ids
// must be sane for the loaded matrix (out-of-range pairs fall back to
// the default connection cost, so 0 is always safe); cost is the
// usual lexicon cost - negative values make the term win against
// splits. The surface must be non-empty - add_user_entries rejects
// the whole batch otherwise, because an empty surface has no trie
// path. Every string is cloned into the analyzer's allocator; "*"
// or an empty lemma falls back to the surface, matching entry
// semantics.
User_Entry :: struct {
	surface:          string,
	left_id:          i16,
	right_id:         i16,
	cost:             i16,
	pos:              string,
	lemma:            string,
	reading:          string,
	reading_jyutping: string,
}

// unk_rule_destroy releases the one owned field of a rule.
unk_rule_destroy :: proc(r: ^Unk_Rule, allocator: mem.Allocator) {
	delete(r.joined_pos, allocator)
}

// unk_pattern_destroy releases a pattern's owned fields. The kind
// guard keeps teardown honest: Charset rows never clone a literal, so
// their pat carries nothing to delete.
unk_pattern_destroy :: proc(p: ^Unk_Pattern, allocator: mem.Allocator) {
	if p.kind != .Charset { delete(p.pat, allocator) }
	delete(p.joined_pos, allocator)
}

// Entry_Info resolves one dictionary row behind a Morpheme's entry_id.
// Every string borrows the analyzer's storage with the Morpheme.pos
// lifetime duty: the views are valid until the analyzer is freed (or,
// for ids taken before one, until an add_user_entries merge rebuilds
// the entry list). lemma is the raw entry value - the "*" falls back
// to the surface at the Morpheme layer, not here.
Entry_Info :: struct {
	surface:          string,
	pos:              string,
	lemma:            string,
	reading:          string,
	reading_jyutping: string,
	left_id:          i16,
	right_id:         i16,
	cost:             i16,
}

// entry_info resolves an entry_id from this analyzer's morphemes.
// ok=false reports an id outside [0, len(entries)) - a caller bug
// (typically a stale id after a merge), not a library failure; the
// err side is reserved for the read-out teardown contract, same
// family as stats: a torn-down analyzer bounces with .Unavailable
// instead of reading freed memory. Nothing is allocated. The string
// fields are entry_string_fields' set, filled in its order.
entry_info :: proc(a: ^Analyzer, id: i32) -> (Entry_Info, bool, Save_Err) {
	if !acquire(a) { return Entry_Info{}, false, .Unavailable }
	defer release(a)
	if id < 0 || int(id) >= len(a.entries) { return Entry_Info{}, false, nil }
	e := &a.entries[id]
	info := Entry_Info{
		surface          = e.surface,
		pos              = e.joined_pos,
		lemma            = e.lemma,
		reading          = e.reading,
		reading_jyutping = e.reading_jyutping,
		left_id          = e.left_id,
		right_id         = e.right_id,
		cost             = e.cost,
	}
	return info, true, nil
}

// Analyzer_Stats inventories what one loaded analyzer holds. It is
// a plain value: nothing in it is owned, and skipped borrows views
// into analyzer-owned strings - the analyzer must outlive the struct
// (the Morpheme.pos lifetime duty).
Analyzer_Stats :: struct {
	entries:         int,  // surface-sorted dictionary rows, homographs included
	terminals:       int,  // trie terminals = distinct surfaces (homograph groups)
	cedar_nodes:     int,  // double-array slots in the base/check arrays
	unk_rules:       int,  // unk.def rules
	unk_patterns:    int,  // patterns.qpat rows
	matrix_left:     int,  // left-id space size; 0 = no matrix loaded
	matrix_right:    int,  // right-id space size
	matrix_cells:    int,  // matrix_left * matrix_right
	matrix_explicit: int,  // cells matrix.def enumerated; the rest carry the default cost
	matrix_density:  f64,  // matrix_explicit / matrix_cells; 1.0 when no matrix is loaded
	// entries_hash fingerprints the dictionary rows a Morpheme's
	// entry_id resolves through (the fields entry_info exposes, in
	// surface-sorted order) - FNV-1a, stamped once at the end of every
	// construction path, so it is identical for the same entries
	// however the analyzer was built: CSV load, .qdct restore, or
	// clone. Use it as a dictionary version: add_user_entries always
	// changes it, and a changed hash invalidates every entry_id taken
	// earlier.
	entries_hash:    u64,
	skipped:         []string, // optional resources absent at load (borrowed views)
}

// stats reads a content inventory of the analyzer. The read runs
// under the acquire/release teardown contract (a concurrent free
// would race the array walks), so a torn-down analyzer bounces with
// .Unavailable instead of reading freed memory. Nothing is
// allocated: .OutOfMemory can never come back.
stats :: proc(a: ^Analyzer) -> (Analyzer_Stats, Save_Err) {
	if !acquire(a) { return Analyzer_Stats{}, .Unavailable }
	defer release(a)

	s: Analyzer_Stats
	s.entries = len(a.entries)
	s.unk_rules = len(a.unk_def)
	s.unk_patterns = len(a.unk_patterns)
	s.cedar_nodes = len(a.cedar.base)
	for t in a.cedar.terminals {
		if t >= 0 { s.terminals += 1 }
	}
	s.matrix_left = a.conn_matrix.n_left
	s.matrix_right = a.conn_matrix.n_right
	s.matrix_cells = s.matrix_left * s.matrix_right
	s.matrix_explicit = a.conn_matrix.explicit
	s.matrix_density = 1.0
	if s.matrix_cells > 0 {
		s.matrix_density = f64(s.matrix_explicit) / f64(s.matrix_cells)
	}
	s.entries_hash = a.entries_hash
	s.skipped = a.skipped_resources[:]
	return s, nil
}

// entries_fingerprint folds every entry's resolved fields - the ones
// entry_info exposes - into an FNV-1a hash. Each string mixes its
// byte length first, so the field boundaries are unambiguous; the
// body then mixes eight bytes per step (an unaligned word load - the
// dependent multiply chain is the cost, and a word step cuts it ~8x
// over the byte form; the tail runs per byte, and the length-first
// rule keeps every distinct byte stream on a distinct mixing
// sequence). The entries array is surface-sorted deterministically,
// which is what makes the value load-path independent. Only the
// construction paths call it, stamping the result into
// Analyzer.entries_hash; stats reads the field and never re-walks
// the entries.
entries_fingerprint :: proc(a: ^Analyzer) -> u64 {
	FNV_OFFSET :: 0xcbf29ce484222325
	FNV_PRIME  :: 0x100000001b3
	h: u64 = FNV_OFFSET
	for &e in a.entries {
		// Each string mixes its byte length first, so the field
		// boundaries are unambiguous.
		for s in entry_string_fields(&e) {
			h = (h ~ cast(u64)(len(s))) * FNV_PRIME
			raw := transmute([]u8)s
			n_words := len(raw) / 8
			for i in 0 ..< n_words {
				w: u64
				intrinsics.mem_copy(&w, &raw[i * 8], 8)
				h = (h ~ w) * FNV_PRIME
			}
			for i in n_words * 8 ..< len(raw) {
				h = (h ~ cast(u64)(raw[i])) * FNV_PRIME
			}
		}
		ids := []u16{cast(u16)(e.left_id), cast(u16)(e.right_id), cast(u16)(e.cost)}
		for v in ids {
			for i in 0 ..< 2 {
				h = (h ~ ((cast(u64)(v) >> cast(u64)(i * 8)) & 0xff)) * FNV_PRIME
			}
		}
	}
	return h
}
