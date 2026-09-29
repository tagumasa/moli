// Morpheme.entry_id and its support surface: ids resolve through
// entry_info, are stable across save_qdct/restore and clone, go stale
// across add_user_entries, and stats.entries_hash tracks the entry
// content as a load-path-independent fingerprint.
package tests

import "base:runtime"
import "core:mem"
import "core:os"
import "core:testing"
import "moli:moli"

// expect_entry_ids_resolves walks a tokenization asserting the id
// contract: unknown morphemes carry -1, dictionary morphemes carry an
// index whose entry_info row matches the morpheme's surface and POS.
expect_entry_ids_resolve :: proc(t: ^testing.T, a: ^moli.Analyzer, ms: []moli.Morpheme) -> bool {
	for m in ms {
		if m.is_unknown {
			if m.entry_id != -1 {
				testing.expectf(t, false, "unknown %s carries id %v", m.surface, m.entry_id)
				return false
			}
			continue
		}
		if m.entry_id < 0 {
			testing.expectf(t, false, "dictionary morpheme %s has id %v", m.surface, m.entry_id)
			return false
		}
		info, ok, err := moli.entry_info(a, m.entry_id)
		if err != nil || !ok {
			testing.expectf(t, false, "entry_info(%v) for %s: (%v, %v)", m.entry_id, m.surface, ok, err)
			return false
		}
		if info.surface != m.surface || info.pos != m.pos {
			testing.expectf(t, false, "id %v resolves (%s | %s), morpheme says (%s | %s)",
				m.entry_id, info.surface, info.pos, m.surface, m.pos)
			return false
		}
	}
	return true
}

@(test)
entry_id_resolves_test :: proc(t: ^testing.T) {
	// Both modes fill entry_id from their lattice/lookup ids.
	modes := []moli.Mode{.Viterbi, .LongestMatch}
	for mode in modes {
		a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {mode = mode})
		if !ok { return }
		defer moli.free(&a)

		arena_buf: [1 << 16]byte
		arena: mem.Arena
		mem.arena_init(&arena, arena_buf[:])

		// 犬とzzz歩く: dictionary rows plus one ASCII unknown run.
		ms, err := moli.tokenize(&a, "犬がzzz歩く", mem.arena_allocator(&arena))
		if err != nil {
			testing.expectf(t, false, "tokenize (%v): %v", mode, err)
			return
		}
		unknowns := 0
		for m in ms {
			if m.is_unknown { unknowns += 1 }
		}
		if unknowns == 0 {
			testing.expectf(t, false, "expected an unknown run, got %v morphemes", len(ms))
			return
		}
		if !expect_entry_ids_resolve(t, &a, ms) { return }
	}
}

@(test)
entry_id_stable_across_restore_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	scratch: mem.Arena
	buf := make([]u8, 1 << 22, allocator)
	defer delete(buf, allocator)
	mem.arena_init(&scratch, buf)

	b, ok_b := qdct_roundtrip_restore(t, &a, "tmp/entry_id_snap.bin",
		mem.arena_allocator(&scratch), context.allocator)
	if !ok_b { return }
	defer moli.free(&b)

	c, cerr := moli.clone(&a, allocator)
	if cerr != nil {
		testing.expectf(t, false, "clone: %v", cerr)
		return
	}
	defer moli.free(&c)

	// Stability across restore and clone: every observable field,
	// entry_id included, compared through per-call arenas (a shared
	// arena reset between tokenizations would alias the slices and
	// void the comparison). This is the live pin behind Morpheme's
	// "entry_id ... identical across snapshot save/restore and clone".
	text := "東京の犬が歩く"
	if !expect_analyses_equal(t, &a, &b, []string{text}) { return }
	if !expect_analyses_equal(t, &a, &c, []string{text}) { return }

	// The restored and cloned analyzers resolve their own ids
	// coherently.
	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	ms_b, terr := moli.tokenize(&b, text, mem.arena_allocator(&arena))
	if terr != nil { testing.expectf(t, false, "tokenize b: %v", terr); return }
	if !expect_entry_ids_resolve(t, &b, ms_b) { return }
	mem.arena_free_all(&arena)
	ms_c, terr2 := moli.tokenize(&c, text, mem.arena_allocator(&arena))
	if terr2 != nil { testing.expectf(t, false, "tokenize c: %v", terr2); return }
	if !expect_entry_ids_resolve(t, &c, ms_c) { return }
}

