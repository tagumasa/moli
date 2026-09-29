// Cedar - the double-array trie that indexes dictionary surfaces for
// longest-match lookup, and the builder that constructs it at load
// time.
//
// The runtime structure is the classical Aoe double array: a
// transition from state s on mapped character c lands at
// t = base[s] + c provided check[t] == s. Characters are compact
// indices from the Char_Map, never raw code points, so each node's
// footprint is bounded by the dictionary alphabet, not the Unicode
// range.
//
// Terminal nodes hold entry GROUPS, not single ids: entries are stored
// in ascending surface order (cedar_build sorts the caller's array,
// stable within equal surfaces), a terminal's homographs are the one
// contiguous range starting at terminals[t], and group_count[head] is
// the range's size. Duplicate surfaces extend their group's count;
// they never overwrite. A node is terminal solely because
// terminals[node] >= 0 - there is no sentinel character.
package moli

import "core:mem"
import "core:sort"
import "core:strings"
import "core:unicode/utf8"

// Cedar is the frozen runtime trie. Position 0 is a placeholder (never
// a valid landing slot); the root sits at position 1. Read-only after
// build; safe for concurrent tokenize use. The four arrays are
// [dynamic], so each carries the allocator it was made with and a bare
// delete frees it correctly.
Cedar :: struct {
	base:        [dynamic]i32, // base[s] + c is the transition landing slot
	check:       [dynamic]i32, // parallel to base; -1 = empty, else parent position
	terminals:   [dynamic]i32, // parallel to base; head entry id of the terminal's homograph group, -1 if not terminal
	group_count: [dynamic]i32, // per entry id: size of the entry's homograph group, valid at group heads (non-heads carry 0)
}

// cedar_destroy releases the four owned arrays. They are [dynamic]
// (allocator-carrying), so bare deletes are correct; deleting a
// zero-value or already-swapped-out Cedar is a no-op. Every teardown
// path - the partial-load release, the user-entry rebuild's failure
// and swap, free - goes through here, so a new array on the struct
// has exactly one release site to extend.
cedar_destroy :: proc(c: ^Cedar) {
	delete(c.base)
	delete(c.check)
	delete(c.terminals)
	delete(c.group_count)
}

// Char_Map compresses the dictionary's character set into the compact
// alphabet [0, N) the double array transits on. Built once at load
// from entry surfaces, most frequent rune first. At lookup time each
// query rune maps through char_code; an absent rune is out of
// vocabulary and ends the walk.
Char_Map :: struct {
	forward:  map[rune]u16,  // rune -> compact index (no reserved index)
	bmp:      []u16,         // direct index for runes < 0x10000 (no_char = unmapped); built wherever forward is
	inverse:  [dynamic]rune, // compact index -> rune
	n_chars:  int,           // alphabet size
}

// no_char marks an unmapped rune in Char_Map.bmp. build_char_map caps
// the alphabet at no_char entries, so no assigned code can collide with
// it.
no_char :: u16(0xFFFF)

// BMP_SIZE is the rune bound of the map's direct-index table: bmp
// covers exactly the runes below it (the BMP); astral runes go through
// the forward map. Every allocation, fill, and test of bmp reads this
// one constant - the load-time build and the snapshot rebuild must
// agree on where the direct table ends.
BMP_SIZE :: 0x10000

// char_code resolves a rune to its compact code; mapped is false for
// runes outside the dictionary alphabet. The BMP table carries every
// rune below BMP_SIZE - all of CJK; astral runes fall through to the
// map.
char_code :: #force_inline proc(m: ^Char_Map, ch: rune) -> (u16, bool) {
	if ch < BMP_SIZE {
		code := m.bmp[ch]
		return code, code != no_char
	}
	return m.forward[ch]
}

// char_map_destroy releases a char map's three owned buffers: forward
// and inverse carry their allocator (map and [dynamic]); bmp is a
// plain slice made with the analyzer's allocator, so its delete takes
// the allocator explicitly. The single release definition for every
// teardown path - see cedar_destroy.
char_map_destroy :: proc(m: ^Char_Map, allocator: mem.Allocator) {
	delete(m.forward)
	delete(m.inverse)
	delete(m.bmp, allocator)
}

