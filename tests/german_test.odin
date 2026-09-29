// German scaffold coverage: the fixture loads through the ipadic
// 13-column schema, both modes tokenize German sentences, compounds
// resolve whole when registered, capital sharp S and typographic
// quotes classify, the fallback POS applies, and the qdct round-trip
// carries the language.
package tests

import "base:runtime"
import "core:mem"
import "core:testing"
import "moli:moli"

GERMAN_FIXTURE :: "tests/fixtures/german_sample.csv"

@(test)
german_classify_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	table, terr := moli.char_class_build(.German, nil, false, allocator)
	if terr != nil {
		testing.expectf(t, false, "char_class_build: %v", terr)
		return
	}
	defer if table.ranges != nil { delete(table.ranges) }

	if cls := moli.char_class_of(&table, 'ß'); cls != .ASCIILetter {
		testing.expectf(t, false, "ß classifies ASCIILetter, got %v", cls)
		return
	}
	if cls := moli.char_class_of(&table, rune(0x1E9E)); cls != .ASCIILetter {
		testing.expectf(t, false, "capital sharp S classifies ASCIILetter, got %v", cls)
		return
	}
	if cls := moli.char_class_of(&table, rune(0x201E)); cls != .Punct {
		testing.expectf(t, false, "German low quote classifies Punct, got %v", cls)
		return
	}
}

@(test)
german_tokenize_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .German, GERMAN_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	ms, err := moli.tokenize(&a, "der Arbeitsplatz ist schnell", arena_alloc)
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	// der | sp | Arbeitsplatz | sp | ist | sp | schnell
	if len(ms) != 7 {
		testing.expectf(t, false, "want 7 morphemes (spaces are unknowns), got %d", len(ms))
		return
	}
	testing.expectf(t, ms[2].surface == "Arbeitsplatz" && ms[2].lemma == "Arbeitsplatz" && !ms[2].is_unknown,
		"registered compound stays whole: (%s, %s, unknown=%v)", ms[2].surface, ms[2].lemma, ms[2].is_unknown)
	testing.expectf(t, ms[6].surface == "schnell" && ms[6].lemma == "schnell", "ADV lemma carries")
	testing.expectf(t, ms[1].is_unknown && ms[1].surface == " ", "inter-word space is its own unknown")

	// Compound with a registered head: the dictionary match at
	// position 0 (invoke off) means the lattice offers only
	// "Großstadt" there, and the unregistered tail answers as one
	// unknown carrying the German fallback POS - the
	// dictionary-part + unknown-tail shape the trial builds on.
	mem.arena_free_all(&arena)
	ms2, err2 := moli.tokenize(&a, "Großstadtbahnhof", arena_alloc)
	if err2 != nil {
		testing.expectf(t, false, "tokenize compound: %v", err2)
		return
	}
	if len(ms2) != 2 || ms2[0].surface != "Großstadt" || ms2[0].is_unknown {
		testing.expectf(t, false, "registered head splits off, got %d morphemes", len(ms2))
		return
	}
	testing.expectf(t, ms2[1].is_unknown && ms2[1].surface == "bahnhof" && ms2[1].pos == "NOUN",
		"unknown tail carries the fallback POS: (%s, %s)", ms2[1].surface, ms2[1].pos)
}

@(test)
german_qdct_roundtrip_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .German, GERMAN_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	b, ok2 := qdct_roundtrip_restore(t, &a, "tmp/german_a.qdct",
		mem.dynamic_arena_allocator(&scratch), context.allocator)
	if !ok2 { return }
	defer moli.free(&b)

	// Each tokenization through its own arena (expect_analyses_equal):
	// a shared arena reset between the two calls would alias the
	// compared slices and turn the equality into a comparison of
	// memory with itself.
	if !expect_analyses_equal(t, &a, &b, []string{"der Arbeitsplatz"}) { return }
}
