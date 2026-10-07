// The Viterbi tokenizer: candidate lattice construction, connection-
// cost dynamic programming, and traceback. Request-scoped scratch (the
// lattice, the start buckets, the path) lives in the caller's arena_allocator;
// the analyzer is read-only throughout.
package moli

import "base:intrinsics"
import "core:mem"
import "core:slice"
import "core:unicode/utf8"

// Connection_Matrix is the dense row-major connection cost table from a
// MeCab matrix.def: costs[left * n_right + right]. Ids 0 are the BOS/
// EOS boundaries by MeCab convention - BOS's right_id and EOS's
// left_id are 0, so boundary transitions hit row/column 0. With no
// matrix loaded (n_left == 0) every lookup answers
// CONNECTION_DEFAULT_COST and the DP optimizes node costs alone -
// still deterministic and well-defined for the id-less ZH/EN schemas.
// Costs were saturated-clamped into i16 at load.
Connection_Matrix :: struct {
	costs:   [dynamic]i16,
	n_left:  int, // left-id space size; 0 = no matrix loaded
	n_right: int, // right-id space size (matrix.def column count)
	explicit: int, // distinct cells matrix.def enumerated; the rest carry CONNECTION_DEFAULT_COST (diagnostics: stats density, never consulted by the DP)
}

// CONNECTION_DEFAULT_COST is the cost of missing and out-of-range
// transition pairs - 7000, the MeCab convention. Unfilled dense cells
// are written with it at import. (It is a constant, not a struct
// field: struct field defaults do not exist on this toolchain, and a
// zero-value matrix carrying 0 would silently corrupt the no-matrix
// DP arithmetic.)
CONNECTION_DEFAULT_COST :: i16(7000)

// DP_UNREACHABLE is the sentinel for "no path has reached this node
// yet" during the Viterbi forward pass. i64 max keeps every real cost
// strictly smaller.
DP_UNREACHABLE :: i64(max(i64))

// Growth floors for the raw-growth buffers: a doubling from an empty
// buffer (0 * 2) still allocates a usable block. The node floor sits
// above the morpheme floor because every tokenize pushes BOS, EOS, and
// at least one node per rune position.
NODE_BUF_GROW_FLOOR      :: 64
MORPHEME_BUF_GROW_FLOOR  :: 16

// Initial capacity of the small per-request dynamic collections (the
// DP path, the n-best entries and heap, the match spill, the surface
// projections' output): request-scale, not dictionary-scale - growth
// past it is rare and one doubling is cheap.
SMALL_START_CAP :: 16

// Lattice_Node is one candidate morpheme during Viterbi: the build and
// emission format. The DP keeps its state (cost-so-far, predecessor) in
// packed parallel arrays inside viterbi_best_path - a 72-byte node put
// its five per-edge-hot fields on 2-3 cache lines, so the relaxation
// reads a dense split view instead. BOS: start == end == 0, right_id 0.
// EOS: start == end == len(text), left_id 0. entry_id >= 0 indexes
// Analyzer.entries; -1 marks BOS/EOS/unknown.
Lattice_Node :: struct {
	start:      int,
	end:        int,
	entry_id:   int,
	is_unknown: bool,
	class:      Char_Class, // class of the rune at start; BOS/EOS carry .Unknown (never emitted). Rides is_unknown's padding block.
	pos:        string, // joined POS; set only for unknown nodes (from the rule)
	left_id:    i16,
	right_id:    i16,
	cost:        i16,    // the node's own cost (entry, rule, or 0 for BOS/EOS)
}

// node_is_sentinel reports whether n is one of the BOS/EOS sentinel
// nodes every emission walk skips: entry_id -1 without the unknown
// mark (unknown nodes carry entry_id -1 too - the pair of fields is
// the encoding, declared at Lattice_Node above).
node_is_sentinel :: #force_inline proc(n: ^Lattice_Node) -> bool {
	return n.entry_id < 0 && !n.is_unknown
}

// matrix_cost looks up a transition. O(1) in-range read;
// CONNECTION_DEFAULT_COST answers out-of-range pairs and the
// no-matrix case.
matrix_cost :: proc(m: ^Connection_Matrix, left: i16, right: i16) -> i16 {
	if m == nil { return CONNECTION_DEFAULT_COST }
	if m.n_left == 0 { return CONNECTION_DEFAULT_COST }
	l := int(left)
	r := int(right)
	if l < 0 || l >= m.n_left { return CONNECTION_DEFAULT_COST }
	if r < 0 || r >= m.n_right { return CONNECTION_DEFAULT_COST }
	return m.costs[l * m.n_right + r]
}

// viterbi_path builds the lattice and runs the best-path DP, returning
// both: emission needs the lattice's nodes alongside the path. The
// tokenize dispatchers sink the result into whichever buffer their
// contract names. BOS and EOS produce no morphemes. The path cost is
// the classic objective - sum of node costs plus sum of transition
// costs - minimized over paths from BOS to EOS.
viterbi_path :: proc(a: ^Analyzer, text: string, cancel: ^Cancel_Token, unk_bias: i32, unk_per_rune: i32, cons: Constraints, arena_allocator: mem.Allocator) -> ([]Lattice_Node, []int, Tokenize_Err) {
	lattice, lerr := build_lattice(a, text, cancel, cons, arena_allocator)
	if lerr != nil { return nil, nil, lerr }

	path, perr := viterbi_best_path(a, lattice, text, unk_bias, unk_per_rune, arena_allocator)
	if perr != nil { return nil, nil, perr }

	return lattice, path, nil
}

// sink_push appends one morpheme to a walk's sink - the caller's
// dynamic array or tokenize's raw-growth buffer. Only the branch for
// the instantiated Sink compiles.
sink_push :: #force_inline proc($Sink: typeid, sink: ^Sink, m: Morpheme) -> Tokenize_Err {
	when Sink == [dynamic]Morpheme {
		if _, aerr := append(sink, m); aerr != nil { return .OutOfMemory }
	} else {
		if aerr := push_morpheme(sink, m); aerr != nil { return .OutOfMemory }
	}
	return nil
}