// Cedar_Builder is the load-time constructor. It phases construction:
// build the char map, append every surface into a shadow trie (sharing
// prefixes), then place sibling groups into the double array. Exists
// only inside load; it never escapes.
//
// The analyzer allocator initializes the retained collections
// - the char map and the cedar's four arrays - before anything is
// appended; growing a nil [dynamic] or map would go through the
// ambient allocator and strand a buffer under the test tracking
// allocator. scratch_allocator (the load-scratch_allocator arena) backs the transient
// shadow trie, its child index, and sibling slices, which die in the
// free-all that ends load - there is no shadow-node teardown.
Cedar_Builder :: struct {
	cedar:     ^Cedar,
	entries:   []Dictionary_Entry,    // built by the importer before cedar_build runs
	char_map:  Char_Map,              // built before any insertion
	nodes:     [dynamic]Shadow_Node, // shadow trie; nodes[0] is the root
	// (parent<<16)|mapped code -> shadow node id. Lookup only: never
	// iterated - the sibling lists stay the ordering authority for
	// collect_children, so placement order (and qdct bytes) cannot
	// depend on map behavior. Without it the sibling-list walk is the
	// dominant load cost: at ipadic scale the root alone holds ~4,900
	// children and averages ~3,100 steps per entry.
	child_index: map[u64]i32,
	cursor:      i32,                // placement high-water mark; starts at 2
	allocator:       mem.Allocator,      // retained: char map + the four cedar arrays
	scratch_allocator:     mem.Allocator,      // transient: shadow trie + child index + sibling slices
}

// Shadow_Node is one node of the temporary trie the builder walks
// before double-array positions exist. placed_at is -1 until place_node
// assigns one; nothing may index base/check by shadow index before
// that.
Shadow_Node :: struct {
	parent:       i32, // shadow node index; -1 for the root
	char:         u16, // mapped edge code from the parent
	first_child:  i32, // shadow node index; -1 if leaf
	next_sibling: i32, // under the same parent; -1 if last
	first_entry:  i32, // head (lowest id) of the homograph group ending here; -1 if not terminal
	placed_at:    i32, // double-array position once placed; -1 until then
}

// Sibling is one (mapped edge code, shadow child) pair of a placement
// group.
Sibling :: struct {
	char:  u16,
	child: int,
}

// Rune_Freq is the build-time (rune, frequency) record sorted in
// build_char_map.
Rune_Freq :: struct {
	r: rune,
	f: int,
}

// cedar_build constructs the whole trie: reorders the entries into
// surface order (the sorted position is the entry id), builds the char
// map from every entry surface, makes all four cedar arrays (with
// b.allocator) and the shadow-node root plus its child index (with
// b.scratch_allocator - never grown from nil), inserts every surface into the
// shadow trie - repeated surfaces extend their terminal's group - then
// places sibling groups recursively from the root. The Load_Err covers
// .Invalid_Format (an alphabet wider than the u16 compact codes) and
// .OutOfMemory (any builder allocation failure - the sort keys, char
// map, shadow trie, or array growth; every partially built state stays
// on the builder for the caller to release, one owner end to end).
cedar_build :: proc(b: ^Cedar_Builder) -> Load_Err {
	// Surface order is the entry id: the sort runs before anything is
	// built, so homographs are adjacent by the time paths are walked.
	// A sort failure (its scratch keys die with the arena) leaves the
	// entries unpermuted.
	if err := sort_entries_by_surface(b); err != nil { return err }

	if err := build_char_map(b); err != nil { return err }

	cap := b.char_map.n_chars + 2
	// Each array is checked the moment it is made: a failed make is a
	// zero-value [dynamic], and the sentinel writes below would index
	// it out of bounds instead of failing the load. Whatever succeeded
	// stays on the builder for the caller's release.
	merr: mem.Allocator_Error
	b.cedar.base,        merr = make([dynamic]i32, 2, cap, b.allocator)
	if merr != nil { return .OutOfMemory }
	b.cedar.check,       merr = make([dynamic]i32, 2, cap, b.allocator)
	if merr != nil { return .OutOfMemory }
	b.cedar.terminals,   merr = make([dynamic]i32, 2, cap, b.allocator)
	if merr != nil { return .OutOfMemory }
	b.cedar.group_count, merr = make([dynamic]i32, 0, len(b.entries), b.allocator)
	if merr != nil { return .OutOfMemory }
	b.nodes,             merr = make([dynamic]Shadow_Node, 1, 1024, b.scratch_allocator)
	if merr != nil { return .OutOfMemory }
	b.child_index,       merr = make(map[u64]i32, 1024, b.scratch_allocator)
	if merr != nil { return .OutOfMemory }
	b.cedar.check[0]     = -1
	b.cedar.check[1]     = 0
	b.cedar.terminals[0] = -1
	b.cedar.terminals[1] = -1
	b.cursor = 2
	// Root shadow node: no parent, no children, no entry, placed at 1.
	b.nodes[0] = Shadow_Node{
		parent       = -1,
		char         = 0,
		first_child  = -1,
		next_sibling = -1,
		first_entry  = -1,
		placed_at    = 1,
	}

	for entry_id in 0 ..< len(b.entries) {
		if err := cedar_insert_path(b, entry_id, b.entries[entry_id].surface); err != nil {
			return err
		}
	}

	if err := place_node(b, i32(0)); err != nil { return err }
	return nil
}

