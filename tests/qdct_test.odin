// qdct coverage: save/load round-trip at the morpheme level (both
// string ownership modes, flat tables, extras, skipped resources),
// corruption rejection (magic, version, truncation, section geometry,
// string refs), the teardown contract on save, and an
// allocation-failure sweep over load_qdct's whole sequence.
package tests

import "base:runtime"
import "core:mem"
import "core:os"
import "core:testing"
import "moli:moli"

@(test)
qdct_roundtrip_test :: proc(t: ^testing.T) {
	allocator := context.allocator

	// Matrix-bearing dictionary with unk rules; the fixture root also
	// records skipped resources, which must survive the round trip.
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	// A 21-column unidic fixture row exercises the extras section.
	u, ok2 := load_ok(t, .Japanese, UNIDIC_FIXTURE, {})
	if !ok2 { return }
	defer moli.free(&u)

	scratch: mem.Arena
	arena_buf := make([]u8, 1 << 22, allocator)
	defer delete(arena_buf, allocator)
	mem.arena_init(&scratch, arena_buf)
	scratch_allocator := mem.arena_allocator(&scratch)

	if serr := moli.save_qdct(&a, "tmp/qdct_a.bin", scratch_allocator); serr != nil {
		testing.expectf(t, false, "save a: %v", serr)
		return
	}
	if serr := moli.save_qdct(&u, "tmp/qdct_u.bin", scratch_allocator); serr != nil {
		testing.expectf(t, false, "save u: %v", serr)
		return
	}

	ra, lerr := moli.load_qdct("tmp/qdct_a.bin", allocator)
	if lerr != nil {
		testing.expectf(t, false, "load a: %v", lerr)
		return
	}
	defer moli.free(&ra)
	ru, lerr2 := moli.load_qdct("tmp/qdct_u.bin", allocator)
	if lerr2 != nil {
		testing.expectf(t, false, "load u: %v", lerr2)
		return
	}
	defer moli.free(&ru)

	// Metadata survived.
	if len(ra.entries) != len(a.entries) || len(ra.unk_def) != len(a.unk_def) {
		testing.expectf(t, false, "counts: entries %v/%v unk %v/%v",
			len(ra.entries), len(a.entries), len(ra.unk_def), len(a.unk_def))
		return
	}
	if ra.conn_matrix.n_left != a.conn_matrix.n_left ||
		ra.conn_matrix.n_right != a.conn_matrix.n_right {
		testing.expectf(t, false, "matrix dims: %vx%v vs %vx%v",
			ra.conn_matrix.n_left, ra.conn_matrix.n_right,
			a.conn_matrix.n_left, a.conn_matrix.n_right)
		return
	}
	if len(ra.skipped_resources) != len(a.skipped_resources) {
		testing.expectf(t, false, "skipped: %v vs %v",
			len(ra.skipped_resources), len(a.skipped_resources))
		return
	}
	if ra.mode != a.mode || ra.lang != a.lang || ra.dict_locale != a.dict_locale {
		testing.expectf(t, false, "header fields differ")
		return
	}
	// Extras survived on the unidic-shaped analyzer.
	if len(ru.entries) > 0 && len(u.entries) > 0 {
		if len(ru.entries[0].extra) != len(u.entries[0].extra) {
			testing.expectf(t, false, "extras: %v vs %v",
				len(ru.entries[0].extra), len(u.entries[0].extra))
			return
		}
	}

	// save is deterministic, so a re-save of the restored analyzer
	// must be byte-identical to the original file. This is the
	// regression for the section-padding drift: save once wrote
	// sections back-to-back while the table advertised 8-aligned
	// offsets, shifting every section after an unpadded one (fixture
	// scales happened to be 8-multiples, so only real dictionaries
	// caught it).
	if serr := moli.save_qdct(&ra, "tmp/qdct_a2.bin", scratch_allocator); serr != nil {
		testing.expectf(t, false, "re-save: %v", serr)
		return
	}
	f1, rerr1 := os.read_entire_file("tmp/qdct_a.bin", context.temp_allocator)
	f2, rerr2 := os.read_entire_file("tmp/qdct_a2.bin", context.temp_allocator)
	if rerr1 != nil || rerr2 != nil {
		testing.expectf(t, false, "re-read: %v / %v", rerr1, rerr2)
		return
	}
	if len(f1) != len(f2) {
		testing.expectf(t, false, "re-save size: %v vs %v", len(f1), len(f2))
		return
	}
	for i in 0 ..< len(f1) {
		if f1[i] != f2[i] {
			testing.expectf(t, false, "re-save differs at byte %v", i)
			return
		}
	}

	// Morpheme-level equality on shared sentences, both modes.
	buf1 := make([]u8, 1 << 18, allocator)
	defer delete(buf1, allocator)
	buf2 := make([]u8, 1 << 18, allocator)
	defer delete(buf2, allocator)
	ar1: mem.Arena
	mem.arena_init(&ar1, buf1)
	ar2: mem.Arena
	mem.arena_init(&ar2, buf2)
	modes := []moli.Mode{.Viterbi, .LongestMatch}
	for mode in modes {
		a.mode = mode
		ra.mode = mode
		sentences := []string{"犬が歩く", "さくらの犬"}
		for s in sentences {
			m1, e1 := moli.tokenize(&a, s, mem.arena_allocator(&ar1))
			m2, e2 := moli.tokenize(&ra, s, mem.arena_allocator(&ar2))
			if e1 != nil || e2 != nil {
				testing.expectf(t, false, "tokenize err %v/%v", e1, e2)
				return
			}
			// Full-field equality (entry_id included) over two
			// distinct arenas: the restored analyzer must answer
			// identically to the one that saved.
			if !expect_morphemes_equal(t, m1, m2) { return }
			mem.arena_init(&ar1, buf1)
			mem.arena_init(&ar2, buf2)
		}
	}
}