// emit_path_walk appends the morphemes of one lattice path, in path
// order, skipping the BOS/EOS sentinels, into the caller's sink. The
// morpheme builders are the single emission definitions; both sinks
// (dynamic array, raw-growth buffer) move together through this one
// walk.
emit_path_walk :: proc(a: ^Analyzer, text: string, lattice: []Lattice_Node, path: []int, $Sink: typeid, sink: ^Sink) -> Tokenize_Err {
	for i in 0 ..< len(path) {
		n := &lattice[path[i]]
		if node_is_sentinel(n) { continue }
		if n.is_unknown {
			if serr := sink_push(Sink, sink, emit_unknown_from_node(a, text, n)); serr != nil {
				return serr
			}
		} else {
			entry := &a.entries[n.entry_id]
			if serr := sink_push(Sink, sink, morpheme_from_entry(a, text, n.start, n.end, i32(n.entry_id), entry, n.class)); serr != nil {
				return serr
			}
		}
	}
	return nil
}

// emit_path_morphemes appends the path's morphemes into a caller-owned
// dynamic array (tokenize_into and the n-best search).
emit_path_morphemes :: proc(a: ^Analyzer, text: string, lattice: []Lattice_Node, path: []int, out: ^[dynamic]Morpheme) -> Tokenize_Err {
	return emit_path_walk(a, text, lattice, path, [dynamic]Morpheme, out)
}

// emit_path_morphemes_buf is emit_path_morphemes into a
// Morpheme_Buffer - the sink behind tokenize. The path length bounds
// the emission exactly (every path node emits one morpheme except the
// BOS/EOS sentinels), so the buffer is reserved once, upfront.
emit_path_morphemes_buf :: proc(a: ^Analyzer, text: string, lattice: []Lattice_Node, path: []int, buf: ^Morpheme_Buffer) -> Tokenize_Err {
	if aerr := reserve_morphemes(buf, len(path)); aerr != nil { return .OutOfMemory }
	return emit_path_walk(a, text, lattice, path, Morpheme_Buffer, buf)
}

// emit_unknown_from_node builds the zero-copy Morpheme for a lattice
// unknown node: the surface slices the input text, the lemma falls
// back to it, and char_class comes off the node (the build classified
// the position's rune once).
emit_unknown_from_node :: proc(a: ^Analyzer, text: string, n: ^Lattice_Node) -> Morpheme {
	surface := text[n.start:n.end]
	return Morpheme{
		surface          = surface,
		pos              = n.pos,
		lemma            = surface,
		reading          = "*",
		reading_jyutping = "*",
		entry_id         = -1,
		cost             = n.cost,
		start            = n.start,
		end              = n.end,
		locale           = a.dict_locale,
		char_class       = n.class,
		is_unknown       = true,
	}
}

// non_zeroed_min_bytes is the cache-scale crossover measured for the
// tokenize scratch: below it the arena's zero-initialization works as
// a write warm-up (cache-resident buffers tokenize faster zeroed), at
// or above it the zero-fill is a memory-bandwidth tax (the 1 MiB+ per
// growth buffers dominate large-input tokenize). Allocations under the
// threshold keep the plain zeroed path.
non_zeroed_min_bytes :: 1 << 20

// alloc_raw is the raw-allocation ladder every raw buffer shares: the
// allocator's .Alloc_Non_Zeroed mode, falling back to the plain zeroed
// .Alloc for allocators that do not implement the mode, so any caller
// allocator keeps working.
alloc_raw :: proc(allocator: mem.Allocator, size: int, alignment: int, loc := #caller_location) -> ([]u8, mem.Allocator_Error) {
	raw, aerr := allocator.procedure(allocator.data, .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
	if aerr == .Mode_Not_Implemented {
		raw, aerr = allocator.procedure(allocator.data, .Alloc, size, alignment, nil, 0, loc)
	}
	return raw, aerr
}

// alloc_non_zeroed requests the raw allocation path for buffers at or
// above non_zeroed_min_bytes. The core mem.Arena zero-initializes
// every allocation by default; lattice scratch is written before any
// read, so skipping the fill saves a full pass over multi-megabyte
// buffers. Allocations under the threshold keep the plain zeroed path.
alloc_non_zeroed :: proc(allocator: mem.Allocator, size: int, alignment: int, loc := #caller_location) -> ([]u8, mem.Allocator_Error) {
	if size < non_zeroed_min_bytes {
		return mem.alloc_bytes(size, alignment, allocator, loc)
	}
	return alloc_raw(allocator, size, alignment, loc)
}

// Raw_Buffer grows an element array through raw, uninitialized
// allocations: every appended slot is written whole before any read,
// so the arena's default zero-initialization of each grown buffer is
// pure overhead once a buffer passes the non_zeroed_min_bytes gate;
// grown-out buffers are abandoned to the arena and die with its reset.
// The lattice's node accumulator and the tokenize output's morpheme
// buffer are the two instantiations - the growth protocol lives here
// exactly once.
Raw_Buffer :: struct($T: typeid) {
	data:      []T,
	len:       int,
	allocator: mem.Allocator,
}

// raw_buf_push appends one element, growing through alloc_non_zeroed
// when full. floor is the instantiation's from-empty growth floor (a
// doubling from zero must still allocate a usable block).
raw_buf_push :: #force_inline proc(buf: ^Raw_Buffer($T), v: T, floor: int) -> mem.Allocator_Error {
	if buf.len == len(buf.data) {
		new_cap := max(floor, len(buf.data) * 2)
		raw, aerr := alloc_non_zeroed(buf.allocator, new_cap * size_of(T), align_of(T))
		if aerr != nil { return aerr }
		grown := mem.slice_ptr(cast(^T)raw_data(raw), new_cap)
		copy(grown, buf.data)
		buf.data = grown
	}
	buf.data[buf.len] = v
	buf.len += 1
	return nil
}