// build_char_map scans every entry surface, sorts the distinct runes
// by descending frequency (ties broken by code point), and assigns
// compact indices 0..N-1. The frequency sort keeps hot transitions
// dense; no index is reserved. N must fit u16 - a dictionary with more
// than 65535 distinct surface runes fails the load with
// .Invalid_Format (only a corrupt or hostile CSV reaches that).
// Entry_Sort_Key carries one entry's sort position: the surface (a
// borrowed view into the entry's own string - moved, never freed,
// here) and the original index, whose tiebreak makes the sort stable
// so homographs keep their file order and become adjacent. The key
// also carries the surface's first eight bytes as one big-endian u64:
// nearly every comparison resolves on the integer (measured 2.8x over
// the full-string comparator at unidic's 756K surfaces), and the
// zero-padded encoding agrees with strings.compare - a shorter
// surface is a prefix of the longer one and compares less - so the
// total order is unchanged and equal prefixes fall through to the
// full comparison.
Entry_Sort_Key :: struct {
	prefix:  u64,
	surface: string,
	idx:     i32,
}

sort_key_prefix :: proc(s: string) -> u64 {
	v: u64 = 0
	for i in 0 ..< 8 {
		v <<= 8
		if i < len(s) { v |= u64(s[i]) }
	}
	return v
}

entry_key_less :: proc(a, b: Entry_Sort_Key) -> int {
	if a.prefix != b.prefix {
		if a.prefix < b.prefix { return -1 }
		return 1
	}
	c := strings.compare(a.surface, b.surface)
	if c != 0 { return c }
	if a.idx < b.idx { return -1 }
	if a.idx > b.idx { return 1 }
	return 0
}

// sort_entries_by_surface reorders the caller's entry array in place
// into ascending surface order. An already-sorted array (snapshot
// rebuilds, pre-sorted dictionaries) is detected by one comparison
// pass and left untouched. Otherwise the keys sort on the scratch
// arena and the permutation is applied by the classic in-place cycle
// walk: entry structs move as values, so string headers travel with
// their owner and nothing is allocated or freed on the entries
// themselves. The two scratch makes are the only failure points; a
// failure returns with the entries unpermuted.
sort_entries_by_surface :: proc(b: ^Cedar_Builder) -> Load_Err {
	n := len(b.entries)
	if n <= 1 { return nil }

	sorted := true
	for i in 1 ..< n {
		if strings.compare(b.entries[i-1].surface, b.entries[i].surface) > 0 {
			sorted = false
			break
		}
	}
	if sorted { return nil }

	keys, kerr := make([]Entry_Sort_Key, n, b.scratch_allocator)
	if kerr != nil { return .OutOfMemory }
	for i in 0 ..< n {
		s := b.entries[i].surface
		keys[i] = Entry_Sort_Key{prefix = sort_key_prefix(s), surface = s, idx = i32(i)}
	}
	sort.quick_sort_proc(keys[:], entry_key_less)

	// Apply keys[i].idx as "position i receives the entry that
	// started at idx". Each cycle is walked once, holding one
	// displaced entry at a time; applied marks placed positions.
	applied, aerr := make([]bool, n, b.scratch_allocator)
	if aerr != nil { return .OutOfMemory }
	for i in 0 ..< n {
		if applied[i] || keys[i].idx == i32(i) { continue }
		held := b.entries[i]
		j := i
		for {
			k := int(keys[j].idx)
			applied[j] = true
			if k == i {
				b.entries[j] = held
				break
			}
			b.entries[j] = b.entries[k]
			j = k
		}
	}
	return nil
}