@(test)
qdct_flat_roundtrip_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {flat_char_class = true})
	if !ok { return }
	defer moli.free(&a)

	arena_buf := make([]u8, 1 << 22, allocator)
	defer delete(arena_buf, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)

	if serr := moli.save_qdct(&a, "tmp/qdct_flat.bin", mem.arena_allocator(&arena)); serr != nil {
		testing.expectf(t, false, "save: %v", serr)
		return
	}
	ra, lerr := moli.load_qdct("tmp/qdct_flat.bin", allocator)
	if lerr != nil {
		testing.expectf(t, false, "load: %v", lerr)
		return
	}
	defer moli.free(&ra)

	if len(ra.char_class.flat) == 0 {
		testing.expectf(t, false, "flat table not rebuilt")
		return
	}
	runes := []rune{'あ', 'ア', '漢', 'A', '9', '𝐀'}
	for r in runes {
		if moli.char_class_of(&ra.char_class, r) != moli.char_class_of(&a.char_class, r) {
			testing.expectf(t, false, "flat class of %v differs", r)
			return
		}
	}
}

@(test)
qdct_corruption_test :: proc(t: ^testing.T) {
	// context.allocator: the rejected loads ride the tracking allocator,
	// which is what lets qdct_expect_reject's partial-teardown claim be
	// checked by the leak gate instead of asserted in a comment.
	allocator := context.allocator
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }
	arena_buf := make([]u8, 1 << 22, allocator)
	defer delete(arena_buf, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	if serr := moli.save_qdct(&a, "tmp/qdct_ok.bin", mem.arena_allocator(&arena)); serr != nil {
		testing.expectf(t, false, "save: %v", serr)
		return
	}
	moli.free(&a)

	valid, verr := os.read_entire_file("tmp/qdct_ok.bin", allocator)
	if verr != nil {
		testing.expectf(t, false, "read back: %v", verr)
		return
	}
	defer delete(valid, allocator)


	// Empty file.
	qdct_expect_reject(t, "empty", []u8{}, allocator)
	// Bad magic.
	bad := make([]u8, len(valid), allocator)
	defer delete(bad, allocator)
	copy(bad, valid)
	bad[0] = 'X'
	qdct_expect_reject(t, "magic", bad, allocator)
	// Bad version.
	copy(bad, valid)
	bad[4] = 0xFF
	qdct_expect_reject(t, "version", bad, allocator)
	// A v3 image (entry-next chains instead of group counts) rejects
	// by the version check alone - the chain values would be nonsense
	// as counts, so the semantic break rides the version break. A v4
	// image rejects the same way: its zero at 0x2C would read as "no
	// matrix cell enumerated" under v5's explicit-count meaning.
	copy(bad, valid)
	bad[4] = 3
	bad[5] = 0
	bad[6] = 0
	bad[7] = 0
	qdct_expect_reject(t, "v3 version", bad, allocator)
	copy(bad, valid)
	bad[4] = 4
	bad[5] = 0
	bad[6] = 0
	bad[7] = 0
	qdct_expect_reject(t, "v4 version", bad, allocator)
	// A group count claiming entries past the array's end: patch the
	// LAST i32 of the group-count section (its offset sits third in
	// the section table, after base/check/terminals) to 0x7F.
	copy(bad, valid)
	gc_table := moli.QDCT_HEADER_SIZE + int(moli.QDCT_SECTION_GROUP_COUNT) * moli.QDCT_SECTION_ENTRY_SIZE
	gco := int(qdct_le64(bad, gc_table))
	gcl := int(qdct_le64(bad, gc_table + 8))
	if gcl < 4 {
		testing.expectf(t, false, "group-count section too small: %v", gcl)
		return
	}
	bad[gco + gcl - 4] = 0x7F
	bad[gco + gcl - 3] = 0x00
	bad[gco + gcl - 2] = 0x00
	bad[gco + gcl - 1] = 0x00
	qdct_expect_reject(t, "group count out of range", bad, allocator)
	// Explicit-cell count above the dense total (the fixture's matrix
	// is 2x2, so anything past 4 is a lie).
	copy(bad, valid)
	bad[0x2C] = 5
	qdct_expect_reject(t, "explicit count", bad, allocator)
	// Invalid language id and invalid locale id: the header validators
	// reject corrupt enum bytes like any other corrupt field.
	copy(bad, valid)
	bad[8] = 0x7F
	qdct_expect_reject(t, "language id", bad, allocator)
	copy(bad, valid)
	bad[10] = 0x7F
	qdct_expect_reject(t, "locale id", bad, allocator)
	// Truncation: shorter than the section table, then short mid-blob.
	qdct_expect_reject(t, "truncated header", valid[:40], allocator)
	qdct_expect_reject(t, "truncated body", valid[:len(valid) / 2], allocator)
	// Section offset pushed past the file end (table entry for base).
	copy(bad, valid)
	bad[moli.QDCT_HEADER_SIZE] = 0xFF
	bad[moli.QDCT_HEADER_SIZE + 1] = 0xFF
	bad[moli.QDCT_HEADER_SIZE + 2] = 0xFF
	bad[moli.QDCT_HEADER_SIZE + 3] = 0x7F
	qdct_expect_reject(t, "offset out of range", bad, allocator)
	// Count/geometry mismatch: shrink n_entries.
	copy(bad, valid)
	bad[0x0C] = bad[0x0C] + 1
	qdct_expect_reject(t, "count mismatch", bad, allocator)
	// A string ref pointing past the blob: corrupt the first entry
	// record's surface length. The entries section offset comes from
	// the section table; its first record starts there.
	copy(bad, valid)
	// The entries section is the 5th table entry (index 4).
	entries_tbl := moli.QDCT_HEADER_SIZE + int(moli.QDCT_SECTION_ENTRIES) * moli.QDCT_SECTION_ENTRY_SIZE
	entries_off := u32(bad[entries_tbl]) | u32(bad[entries_tbl + 1]) << 8 |
		u32(bad[entries_tbl + 2]) << 16 | u32(bad[entries_tbl + 3]) << 24
	if int(entries_off) + 8 < len(bad) {
		bad[entries_off + 7] = 0x7F // first record's surface.len MSB
	}
	qdct_expect_reject(t, "string ref past blob", bad, allocator)

	// Missing file.
	_, err := moli.load_qdct("tmp/qdct_nonexistent.bin", allocator)
	if err != moli.Load_Fault(.File_Not_Found) {
		testing.expectf(t, false, "missing file: %v", err)
		return
	}
}

