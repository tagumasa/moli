// qdct: the binary snapshot boundary. save_qdct serializes a loaded
// Analyzer into one offset-addressed image; load_qdct validates the
// image and rebuilds the analyzer with every string pointing into the
// retained file image (Analyzer.image) instead of per-string clones.
// The layout carries offsets, never pointers, so the later mmap load
// reuses the same fixups against a mapping.
//
// Byte order: the header, the section table, and every scalar the
// loader reads field-by-field are explicitly little-endian; the bulk
// array and record sections are written in host byte order — little-
// endian on every supported target (linux/darwin/windows, x86_64 and
// arm64), which is all the format promises. A big-endian host would
// write images only that host reads back (and a cross-endian handoff
// fails the base-value validation rather than misreading).
package moli

import "base:runtime"
import "core:io"
import "core:mem"
import "core:os"

// Version history: 1 shipped the original 13 sections; 2 added the
// char-flags section (char.def invoke/group/length per class); 3 added
// the patterns section (surface-pattern augmentation for unknown
// runs); 4 replaced the entry-next link array with the homograph
// group-count array (entries are surface-sorted with contiguous
// groups - same geometry, one i32 per entry, different meaning); 5
// kept the geometry but wrote Entry_Record without its trailing pad
// (52 bytes); 6 restores the pad (56 bytes, the 8-byte record stride
// every other record already had). Older files are rejected by the
// version check - the v3 chain values would be nonsense as counts and
// v5 entry geometry misreads under v6; regenerate them.
QDCT_VERSION :: u32(6)

QDCT_HEADER_SIZE :: 64
QDCT_SECTION_ENTRY_SIZE :: 16 // (offset u64, length u64) per section

// Qdct_Section names the image's sections; a member's ordinal is the
// section-table slot the format writes it in. Keyed as an enum so the
// size switch (qdct_section_size) must enumerate every member: a new
// section without its arm is a compile error, not a silently
// zero-sized section. The QDCT_SECTION_* constants below are the
// members' wire names - typed aliases, so switch cases, section-table
// indexing, and the tests' geometry arithmetic (through int()) share
// one vocabulary. A member's ordinal fixes its table slot, not its
// position in the file: the reader walks the table, and the writer
// places BLOB last (the only section whose length is unknown before
// the entries walk).
Qdct_Section :: enum {
	BASE,
	CHECK,
	TERMINALS,
	GROUP_COUNT,
	ENTRIES,
	EXTRAS,
	UNK,
	RANGES,
	PAIRS,
	COSTS,
	BLOB,
	SKIPPED,
	FALLBACK,
	CHAR_FLAGS,
	PATTERNS,
}

QDCT_SECTION_COUNT :: len(Qdct_Section)
QDCT_SECTION_TABLE_SIZE :: QDCT_SECTION_COUNT * QDCT_SECTION_ENTRY_SIZE

QDCT_SECTION_BASE        :: Qdct_Section.BASE
QDCT_SECTION_CHECK       :: Qdct_Section.CHECK
QDCT_SECTION_TERMINALS   :: Qdct_Section.TERMINALS
QDCT_SECTION_GROUP_COUNT :: Qdct_Section.GROUP_COUNT
QDCT_SECTION_ENTRIES     :: Qdct_Section.ENTRIES
QDCT_SECTION_EXTRAS      :: Qdct_Section.EXTRAS
QDCT_SECTION_UNK         :: Qdct_Section.UNK
QDCT_SECTION_RANGES      :: Qdct_Section.RANGES
QDCT_SECTION_PAIRS       :: Qdct_Section.PAIRS
QDCT_SECTION_COSTS       :: Qdct_Section.COSTS
QDCT_SECTION_BLOB        :: Qdct_Section.BLOB
QDCT_SECTION_SKIPPED     :: Qdct_Section.SKIPPED
QDCT_SECTION_FALLBACK    :: Qdct_Section.FALLBACK
QDCT_SECTION_CHAR_FLAGS  :: Qdct_Section.CHAR_FLAGS
QDCT_SECTION_PATTERNS    :: Qdct_Section.PATTERNS

// Header field offsets, one name per little-endian u32 the header
// carries after magic(0x00)/version(0x04)/lang(0x08)/mode(0x09)/
// locale(0x0A)/flat(0x0B). qdct_image writes them sequentially in this
// order and asserts its cursor against the last one; qdct_rebuild
// addresses them by these names - the two sides share one vocabulary
// instead of order-here, hex-there.
QDCT_OFF_ENTRIES  :: 0x0C
QDCT_OFF_UNK      :: 0x10
QDCT_OFF_RANGES   :: 0x14
QDCT_OFF_PAIRS    :: 0x18
QDCT_OFF_SKIPPED  :: 0x1C
QDCT_OFF_LEFT     :: 0x20
QDCT_OFF_RIGHT    :: 0x24
QDCT_OFF_EXTRAS   :: 0x28
QDCT_OFF_EXPLICIT :: 0x2C
QDCT_OFF_PATTERNS :: 0x30

// Qdct_Counts carries the header counts and blob size both the image
// builder and the load validator derive section sizes from (the load
// side reads them out of the header, the save side off the analyzer).
Qdct_Counts :: struct {
	n_cedar:    int,
	n_entries:  int,
	n_extras:   int,
	n_unk:      int,
	n_patterns: int,
	n_ranges:   int,
	n_pairs:    int,
	n_left:     int,
	n_right:    int,
	n_skipped:  int,
	blob_len:   int,
}

// qdct_section_size is the one statement of every section's byte size
// - the wire geometry the image builder fills its section table from
// and the load validator checks the image's table against. A stride
// or record change must land here alone; with the sizes stated twice,
// save and load could drift until a reload rejects what a save wrote.
// The section key is the Qdct_Section enum, so a member without an arm
// here fails to compile rather than answering a silent zero.
qdct_section_size :: proc(c: ^Qdct_Counts, section: Qdct_Section) -> int {
	switch section {
	case QDCT_SECTION_BASE:        return c.n_cedar * size_of(i32)
	case QDCT_SECTION_CHECK:       return c.n_cedar * size_of(i32)
	case QDCT_SECTION_TERMINALS:   return c.n_cedar * size_of(i32)
	case QDCT_SECTION_GROUP_COUNT: return c.n_entries * size_of(i32)
	case QDCT_SECTION_ENTRIES:     return c.n_entries * size_of(Entry_Record)
	case QDCT_SECTION_EXTRAS:      return c.n_extras * size_of(Str_Ref)
	case QDCT_SECTION_UNK:         return c.n_unk * size_of(Unk_Record)
	case QDCT_SECTION_RANGES:      return c.n_ranges * size_of(Char_Range)
	case QDCT_SECTION_PAIRS:       return c.n_pairs * size_of(Pair)
	case QDCT_SECTION_COSTS:       return c.n_left * c.n_right * size_of(i16)
	case QDCT_SECTION_BLOB:        return c.blob_len
	case QDCT_SECTION_SKIPPED:     return c.n_skipped * size_of(Str_Ref)
	case QDCT_SECTION_FALLBACK:    return size_of(Str_Ref)
	case QDCT_SECTION_CHAR_FLAGS:  return len(Char_Class) * size_of(Char_Flags_Record)
	case QDCT_SECTION_PATTERNS:    return c.n_patterns * size_of(Pattern_Record)
	}
	return 0 // unreachable: the switch is total over Qdct_Section
}