build_char_map :: proc(b: ^Cedar_Builder) -> Load_Err {
	// Rune frequencies counted through a direct-indexed BMP table plus
	// a small astral map: the map[rune]int this replaced paid a hashed
	// read-modify-write per surface rune, millions at unidic scale. The
	// counters are u32 - a rune's count is bounded by the file's rune
	// total, and a wrap would need a single-rune dictionary over 4 GiB.
	// All three scratch structures ride the scratch allocator; the
	// analyzer keeps none of them.
	bmp_freq, merr := make([]u32, BMP_SIZE, b.scratch_allocator)
	if merr != nil { return .OutOfMemory }
	astral, amerr := make(map[rune]u32, 16, b.scratch_allocator)
	if amerr != nil {
		delete(bmp_freq, b.scratch_allocator)
		return .OutOfMemory
	}
	for entry in b.entries {
		for ch in entry.surface {
			if ch >= 0 && ch < BMP_SIZE {
				bmp_freq[cast(int)ch] += 1
			} else {
				astral[ch] += 1
			}
		}
	}

	n_pairs := len(astral)
	for f, _ in bmp_freq {
		if f > 0 { n_pairs += 1 }
	}
	if n_pairs > int(no_char) {
		delete(bmp_freq, b.scratch_allocator)
		delete(astral)
		return .Invalid_Format
	}

	pairs, pmerr := make([dynamic]Rune_Freq, 0, n_pairs, b.scratch_allocator)
	if pmerr != nil {
		delete(bmp_freq, b.scratch_allocator)
		delete(astral)
		return .OutOfMemory
	}
	for f, r in bmp_freq {
		if f == 0 { continue }
		if _, e := append(&pairs, Rune_Freq{r = rune(r), f = int(f)}); e != nil {
			delete(bmp_freq, b.scratch_allocator)
			delete(astral)
			delete(pairs)
			return .OutOfMemory
		}
	}
	for r, f in astral {
		if _, e := append(&pairs, Rune_Freq{r = r, f = int(f)}); e != nil {
			delete(bmp_freq, b.scratch_allocator)
			delete(astral)
			delete(pairs)
			return .OutOfMemory
		}
	}
	delete(bmp_freq, b.scratch_allocator)
	delete(astral)

	sort.quick_sort_proc(pairs[:], proc(a, b: Rune_Freq) -> int {
		if a.f > b.f { return -1 }
		if a.f < b.f { return 1 }
		if a.r < b.r { return -1 }
		if a.r > b.r { return 1 }
		return 0
	})

	// Partial state stays on the builder for the caller to release -
	// the same discipline as the cedar arrays. Only the locals (freq,
	// pairs) are cleaned up here, because no caller can reach them.
	b.char_map.forward, merr = make(map[rune]u16, len(pairs), b.allocator)
	if merr != nil {
		delete(pairs)
		return .OutOfMemory
	}
	b.char_map.inverse, merr = make([dynamic]rune, 0, len(pairs), b.allocator)
	if merr != nil {
		delete(pairs)
		return .OutOfMemory
	}
	b.char_map.bmp, merr = make([]u16, BMP_SIZE, b.allocator)
	if merr != nil {
		delete(pairs)
		return .OutOfMemory
	}
	for i in 0 ..< len(b.char_map.bmp) {
		b.char_map.bmp[i] = no_char
	}
	for p, i in pairs {
		idx := u16(i)
		b.char_map.forward[p.r] = idx
		if p.r < BMP_SIZE {
			b.char_map.bmp[p.r] = idx
		}
		if _, e := append(&b.char_map.inverse, p.r); e != nil {
			delete(pairs)
			delete(b.char_map.bmp, b.allocator)
			b.char_map.bmp = nil
			return .OutOfMemory
		}
	}
	b.char_map.n_chars = len(pairs)
	delete(pairs)
	return nil
}