// raw_buf_reserve pre-sizes the buffer for a known bound, replacing
// the doubling chain's intermediate copies with one exact allocation
// (each grown buffer is copied, then abandoned). Slots between len
// and capacity are never read; every emitted slot is written whole,
// keeping the raw allocation safe.
raw_buf_reserve :: proc(buf: ^Raw_Buffer($T), cap: int) -> mem.Allocator_Error {
	if cap <= len(buf.data) { return nil }
	raw, aerr := alloc_non_zeroed(buf.allocator, cap * size_of(T), align_of(T))
	if aerr != nil { return aerr }
	grown := mem.slice_ptr(cast(^T)raw_data(raw), cap)
	copy(grown, buf.data[:buf.len])
	buf.data = grown
	return nil
}

// Node_Buffer is the lattice-build node accumulator; see Raw_Buffer
// for the growth protocol.
Node_Buffer :: Raw_Buffer(Lattice_Node)

push_node :: #force_inline proc(buf: ^Node_Buffer, node: Lattice_Node) -> mem.Allocator_Error {
	return raw_buf_push(buf, node, NODE_BUF_GROW_FLOOR)
}

// Morpheme_Buffer is the emitted-morpheme result buffer of tokenize;
// the returned slice data[:len] is the caller's result. The
// non-zeroed crossover was measured for the tokenize scratch
// generally, not the lattice alone.
Morpheme_Buffer :: Raw_Buffer(Morpheme)

push_morpheme :: #force_inline proc(buf: ^Morpheme_Buffer, m: Morpheme) -> mem.Allocator_Error {
	return raw_buf_push(buf, m, MORPHEME_BUF_GROW_FLOOR)
}

// reserve_morphemes pre-sizes the morpheme buffer for a known bound
// on the emitted count: the Viterbi emission knows len(path) before
// it starts.
reserve_morphemes :: proc(buf: ^Morpheme_Buffer, cap: int) -> mem.Allocator_Error {
	return raw_buf_reserve(buf, cap)
}

// Lattice_Walk_Table is the Viterbi build's per-request decode cache:
// one sweep decodes each rune, maps it through the char map, and
// classifies it, packing the results at the rune's start byte. The
// lattice build then never decodes again - the per-position width and
// class, the trie walk's per-level codes, the unknown-run walk, the
// unknown-prefix walk, and the emitted morphemes' char classes all read
// packed entries. It is the Viterbi counterpart of the greedy path's
// Scan_Table (cedar.odin) with a different packing: the greedy walk
// needs code and width only and stops on unmapped runes, while the
// lattice also needs each position's class (unknown candidates fire
// there regardless of mapping), so unmapped rune starts carry
// width+class with the mapped bit clear instead of collapsing into the
// greedy sentinel.
//
// Entry layout (u32):
//   bits  0..15  char-map code (valid when the mapped bit is set; the
//                alphabet is capped below no_char, see cedar.odin)
//   bit   16     mapped flag
//   bits 17..19  UTF-8 width of the rune (1..4)
//   bits 20..23  Char_Class value (13 members fit)
// Interior bytes of a multi-byte rune carry 0 - a real entry always
// has its mapped-or-class bits placed above width 0, so all-zero is
// the interior sentinel. The walk treats interior bytes and unmapped
// rune starts identically (stop), so it tests the mapped bit alone.
// The sweep defines every byte of the table, so the buffer takes the
// allocator's raw path at every size (see scan_table_build for the
// crossover-gate reasoning).
Lattice_Walk_Table :: struct {
	text:  string,
	codes: []u32,
}

LT_MAPPED :: u32(1) << 16
LT_WIDTH_SHIFT :: 17 // packed-entry layout: bits 17..19 carry the UTF-8 width (1..4)
LT_CLASS_SHIFT :: 20 // bits 20..23 carry the Char_Class value (13 members fit)
LT_WIDTH_MASK :: u32(0x7) // the three width bits at LT_WIDTH_SHIFT
LT_CLASS_MASK :: u32(0xF) // the four class bits at LT_CLASS_SHIFT

lattice_walk_table_build :: proc(m: ^Char_Map, cc: ^Char_Class_Table, text: string, arena_allocator: mem.Allocator, loc := #caller_location) -> (t: Lattice_Walk_Table, err: mem.Allocator_Error) {
	raw, aerr := alloc_raw(arena_allocator, len(text) * size_of(u32), align_of(u32), loc)
	if aerr != nil { return Lattice_Walk_Table{}, aerr }
	codes := mem.slice_ptr(cast(^u32)raw_data(raw), len(text))
	p := 0
	for p < len(text) {
		r, w := utf8.decode_rune_in_string(text[p:])
		if w == 0 { w = 1 }
		e := u32(char_class_of(cc, r)) << LT_CLASS_SHIFT | u32(w) << LT_WIDTH_SHIFT
		if code, mapped := char_code(m, r); mapped {
			e |= LT_MAPPED | u32(code)
		}
		codes[p] = e
		for q in p + 1 ..< min(p + w, len(text)) {
			codes[q] = 0
		}
		p += w
	}
	return Lattice_Walk_Table{text = text, codes = codes}, nil
}

// Match_List is build_lattice's per-position match accumulator: the
// ids of every entry whose surface starts at one position. Real
// positions collect a handful of ids (one homograph group per terminal
// along the walk), so a fixed stack array serves them without touching
// the allocator; the dynamic spill keeps the accumulator unbounded for
// pathological homograph groups. The previous [dynamic]int paid a
// resize call per position and append machinery per id; the fixed
// prefix drops both on the common path. The spill is allocated lazily
// on first overflow and reused (length-reset only) for the rest of the
// request; it dies with the caller's arena.
MATCH_FIXED :: 128

Match_List :: struct {
	fixed:     [MATCH_FIXED]int,
	n:         int,
	spill:     [dynamic]int,
	allocator: mem.Allocator,
}

match_push :: #force_inline proc(ml: ^Match_List, v: int) -> mem.Allocator_Error {
	if ml.n < MATCH_FIXED {
		ml.fixed[ml.n] = v
		ml.n += 1
		return nil
	}
	if ml.spill == nil {
		spill, merr := make([dynamic]int, 0, SMALL_START_CAP, ml.allocator)
		if merr != nil { return merr }
		ml.spill = spill
	}
	if _, err := append(&ml.spill, v); err != nil { return err }
	ml.n += 1
	return nil
}

match_reset :: #force_inline proc(ml: ^Match_List) {
	ml.n = 0
	if ml.spill != nil { resize(&ml.spill, 0) }
}