@(test)
entry_info_rejects_stale_and_teardown_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }

	if _, ok2, err := moli.entry_info(&a, -1); ok2 || err != nil {
		testing.expectf(t, false, "id -1 answered (%v, %v)", ok2, err)
		return
	}
	st, _ := moli.stats(&a)
	if _, ok2, err := moli.entry_info(&a, i32(st.entries)); ok2 || err != nil {
		testing.expectf(t, false, "id at entries count answered (%v, %v)", ok2, err)
		return
	}

	moli.free(&a)
	if _, _, err := moli.entry_info(&a, 0); err != .Unavailable {
		testing.expectf(t, false, "torn-down entry_info: %v", err)
		return
	}
}

@(test)
entries_hash_fingerprints_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	scratch: mem.Arena
	buf := make([]u8, 1 << 22, allocator)
	defer delete(buf, allocator)
	mem.arena_init(&scratch, buf[:])
	if serr := moli.save_qdct(&a, "tmp/entry_hash_snap.bin", mem.arena_allocator(&scratch)); serr != nil {
		testing.expectf(t, false, "save_qdct: %v", serr)
		return
	}
	b, lerr := moli.load_qdct("tmp/entry_hash_snap.bin", runtime.default_allocator())
	if lerr != nil {
		testing.expectf(t, false, "load_qdct: %v", lerr)
		return
	}
	defer moli.free(&b)
	os.remove("tmp/entry_hash_snap.bin")

	c, cerr := moli.clone(&a, allocator)
	if cerr != nil { testing.expectf(t, false, "clone: %v", cerr); return }
	defer moli.free(&c)

	d, ok3 := load_ok(t, .Japanese, UNIDIC_FIXTURE, {})
	if !ok3 { return }
	defer moli.free(&d)

	sa, _ := moli.stats(&a)
	sb, _ := moli.stats(&b)
	sc, _ := moli.stats(&c)
	sd, _ := moli.stats(&d)
	if sa.entries_hash == 0 {
		testing.expectf(t, false, "entries_hash is the zero value")
		return
	}
	if sa.entries_hash != sb.entries_hash || sa.entries_hash != sc.entries_hash {
		testing.expectf(t, false, "same entries hashed differently: %x/%x/%x",
			sa.entries_hash, sb.entries_hash, sc.entries_hash)
		return
	}
	if sa.entries_hash == sd.entries_hash {
		testing.expectf(t, false, "different dictionaries hashed equal: %x", sa.entries_hash)
		return
	}

	user := []moli.User_Entry{{surface = "犬助", pos = "名詞,固有名詞", lemma = "犬助", reading = "ケンスケ"}}
	if uerr := moli.add_user_entries(&a, user[:]); uerr != nil {
		testing.expectf(t, false, "add_user_entries: %v", uerr)
		return
	}
	sa2, _ := moli.stats(&a)
	if sa2.entries_hash == sa.entries_hash {
		testing.expectf(t, false, "merge did not change entries_hash: %x", sa.entries_hash)
		return
	}
	// The post-merge analyzer still resolves its own ids coherently.
	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	ms, err := moli.tokenize(&a, "犬助が歩く", mem.arena_allocator(&arena))
	if err != nil { testing.expectf(t, false, "tokenize: %v", err); return }
	if !expect_entry_ids_resolve(t, &a, ms) { return }
}