// cedar_insert_path walks (creating as needed) the shadow nodes for
// surface's mapped codes, then joins entry_id to the final node's
// group. Entries arrive surface-sorted, so an occupied terminal with
// the same surface is always the previous entry's group: extend its
// head's count. The surface comparison is a guard, not the grouping
// mechanism - within one build the char map covers every rune of
// every surface, so distinct surfaces reach distinct terminals.
// Surfaces are non-empty - both entry producers validate (parse_entry
// rejects an empty CSV surface, add_user_entries rejects an empty user
// surface) - because a zero-length surface would join the shadow root,
// which no terminal ever points at. .OutOfMemory propagates from the
// shadow-trie growth; the caller owns whatever was already appended
// to the builder's arrays.
cedar_insert_path :: proc(b: ^Cedar_Builder, entry_id: int, surface: string) -> Load_Err {
	node := i32(0)
	for ch in surface {
		code, mapped := char_code(&b.char_map, ch)
		// The char map is built from every entry surface before any
		// insert runs, so an unmapped rune can only mean that
		// invariant broke. Silently skipping the rune would join the
		// entry to a wrong shorter-prefix terminal - reject instead.
		if !mapped { return .Invalid_Format }
		child, cerr := find_or_create_child(b, node, code)
		if cerr != nil { return cerr }
		node = child
	}

	if _, e := append(&b.cedar.group_count, 0); e != nil { return .OutOfMemory }
	head := b.nodes[node].first_entry
	if head >= 0 && b.entries[head].surface == surface {
		b.cedar.group_count[head] += 1
	} else {
		b.nodes[node].first_entry = i32(entry_id)
		b.cedar.group_count[entry_id] = 1
	}
	return nil
}

// find_or_create_child returns the shadow child of node on the mapped
// code, appending a fresh node at the front of the sibling list when
// absent. The child index answers the lookup in O(1); the sibling list
// is still maintained (front-inserted) because collect_children walks
// it for deterministic placement order. The error side carries
// shadow-trie growth failure; the i32 is meaningless (0) when it is
// set.
find_or_create_child :: proc(b: ^Cedar_Builder, node: i32, code: u16) -> (i32, Load_Err) {
	key := (cast(u64)cast(u32)(node) << 16) | cast(u64)(code)
	if child, ok := b.child_index[key]; ok {
		return child, nil
	}
	fresh := i32(len(b.nodes))
	_, e := append(&b.nodes, Shadow_Node{
		parent       = node,
		char         = code,
		first_child  = -1,
		next_sibling = b.nodes[node].first_child,
		first_entry  = -1,
		placed_at    = -1,
	})
	if e != nil { return 0, .OutOfMemory }
	b.nodes[node].first_child = fresh
	b.child_index[key] = fresh
	return fresh, nil
}

// collect_children materializes a shadow node's children as a flat
// sibling slice, allocated from the builder's scratch allocator.
collect_children :: proc(b: ^Cedar_Builder, node: i32) -> ([]Sibling, Load_Err) {
	out, aerr := make([dynamic]Sibling, 0, 8, b.scratch_allocator)
	if aerr != nil { return nil, .OutOfMemory }
	child := b.nodes[node].first_child
	for child >= 0 {
		if _, e := append(&out, Sibling{char = b.nodes[child].char, child = int(child)}); e != nil {
			return nil, .OutOfMemory
		}
		child = b.nodes[child].next_sibling
	}
	return out[:], nil
}