// The .qdct record forms' representational limits, stated once for the
// builder (the loader enforces its side through the geometry,
// bijection, and member checks): every header count field is u32, a
// blob-relative string ref is u32 in both halves, an entry's extras
// window is u16 wide into a u32-indexed section, and the compact trie
// alphabet is u16 with 0xFFFF reserved as cedar's no_char sentinel.
QDCT_MAX_U32  :: 0xFFFFFFFF // header counts, Str_Ref.off/.len, extra_first
QDCT_MAX_U16  :: 0xFFFF     // extra_count
QDCT_MAX_CODE :: 0xFFFE     // Pair.code (0xFFFF is no_char)

// qdct_counts_limit_err answers .Format_Limit when the analyzer's
// shape exceeds one of the record-form limits above - the one
// save-side limits check, run before the first image byte is written
// so no writer narrows a field silently (a wrapped blob ref or extras
// count would pass the loader's bound checks as a valid-but-wrong
// value). The check is total: with it passed, every string length and
// blob offset sits under blob_len, every extras index under n_extras,
// and every extra window inside the u16 cap.
qdct_counts_limit_err :: proc(a: ^Analyzer, c: ^Qdct_Counts) -> Save_Err {
	if c.n_cedar > QDCT_MAX_U32 || c.n_entries > QDCT_MAX_U32 || c.n_unk > QDCT_MAX_U32 ||
	   c.n_patterns > QDCT_MAX_U32 || c.n_ranges > QDCT_MAX_U32 || c.n_skipped > QDCT_MAX_U32 ||
	   c.n_left > QDCT_MAX_U32 || c.n_right > QDCT_MAX_U32 {
		return .Format_Limit
	}
	if c.blob_len > QDCT_MAX_U32 || c.n_extras > QDCT_MAX_U32 || c.n_pairs > QDCT_MAX_CODE {
		return .Format_Limit
	}
	for e in a.entries {
		if len(e.extra) > QDCT_MAX_U16 { return .Format_Limit }
	}
	return nil
}

// Str_Ref locates one string inside the blob section.
Str_Ref :: struct {
	off: u32,
	len: u32,
}

// Entry_Record is the on-disk form of one Dictionary_Entry: five string
// refs into the blob, the connection ids and cost, and a (count,
// first) window into the extras section. pad0 pads the record to 56
// bytes - an 8-byte stride, like every other record - so on the
// 8-aligned section base every record (and every Str_Ref within it)
// stays 8-aligned.
Entry_Record :: struct {
	surface:          Str_Ref,
	joined_pos:       Str_Ref,
	lemma:            Str_Ref,
	reading:          Str_Ref,
	reading_jyutping: Str_Ref,
	left_id:          i16,
	right_id:         i16,
	cost:             i16,
	extra_count:      u16,
	extra_first:      u32,
	pad0:             u32,
}

// Unk_Record is the on-disk form of one Unk_Rule.
Unk_Record :: struct {
	class:      i8,
	pad0:       u8,
	left_id:    i16,
	right_id:   i16,
	cost:       i16,
	joined_pos: Str_Ref,
}

// Pattern_Record is the on-disk form of one Unk_Pattern: kind 0/1/2 =
// prefix/suffix/charset, the class a charset row names, the connection
// ids and cost, and the pattern literal plus joined POS as blob refs.
Pattern_Record :: struct {
	kind:       u8,
	class:      i8,
	left_id:    i16,
	right_id:   i16,
	cost:       i16,
	pat:        Str_Ref,
	joined_pos: Str_Ref,
}

// Pair is one (rune, compact code) row of the char map; the forward
// map, inverse array, and alphabet size are all rebuilt from these.
Pair :: struct {
	r:    i32,
	code: u16,
	pad0: u16,
}

// Char_Flags_Record is the on-disk form of one class's char.def
// category row: bits bit0 = invoke, bit1 = group; length is the
// 1..length rune-prefix candidate cap.
Char_Flags_Record :: struct {
	bits:   u8,
	length: u8,
}

// ---------------------------------------------------------------------------
// save
// ---------------------------------------------------------------------------

// save_qdct writes the analyzer to path as one .qdct image. It reads
// analyzer state under the same acquire/release teardown contract as
// the tokenize family: safe to run concurrently with tokenize calls,
// and it answers .Unavailable once teardown has begun. The transient
// image is built in the allocator and released before returning; the
// analyzer is not modified.
save_qdct :: proc(a: ^Analyzer, path: string, allocator: mem.Allocator) -> Save_Err {
	image, used, err := qdct_image(a, allocator)
	if err != nil { return err }
	defer delete(image, allocator)

	if werr := os.write_entire_file(path, image[:used]); werr != nil {
		return .IO_Write
	}
	return nil
}