match_get :: #force_inline proc(ml: ^Match_List, i: int) -> int {
	if i < MATCH_FIXED { return ml.fixed[i] }
	return ml.spill[i - MATCH_FIXED]
}

// build_lattice enumerates, per rune position: every dictionary entry
// whose surface starts there (all homographs of every matching
// prefix), and - when the class's char.def flags call for it - the
// unknown candidates for the contiguous same-class run starting
// there: the grouped run (group), every 1..length-rune prefix
// (length), or both; classes marked invoke fire even where a
// dictionary word starts. The per-rune candidates keep the lattice
// connected - a dictionary word starting inside a run would otherwise
// be a dead node (the run candidate overshoots its start, and nothing
// else ends there). Nodes append in ascending start order, which is
// the topological order the DP relies on.
//
// cons, when active, filters the finished enumeration down to the
// candidates the constraints allow (constraint.odin): a constraint
// that changes nothing reproduces the unconstrained lattice exactly,
// and one that over-constrains leaves positions the DP cannot reach -
// detected by the searches as Unsatisfiable_Error, never here.
build_lattice :: proc(a: ^Analyzer, text: string, cancel: ^Cancel_Token, cons: Constraints, arena_allocator: mem.Allocator) -> ([]Lattice_Node, Tokenize_Err) {
	nodes: Node_Buffer
	nodes.allocator = arena_allocator

	// One sweep defines the per-request walk table; from here on the
	// build reads packed entries - no per-position decode, no per-level
	// decode in the trie walk, no per-rune decode in the unknown-run
	// and prefix walks.
	tab, wterr := lattice_walk_table_build(&a.char_map, &a.char_class, text, arena_allocator)
	if wterr != nil { return nil, .OutOfMemory }

	matches: Match_List
	matches.allocator = arena_allocator

	// The pattern-resolution fork is request-invariant; hoisted out of
	// the per-position loop.
	has_pat := len(a.unk_patterns) > 0

	// End of the same-class run containing p, valid while p sits below
	// it. Every position of one run shares that run's end and p visits
	// the rune positions in order, so the walk below runs once per run
	// and its result serves the positions inside it.
	cached_run_end := 0

	if aerr := push_node(&nodes, Lattice_Node{
		start = 0, end = 0, entry_id = -1,
		left_id = 0, right_id = 0, cost = 0,
	}); aerr != nil { return nil, .OutOfMemory }

	p: int = 0
	for p < len(text) {
		// Cancellation poll: once per rune position, before any
		// candidate work at the position (nil token: one branch).
		if cancel != nil && token_cancelled(cancel) {
			return nil, Cancelled_Error{byte_offset = p}
		}

		// One packed entry per position: the width advances p, the
		// class drives the unknown branch, and all_matches_at walks
		// the table from here.
		pe := tab.codes[p]
		rune_width := int((pe >> LT_WIDTH_SHIFT) & LT_WIDTH_MASK)
		class := Char_Class((pe >> LT_CLASS_SHIFT) & LT_CLASS_MASK)

		match_reset(&matches)
		if amerr := all_matches_at(a, &tab, p, &matches); amerr != nil {
			return nil, .OutOfMemory
		}

		fl := a.char_flags[int(class)]

		if matches.n > 0 {
			for mi in 0 ..< matches.n {
				ent := &a.entries[match_get(&matches, mi)]
				if aerr := push_node(&nodes, Lattice_Node{
					start = p, end = p + len(ent.surface), entry_id = match_get(&matches, mi),
					class = class,
					left_id = ent.left_id, right_id = ent.right_id, cost = ent.cost,
				}); aerr != nil { return nil, .OutOfMemory }
			}
			if !fl.invoke {
				p += rune_width
				continue
			}
		}

		// Unknown candidates for the class at p, deduplicated by end
		// offset (ends ascend: the grouped run last, rune prefixes in
		// order). A class with both group and length off still gets
		// the single rune - the lattice must offer a candidate at
		// every position the DP can reach. The run and prefix walks
		// advance over the table's packed widths and compare its
		// packed classes - never decoding. A per-position run walk
		// made one contiguous same-class block quadratic in its
		// length; the cache above walks each run once.
		if p >= cached_run_end {
			e := p + rune_width
			for e < len(text) {
				re := tab.codes[e]
				rw := int((re >> LT_WIDTH_SHIFT) & LT_WIDTH_MASK)
				if rw == 0 || Char_Class((re >> LT_CLASS_SHIFT) & LT_CLASS_MASK) != class { break }
				e += rw
			}
			cached_run_end = e
		}
		run_end := cached_run_end
		// The grouped run resolves the shared ladder first. With
		// surface patterns loaded, every candidate then resolves its
		// own surface (a suffix row can label the whole run while its
		// shorter prefixes keep the class label); with none loaded one
		// resolution serves the position, exactly as before.
		joined_pos, cost, left_id, right_id := resolve_unk(a, class, text[p:run_end])
		last_end := -1
		if fl.group {
			if aerr := push_node(&nodes, Lattice_Node{
				start = p, end = run_end, entry_id = -1, is_unknown = true,
				class = class, pos = joined_pos, left_id = left_id, right_id = right_id,
				cost = cost,
			}); aerr != nil { return nil, .OutOfMemory }
			last_end = run_end
		}
		cur_end := p
		for l := 0; cur_end < run_end && l < int(fl.length); l += 1 {
			cur_end += int((tab.codes[cur_end] >> LT_WIDTH_SHIFT) & LT_WIDTH_MASK)
			// Skip the ends already emitted: the previous prefix
			// (prefix ends ascend) and, when the grouped run was
			// emitted, the run end the longest prefix reaches.
			if cur_end == last_end || (fl.group && cur_end == run_end) { continue }
			if has_pat {
				joined_pos, cost, left_id, right_id = resolve_unk(a, class, text[p:cur_end])
			}
			if aerr := push_node(&nodes, Lattice_Node{
				start = p, end = cur_end, entry_id = -1, is_unknown = true,
				class = class, pos = joined_pos, left_id = left_id, right_id = right_id,
				cost = cost,
			}); aerr != nil { return nil, .OutOfMemory }
			last_end = cur_end
		}
		if last_end < 0 {
			if has_pat {
				joined_pos, cost, left_id, right_id = resolve_unk(a, class, text[p:p+rune_width])
			}
			if aerr := push_node(&nodes, Lattice_Node{
				start = p, end = p + rune_width, entry_id = -1, is_unknown = true,
				class = class, pos = joined_pos, left_id = left_id, right_id = right_id,
				cost = cost,
			}); aerr != nil { return nil, .OutOfMemory }
		}

		p += rune_width
	}

	if aerr := push_node(&nodes, Lattice_Node{
		start = len(text), end = len(text), entry_id = -1,
		left_id = 0, right_id = 0, cost = 0,
	}); aerr != nil { return nil, .OutOfMemory }

	if constraints_active(cons) {
		nodes.len = constraint_filter_lattice(a, nodes.data[:nodes.len], cons)
	}
	return nodes.data[:nodes.len], nil
}