@(test)
qdct_save_after_free_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }
	moli.free(&a)

	arena_buf := make([]u8, 1 << 22, allocator)
	defer delete(arena_buf, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)

	err := moli.save_qdct(&a, "tmp/qdct_dead.bin", mem.arena_allocator(&arena))
	if err != moli.Save_Fault(.Unavailable) {
		testing.expectf(t, false, "save after free: %v", err)
		return
	}
}

// The save boundary's write leg: a path that cannot be written (a
// directory) surfaces as Save_Fault.IO_Write with nothing half-written
// left behind.
@(test)
qdct_save_write_error_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	arena_buf := make([]u8, 1 << 22, context.allocator)
	defer delete(arena_buf, context.allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)

	err := moli.save_qdct(&a, "tmp", mem.arena_allocator(&arena))
	if !expect_save_fault(t, "save to a directory", err, .IO_Write) { return }
}

// The save boundary's allocation leg: a starved budget allocator must
// fail the image build as Save_Fault.OutOfMemory on both the snapshot
// and save_qdct paths - and a budget that covers the single image
// allocation must succeed, so the fault cannot come from anywhere but
// the build.
@(test)
qdct_save_oom_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	b0 := Budget_Allocator{backing = context.allocator, remaining = 0}
	budget0 := mem.Allocator{data = &b0, procedure = budget_allocator_proc}
	_, err := moli.snapshot(&a, budget0)
	if !expect_save_fault(t, "snapshot under a zero budget", err, .OutOfMemory) { return }

	err = moli.save_qdct(&a, "tmp/qdct_oom_save.bin", budget0)
	if !expect_save_fault(t, "save_qdct under a zero budget", err, .OutOfMemory) { return }

	b1 := Budget_Allocator{backing = context.allocator, remaining = 1}
	budget1 := mem.Allocator{data = &b1, procedure = budget_allocator_proc}
	image, serr := moli.snapshot(&a, budget1)
	if serr != nil {
		testing.expectf(t, false, "snapshot under budget 1: %v", serr)
		return
	}
	delete(image, budget1)
}

// qdct_expect_reject writes data out and asserts load_qdct refuses it;
// the rejected load also drives the mid-build partial teardown, so the
// suite's leak gate covers that path.
qdct_expect_reject :: proc(t: ^testing.T, name: string, data: []u8, allocator: runtime.Allocator) {
	os.remove("tmp/qdct_bad.bin")
	if werr := os.write_entire_file("tmp/qdct_bad.bin", data); werr != nil {
		testing.expectf(t, false, "write %s: %v", name, werr)
		return
	}
	_, err := moli.load_qdct("tmp/qdct_bad.bin", allocator)
	if err == nil {
		testing.expectf(t, false, "%s must be rejected", name)
	}
}