// qdct_image serializes the analyzer into one .qdct image allocated
// with the allocator. Ownership of the whole buffer passes to the
// caller; used answers the image's exact length — the buffer is sized
// at the blob's undeduplicated bound, deduplication shrinks the blob
// from the end, and everything past used is slack. save_qdct writes
// image[:used]; snapshot copies the exact prefix out. The state read
// runs under the acquire/release teardown contract (a concurrent free
// cannot race it), and the source analyzer is untouched. save_qdct,
// snapshot, and clone share this one builder.
//
// The write pass is single: sections stream into the image at their
// table-declared offsets while the blob section, placed last (the
// only section whose length is unknown before the walk), grows from
// blob_start. A repeated string value is written once through exact
// paths: fields marked in the entry's interned mask share one
// canonical allocation, so a pointer-keyed lookup answers their ref; a
// field named by an alias bit reuses the aliased field's ref (the
// equality is a recorded fact of the load, not something the writer
// re-derives); an extra equal to one of its entry's five fields reuses
// that field's ref. Other repeats are written again — the values that
// repeat across entries without sharing an allocation (surfaces,
// high-cardinality lemmas and readings) cost more to look up than
// their bytes cost to write. The loader is indifferent to the blob's
// layout: a Str_Ref is a view into whatever bytes sit at (off, len).
qdct_image :: proc(a: ^Analyzer, allocator: mem.Allocator) -> ([]u8, int, Save_Err) {
	if !acquire(a) { return nil, 0, .Unavailable }
	defer release(a)

	n_entries := len(a.entries)
	n_unk := len(a.unk_def)
	n_patterns := len(a.unk_patterns)
	n_ranges := len(a.char_class.ranges)
	n_pairs := len(a.char_map.inverse)
	n_skipped := len(a.skipped_resources)
	n_left := a.conn_matrix.n_left
	n_right := a.conn_matrix.n_right
	n_cedar := len(a.cedar.base)

	// The len-only walk bounds the blob at its undeduplicated size, so
	// the write pass never grows the buffer.
	n_extras := 0
	blob_bound := 0
	for &e in a.entries {
		for s in entry_string_fields(&e) { blob_bound += len(s) }
		n_extras += len(e.extra)
		for s in e.extra { blob_bound += len(s) }
	}
	for r in a.unk_def { blob_bound += len(r.joined_pos) }
	for p in a.unk_patterns { blob_bound += len(p.pat) + len(p.joined_pos) }
	for s in a.skipped_resources { blob_bound += len(s) }
	blob_bound += len(a.unknown_fallback_pos)

	counts := Qdct_Counts{
		n_cedar    = n_cedar,
		n_entries  = n_entries,
		n_extras   = n_extras,
		n_unk      = n_unk,
		n_patterns = n_patterns,
		n_ranges   = n_ranges,
		n_pairs    = n_pairs,
		n_left     = n_left,
		n_right    = n_right,
		n_skipped  = n_skipped,
		blob_len   = blob_bound,
	}
	if lerr := qdct_counts_limit_err(a, &counts); lerr != nil { return nil, 0, lerr }

	// Section geometry. Every member but BLOB keeps its ordinal
	// position; BLOB is written last so its walk-determined length
	// shifts nothing - every other offset depends only on counts.
	sizes := [QDCT_SECTION_COUNT]int{}
	offsets := [QDCT_SECTION_COUNT]int{}
	total := QDCT_HEADER_SIZE + QDCT_SECTION_TABLE_SIZE
	for i in 0 ..< QDCT_SECTION_COUNT {
		sizes[i] = qdct_section_size(&counts, Qdct_Section(i))
		if Qdct_Section(i) == QDCT_SECTION_BLOB { continue }
		offsets[i] = total
		total += align8(sizes[i])
	}
	offsets[QDCT_SECTION_BLOB] = total
	blob_start := total

	image, merr := make([]u8, blob_start + blob_bound, allocator)
	if merr != nil { return nil, 0, .OutOfMemory }

	// Pointer table for the canonical fields: data pointer -> blob
	// ref. Open-addressed with linear probing; a growth allocation
	// that fails answers .OutOfMemory through the field resolution.
	pt := Ptr_Table{allocator = allocator, mask = 4095}
	pt_slots, pmerr := make([]Ptr_Slot, 4096, allocator)
	if pmerr != nil {
		delete(image, allocator)
		return nil, 0, .OutOfMemory
	}
	pt.slots = pt_slots
	defer delete(pt.slots, allocator)

	w := Writer{buf = image}
	blob := Blob_Sink{start = blob_start}
	// Header.
	magic := "QDCT"
	w_bytes(&w, transmute([]u8)magic)
	w_u32(&w, QDCT_VERSION)
	w_u8(&w, u8(int(a.lang)))
	w_u8(&w, u8(int(a.mode)))
	w_u8(&w, u8(int(a.dict_locale)))
	w_u8(&w, len(a.char_class.flat) > 0 ? 1 : 0)
	w_u32(&w, u32(n_entries))              // QDCT_OFF_ENTRIES
	w_u32(&w, u32(n_unk))                  // QDCT_OFF_UNK
	w_u32(&w, u32(n_ranges))               // QDCT_OFF_RANGES
	w_u32(&w, u32(n_pairs))                // QDCT_OFF_PAIRS
	w_u32(&w, u32(n_skipped))              // QDCT_OFF_SKIPPED
	w_u32(&w, u32(n_left))                 // QDCT_OFF_LEFT
	w_u32(&w, u32(n_right))                // QDCT_OFF_RIGHT
	w_u32(&w, u32(n_extras))               // QDCT_OFF_EXTRAS
	w_u32(&w, u32(a.conn_matrix.explicit)) // QDCT_OFF_EXPLICIT - matrix explicit cells (v5; reserved before)
	w_u32(&w, u32(n_patterns))             // QDCT_OFF_PATTERNS
	// The sequential writes above must end exactly past the last named
	// header offset: this pins the writer's field order to the reader's
	// QDCT_OFF_* vocabulary.
	assert(w.pos == QDCT_OFF_PATTERNS + size_of(u32))
	skip_to(&w, QDCT_HEADER_SIZE + QDCT_SECTION_TABLE_SIZE)

	// Cedar arrays. Every section is written at its table-declared
	// offset: sections whose size is not a multiple of 8 carry padding
	// gaps, and writing them back-to-back would shift each following
	// section against its advertised offset (caught as a one- and
	// two-element shift of check/terminals at ipadic scale).
	w_bytes(&w, mem.slice_to_bytes(a.cedar.base[:]))
	skip_to(&w, offsets[QDCT_SECTION_CHECK])
	w_bytes(&w, mem.slice_to_bytes(a.cedar.check[:]))
	skip_to(&w, offsets[QDCT_SECTION_TERMINALS])
	w_bytes(&w, mem.slice_to_bytes(a.cedar.terminals[:]))
	skip_to(&w, offsets[QDCT_SECTION_GROUP_COUNT])
	w_bytes(&w, mem.slice_to_bytes(a.cedar.group_count[:]))
	skip_to(&w, offsets[QDCT_SECTION_ENTRIES])

	// Entries + extras: records stream sequentially while their string
	// fields resolve through the dedup paths and the extra refs land
	// in their own section.
	extras_pos := offsets[QDCT_SECTION_EXTRAS]
	extra_idx := 0
	for &e in a.entries {
		ss := entry_string_fields(&e)
		refs: [5]Str_Ref
		// A restored row's strings are views into one image: equal
		// values share an offset (a pointer hit is a value hit) and an
		// offset is never shared by different values. Deduping those
		// rows by pointer on every field is what makes a re-save of a
		// restored analyzer reproduce the image byte for byte. An
		// imported row instead resolves its alias bits - equalities its
		// own load recorded - so a field with nothing to reuse appends
		// with no lookup at all.
		restored := !e.strings_owned
		for s, f in ss {
			canonical := restored || (f > 0 && e.interned & u8(1 << u8(f-1)) != 0)
			alias_g := -1
			if f == 2 {
				if e.alias & ALIAS_LEMMA_SURFACE != 0 { alias_g = 0 }
			} else if f == 3 {
				if e.alias & ALIAS_READING_SURFACE != 0 {
					alias_g = 0
				} else if e.alias & ALIAS_READING_LEMMA != 0 {
					alias_g = 2
				}
			} else if f == 4 {
				if e.alias & ALIAS_JYUTPING_READING != 0 { alias_g = 3 }
			}
			ref, ok := resolve_str(&pt, &w, &blob, s, canonical,
				alias_g >= 0, alias_g >= 0 ? refs[alias_g] : Str_Ref{})
			if !ok { return nil, 0, .OutOfMemory }
			refs[f] = ref
		}
		rec := Entry_Record{
			surface          = refs[0],
			joined_pos       = refs[1],
			lemma            = refs[2],
			reading          = refs[3],
			reading_jyutping = refs[4],
			left_id          = e.left_id,
			right_id         = e.right_id,
			cost             = e.cost,
		}
		rec.extra_count = u16(len(e.extra))
		rec.extra_first = u32(extra_idx)
		for s in e.extra {
			ref, hit := Str_Ref{}, false
			for g in 0 ..< 5 {
				if ss[g] == s {
					ref, hit = refs[g], true
					break
				}
			}
			if !hit { ref = blob_append(&w, &blob, s) }
			write_ref_at(&w, extras_pos, ref)
			extras_pos += size_of(Str_Ref)
			extra_idx += 1
		}
		w_bytes(&w, mem.ptr_to_bytes(&rec))
	}
	skip_to(&w, offsets[QDCT_SECTION_UNK])

	for r in a.unk_def {
		rec := Unk_Record{
			class   = i8(int(r.class)),
			pad0    = 0,
			left_id = r.left_id,
			right_id = r.right_id,
			cost    = r.cost,
		}
		rec.joined_pos = blob_append(&w, &blob, r.joined_pos)
		w_bytes(&w, mem.ptr_to_bytes(&rec))
	}
	skip_to(&w, offsets[QDCT_SECTION_RANGES])

	w_bytes(&w, mem.slice_to_bytes(a.char_class.ranges[:]))
	skip_to(&w, offsets[QDCT_SECTION_PAIRS])

	for code in 0 ..< len(a.char_map.inverse) {
		p := Pair{r = i32(a.char_map.inverse[code]), code = u16(code)}
		w_bytes(&w, mem.ptr_to_bytes(&p))
	}
	skip_to(&w, offsets[QDCT_SECTION_COSTS])

	if n_left > 0 {
		w_bytes(&w, mem.slice_to_bytes(a.conn_matrix.costs[:]))
	}
	skip_to(&w, offsets[QDCT_SECTION_SKIPPED])

	skipped_pos := offsets[QDCT_SECTION_SKIPPED]
	for s in a.skipped_resources {
		write_ref_at(&w, skipped_pos, blob_append(&w, &blob, s))
		skipped_pos += size_of(Str_Ref)
	}
	skip_to(&w, offsets[QDCT_SECTION_FALLBACK])

	write_ref_at(&w, offsets[QDCT_SECTION_FALLBACK], blob_append(&w, &blob, a.unknown_fallback_pos))
	skip_to(&w, offsets[QDCT_SECTION_CHAR_FLAGS])

	for i in 0 ..< len(Char_Class) {
		f := a.char_flags[i]
		bits := u8(0)
		if f.invoke { bits |= 1 }
		if f.group { bits |= 2 }
		rec := Char_Flags_Record{bits = bits, length = f.length}
		w_bytes(&w, mem.ptr_to_bytes(&rec))
	}
	skip_to(&w, offsets[QDCT_SECTION_PATTERNS])

	for p in a.unk_patterns {
		rec := Pattern_Record{
			kind     = u8(int(p.kind)),
			class    = i8(int(p.class)),
			left_id  = p.left_id,
			right_id = p.right_id,
			cost     = p.cost,
		}
		rec.pat        = blob_append(&w, &blob, p.pat)
		rec.joined_pos = blob_append(&w, &blob, p.joined_pos)
		w_bytes(&w, mem.ptr_to_bytes(&rec))
	}

	// The section table, written now that the blob's length is final;
	// its region has stayed zero since the header pass skipped over it.
	sizes[QDCT_SECTION_BLOB] = blob.cur
	skip_to(&w, QDCT_HEADER_SIZE)
	for i in 0 ..< QDCT_SECTION_COUNT {
		w_u64(&w, u64(offsets[i]))
		w_u64(&w, u64(sizes[i]))
	}

	assert(blob.cur <= blob_bound)
	return image, blob_start + blob.cur, nil
}