// all_matches_at appends every entry id whose surface is a prefix of
// tab.text[pos:] - every homograph in each terminal's group - into the
// caller's accumulator. The caller owns the accumulator and resets it
// between positions; build_lattice reuses one for the whole request.
// The walk is single-path (only one rune matches per byte position);
// entries whose surface merely shares a prefix are correctly excluded.
// Each level reads the packed table entry - the mapped bit fails the
// walk on interior bytes and unmapped runes alike, and the code half
// steps the trie with no decode and no char-map lookup. Emission order
// is unchanged from the recursive original: the root terminal's group
// first, then each reached terminal's group in walk order, group
// members highest id first - the candidate order the lattice has
// always seen.
all_matches_at :: proc(a: ^Analyzer, tab: ^Lattice_Walk_Table, pos: int, results: ^Match_List) -> mem.Allocator_Error {
	// Root terminal: an empty-surface entry would emit here, before
	// any rune is consumed.
	head := int(a.cedar.terminals[1])
	if head >= 0 {
		n := int(a.cedar.group_count[head])
		for i := n - 1; i >= 0; i -= 1 {
			if err := match_push(results, head + i); err != nil { return err }
		}
	}

	node := i32(1)
	cur := pos
	for cur < len(tab.text) {
		e := tab.codes[cur]
		if e & LT_MAPPED == 0 { break }
		t, stepped := cedar_step(&a.cedar, node, u16(e))
		if !stepped { break }
		node = t
		cur += int((e >> LT_WIDTH_SHIFT) & LT_WIDTH_MASK)
		if h := int(a.cedar.terminals[node]); h >= 0 {
			n := int(a.cedar.group_count[h])
			for i := n - 1; i >= 0; i -= 1 {
				if err := match_push(results, h + i); err != nil { return err }
			}
		}
	}
	return nil
}

// viterbi_best_path runs the forward DP over the lattice - relaxing
// every edge exactly once, thanks to the ascending start order - and
// traces the minimum-cost path from EOS back to BOS. On the
// unconstrained lattice reachability is guaranteed (every position
// starts a candidate or an unknown candidate); a constraint mask can
// genuinely empty a position, and that case unwinds as
// Unsatisfiable_Error (byte_offset = the earliest blocked position)
// instead of a fabricated path. The fixed scan order makes
// tie-breaking deterministic.
//
// unk_bias shifts every unknown node's contribution to the search by
// that many units (Tokenize_Options.unk_cost_bias): it changes which
// path wins, never the emitted costs. Successor lookup is a counting
// sort: bucket boundaries in one flat offsets array, node indices in
// one flat order array - never a [dynamic] bucket per input byte
// (that would spend a header per byte). The DP accumulator is i64:
// the path sums i16 node and edge costs over up to ~10^6 morphemes,
// which overflows i32.
// lattice_successor_index returns the successor buckets' boundaries:
// bucket [pos] is the contiguous lattice index range
// [offsets[pos], offsets[pos+1]) - the nodes starting at pos, in
// append order. build_lattice appends nodes grouped by ascending start
// (BOS at 0 first, every per-position push starts at that position,
// EOS at text_len last) and node starts stay within text_len, so the
// buckets are exactly those contiguous index ranges - no
// ordered-indices array exists, and the successors of a node ending at
// e are read directly as offsets[e] ..< offsets[e+1]. Both the forward
// DP and the n-best search rely on this grouping invariant; it is
// load-bearing and documented at build_lattice. Which bucket members
// are admissible edge targets is likewise one rule: edge_target_ok
// directly below.
lattice_successor_index :: proc(lattice: []Lattice_Node, text_len: int, arena_allocator: mem.Allocator) -> (offsets: []int, err: Tokenize_Err) {
	// The counter array needs its zeros; every slot is then overwritten
	// by the prefix sum, which turns the counts into boundaries.
	offs, aerr := make([]int, text_len + 2, arena_allocator)
	if aerr != nil { return nil, .OutOfMemory }
	for node in lattice {
		offs[node.start + 1] += 1
	}
	for i in 1 ..= text_len + 1 {
		offs[i] += offs[i - 1]
	}
	return offs, nil
}

// edge_target_ok is the one successor-admission rule every edge loop
// over the buckets applies (the forward DP relaxation, the backward
// heuristic DP, the A* expansion): the relaxing/expanding node itself
// and BOS (index 0) are never edge targets. The node itself: a
// zero-width node's successor bucket is its own start group, so it
// sits among its own successors, and admitting the self-edge sets
// prev = self in the forward DP - a cycle the traceback below can
// never leave. BOS: it is the forward DP's fixed source (dp pinned to
// 0 at index 0), and on empty text BOS and EOS are both zero-width at
// offset 0 and share the start-0 bucket, so without the source guard
// a negative boundary cell (ipadic ships `0 0 -434`) relaxes BOS back
// through EOS (cand = 2*cost < 0), welding a BOS<->EOS prev cycle. In
// the backward DP and the A* expansion the BOS skip is presently
// unreachable (only a node ending at 0 can list BOS among its
// successors, and only the sentinels are zero-width) - the rule lives
// here so the three loops cannot drift apart again.
edge_target_ok :: #force_inline proc(from: int, sj: int) -> bool {
	return sj != from && sj != 0
}