// qdct_le64 reads one little-endian u64 out of an image (section
// table entries for the hand-patched corruption legs above).
qdct_le64 :: proc(b: []u8, off: int) -> u64 {
	u: u64
	for i in 0 ..< 8 {
		u |= u64(b[off + i]) << cast(u64)(8 * i)
	}
	return u
}

// Every allocation point in load_qdct must fail as .OutOfMemory with
// the partial analyzer fully released (the leak gate checks the
// release); a generous budget must load cleanly and free cleanly.
@(test)
qdct_load_oom_sweep_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }

	arena_buf := make([]u8, 1 << 22, allocator)
	defer delete(arena_buf, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	if serr := moli.save_qdct(&a, "tmp/qdct_oom.bin", mem.arena_allocator(&arena)); serr != nil {
		testing.expectf(t, false, "save: %v", serr)
		return
	}
	moli.free(&a)

	saw_oom := false
	loaded := false
	// Budget 1 covers the file read; every budget after it starves one
	// of the rebuild allocations in turn.
	for budget in 1 ..< 40 {
		b := Budget_Allocator{backing = context.allocator, remaining = budget}
		budget_alloc := mem.Allocator{data = &b, procedure = budget_allocator_proc}
		ra, err := moli.load_qdct("tmp/qdct_oom.bin", budget_alloc)
		if err == nil {
			moli.free(&ra) // while b lives: the deletes route through it
			loaded = true
		} else {
			testing.expectf(t, err == moli.Load_Fault.OutOfMemory,
				"budget %d: load_qdct must fail with .OutOfMemory, got %v", budget, err)
			saw_oom = true
		}
	}
	testing.expectf(t, saw_oom && loaded,
		"the sweep must cover both failure and success (oom=%v loaded=%v)", saw_oom, loaded)
}

// The in-memory entry takes ownership of the caller's buffer and
// restores the same analyzer the file entry does: morpheme-level
// equality against the analyzer that saved the snapshot, and free
// releases the handed-over image exactly once (the leak gate enforces
// the single owner - an error return releases it too, so nothing here
// deletes data).
@(test)
qdct_bytes_round_trip_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }

	arena_buf := make([]u8, 1 << 22, allocator)
	defer delete(arena_buf, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	if serr := moli.save_qdct(&a, "tmp/qdct_bytes.bin", mem.arena_allocator(&arena)); serr != nil {
		testing.expectf(t, false, "save: %v", serr)
		moli.free(&a)
		return
	}
	// The original is no longer needed once the snapshot exists.
	moli.free(&a)

	data, derr := os.read_entire_file("tmp/qdct_bytes.bin", allocator)
	if derr != nil {
		testing.expectf(t, false, "read back: %v", derr)
		return
	}
	// Both entries restored and alive together: morpheme strings are
	// zero-copy into analyzer-owned storage, so comparing them across
	// a free would read freed memory - compare two live analyzers.
	fa, ferr2 := moli.load_qdct("tmp/qdct_bytes.bin", allocator)
	if ferr2 != nil {
		delete(data, allocator) // not handed over yet
		testing.expectf(t, false, "load_qdct: %v", ferr2)
		return
	}
	want, werr := moli.tokenize(&fa, "犬が歩く", mem.arena_allocator(&arena))
	if werr != nil {
		testing.expectf(t, false, "tokenize(file): %v", werr)
		moli.free(&fa)
		return
	}

	// Ownership transfers here: b's free below releases data.
	b, berr := moli.load_qdct_bytes(data, allocator)
	if berr != nil {
		moli.free(&fa)
		testing.expectf(t, false, "load_qdct_bytes: %v", berr)
		return
	}
	got, gerr := moli.tokenize(&b, "犬が歩く", mem.arena_allocator(&arena))
	if gerr != nil {
		testing.expectf(t, false, "tokenize(bytes): %v", gerr)
		moli.free(&b)
		moli.free(&fa)
		return
	}
	same := len(got) == len(want)
	bad_i := -1
	if same {
		for i in 0 ..< len(want) {
			if got[i].surface != want[i].surface || got[i].pos != want[i].pos ||
				got[i].lemma != want[i].lemma || got[i].cost != want[i].cost {
				same = false
				bad_i = i
				break
			}
		}
	}
	testing.expectf(t, same,
		"bytes restore matches the file restore (%v vs %v morphemes; first diff at %v)",
		len(got), len(want), bad_i)
	if bad_i >= 0 {
		testing.expectf(t, false, "at %v: got %q pos %q, want %q pos %q", bad_i,
			got[bad_i].surface, got[bad_i].pos,
			want[bad_i].surface, want[bad_i].pos)
	}
	moli.free(&b)
	moli.free(&fa)
}

// The buffer-ownership transfer holds at the zero-length edge: a
// zero-length but allocated buffer handed to load_qdct_bytes rejects
// as too short AND its storage is released by the loader's failure
// path (the leak gate polices it) - the contract promises every
// failure path releases the buffer, however short it turned out to be.
@(test)
qdct_bytes_empty_owned_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	full, merr := make([]u8, 8, allocator)
	if merr != nil {
		testing.expectf(t, false, "make: %v", merr)
		return
	}
	buf := full[:0] // zero length, non-nil data pointer: storage owned
	_, lerr := moli.load_qdct_bytes(buf, allocator)
	testing.expectf(t, lerr == moli.Load_Fault.Invalid_Format,
		"empty buffer must be rejected, got %v", lerr)
}