// snapshot serializes the analyzer into an in-memory .qdct image -
// byte-identical to what save_qdct writes - owned by the caller
// (delete(image, allocator) releases it). The exact-size copy exists
// because the build buffer carries deduplication slack past its used
// length, and a caller's delete must free the allocation it holds at
// the length it holds it. Handing the bytes to load_qdct_bytes(image,
// allocator) restores an equal analyzer with the image's ownership
// transferring to that call.
snapshot :: proc(a: ^Analyzer, allocator: mem.Allocator) -> ([]u8, Save_Err) {
	build, used, err := qdct_image(a, allocator)
	if err != nil { return nil, err }
	defer delete(build, allocator)

	image, merr := make([]u8, used, allocator)
	if merr != nil { return nil, .OutOfMemory }
	copy(image, build[:used])
	return image, nil
}

// clone produces an independent copy of the analyzer under the allocator:
// one image build plus one restore, so the copy carries exactly a
// load_qdct result's ownership shape (one retained image, every
// string a view into it) and answers identically to the original.
// Nothing is shared with the source - freeing either analyzer
// leaves the other fully usable, and cloning an mmap-backed
// analyzer yields a real copy, not a shared mapping. The intended
// use is variant dictionaries (clone a shared base, add_user_entries
// into the private copy), not per-thread tokenizing copies.
clone :: proc(a: ^Analyzer, allocator: mem.Allocator) -> (Analyzer, Save_Err) {
	image, serr := snapshot(a, allocator)
	if serr != nil { return Analyzer{}, serr }
	b, berr := load_qdct_bytes(image, allocator)
	if berr != nil {
		// qdct_image serialized this image within the same call, so
		// only .OutOfMemory is reachable here (the rebuild's
		// validation sees bytes this same procedure just wrote). The
		// legs are enumerated member by member so a future Load_Fault
		// addition must decide its translation instead of falling
		// into a catch-all.
		switch f in berr {
		case Load_Fault:
			switch f {
			case .OutOfMemory:
				return Analyzer{}, Save_Fault.OutOfMemory
			case .File_Not_Found, .IO_Read:
				// Unreachable: load_qdct_bytes touches no file.
				return Analyzer{}, Save_Fault.IO_Write
			case .Invalid_Format, .Nil_Handle:
				return Analyzer{}, Save_Fault.IO_Write
			}
		case Schema_Mismatch_Error:
			return Analyzer{}, Save_Fault.IO_Write
		}
	}
	return b, nil
}

// Blob_Sink names the blob region's placement inside the image: bytes
// append at image[start + cur], and each append answers the ref it
// wrote. The region was sized at the undeduplicated bound, so appends
// never grow.
Blob_Sink :: struct {
	start: int,
	cur:   int,
}

blob_append :: proc(w: ^Writer, blob: ^Blob_Sink, s: string) -> Str_Ref {
	ref := Str_Ref{off = u32(blob.cur), len = u32(len(s))}
	w_bytes_at(w, blob.start + blob.cur, transmute([]byte)s)
	blob.cur += len(s)
	return ref
}

// Ptr_Slot is one pointer-table slot. The key is the string's data
// pointer with the top bit set - user-space pointers keep that bit
// clear, so a live key never reads as the all-zero empty slot.
Ptr_Slot :: struct {
	key: uintptr,
	ref: Str_Ref,
}

// Ptr_Table interns canonical strings by data pointer: equal pointers
// are equal values (the importer's intern table owns one allocation
// per distinct value; a restored analyzer's strings are views into one
// image, where equal values share an offset and an offset is never
// shared by different values). Open-addressed with linear probing,
// grown by doubling at a 3/4 load - growth keeps at least a quarter of
// the slots empty, so every probe terminates.
Ptr_Table :: struct {
	slots:     []Ptr_Slot,
	mask:      u32,
	used:      int,
	allocator: mem.Allocator,
}

ptr_table_hash :: proc(key: uintptr) -> u32 {
	return u32(((key >> 4) * 0x9E3779B97F4A7C15) >> 32)
}

ptr_table_get :: proc(t: ^Ptr_Table, p: uintptr) -> (Str_Ref, bool) {
	key := p | (uintptr(1) << 63)
	idx := ptr_table_hash(key) & t.mask
	for {
		slot := &t.slots[idx]
		if slot.key == key { return slot.ref, true }
		if slot.key == 0 { return Str_Ref{}, false }
		idx = (idx + 1) & t.mask
	}
}