// place_node walks the shadow trie placing every sibling group into
// the double array, depth-first over an explicit worklist on the
// scratch allocator: recursion would pay one stack frame per trie
// level, and trie depth equals the longest surface's rune count -
// unbounded against hostile input. Children are pushed reversed so
// the LIFO pops them in sibling order: the placement order (and with
// it the qdct bytes) is identical to the recursive walk's. The error
// side carries allocation failure outward; partial array growth
// stays owned by the builder for the caller to release.
place_node :: proc(b: ^Cedar_Builder, root: i32) -> Load_Err {
	work, werr := make([dynamic]i32, 0, 64, b.scratch_allocator)
	if werr != nil { return .OutOfMemory }
	if _, e := append(&work, root); e != nil { return .OutOfMemory }
	for len(work) > 0 {
		node := work[len(work) - 1]
		resize(&work, len(work) - 1)

		siblings, cerr := collect_children(b, node)
		if cerr != nil { return cerr }
		if len(siblings) == 0 { continue }

		pos, perr := find_placement(b, siblings)
		if perr != nil { return perr }
		parent_pos := b.nodes[node].placed_at
		b.cedar.base[parent_pos] = pos
		for sibling in siblings {
			t := pos + i32(sibling.char)
			b.cedar.check[t]     = parent_pos
			b.cedar.terminals[t] = b.nodes[sibling.child].first_entry
			b.nodes[sibling.child].placed_at = t
		}

		for i := len(siblings) - 1; i >= 0; i -= 1 {
			if _, e := append(&work, i32(siblings[i].child)); e != nil { return .OutOfMemory }
		}
	}
	return nil
}

// find_placement scans forward from the high-water cursor for the
// first position where the group fits, growing the arrays ahead of the
// scan so unallocated territory is free space rather than a
// pseudo-collision - every candidate is judged by occupancy alone. The
// cursor never moves backward: slots rejected by an earlier group are
// not reconsidered, trading a little density for amortized O(1)
// scanning. Because mapped codes are 0-based and placement starts at
// 2, no landing slot can ever be the reserved positions 0 or 1. Array
// growth failure surfaces as .OutOfMemory.
find_placement :: proc(b: ^Cedar_Builder, siblings: []Sibling) -> (i32, Load_Err) {
	pos := b.cursor
	for {
		if int(pos) + b.char_map.n_chars >= len(b.cedar.check) {
			if err := grow_arrays(b, int(pos) + b.char_map.n_chars); err != nil {
				return 0, err
			}
		}
		collision := false
		for sibling in siblings {
			t := pos + i32(sibling.char)
			if b.cedar.check[t] != -1 {
				collision = true
				break
			}
		}
		if !collision {
			b.cursor = pos + 1
			return pos, nil
		}
		pos += 1
	}
}

// grow_arrays extends base/check/terminals to the target length in
// one reservation per array (resize zero-fills the new slots - base's
// desired fill) and then fills check/terminals by index: the house
// bulk idiom, the one import_matrix_def's dense fill already uses -
// the append form paid a capacity check and a length bump per slot,
// three arrays over, for every growth at dictionary scale. A failed
// resize aborts mid-batch - the three arrays may then differ in
// length, which is safe only because the error path releases them
// all.
grow_arrays :: proc(b: ^Cedar_Builder, min_len: int) -> Load_Err {
	batch := max(b.char_map.n_chars, 8)
	target := max(min_len + 1, len(b.cedar.base) + batch)
	n0 := len(b.cedar.base)
	if resize(&b.cedar.base, target) != nil { return .OutOfMemory }
	if resize(&b.cedar.check, target) != nil { return .OutOfMemory }
	if resize(&b.cedar.terminals, target) != nil { return .OutOfMemory }
	for i in n0 ..< target {
		b.cedar.check[i] = -1
		b.cedar.terminals[i] = -1
	}
	return nil
}

// cedar_step answers the landing slot of one transition from node on
// the mapped code, or ok = false when the slot is outside the array or
// not owned by node. The ONE definition of the double-array transition
// check: every runtime walk goes through it, so the guard (t bounded on
// both sides — snapshot base values are validated non-negative at
// load, the walk still re-checks) can never drift between callers.
// Zero-allocation, O(1).
cedar_step :: proc(c: ^Cedar, node: i32, code: u16) -> (t: i32, ok: bool) {
	t = c.base[node] + i32(code)
	if t < 0 || int(t) >= len(c.check) { return 0, false }
	return t, c.check[t] == node
}

// Scan_Table is the request-scoped decode cache for the longest-match
// walk: per byte offset of the analyzed text, the rune starting there
// mapped to its alphabet code plus its width, packed as
// (width << SCAN_WIDTH_SHIFT) | code. One linear sweep computes it, so the walk's
// per-level decode-and-map becomes a single table load and the same
// position is never decoded twice across walk steps. Every byte that
// does not start a mapped rune - mid-rune bytes, unmapped runes -
// carries SCAN_NO_RUNE, so a walk querying any byte offset breaks
// exactly where the decoding walk did (a mid-rune offset decodes as
// RUNE_ERROR and maps to nothing). Request scratch on the caller's
// arena_allocator; the walks never write it.
Scan_Table :: struct {
	text:  string,
	codes: []u32,
}