// The mapped restore answers identically to the read-copy restore:
// same counts, same morphemes in both modes, image marked mapped. The
// mapping itself never passes through the allocator; the rebuild's
// allocations do, so they ride the tracking allocator here.
@(test)
qdct_mmap_roundtrip_test :: proc(t: ^testing.T) {
	allocator := context.allocator

	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	arena_buf := make([]u8, 1 << 22, allocator)
	defer delete(arena_buf, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	if serr := moli.save_qdct(&a, "tmp/qdct_map.bin", mem.arena_allocator(&arena)); serr != nil {
		testing.expectf(t, false, "save: %v", serr)
		return
	}

	ra, lerr := moli.load_qdct_mmap("tmp/qdct_map.bin", allocator)
	if lerr != nil {
		testing.expectf(t, false, "mmap load: %v", lerr)
		return
	}
	defer moli.free(&ra)

	// Windows has no portable core mmap: qdct_map_file falls back to a
	// read copy and never marks the image mapped, so the flag contract
	// this pins is per-OS (see qdct_map_windows.odin).
	when ODIN_OS == .Windows {
		if ra.image_mapped {
			testing.expectf(t, false, "the Windows read-copy fallback must not mark the image mapped")
			return
		}
	} else {
		if !ra.image_mapped {
			testing.expectf(t, false, "image not marked mapped")
			return
		}
	}
	if len(ra.entries) != len(a.entries) || len(ra.unk_def) != len(a.unk_def) {
		testing.expectf(t, false, "counts: entries %v/%v unk %v/%v",
			len(ra.entries), len(a.entries), len(ra.unk_def), len(a.unk_def))
		return
	}

	buf1 := make([]u8, 1 << 18, allocator)
	defer delete(buf1, allocator)
	buf2 := make([]u8, 1 << 18, allocator)
	defer delete(buf2, allocator)
	ar1: mem.Arena
	mem.arena_init(&ar1, buf1)
	ar2: mem.Arena
	mem.arena_init(&ar2, buf2)
	modes := []moli.Mode{.Viterbi, .LongestMatch}
	sentences := []string{"犬が歩く", "さくらの犬"}
	for mode in modes {
		a.mode = mode
		ra.mode = mode
		for s in sentences {
			m1, e1 := moli.tokenize(&a, s, mem.arena_allocator(&ar1))
			m2, e2 := moli.tokenize(&ra, s, mem.arena_allocator(&ar2))
			if e1 != nil || e2 != nil {
				testing.expectf(t, false, "tokenize err %v/%v", e1, e2)
				return
			}
			if !expect_morphemes_equal(t, m1, m2) { return }
			mem.arena_init(&ar1, buf1)
			mem.arena_init(&ar2, buf2)
		}
	}
}

// The mapped path refuses absent, empty, corrupt, and unmappable files
// without touching a page beyond the file, and its one allocation
// before the shared rebuild (the path copy for the open call) fails as
// .OutOfMemory under a starved allocator.
@(test)
qdct_mmap_reject_test :: proc(t: ^testing.T) {
	allocator := context.allocator

	_, err := moli.load_qdct_mmap("tmp/qdct_nonexistent.bin", allocator)
	if err != moli.Load_Fault(.File_Not_Found) {
		testing.expectf(t, false, "missing file: %v", err)
		return
	}

	if werr := os.write_entire_file("tmp/qdct_mmap_empty.bin", []u8{}); werr != nil {
		testing.expectf(t, false, "write empty: %v", werr)
		return
	}
	_, err = moli.load_qdct_mmap("tmp/qdct_mmap_empty.bin", allocator)
	if err != moli.Load_Fault(.Invalid_Format) {
		testing.expectf(t, false, "empty: %v", err)
		return
	}

	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }
	arena_buf := make([]u8, 1 << 22, allocator)
	defer delete(arena_buf, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	if serr := moli.save_qdct(&a, "tmp/qdct_mmap_bad.bin", mem.arena_allocator(&arena)); serr != nil {
		testing.expectf(t, false, "save: %v", serr)
		moli.free(&a)
		return
	}
	moli.free(&a)

	valid, verr := os.read_entire_file("tmp/qdct_mmap_bad.bin", allocator)
	if verr != nil {
		testing.expectf(t, false, "read back: %v", verr)
		return
	}
	defer delete(valid, allocator)
	valid[0] = 'X' // validation runs in place over the mapping
	if werr := os.write_entire_file("tmp/qdct_mmap_bad.bin", valid); werr != nil {
		testing.expectf(t, false, "rewrite: %v", werr)
		return
	}
	_, err = moli.load_qdct_mmap("tmp/qdct_mmap_bad.bin", allocator)
	if err != moli.Load_Fault(.Invalid_Format) {
		testing.expectf(t, false, "magic: %v", err)
		return
	}

	// A directory cannot be mapped; the kernel refusal surfaces as
	// Invalid_Format, not a crash. On Windows the mmap edge is the
	// read-copy fallback: the CRT opens a directory happily and the
	// read fails, so the answer there is the read fault .IO_Read.
	_, err = moli.load_qdct_mmap("tmp", allocator)
	when ODIN_OS == .Windows {
		if err != moli.Load_Fault(.IO_Read) {
			testing.expectf(t, false, "directory (read-copy fallback): %v", err)
			return
		}
	} else {
		if err != moli.Load_Fault(.Invalid_Format) {
			testing.expectf(t, false, "directory: %v", err)
			return
		}
	}

	// A starved allocator answers .OutOfMemory on both platforms, but
	// at different points: POSIX fails the path clone that precedes
	// every file access, while the Windows read-copy fallback
	// allocates nothing before the read buffer itself - the loader
	// splits that allocation failure out of the read fault.
	b := Budget_Allocator{backing = context.allocator, remaining = 0}
	budget_alloc := mem.Allocator{data = &b, procedure = budget_allocator_proc}
	_, err = moli.load_qdct_mmap("tmp/qdct_mmap_bad.bin", budget_alloc)
	if err != moli.Load_Fault(.OutOfMemory) {
		testing.expectf(t, false, "budget 0: %v", err)
		return
	}
}

// The read-copy path distinguishes its failure modes: an absent file
// answers .File_Not_Found, a file the OS refuses to read answers
// .IO_Read - not .Invalid_Format, the bytes were never seen. A
// directory is that refusal on both platforms: the open succeeds
// (POSIX) or is permitted (the Windows CRT) and the read then fails
// (EISDIR / EACCES). The partial buffer read_entire_file hands back
// together with the error is released by the loader; the leak gate
// polices that release.
@(test)
qdct_read_error_test :: proc(t: ^testing.T) {
	allocator := context.allocator

	_, err := moli.load_qdct("tmp/qdct_nonexistent.bin", allocator)
	if err != moli.Load_Fault(.File_Not_Found) {
		testing.expectf(t, false, "missing file: %v", err)
		return
	}

	_, err = moli.load_qdct("tmp", allocator)
	if err != moli.Load_Fault(.IO_Read) {
		testing.expectf(t, false, "directory: %v", err)
		return
	}

	// The CSV load path distinguishes the same way (same open/read
	// failure mapping): a directory as the dictionary path answers the
	// read fault, not .Invalid_Format.
	_, err = moli.load(.Japanese, "tmp", {}, allocator)
	if err != moli.Load_Fault(.IO_Read) {
		testing.expectf(t, false, "csv directory: %v", err)
		return
	}
}

// Hostile section tables and pair sections must answer
// .Invalid_Format: a non-empty section may not alias the header or
// overlap another section, and the pair rows must form a total
// bijection of real code points over [0, n_pairs). Each leg patches
// one field of an otherwise valid image; the duplicate-code leg also
// exercises the coverage check (codes and rows are equal in count, so
// a duplicate always leaves a hole). A rejected load has already
// consumed the image buffer through the rebuild's release, so the
// leak gate polices the rejection legs too.
// patch_u64 writes v little-endian at byte offset b of image.
patch_u64 :: proc(image: []u8, b: int, v: int) {
	x := u64(v)
	for i in 0 ..< 8 {
		image[b + i] = u8(x >> cast(u64)(8 * i))
	}
}

@(test)
qdct_hostile_sections_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	for leg in 0 ..< 4 {
		image, serr := moli.snapshot(&a, allocator)
		if serr != nil {
			testing.expectf(t, false, "snapshot: %v", serr)
			return
		}
		entries_tbl := moli.QDCT_HEADER_SIZE + int(moli.QDCT_SECTION_ENTRIES) * moli.QDCT_SECTION_ENTRY_SIZE
		blob_off := int(moli.le_u64(image, moli.QDCT_HEADER_SIZE + int(moli.QDCT_SECTION_BLOB) * moli.QDCT_SECTION_ENTRY_SIZE))
		pairs_tbl := moli.QDCT_HEADER_SIZE + int(moli.QDCT_SECTION_PAIRS) * moli.QDCT_SECTION_ENTRY_SIZE
		pairs_off := int(moli.le_u64(image, pairs_tbl))
		pairs_end := pairs_off + int(moli.le_u64(image, pairs_tbl + 8))
		switch leg {
		case 0: // alias the header
			patch_u64(image, entries_tbl, 0)
		case 1: // overlap: entries onto the blob section
			patch_u64(image, entries_tbl, blob_off)
		case 2: // duplicate pair code (leaves a hole by counting)
			pairs := mem.slice_data_cast([]moli.Pair, image[pairs_off:pairs_end])
			if len(pairs) < 2 {
				testing.expectf(t, false, "fixture needs >=2 pairs, has %v", len(pairs))
				return
			}
			pairs[1].code = pairs[0].code
		case 3: // pair rune below the code point range
			pairs := mem.slice_data_cast([]moli.Pair, image[pairs_off:pairs_end])
			pairs[0].r = -1
		}
		b, rerr := moli.load_qdct_bytes(image, allocator)
		if rerr == nil { moli.free(&b) }
		testing.expectf(t, rerr == moli.Load_Fault.Invalid_Format,
			"leg %d: hostile image must be rejected, got %v", leg, rerr)
	}
}