// Successors is the searches' split view of the lattice: the three
// per-edge-hot successor fields as flat parallel arrays, packed by
// pack_successors (the layout note at viterbi_best_path says why the DP
// reads a split view instead of the node struct). unk_runes joins the
// pack only when the caller prices unknowns per rune (a nonzero
// unk_per_rune): each unknown node's surface rune count, counted once
// at pack time instead of once per incoming edge. It is nil otherwise
// and never read nil - edge_cost consults it under the same
// unk_per_rune != 0 condition that requests it.
Successors :: struct {
	left_id:   []i16,
	cost:      []i16,
	unknown:   []bool,
	unk_runes: []i32,
}

// pack_successors fills one Successors view over the whole lattice: one
// sequential pass up front, then dense per-edge reads for the rest of
// the search. Every slot is written before any read, which is what makes
// the raw (non-zeroed above the size gate) allocations safe. unk_runes
// rides the same pass and the same arena, requested by a nonzero
// unk_per_rune (the only condition under which it is read).
pack_successors :: proc(lattice: []Lattice_Node, text: string, unk_per_rune: i32, arena_allocator: mem.Allocator) -> (succ: Successors, err: Tokenize_Err) {
	n_nodes := len(lattice)
	lid_raw, lerr := alloc_non_zeroed(arena_allocator, n_nodes * size_of(i16), align_of(i16))
	if lerr != nil { return Successors{}, .OutOfMemory }
	succ.left_id = mem.slice_ptr(cast(^i16)raw_data(lid_raw), n_nodes)
	cost_raw, cerr := alloc_non_zeroed(arena_allocator, n_nodes * size_of(i16), align_of(i16))
	if cerr != nil { return Successors{}, .OutOfMemory }
	succ.cost = mem.slice_ptr(cast(^i16)raw_data(cost_raw), n_nodes)
	unk_raw, uerr := alloc_non_zeroed(arena_allocator, n_nodes * size_of(bool), align_of(bool))
	if uerr != nil { return Successors{}, .OutOfMemory }
	succ.unknown = mem.slice_ptr(cast(^bool)raw_data(unk_raw), n_nodes)
	if unk_per_rune != 0 {
		runes_raw, rerr := alloc_non_zeroed(arena_allocator, n_nodes * size_of(i32), align_of(i32))
		if rerr != nil { return Successors{}, .OutOfMemory }
		succ.unk_runes = mem.slice_ptr(cast(^i32)raw_data(runes_raw), n_nodes)
	}
	for i in 0 ..< n_nodes {
		n := &lattice[i]
		succ.left_id[i] = n.left_id
		succ.cost[i] = n.cost
		succ.unknown[i] = n.is_unknown
		if n.is_unknown && unk_per_rune != 0 {
			succ.unk_runes[i] = i32(utf8.rune_count_in_string(text[n.start:n.end]))
		}
	}
	return succ, nil
}

// matrix_row_base answers the row base for one node's outgoing
// transitions - nil when every edge from it must take
// CONNECTION_DEFAULT_COST (no matrix loaded, or the node's right_id
// outside the left-id space; lex.csv and unk.def ids are not validated
// against the matrix dimensions at import, so the range check stays per
// node).
matrix_row_base :: #force_inline proc(m: ^Connection_Matrix, right_id: i16) -> ^i16 {
	if m.n_left == 0 { return nil }
	l := int(right_id)
	if l < 0 || l >= m.n_left { return nil }
	return intrinsics.ptr_offset(cast(^i16)raw_data(m.costs), l * m.n_right)
}

// edge_cost is the one edge-weight definition the searches share: the
// transition cost (the matrix cell, or CONNECTION_DEFAULT_COST for the
// no-matrix and out-of-range pairs), the successor's own node cost, and
// - for an unknown successor - the unk bias and per-rune term off the
// pack-time rune count (Successors.unk_runes). The forward DP, the
// backward heuristic DP, and the A* expansion must apply the same
// weights or their orderings disagree (the Tokenize_Options unk_cost_*
// contract), so the arithmetic lives here exactly once; each search
// adds its own accumulator on top. i64 addition is associative, so the
// grouping change against the former inline sums is bit-identical.
edge_cost :: #force_inline proc(m: ^Connection_Matrix, row_base: ^i16, succ: ^Successors, sj: int, unk_bias: i32, unk_per_rune: i32) -> i64 {
	// sj is a lattice index by the successor-bucket invariant
	// (lattice_successor_index), so the packed-array reads carry no
	// bounds checks.
	#no_bounds_check {
		edge := CONNECTION_DEFAULT_COST
		if row_base != nil {
			r := int(succ.left_id[sj])
			if r >= 0 && r < m.n_right {
				edge = (intrinsics.ptr_offset(row_base, r))^
			}
		}
		cost := i64(edge) + i64(succ.cost[sj])
		if succ.unknown[sj] {
			cost += i64(unk_bias)
			if unk_per_rune != 0 {
				cost += i64(unk_per_rune) * i64(succ.unk_runes[sj])
			}
		}
		return cost
	}
}