// ptr_table_put registers p -> ref; ok false means the growth
// allocation failed and nothing was registered.
ptr_table_put :: proc(t: ^Ptr_Table, p: uintptr, ref: Str_Ref) -> bool {
	if t.used * 4 > len(t.slots) * 3 && !ptr_table_grow(t) { return false }
	key := p | (uintptr(1) << 63)
	idx := ptr_table_hash(key) & t.mask
	for {
		slot := &t.slots[idx]
		if slot.key == key {
			slot.ref = ref
			return true
		}
		if slot.key == 0 {
			slot^ = Ptr_Slot{key = key, ref = ref}
			t.used += 1
			return true
		}
		idx = (idx + 1) & t.mask
	}
}

ptr_table_grow :: proc(t: ^Ptr_Table) -> bool {
	slots_new, aerr := make([]Ptr_Slot, len(t.slots) * 2, t.allocator)
	if aerr != nil { return false }
	mask_new := u32(len(slots_new) - 1)
	for slot in t.slots {
		if slot.key == 0 { continue }
		idx := ptr_table_hash(slot.key) & mask_new
		for slots_new[idx].key != 0 { idx = (idx + 1) & mask_new }
		slots_new[idx] = slot
	}
	delete(t.slots, t.allocator)
	t.slots = slots_new
	t.mask = mask_new
	return true
}

// resolve_str answers one entry string field's blob ref. The empty
// string resolves to the zero ref everywhere and never touches the
// pointer table: str_ptr answers 0 for it, and keying it would alias
// every empty field onto the first one's ref on the restored pass
// alone - the two passes must agree field for field, or a
// save-restore-resave is not byte-identical. A canonical field
// consults the pointer table (an imported row's interned mask bit -
// mask bit f-1 aligns with entry_string_fields' order, field f -
// marks fields that borrow the importer's intern table; a restored
// row, strings_owned false, routes every field there through the
// image-view identity above). An aliased field reuses the aliased
// field's ref with no comparison - its load recorded the equality as
// an alias bit, and the analyzer is immutable after load returns, so
// the bit still holds. The first occurrence appends. ok false means
// the pointer table's growth allocation failed and nothing was
// registered.
resolve_str :: #force_inline proc(
	pt:        ^Ptr_Table,
	w:         ^Writer,
	blob:      ^Blob_Sink,
	s:         string,
	canonical: bool,
	alias:     bool,
	ref_alias: Str_Ref,
) -> (Str_Ref, bool) {
	if len(s) == 0 { return Str_Ref{}, true }
	if canonical {
		if r, ok := ptr_table_get(pt, str_ptr(s)); ok { return r, true }
	}
	ref := ref_alias
	if !alias {
		ref = blob_append(w, blob, s)
	}
	if canonical && !ptr_table_put(pt, str_ptr(s), ref) {
		return Str_Ref{}, false
	}
	return ref, true
}

// str_ptr answers the key a canonical string registers under. The
// empty string has no bytes to point at and answers 0; every other
// live allocation is unique, so equal keys are equal values.
str_ptr :: proc(s: string) -> uintptr {
	if len(s) == 0 { return 0 }
	return uintptr(raw_data(transmute([]byte)s))
}

// write_ref_at stores one Str_Ref at an absolute position (the extras /
// skipped / fallback sections, which fill out of walk order).
write_ref_at :: proc(w: ^Writer, pos: int, ref: Str_Ref) {
	w_u32_at(w, pos, ref.off)
	w_u32_at(w, pos + 4, ref.len)
}

align8 :: proc(n: int) -> int {
	r := n % 8
	if r != 0 { return n + 8 - r }
	return n
}

// Writer is a trivial little-endian cursor over a pre-sized image.
Writer :: struct {
	buf: []u8,
	pos: int,
}

// w_room asserts that n bytes at pos fit the pre-sized image. The
// image length and every write derive from the same size computation
// in qdct_image, so a mismatch is an internal invariant break - the
// writers must not be the place where it corrupts memory silently.
// Every save/snapshot/clone run exercises each writer, so the check is
// continuously under test.
w_room :: proc(w: ^Writer, pos, n: int) {
	assert(pos >= 0 && n >= 0 && pos + n <= len(w.buf),
		"qdct image write runs past the pre-sized buffer")
}

w_bytes :: proc(w: ^Writer, data: []byte) {
	w_room(w, w.pos, len(data))
	copy(w.buf[w.pos:w.pos + len(data)], data)
	w.pos += len(data)
}

// w_bytes_at writes at an absolute position without moving the
// cursor (the blob region, which fills out of section order).
w_bytes_at :: proc(w: ^Writer, pos: int, data: []byte) {
	w_room(w, pos, len(data))
	copy(w.buf[pos:pos + len(data)], data)
}

w_u8 :: proc(w: ^Writer, v: u8) {
	w_room(w, w.pos, 1)
	w.buf[w.pos] = v
	w.pos += 1
}

w_u32 :: proc(w: ^Writer, v: u32) {
	w_u32_at(w, w.pos, v)
	w.pos += 4
}

w_u32_at :: proc(w: ^Writer, pos: int, v: u32) {
	w_room(w, pos, 4)
	w.buf[pos] = u8(v)
	w.buf[pos + 1] = u8(v >> 8)
	w.buf[pos + 2] = u8(v >> 16)
	w.buf[pos + 3] = u8(v >> 24)
}

w_u64 :: proc(w: ^Writer, v: u64) {
	w_room(w, w.pos, 8)
	for i in 0 ..< 8 {
		w.buf[w.pos + i] = u8(v >> u64(8 * i))
	}
	w.pos += 8
}

// skip_to jumps the cursor (writing nothing); sections are pre-zeroed
// by the fresh allocation, so padding gaps stay zero.
skip_to :: proc(w: ^Writer, pos: int) {
	w.pos = pos
}

// ---------------------------------------------------------------------------
// load
// ---------------------------------------------------------------------------

// load_qdct rebuilds an analyzer from a .qdct file by reading it into
// memory first; load_qdct_mmap below maps it instead where the
// platform allows.
load_qdct :: proc(path: string, allocator: mem.Allocator) -> (Analyzer, Load_Err) {
	data, rerr := qdct_read_file(path, allocator)
	if rerr != nil { return Analyzer{}, rerr }
	return qdct_rebuild(data, allocator, false)
}

// qdct_read_file is the one read-copy acquisition path, shared by
// load_qdct and the Windows mmap fallback: open answers
// .File_Not_Found, a failed read answers .IO_Read. A failed buffer
// allocation answers .OutOfMemory instead: read_entire_file reports it
// inside the same os.Error union as a read refusal, and on the
// Windows fallback the read buffer is the path's first allocation, so
// the two must be split apart - a starved allocator is not a read
// fault. read_entire_file hands back a shortened buffer together with
// the error on a partial read - that buffer is owned by the allocator
// and released here, never discarded.
qdct_read_file :: proc(path: string, allocator: mem.Allocator) -> ([]u8, Load_Err) {
	f, ferr := os.open(path)
	if ferr != nil { return nil, .File_Not_Found }
	data, rerr := os.read_entire_file(f, allocator)
	os.close(f)
	if rerr != nil {
		if data != nil { delete(data, allocator) }
		// Every member but the allocation failure is a read refusal
		// (nil included - the switch sits under rerr != nil). The
		// members are enumerated so a future os.Error addition must
		// decide its translation, not fall into a catch-all.
		switch _ in rerr {
		case runtime.Allocator_Error:                      return nil, .OutOfMemory
		case os.General_Error, io.Error, os.Platform_Error: return nil, .IO_Read
		case:                                              return nil, .IO_Read
		}
	}
	return data, nil
}