// The save-side limits check refuses - never silently narrows - an
// analyzer past the record forms' representational limits. The one
// declaration is qdct_counts_limit_err (qdct_image runs it before
// writing a byte); a real oversized dictionary cannot be built in a
// test, so the check is pinned directly with crafted counts.
@(test)
qdct_save_limits_test :: proc(t: ^testing.T) {
	a: moli.Analyzer // zero entries: only the counts legs fire

	cases := []moli.Qdct_Counts{
		{blob_len = moli.QDCT_MAX_U32 + 1},
		{n_entries = moli.QDCT_MAX_U32 + 1},
		{n_extras = moli.QDCT_MAX_U32 + 1},
		{n_pairs = moli.QDCT_MAX_CODE + 1},
		{n_unk = moli.QDCT_MAX_U32 + 1},
		{n_ranges = moli.QDCT_MAX_U32 + 1},
		{n_skipped = moli.QDCT_MAX_U32 + 1},
		{n_patterns = moli.QDCT_MAX_U32 + 1},
		{n_left = moli.QDCT_MAX_U32 + 1},
		{n_right = moli.QDCT_MAX_U32 + 1},
		{n_cedar = moli.QDCT_MAX_U32 + 1},
	}
	for i in 0 ..< len(cases) {
		if err := moli.qdct_counts_limit_err(&a, &cases[i]); err != moli.Save_Fault.Format_Limit {
			testing.expectf(t, false, "case %d must refuse as .Format_Limit, got %v", i, err)
			return
		}
	}

	// The per-entry extras window: one entry with 65536 extras refuses
	// even at zero totals, and the same entry passes once the window
	// fits the u16 cap (the [dynamic] is a value - the field is
	// re-assigned after each resize).
	extra := make([dynamic]string, moli.QDCT_MAX_U16 + 1, context.allocator)
	defer delete(extra)
	a.entries = make([dynamic]moli.Dictionary_Entry, 1, context.allocator)
	defer delete(a.entries)
	a.entries[0] = moli.Dictionary_Entry{extra = extra}
	ok_counts := moli.Qdct_Counts{}
	if err := moli.qdct_counts_limit_err(&a, &ok_counts); err != moli.Save_Fault.Format_Limit {
		testing.expectf(t, false, "over-wide extras window must refuse, got %v", err)
		return
	}
	resize(&extra, moli.QDCT_MAX_U16)
	a.entries[0] = moli.Dictionary_Entry{extra = extra}
	if err := moli.qdct_counts_limit_err(&a, &ok_counts); err != nil {
		testing.expectf(t, false, "representable shape must pass, got %v", err)
		return
	}
}