viterbi_best_path :: proc(a: ^Analyzer, lattice: []Lattice_Node, text: string, unk_bias: i32, unk_per_rune: i32, arena_allocator: mem.Allocator) -> ([]int, Tokenize_Err) {
	text_len := len(text)
	offsets, serr := lattice_successor_index(lattice, text_len, arena_allocator)
	if serr != nil { return nil, serr }

	// The relaxation reads, per edge, the successor's left_id, cost,
	// is_unknown, cost-so-far, and predecessor. On the node struct those
	// five values are scattered across the whole struct (and the DP state
	// is not node data at all), while the DP crosses every edge exactly
	// once. So the successor-side state is packed into flat parallel
	// arrays before the loop: one sequential pass over the lattice up
	// front, then dense accesses per edge. The node struct itself stays
	// the build/emission format - only the DP's view is split.
	n_nodes := len(lattice)

	// dp is the only array that needs an initial value pattern:
	// DP_UNREACHABLE everywhere but the pinned BOS source. prev is written
	// by the first relaxation of each reached node and read only along the
	// best path (every node on it was relaxed), so only prev[0] = -1 is
	// fixed. Every array slot is written before any read, which is what
	// makes the raw (non-zeroed above the size gate) allocation safe.
	dp_raw, derr := alloc_non_zeroed(arena_allocator, n_nodes * size_of(i64), align_of(i64))
	if derr != nil { return nil, .OutOfMemory }
	dp := mem.slice_ptr(cast(^i64)raw_data(dp_raw), n_nodes)
	for i in 0 ..< n_nodes { dp[i] = DP_UNREACHABLE }
	dp[0] = 0
	prev_raw, perr := alloc_non_zeroed(arena_allocator, n_nodes * size_of(int), align_of(int))
	if perr != nil { return nil, .OutOfMemory }
	prev := mem.slice_ptr(cast(^int)raw_data(prev_raw), n_nodes)
	prev[0] = -1

	succ, serr2 := pack_successors(lattice, text, unk_per_rune, arena_allocator)
	if serr2 != nil { return nil, serr2 }

	// The edge lookup is hoisted per left node: matrix_cost's no-matrix
	// and left-range guards depend only on n.right_id, and so does the
	// row base. lex.csv and unk.def ids are not validated against the
	// matrix dimensions at import, so the right-range check stays per
	// successor; row_base is dereferenced only through it.
	m := &a.conn_matrix
	for i := 0; i < n_nodes; i += 1 {
		// Every index here is a lattice index - i by the loop bound,
		// sj by the successor-bucket invariant, n.end by the walk
		// table - so the body carries no bounds checks.
		#no_bounds_check {
			if dp[i] == DP_UNREACHABLE { continue }
			n := &lattice[i]

			row_base := matrix_row_base(m, n.right_id)

			succ_lo := 0
			succ_hi := 0
			if n.end <= text_len {
				succ_lo = offsets[n.end]
				succ_hi = offsets[n.end + 1]
			}
			for sj in succ_lo ..< succ_hi {
				if !edge_target_ok(i, sj) { continue }
				cand := dp[i] + edge_cost(m, row_base, &succ, sj, unk_bias, unk_per_rune)
				if cand < dp[sj] {
					dp[sj] = cand
					prev[sj] = i
				}
			}
		}
	}

	eos := n_nodes - 1
	if dp[eos] == DP_UNREACHABLE {
		return nil, Unsatisfiable_Error{byte_offset = first_unreached_forward(lattice, dp, text, arena_allocator)}
	}
	path, merr := make([dynamic]int, 0, SMALL_START_CAP, arena_allocator)
	if merr != nil { return nil, .OutOfMemory }
	cur := eos
	for cur >= 0 {
		if _, aerr := append(&path, cur); aerr != nil { return nil, .OutOfMemory }
		cur = prev[cur]
	}
	slice.reverse(path[:])
	return path[:], nil
}

// ---------------------------------------------------------------------------
// n-best enumeration
// ---------------------------------------------------------------------------

// NBest_Path is one enumerated path: its search cost (sum of node and
// edge costs, including any Tokenize_Options.unk_cost_bias the call
// passed - emitted Morpheme costs stay the rules' own) and its
// morphemes in order.
NBest_Path :: struct {
	cost:      i64,
	morphemes: []Morpheme,
}

// NBest_Entry is one A* state: the exact cost g of one specific
// prefix path from BOS ending at node, its parent entry (index into
// the entry array, -1 for the BOS root), and f = g + h(node) - with
// h the exact remaining cost, f is the best total reachable through
// this prefix.
NBest_Entry :: struct {
	g:      i64,
	f:      i64,
	node:   int,
	parent: int,
}

// tokenize_nbest enumerates the k lowest-cost lattice paths, best
// first, into out (cleared at entry, before the request prelude - a
// faulted call leaves none of a previous call's paths behind). The
// search is A* with an exact heuristic: one backward DP computes each
// node's best remaining cost, so every heap pop extends the prefix on
// a provably optimal completion and completed paths leave the heap in
// cost order. Ties break by insertion order - enumeration is
// deterministic. k < 1 clamps to 1; fewer than k paths come back when
// the lattice holds fewer distinct paths. Same acquire/release and
// error contract as tokenize, and the same request prelude every
// tokenize-family entry shares (tokenize_scan_text: strict input,
// constraint validation, NFC composition). Greedy mode is meaningless
// here, so a.mode is ignored and the lattice is always searched; with
// opts.normalize_nfc every path's surfaces slice the arena_allocator
// copy. cons carries the constrained-analysis set (constraint.odin);
// the zero value is the unconstrained search, and an over-constrained
// mask faults with Unsatisfiable_Error (byte_offset = the far edge of
// the blocked region) before any path is emitted.
tokenize_nbest :: proc(a: ^Analyzer, text: string, k: int, opts: Tokenize_Options, cons: Constraints, out: ^[dynamic]NBest_Path, arena_allocator: mem.Allocator) -> Tokenize_Err {
	if !acquire(a) { return .Unavailable }
	defer release(a)

	want := k
	if want < 1 { want = 1 }
	resize(out, 0)

	scan, serr := tokenize_scan_text(opts, text, cons, arena_allocator)
	if serr != nil { return serr }
	return nbest_search(a, scan, want, opts, cons, out, arena_allocator)
}

