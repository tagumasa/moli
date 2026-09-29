// Two-file jyutping merge coverage: join semantics (donor, not union),
// first-row-wins, homograph groups patched together, absent readings,
// prefix-surface equality, the pinyin reading surviving the merge, the
// malformed-donor gauntlet at the load boundary, the patch clone's OOM
// leg, and the snapshot round-trip of the merged readings.
package tests

import "base:runtime"
import "core:mem"
import "core:os"
import "core:testing"
import "moli:moli"

// The merge end to end through the real load: every donor rule lands on
// the entries it should, and only those.
@(test)
jyutping_merge_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .ChineseCN, MERGE_CN_FIXTURE,
		{mode = .LongestMatch, jyutping_csv_path = MERGE_HK_FIXTURE})
	if !ok { return }
	defer moli.free(&a)

	// The donor adds nothing: 7 primary rows stay 7 entries.
	if len(a.entries) != 7 {
		testing.expectf(t, false, "entries: %v, want 7 (a donor adds none)", len(a.entries))
		return
	}

	expect := []struct {
		surface:  string,
		jyutping: string,
		occurs:   int,
	}{
		{surface = "香港",     jyutping = "hoeng1 gong2",        occurs = 1}, // first row wins, not gong2 hoeng1
		{surface = "島",       jyutping = "dou2",                occurs = 2}, // the homograph pair patches as a group
		{surface = "茶餐廳",   jyutping = "caa1 caan1 teng1",    occurs = 1}, // empty and "*" rows skip, the real row applies
		{surface = "今日",     jyutping = "gam1 jat6",           occurs = 1}, // its own row, not the longer surface's value
		{surface = "今日新聞", jyutping = "gam1 jat6 san1 man4", occurs = 1},
		{surface = "溫哥華",   jyutping = "*",                   occurs = 1}, // absent from the donor entirely
	}
	for e in expect {
		n := 0
		for entry in a.entries {
			if entry.surface != e.surface { continue }
			n += 1
			if entry.reading_jyutping != e.jyutping {
				testing.expectf(t, false, "%q: jyutping %q, want %q",
					e.surface, entry.reading_jyutping, e.jyutping)
				return
			}
		}
		if n != e.occurs {
			testing.expectf(t, false, "%q: %v entries, want %v", e.surface, n, e.occurs)
			return
		}
	}
	// The pinyin reading from the primary survives the merge untouched.
	for entry in a.entries {
		if entry.surface == "香港" && entry.reading != "xiang1 gang3" {
			testing.expectf(t, false, "香港 reading %q, want the primary's pinyin", entry.reading)
			return
		}
	}
	// A donor-only surface must not enter the lexicon.
	for entry in a.entries {
		if entry.surface == "旺角" {
			testing.expectf(t, false, "a donor-only surface must not become an entry")
			return
		}
	}
	// The merge is opt-in: it records nothing in skipped_resources
	// (the four canonical resources of a sibling-less directory).
	if len(a.skipped_resources) != 4 {
		testing.expectf(t, false, "skipped_resources: %v, want 4", len(a.skipped_resources))
		return
	}

	// Morphemes carry the merged reading.
	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	ms, terr := moli.tokenize(&a, "香港島", mem.arena_allocator(&arena))
	if terr != nil {
		testing.expectf(t, false, "tokenize: %v", terr)
		return
	}
	if len(ms) != 2 {
		testing.expectf(t, false, "香港島: %v morphemes, want 2", len(ms))
		return
	}
	if ms[0].surface != "香港" || ms[0].reading_jyutping != "hoeng1 gong2" ||
		ms[1].surface != "島" || ms[1].reading_jyutping != "dou2" || ms[1].reading != "dao3" {
		testing.expectf(t, false, "morphemes: (%q %q %q) (%q %q %q)",
			ms[0].surface, ms[0].reading, ms[0].reading_jyutping,
			ms[1].surface, ms[1].reading, ms[1].reading_jyutping)
		return
	}

	// Without the option everything stays "*": the donor is the only
	// source of reading_jyutping.
	b, ok2 := load_ok(t, .ChineseCN, MERGE_CN_FIXTURE, {mode = .LongestMatch})
	if !ok2 { return }
	defer moli.free(&b)
	if len(b.entries) != len(a.entries) {
		testing.expectf(t, false, "no-donor load: %v entries vs %v", len(b.entries), len(a.entries))
		return
	}
	for entry in b.entries {
		if entry.reading_jyutping != "*" {
			testing.expectf(t, false, "%q: no donor loaded, jyutping must stay *", entry.surface)
			return
		}
	}
}