// load_qdct_mmap restores a snapshot through a read-only private
// memory mapping where the platform provides one (POSIX), or through
// the read-copy path where it does not (the Windows fallback).
// Validation and the rebuilt analyzer are identical to load_qdct; the
// difference is what backs the analyzer's image — a mapping that
// teardown unmaps. The snapshot file must not be modified or truncated
// in place while it is mapped; replacing the file by rename is safe.
load_qdct_mmap :: proc(path: string, allocator: mem.Allocator) -> (Analyzer, Load_Err) {
	data, mapped, err := qdct_map_file(path, allocator)
	if err != nil { return Analyzer{}, err }
	return qdct_rebuild(data, allocator, mapped)
}

// load_qdct_bytes restores an analyzer from an in-memory snapshot
// image. data must have been allocated with the allocator, and ownership
// transfers with the call: the analyzer's free releases the buffer,
// and every failure path releases it the same way, so the caller must
// neither delete data nor reuse it after handing it over - including
// on an error return.
load_qdct_bytes :: proc(data: []u8, allocator: mem.Allocator) -> (Analyzer, Load_Err) {
	return qdct_rebuild(data, allocator, false)
}

// qdct_rebuild is the one rebuild ladder behind every snapshot load
// entry (read-copy, caller-owned buffer, mapping). The image is kept
// as Analyzer.image and every string points into it; teardown frees
// the image instead of the strings (unmaps it when mapped). Structural
// validation is total: magic, version, section geometry, string refs,
// char-map codes, and the two cedar arrays that feed direct indexing
// (terminals, group_count) are all checked before anything is indexed,
// so a corrupt or hostile file answers .Invalid_Format, never
// out-of-bounds memory. Every allocation is checked too: OOM answers
// .OutOfMemory through the same free(&a) release, retaining nothing.
// mapped is set on the analyzer before any failure return, so each
// error path's free(&a) releases the image the way it was acquired.
qdct_rebuild :: proc(data: []u8, allocator: mem.Allocator, mapped: bool) -> (Analyzer, Load_Err) {
	a: Analyzer
	a.image = data
	a.image_mapped = mapped
	a.allocator = allocator
	a.drain_wait = drain_wait_sleep

	if len(data) < QDCT_HEADER_SIZE + QDCT_SECTION_TABLE_SIZE {
		free(&a)
		return Analyzer{}, .Invalid_Format
	}
	if string(data[0:4]) != "QDCT" { free(&a); return Analyzer{}, .Invalid_Format }
	if le_u32(data, 4) != QDCT_VERSION { free(&a); return Analyzer{}, .Invalid_Format }

	lang := Language(int(data[8]))
	mode := Mode(int(data[9]))
	locale := Locale(int(data[10]))
	flat := data[11] != 0
	if !valid_language(lang) || !valid_mode(mode) || !valid_locale(locale) {
		free(&a)
		return Analyzer{}, .Invalid_Format
	}
	// Header fields by name (QDCT_OFF_*), in write order.
	n_entries := int(le_u32(data, QDCT_OFF_ENTRIES))
	n_unk := int(le_u32(data, QDCT_OFF_UNK))
	n_ranges := int(le_u32(data, QDCT_OFF_RANGES))
	n_pairs := int(le_u32(data, QDCT_OFF_PAIRS))
	n_skipped := int(le_u32(data, QDCT_OFF_SKIPPED))
	n_left := int(le_u32(data, QDCT_OFF_LEFT))
	n_right := int(le_u32(data, QDCT_OFF_RIGHT))
	n_extras := int(le_u32(data, QDCT_OFF_EXTRAS))
	n_explicit := int(le_u32(data, QDCT_OFF_EXPLICIT))
	n_patterns := int(le_u32(data, QDCT_OFF_PATTERNS))
	// The explicit-cell count (v5) cannot exceed the dense total, and
	// a matrix-less image carries zero. (The > arm is what closes the
	// n_left*n_right signed-overflow attack; the count itself is a u32
	// widened to int and cannot be negative.)
	if n_explicit > n_left * n_right || (n_left == 0 && n_explicit != 0) {
		free(&a)
		return Analyzer{}, .Invalid_Format
	}

	off := [QDCT_SECTION_COUNT]int{}
	slen := [QDCT_SECTION_COUNT]int{}
	file_len := len(data)
	for i in 0 ..< QDCT_SECTION_COUNT {
		o := le_u64(data, QDCT_HEADER_SIZE + i * QDCT_SECTION_ENTRY_SIZE)
		l := le_u64(data, QDCT_HEADER_SIZE + i * QDCT_SECTION_ENTRY_SIZE + 8)
		if o % 8 != 0 || o > u64(file_len) || l > u64(file_len) - o {
			free(&a)
			return Analyzer{}, .Invalid_Format
		}
		off[i] = int(o)
		slen[i] = int(l)
	}
	// Non-empty sections live strictly after the header and section
	// table and never overlap each other: a section aliasing another
	// section's bytes (or the header/table) would reinterpret record
	// bytes under a second type - string refs read out of entry
	// records, say. Empty sections carry no bytes and may share the
	// running end offset.
	for i in 0 ..< QDCT_SECTION_COUNT {
		if slen[i] == 0 { continue }
		if off[i] < QDCT_HEADER_SIZE + QDCT_SECTION_TABLE_SIZE {
			free(&a)
			return Analyzer{}, .Invalid_Format
		}
		for j in 0 ..< i {
			if slen[j] == 0 { continue }
			if off[i] < off[j] + slen[j] && off[j] < off[i] + slen[i] {
				free(&a)
				return Analyzer{}, .Invalid_Format
			}
		}
	}

	// Section geometry must match the counts exactly. The cedar count
	// boots the loop - every other count came from the header, while
	// the cedar count derives from the base section's own length (and
	// the loop's BASE arm then requires that length to divide evenly
	// into the i32 stride it is reinterpreted as).
	n_cedar := slen[QDCT_SECTION_BASE] / size_of(i32)
	if n_cedar < 2 { free(&a); return Analyzer{}, .Invalid_Format }
	counts := Qdct_Counts{
		n_cedar    = n_cedar,
		n_entries  = n_entries,
		n_extras   = n_extras,
		n_unk      = n_unk,
		n_patterns = n_patterns,
		n_ranges   = n_ranges,
		n_pairs    = n_pairs,
		n_left     = n_left,
		n_right    = n_right,
		n_skipped  = n_skipped,
		blob_len   = slen[QDCT_SECTION_BLOB],
	}
	for i in 0 ..< QDCT_SECTION_COUNT {
		if slen[i] != qdct_section_size(&counts, Qdct_Section(i)) {
			free(&a)
			return Analyzer{}, .Invalid_Format
		}
	}
	// A matrix-less image carries no right dimension either - the
	// zero-cell costs size alone could not see a bogus n_right.
	if (n_left == 0) != (n_right == 0) {
		free(&a)
		return Analyzer{}, .Invalid_Format
	}

	// The arrays lattice walks index, directly or through transition
	// arithmetic, are bounded before anything is indexed. group_count
	// must keep enumeration inside the entries array (a link chain
	// could loop forever; a range is bounded by construction);
	// terminals must be -1 or an entry id; base values must land in
	// [0, n_cedar) — every used slot's base is a position the builder
	// placed (placement keeps pos < len) and unused slots carry 0, so
	// anything outside is a corrupt image. With base bounded,
	// base[s] + code can neither go negative nor wrap, and the
	// landing-slot check in the walk bounds the rest. check values are
	// deliberately unbounded: they are only compared against a node
	// index, never used as one.
	base_vals := mem.slice_data_cast([]i32, data[off[QDCT_SECTION_BASE]:off[QDCT_SECTION_BASE] + slen[QDCT_SECTION_BASE]])
	for v in base_vals {
		if v < 0 || v >= i32(n_cedar) { free(&a); return Analyzer{}, .Invalid_Format }
	}
	group_count := mem.slice_data_cast([]i32, data[off[QDCT_SECTION_GROUP_COUNT]:off[QDCT_SECTION_GROUP_COUNT] + slen[QDCT_SECTION_GROUP_COUNT]])
	for gc, i in group_count {
		if gc < 0 || int(gc) > n_entries - i { free(&a); return Analyzer{}, .Invalid_Format }
	}
	terminals := mem.slice_data_cast([]i32, data[off[QDCT_SECTION_TERMINALS]:off[QDCT_SECTION_TERMINALS] + slen[QDCT_SECTION_TERMINALS]])
	for t in terminals {
		if t != -1 && (t < 0 || t >= i32(n_entries) || group_count[t] < 1) {
			free(&a)
			return Analyzer{}, .Invalid_Format
		}
	}
	// Char-map codes must land inside the inverse array being built,
	// appear exactly once, and cover all of [0, n_pairs): the
	// forward/inverse maps are rebuilt as a total bijection, so a
	// duplicate silently overwrites and a hole leaves inverse[code]
	// at its zero fill (NUL) for cedar walks to read. Runes must be
	// real code points - the forward map is keyed by rune. The
	// alphabet is also capped one below the u16 code width: code
	// 0xFFFF is the no_char sentinel the BMP direct table reads as
	// unmapped, so a 65536-pair image would misclassify its own last
	// rune (build_char_map caps the builder side; hostile images get
	// the same refusal here).
	if n_pairs > int(no_char) {
		free(&a)
		return Analyzer{}, .Invalid_Format
	}
	pairs := mem.slice_data_cast([]Pair, data[off[QDCT_SECTION_PAIRS]:off[QDCT_SECTION_PAIRS] + slen[QDCT_SECTION_PAIRS]])
	seen, merr2 := make([]bool, n_pairs, allocator)
	if merr2 != nil { free(&a); return Analyzer{}, .OutOfMemory }
	defer delete(seen, allocator)
	for p in pairs {
		if p.r < 0 || p.r > 0x10FFFF || int(p.code) >= n_pairs || seen[p.code] {
			free(&a)
			return Analyzer{}, .Invalid_Format
		}
		seen[p.code] = true
	}
	for marked in seen {
		if !marked { free(&a); return Analyzer{}, .Invalid_Format }
	}

	a.lang = lang
	a.mode = mode
	a.dict_locale = locale

	// Each copy is assigned the moment it succeeds. A collective check
	// here would leave the succeeded copies in locals that free(&a)
	// cannot reach - an OOM mid-way leaked every array before the
	// failing one.
	cerr: Load_Err
	a.cedar.base, cerr = qdct_copy_i32(mem.slice_data_cast([]i32, data[off[QDCT_SECTION_BASE]:off[QDCT_SECTION_BASE] + slen[QDCT_SECTION_BASE]]), allocator)
	if cerr != nil { free(&a); return Analyzer{}, .OutOfMemory }
	a.cedar.check, cerr = qdct_copy_i32(mem.slice_data_cast([]i32, data[off[QDCT_SECTION_CHECK]:off[QDCT_SECTION_CHECK] + slen[QDCT_SECTION_CHECK]]), allocator)
	if cerr != nil { free(&a); return Analyzer{}, .OutOfMemory }
	a.cedar.terminals, cerr = qdct_copy_i32(terminals, allocator)
	if cerr != nil { free(&a); return Analyzer{}, .OutOfMemory }
	a.cedar.group_count, cerr = qdct_copy_i32(group_count, allocator)
	if cerr != nil { free(&a); return Analyzer{}, .OutOfMemory }

	blob := data[off[QDCT_SECTION_BLOB]:off[QDCT_SECTION_BLOB] + slen[QDCT_SECTION_BLOB]]

	merr: mem.Allocator_Error
	a.entries, merr = make([dynamic]Dictionary_Entry, 0, n_entries, allocator)
	if merr != nil { free(&a); return Analyzer{}, .OutOfMemory }
	records := mem.slice_data_cast([]Entry_Record, data[off[QDCT_SECTION_ENTRIES]:off[QDCT_SECTION_ENTRIES] + slen[QDCT_SECTION_ENTRIES]])
	extra_refs := mem.slice_data_cast([]Str_Ref, data[off[QDCT_SECTION_EXTRAS]:off[QDCT_SECTION_EXTRAS] + slen[QDCT_SECTION_EXTRAS]])
	for rec in records {
		e := Dictionary_Entry{
			left_id  = rec.left_id,
			right_id = rec.right_id,
			cost     = rec.cost,
		}
		ok := true
		e.surface, ok = qdct_str_of(blob, rec.surface)
		if ok { e.joined_pos, ok = qdct_str_of(blob, rec.joined_pos) }
		if ok { e.lemma, ok = qdct_str_of(blob, rec.lemma) }
		if ok { e.reading, ok = qdct_str_of(blob, rec.reading) }
		if ok { e.reading_jyutping, ok = qdct_str_of(blob, rec.reading_jyutping) }
		if !ok || int(rec.extra_first) + int(rec.extra_count) > len(extra_refs) {
			free(&a)
			return Analyzer{}, .Invalid_Format
		}
		if rec.extra_count > 0 {
			e.extra, merr = make([dynamic]string, 0, int(rec.extra_count), allocator)
			if merr != nil { free(&a); return Analyzer{}, .OutOfMemory }
			for j in 0 ..< int(rec.extra_count) {
				s, sok := qdct_str_of(blob, extra_refs[int(rec.extra_first) + j])
				if !sok { free(&a); return Analyzer{}, .Invalid_Format }
				append(&e.extra, s)
			}
		}
		append(&a.entries, e)
	}

	a.unk_def, merr = make([dynamic]Unk_Rule, 0, n_unk, allocator)
	if merr != nil { free(&a); return Analyzer{}, .OutOfMemory }
	unks := mem.slice_data_cast([]Unk_Record, data[off[QDCT_SECTION_UNK]:off[QDCT_SECTION_UNK] + slen[QDCT_SECTION_UNK]])
	for rec in unks {
		// The class is a Char_Class ordinal: a rule the CSV loader
		// could never have produced is a corrupt file (the pattern
		// records carry the same validation).
		if rec.class < 0 || rec.class >= i8(len(Char_Class)) {
			free(&a)
			return Analyzer{}, .Invalid_Format
		}
		pos, pok := qdct_str_of(blob, rec.joined_pos)
		if !pok { free(&a); return Analyzer{}, .Invalid_Format }
		append(&a.unk_def, Unk_Rule{
			class      = Char_Class(int(rec.class)),
			left_id    = rec.left_id,
			right_id   = rec.right_id,
			cost       = rec.cost,
			joined_pos = pos,
		})
	}

	// Surface patterns: kind and (for charset rows) the named class
	// are validated, not just geometry - a record the CSV loader could
	// never have produced is a corrupt file.
	a.unk_patterns, merr = make([dynamic]Unk_Pattern, 0, n_patterns, allocator)
	if merr != nil { free(&a); return Analyzer{}, .OutOfMemory }
	patrecs := mem.slice_data_cast([]Pattern_Record, data[off[QDCT_SECTION_PATTERNS]:off[QDCT_SECTION_PATTERNS] + slen[QDCT_SECTION_PATTERNS]])
	for rec in patrecs {
		if rec.kind > 2 { free(&a); return Analyzer{}, .Invalid_Format }
		pat, patok := qdct_str_of(blob, rec.pat)
		if !patok { free(&a); return Analyzer{}, .Invalid_Format }
		pos, posok := qdct_str_of(blob, rec.joined_pos)
		if !posok { free(&a); return Analyzer{}, .Invalid_Format }
		kind: Unk_Pattern_Kind
		switch rec.kind {
		case 0: kind = .Prefix
		case 1: kind = .Suffix
		case:  kind = .Charset
		}
		if kind != .Charset && len(pat) == 0 {
			free(&a)
			return Analyzer{}, .Invalid_Format
		}
		cls: Char_Class = .Unknown
		if kind == .Charset {
			if rec.class < 0 || rec.class >= i8(len(Char_Class)) {
				free(&a)
				return Analyzer{}, .Invalid_Format
			}
			cls = Char_Class(int(rec.class))
		}
		append(&a.unk_patterns, Unk_Pattern{
			kind       = kind,
			class      = cls,
			pat        = pat,
			left_id    = rec.left_id,
			right_id   = rec.right_id,
			cost       = rec.cost,
			joined_pos = pos,
		})
	}

	ranges, rngerr := make([dynamic]Char_Range, n_ranges, allocator)
	if rngerr != nil { free(&a); return Analyzer{}, .OutOfMemory }
	copy(ranges[:], mem.slice_data_cast([]Char_Range, data[off[QDCT_SECTION_RANGES]:off[QDCT_SECTION_RANGES] + slen[QDCT_SECTION_RANGES]]))
	if !char_ranges_valid(ranges[:]) {
		delete(ranges)
		free(&a)
		return Analyzer{}, .Invalid_Format
	}
	a.char_class.ranges = ranges
	if flat {
		flat_arr, ferr := char_class_flat_from_ranges(ranges[:], allocator)
		if ferr != nil { free(&a); return Analyzer{}, ferr }
		a.char_class.flat = flat_arr
	}

	// Char-def category flags, one record per Char_Class member.
	flag_records := mem.slice_data_cast([]Char_Flags_Record, data[off[QDCT_SECTION_CHAR_FLAGS]:off[QDCT_SECTION_CHAR_FLAGS] + slen[QDCT_SECTION_CHAR_FLAGS]])
	for i in 0 ..< len(Char_Class) {
		rec := flag_records[i]
		if (rec.bits & 0b11111100) != 0 { free(&a); return Analyzer{}, .Invalid_Format }
		a.char_flags[i] = Char_Flags{
			invoke = (rec.bits & 1) != 0,
			group  = (rec.bits & 2) != 0,
			length = rec.length,
		}
	}

	// The map must exist before the insert loop below: inserting into a
	// nil map would grow through the ambient allocator, and indexing a
	// zero-value inverse would go out of bounds.
	a.char_map.forward, merr = make(map[rune]u16, n_pairs, allocator)
	if merr != nil { free(&a); return Analyzer{}, .OutOfMemory }
	a.char_map.inverse, merr = make([dynamic]rune, n_pairs, allocator)
	if merr != nil { free(&a); return Analyzer{}, .OutOfMemory }
	a.char_map.bmp, merr = make([]u16, BMP_SIZE, allocator)
	if merr != nil { free(&a); return Analyzer{}, .OutOfMemory }
	for i in 0 ..< len(a.char_map.bmp) {
		a.char_map.bmp[i] = no_char
	}
	a.char_map.n_chars = n_pairs
	for p in pairs {
		a.char_map.forward[rune(p.r)] = p.code
		a.char_map.inverse[p.code] = rune(p.r)
		if p.r >= 0 && p.r < BMP_SIZE {
			a.char_map.bmp[p.r] = p.code
		}
	}

	if n_left > 0 {
		costs, cerr := make([dynamic]i16, n_left * n_right, allocator)
		if cerr != nil { free(&a); return Analyzer{}, .OutOfMemory }
		copy(costs[:], mem.slice_data_cast([]i16, data[off[QDCT_SECTION_COSTS]:off[QDCT_SECTION_COSTS] + slen[QDCT_SECTION_COSTS]]))
		a.conn_matrix = Connection_Matrix{costs = costs, n_left = n_left, n_right = n_right, explicit = n_explicit}
	}

	a.skipped_resources, merr = make([dynamic]string, 0, n_skipped, allocator)
	if merr != nil { free(&a); return Analyzer{}, .OutOfMemory }
	skipped_refs := mem.slice_data_cast([]Str_Ref, data[off[QDCT_SECTION_SKIPPED]:off[QDCT_SECTION_SKIPPED] + slen[QDCT_SECTION_SKIPPED]])
	for ref in skipped_refs {
		s, sok := qdct_str_of(blob, ref)
		if !sok { free(&a); return Analyzer{}, .Invalid_Format }
		append(&a.skipped_resources, s)
	}
	fb_ref := mem.slice_data_cast([]Str_Ref, data[off[QDCT_SECTION_FALLBACK]:off[QDCT_SECTION_FALLBACK] + slen[QDCT_SECTION_FALLBACK]])[0]
	fb, fbok := qdct_str_of(blob, fb_ref)
	if !fbok { free(&a); return Analyzer{}, .Invalid_Format }
	a.unknown_fallback_pos = fb
	a.entries_hash = entries_fingerprint(&a)

	return a, nil
}