// A hostile image whose pair section really counts 0x10000 rows -
// past the alphabet cap, since compact code 0xFFFF is the no_char
// sentinel the BMP table reads as unmapped - must be refused even
// though its geometry is internally consistent: the pairs section is
// appended at the image end with the section table and header count
// patched to match, so only the cap check can catch it.
@(test)
qdct_hostile_alphabet_cap_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	image, serr := moli.snapshot(&a, allocator)
	if serr != nil {
		testing.expectf(t, false, "snapshot: %v", serr)
		return
	}

	n_pairs := int(moli.no_char) + 1
	new_off := moli.align8(len(image))
	pairs_size := n_pairs * size_of(moli.Pair)
	grown := make([]u8, new_off + pairs_size, allocator)
	copy(grown, image)
	delete(image, allocator)

	pairs_tbl := moli.QDCT_HEADER_SIZE + int(moli.QDCT_SECTION_PAIRS) * moli.QDCT_SECTION_ENTRY_SIZE
	patch_u64(grown, pairs_tbl, new_off)
	patch_u64(grown, pairs_tbl + 8, pairs_size)
	npu := u32(n_pairs)
	for i in 0 ..< 4 {
		grown[moli.QDCT_OFF_PAIRS + i] = u8(npu >> cast(u32)(8 * i))
	}
	pairs_view := mem.slice_data_cast([]moli.Pair, grown[new_off:new_off + pairs_size])
	for i in 0 ..< n_pairs {
		pairs_view[i] = moli.Pair{r = i32(i), code = u16(i)}
	}

	b, rerr := moli.load_qdct_bytes(grown, allocator)
	if rerr == nil { moli.free(&b) }
	testing.expectf(t, rerr == moli.Load_Fault.Invalid_Format,
		"65536-pair alphabet must be rejected, got %v", rerr)
}