// SCAN_NO_RUNE marks a table slot the walk must stop on. The code half
// alone would collide with a width-carrying entry, so the whole word is
// the sentinel: real entries always have width bits set (width >= 1),
// and codes stay below no_char, which reserves the half's top value.
SCAN_NO_RUNE :: u32(0xFFFF)

// The packed entry's layout halves beside the sentinel: the rune's
// UTF-8 width at SCAN_WIDTH_SHIFT, its mapped alphabet code in the low
// SCAN_CODE_MASK bits (codes stay below no_char, which reserves the
// half's top value against a width-carrying entry).
SCAN_WIDTH_SHIFT :: 16
SCAN_CODE_MASK   :: u32(0xFFFF)

// scan_table_build is the one sweep behind Scan_Table: decode each rune
// once, map it through the char map, and write the packed entry at its
// start byte and the sentinel at the rune's interior bytes. Text with
// malformed UTF-8 fills one sentinel byte per invalid byte, matching
// decode's one-byte-at-a-time degradation. The sweep defines every byte
// of the table, so the buffer takes the allocator's raw path at every
// size - the non-zeroed crossover gate exists for buffers the request
// only partially writes, and a zero-fill here would be a wasted pass.
scan_table_build :: proc(m: ^Char_Map, text: string, arena_allocator: mem.Allocator, loc := #caller_location) -> (s: Scan_Table, err: mem.Allocator_Error) {
	raw, aerr := alloc_raw(arena_allocator, len(text) * size_of(u32), align_of(u32), loc)
	if aerr != nil { return Scan_Table{}, aerr }
	codes := mem.slice_ptr(cast(^u32)raw_data(raw), len(text))
	p := 0
	for p < len(text) {
		r, w := utf8.decode_rune_in_string(text[p:])
		if w == 0 { w = 1 }
		e := SCAN_NO_RUNE
		if code, mapped := char_code(m, r); mapped {
			e = u32(w << SCAN_WIDTH_SHIFT) | u32(code)
		}
		codes[p] = e
		for q in p + 1 ..< min(p + w, len(text)) {
			codes[q] = SCAN_NO_RUNE
		}
		p += w
	}
	return Scan_Table{text = text, codes = codes}, nil
}

// cedar_match is the longest-match primitive: it walks the scan table
// from byte offset pos through mapped transitions and reports the group
// head and end offset of the longest terminal reached. The head is not a
// resolved entry - greedy mode resolves it (cedar_resolve_entry), Viterbi
// enumerates the whole group. Zero-allocation; an unmapped rune (or a
// mid-rune offset) ends the walk. O(1) per rune, O(runes-walked) total.
cedar_match :: proc(c: ^Cedar, s: ^Scan_Table, pos: int) -> (head: int, end_pos: int, ok: bool) {
	node := i32(1)
	last_head: int = -1
	last_end:  int = pos
	cur := pos
	for cur < len(s.text) {
		e := s.codes[cur]
		if e == SCAN_NO_RUNE { break }
		code := u16(e & SCAN_CODE_MASK)
		t, stepped := cedar_step(c, node, code)
		if !stepped { break }
		node = t
		cur += int(e >> SCAN_WIDTH_SHIFT)
		if term := c.terminals[node]; term >= 0 {
			last_head = int(term)
			last_end  = cur
		}
	}
	if last_head < 0 { return 0, 0, false }
	return last_head, last_end, true
}

// cedar_resolve_entry picks one entry from a homograph group for greedy
// mode: lowest cost, and the ascending range scan keeps the lowest id
// (file order within the surface group) on a tie for free. Viterbi
// never resolves - every group member becomes its own lattice
// candidate.
cedar_resolve_entry :: proc(c: ^Cedar, entries: []Dictionary_Entry, head: int) -> int {
	best := head
	for i in 1 ..< int(c.group_count[head]) {
		if entries[head + i].cost < entries[best].cost {
			best = head + i
		}
	}
	return best
}