// qdct_copy_i32 materializes a section view as an analyzer-owned
// dynamic array.
qdct_copy_i32 :: proc(src: []i32, allocator: mem.Allocator) -> ([dynamic]i32, Load_Err) {
	out, err := make([dynamic]i32, len(src), allocator)
	if err != nil { return nil, .OutOfMemory }
	copy(out[:], src)
	return out, nil
}

// qdct_str_of answers the blob slice a Str_Ref points at, rejecting any
// ref that runs past the blob.
qdct_str_of :: proc(blob: []u8, ref: Str_Ref) -> (string, bool) {
	o, l := int(ref.off), int(ref.len)
	if o < 0 || l < 0 || o + l > len(blob) { return "", false }
	return string(blob[o:o + l]), true
}

le_u32 :: proc(b: []u8, at: int) -> u32 {
	return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
}

le_u64 :: proc(b: []u8, at: int) -> u64 {
	v := u64(0)
	for i in 0 ..< 8 {
		v |= u64(b[at + i]) << u64(8 * i)
	}
	return v
}

valid_language :: proc(l: Language) -> bool {
	switch l {
	case .Japanese, .ChineseCN, .ChineseTW, .ChineseHK, .EnglishGB, .EnglishUS, .German:
		return true
	}
	return false
}

valid_mode :: proc(m: Mode) -> bool {
	return m == .Viterbi || m == .LongestMatch
}

valid_locale :: proc(l: Locale) -> bool {
	switch l {
	case .None, .GB, .US, .CN, .TW, .HK:
		return true
	}
	return false
}