// A hostile unk record carrying a class ordinal outside Char_Class
// must be refused like the pattern records' class: a rule the CSV
// loader could never have produced is a corrupt file.
@(test)
qdct_hostile_unk_class_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	image, serr := moli.snapshot(&a, allocator)
	if serr != nil {
		testing.expectf(t, false, "snapshot: %v", serr)
		return
	}
	unk_tbl := moli.QDCT_HEADER_SIZE + int(moli.QDCT_SECTION_UNK) * moli.QDCT_SECTION_ENTRY_SIZE
	if int(moli.le_u64(image, unk_tbl + 8)) < size_of(moli.Unk_Record) {
		testing.expectf(t, false, "fixture carries no unk rules")
		return
	}
	unk_off := int(moli.le_u64(image, unk_tbl))
	image[unk_off] = 0x7F // first Unk_Record.class
	b, rerr := moli.load_qdct_bytes(image, allocator)
	if rerr == nil { moli.free(&b) }
	testing.expectf(t, rerr == moli.Load_Fault.Invalid_Format,
		"unk class outside Char_Class must be rejected, got %v", rerr)
}

// Hostile cedar base values and char ranges must answer
// .Invalid_Format before any walk or flat build indexes them: a
// negative base makes base[s] + code land at a negative slot (the
// upper-bound check alone passes), a base past the array is equally
// corrupt, and a range with a negative lo or a hi beyond the code-point
// universe would index the flat table out of bounds. The flat table is
// requested (header byte 11) so a slipped-through negative range would
// panic, not just misclassify. Each leg patches one field of an
// otherwise valid image; the rejection consumes the image, so the leak
// gate polices the legs.
@(test)
qdct_hostile_base_ranges_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {flat_char_class = true})
	if !ok { return }
	defer moli.free(&a)

	for leg in 0 ..< 4 {
		image, serr := moli.snapshot(&a, allocator)
		if serr != nil {
			testing.expectf(t, false, "snapshot: %v", serr)
			return
		}
		base_tbl := moli.QDCT_HEADER_SIZE + int(moli.QDCT_SECTION_BASE) * moli.QDCT_SECTION_ENTRY_SIZE
		base_off := int(moli.le_u64(image, base_tbl))
		base_len := int(moli.le_u64(image, base_tbl + 8))
		ranges_tbl := moli.QDCT_HEADER_SIZE + int(moli.QDCT_SECTION_RANGES) * moli.QDCT_SECTION_ENTRY_SIZE
		ranges_off := int(moli.le_u64(image, ranges_tbl))
		base := mem.slice_data_cast([]i32, image[base_off:base_off + base_len])
		ranges := mem.slice_data_cast([]moli.Char_Range, image[ranges_off:])
		switch leg {
		case 0: // root base negative: t = base[1] + code can go negative
			base[1] = -0x7FFFFFFF
		case 1: // base past the array end
			base[1] = i32(base_len / 4 + 64)
		case 2: // range lo negative: flat fill would index negatively
			ranges[0].lo = -8
			ranges[0].hi = 16
		case 3: // range hi beyond the code-point universe
			ranges[0].hi = 0x200000
		}
		b, rerr := moli.load_qdct_bytes(image, allocator)
		if rerr == nil { moli.free(&b) }
		testing.expectf(t, rerr == moli.Load_Fault.Invalid_Format,
			"leg %d: hostile image must be rejected, got %v", leg, rerr)
	}
}

// Merging user rows into an image-backed analyzer (the clone-then-
// customize workflow) must give those rows per-row string ownership:
// teardown releases them with the entries they live in, not with the
// image they never pointed into. Everything here rides the suite's
// tracking allocator, so the zero-leak gate is the assertion: five
// leaked string clones per merged row would print.
@(test)
qdct_user_merge_teardown_test :: proc(t: ^testing.T) {
	a, lerr := moli.load(.Japanese, IPADIC_FIXTURE, {}, context.allocator)
	if lerr != nil {
		testing.expectf(t, false, "load: %v", lerr)
		return
	}
	image, serr := moli.snapshot(&a, context.allocator)
	if serr != nil {
		moli.free(&a)
		testing.expectf(t, false, "snapshot: %v", serr)
		return
	}
	moli.free(&a)
	b, rerr := moli.load_qdct_bytes(image, context.allocator)
	if rerr != nil {
		delete(image, context.allocator)
		testing.expectf(t, false, "load_qdct_bytes: %v", rerr)
		return
	}

	user := []moli.User_Entry{
		{surface = "ぞの犬", left_id = 0, right_id = 0, cost = -5000, pos = "名詞,固有名詞", lemma = "*", reading = "*", reading_jyutping = "*"},
	}
	if uerr := moli.add_user_entries(&b, user); uerr != nil {
		moli.free(&b)
		testing.expectf(t, false, "add_user_entries: %v", uerr)
		return
	}

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	ms, terr := moli.tokenize(&b, "ぞの犬", mem.arena_allocator(&arena))
	if terr != nil {
		moli.free(&b)
		testing.expectf(t, false, "tokenize after the merge: %v", terr)
		return
	}
	testing.expectf(t, len(ms) == 1 && ms[0].surface == "ぞの犬" && !ms[0].is_unknown,
		"the merged row answers on the image-backed analyzer")

	moli.free(&b)
}