// The donor boundary: every malformed shape rejects through load, a
// missing file is a hard error, an empty donor is legal, and the patch
// clone's allocation failure leaves the analyzer untouched.
@(test)
jyutping_loader_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()

	bad := []struct {
		name:    string,
		content: string,
	}{
		{name = "ipadic-shaped file is not a donor",
			content = "さくら,0,0,5500,名詞,一般,*,*,*,*,さくら,サクラ,サクラ\n"},
		{name = "column count drifts after detection",
			content = "香港,0,0,5000,ns,hoeng1 gong2,香港,香港,HK\n島,0,0,6000\n"},
		{name = "non-numeric id",
			content = "香港,x,0,5000,ns,hoeng1 gong2,香港,香港,HK\n"},
		{name = "empty surface",
			content = ",0,0,5000,ns,hoeng1 gong2,香港,香港,HK\n"},
		{name = "unterminated quote",
			content = "\"香港,0,0,5000,ns,hoeng1 gong2,香港,香港,HK\n"},
		{name = "unclassifiable first line",
			content = "abc\n"},
	}
	for b in bad {
		write_tmp(t, "tmp/jyut_bad.csv", b.content)
		_, err := moli.load(.ChineseCN, MERGE_CN_FIXTURE,
			{mode = .LongestMatch, jyutping_csv_path = "tmp/jyut_bad.csv"}, allocator)
		if err == nil {
			testing.expectf(t, false, "%s must fail the load", b.name)
			return
		}
	}

	// An explicitly named missing donor is a hard error.
	_, err := moli.load(.ChineseCN, MERGE_CN_FIXTURE,
		{jyutping_csv_path = "tmp/no_such_donor.csv"}, allocator)
	if err != moli.Load_Fault.File_Not_Found {
		testing.expectf(t, false, "missing donor: want .File_Not_Found, got %v", err)
		return
	}

	// A donor with no rows is legal and patches nothing.
	write_tmp(t, "tmp/jyut_empty.csv", "\n")
	a, ok := load_ok(t, .ChineseCN, MERGE_CN_FIXTURE,
		{mode = .LongestMatch, jyutping_csv_path = "tmp/jyut_empty.csv"})
	if !ok { return }
	defer moli.free(&a)
	for entry in a.entries {
		if entry.reading_jyutping != "*" {
			testing.expectf(t, false, "%q: an empty donor must not patch", entry.surface)
			return
		}
	}

	// The patch clone fails under a spent budget: the load reports
	// OutOfMemory and the entries keep their "*" strings (the clone
	// happens before the old string is freed).
	a2, ok2 := load_ok(t, .ChineseCN, MERGE_CN_FIXTURE, {mode = .LongestMatch})
	if !ok2 { return }
	defer moli.free(&a2)
	ba := Budget_Allocator{backing = context.allocator, remaining = 0}
	balloc := mem.Allocator{data = &ba, procedure = budget_allocator_proc}
	imp: moli.Importer
	imp.allocator = balloc
	mem.dynamic_arena_init(&imp.scratch)
	defer mem.dynamic_arena_destroy(&imp.scratch)
	if jerr := moli.import_jyutping_csv(&imp, &a2, MERGE_HK_FIXTURE); jerr != moli.Load_Fault.OutOfMemory {
		testing.expectf(t, false, "patch OOM: want .OutOfMemory, got %v", jerr)
		return
	}
	for entry in a2.entries {
		if entry.reading_jyutping != "*" {
			testing.expectf(t, false, "%q: a failed patch must leave the entry untouched", entry.surface)
			return
		}
	}
}

// The merged readings ride through save_qdct/load_qdct untouched - the
// snapshot already serializes reading_jyutping, so no format change.
@(test)
jyutping_qdct_roundtrip_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .ChineseCN, MERGE_CN_FIXTURE,
		{mode = .LongestMatch, jyutping_csv_path = MERGE_HK_FIXTURE})
	if !ok { return }
	defer moli.free(&a)

	ra, ok_ra := qdct_roundtrip_restore(t, &a, "tmp/jyutping_round.qdct",
		context.allocator, context.allocator)
	if !ok_ra { return }
	defer moli.free(&ra)

	if len(ra.entries) != len(a.entries) {
		testing.expectf(t, false, "entries: %v vs %v", len(ra.entries), len(a.entries))
		return
	}
	for e, i in a.entries {
		r := ra.entries[i]
		if r.surface != e.surface || r.reading != e.reading ||
			r.reading_jyutping != e.reading_jyutping {
			testing.expectf(t, false, "entry %d differs after the round-trip", i)
			return
		}
	}

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	ms, terr := moli.tokenize(&ra, "茶餐廳", mem.arena_allocator(&arena))
	if terr != nil {
		testing.expectf(t, false, "tokenize: %v", terr)
		return
	}
	if len(ms) != 1 {
		testing.expectf(t, false, "茶餐廳: %v morphemes, want 1", len(ms))
		return
	}
	if ms[0].reading_jyutping != "caa1 caan1 teng1" {
		testing.expectf(t, false, "restored jyutping %q", ms[0].reading_jyutping)
		return
	}

	// The temp snapshot is a file, not a checked-in artifact.
	if rerr := os.remove("tmp/jyutping_round.qdct"); rerr != nil {
		testing.expectf(t, false, "remove snapshot: %v", rerr)
	}
}