// nbest_search is the n-best core under tokenize_nbest's
// acquire/release umbrella.
nbest_search :: proc(a: ^Analyzer, text: string, want: int, opts: Tokenize_Options, cons: Constraints, out: ^[dynamic]NBest_Path, arena_allocator: mem.Allocator) -> Tokenize_Err {
	lattice, lerr := build_lattice(a, text, opts.cancel_token, cons, arena_allocator)
	if lerr != nil { return lerr }
	text_len := len(text)
	offsets, serr := lattice_successor_index(lattice, text_len, arena_allocator)
	if serr != nil { return serr }

	// Backward DP: h[i] is the cheapest completion of node i - its
	// outgoing edge plus the successor's (biased) node cost plus the
	// successor's own completion. Processed in reverse index order,
	// which is reverse topological order here (nodes append in
	// ascending start order and every edge goes to a later start).
	// The successor-side reads ride the same packed parallel arrays as
	// viterbi_best_path; h is raw-allocated because the fill loop
	// overwrites every slot with DP_UNREACHABLE anyway.
	n_nodes := len(lattice)

	h_raw, herr_raw := alloc_non_zeroed(arena_allocator, n_nodes * size_of(i64), align_of(i64))
	if herr_raw != nil { return .OutOfMemory }
	h := mem.slice_ptr(cast(^i64)raw_data(h_raw), n_nodes)
	for i in 0 ..< n_nodes { h[i] = DP_UNREACHABLE }
	eos := n_nodes - 1
	h[eos] = 0

	succ, serr2 := pack_successors(lattice, text, opts.unk_cost_per_rune, arena_allocator)
	if serr2 != nil { return serr2 }

	m := &a.conn_matrix
	for i := n_nodes - 1; i >= 0; i -= 1 {
		n := &lattice[i]
		if n.end > text_len { continue }

		row_base := matrix_row_base(m, n.right_id)

		for sj in offsets[n.end] ..< offsets[n.end + 1] {
			if !edge_target_ok(i, sj) { continue }
			if h[sj] == DP_UNREACHABLE { continue }
			cand := edge_cost(m, row_base, &succ, sj, opts.unk_cost_bias, opts.unk_cost_per_rune) + h[sj]
			if h[i] == DP_UNREACHABLE || cand < h[i] { h[i] = cand }
		}
	}

	entries, eerr := make([dynamic]NBest_Entry, 0, SMALL_START_CAP, arena_allocator)
	if eerr != nil { return .OutOfMemory }
	// The heap holds entry indices; ordering is by (f, insertion
	// index) - both deterministic.
	heap, herr := make([dynamic]int, 0, SMALL_START_CAP, arena_allocator)
	if herr != nil { return .OutOfMemory }

	// On the unconstrained lattice connectivity guarantees every
	// position a candidate, so this fires only under a constraint
	// mask that emptied a region - reported as Unsatisfiable_Error
	// with the far edge of the block, not as an empty result.
	if h[0] == DP_UNREACHABLE {
		return Unsatisfiable_Error{byte_offset = first_unreached_backward(lattice, h, text, arena_allocator)}
	}
	if _, aerr := append(&entries, NBest_Entry{g = 0, f = h[0], node = 0, parent = -1}); aerr != nil {
		return .OutOfMemory
	}
	if nbest_heap_push(&heap, 0, &entries) != nil { return .OutOfMemory }

	for len(out^) < want && len(heap) > 0 {
		ei := nbest_heap_pop(&heap, &entries)
		e := entries[ei]
		// Cancellation poll: once per heap pop, the enumeration's unit
		// of work. The walk polls per position inside build_lattice;
		// the DP and emission phases are output-bounded, but the A*
		// heap frontier grows with the lattice, so this is the one
		// post-walk phase that stays interruptible. The unwind offset
		// is the popped prefix's node start - paths already appended
		// stay written.
		if opts.cancel_token != nil && token_cancelled(opts.cancel_token) {
			return Cancelled_Error{byte_offset = lattice[e.node].start}
		}
		if e.node == eos {
			path, merr2 := make([dynamic]int, 0, SMALL_START_CAP, arena_allocator)
			if merr2 != nil { return .OutOfMemory }
			cur := ei
			for cur >= 0 {
				if _, aerr := append(&path, entries[cur].node); aerr != nil {
					return .OutOfMemory
				}
				cur = entries[cur].parent
			}
			slice.reverse(path[:])
			morphs, merr3 := make([dynamic]Morpheme, 0, len(path), arena_allocator)
			if merr3 != nil { return .OutOfMemory }
			if eerr := emit_path_morphemes(a, text, lattice, path[:], &morphs); eerr != nil {
				return eerr
			}
			if _, oerr := append(out, NBest_Path{cost = e.g, morphemes = morphs[:]}); oerr != nil {
				return .OutOfMemory
			}
			continue
		}
		n := &lattice[e.node]
		if n.end > text_len { continue }

		row_base := matrix_row_base(m, n.right_id)

		for sj in offsets[n.end] ..< offsets[n.end + 1] {
			if !edge_target_ok(e.node, sj) { continue }
			if h[sj] == DP_UNREACHABLE { continue }
			g := e.g + edge_cost(m, row_base, &succ, sj, opts.unk_cost_bias, opts.unk_cost_per_rune)
			ne := NBest_Entry{g = g, f = g + h[sj], node = sj, parent = ei}
			if _, aerr := append(&entries, ne); aerr != nil { return .OutOfMemory }
			if nbest_heap_push(&heap, len(entries) - 1, &entries) != nil {
				return .OutOfMemory
			}
		}
	}
	return nil
}

// nbest_entry_less orders heap entries by f, then insertion index.
nbest_entry_less :: proc(entries: []NBest_Entry, x, y: int) -> bool {
	if entries[x].f != entries[y].f { return entries[x].f < entries[y].f }
	return x < y
}

nbest_heap_push :: proc(heap: ^[dynamic]int, v: int, entries: ^[dynamic]NBest_Entry) -> mem.Allocator_Error {
	if _, err := append(heap, v); err != nil { return err }
	i := len(heap^) - 1
	for i > 0 {
		p := (i - 1) / 2
		if !nbest_entry_less(entries[:], heap^[i], heap^[p]) { break }
		heap^[i], heap^[p] = heap^[p], heap^[i]
		i = p
	}
	return nil
}

nbest_heap_pop :: proc(heap: ^[dynamic]int, entries: ^[dynamic]NBest_Entry) -> int {
	top := heap^[0]
	last := len(heap^) - 1
	heap^[0] = heap^[last]
	resize(heap, last)
	i := 0
	for {
		l, r := 2 * i + 1, 2 * i + 2
		best := i
		if l < len(heap^) && nbest_entry_less(entries[:], heap^[l], heap^[best]) { best = l }
		if r < len(heap^) && nbest_entry_less(entries[:], heap^[r], heap^[best]) { best = r }
		if best == i { break }
		heap^[i], heap^[best] = heap^[best], heap^[i]
		i = best
	}
	return top
}
