// DWDSmor Open Edition trial: load the
// converted German dictionary, tokenize with the default options and
// with unk_cost_per_rune - the search-time knob that prices an unknown
// by its length so OOV compounds can split (Haus|museum, Museum|s|platz
// via the Fugenlaute rows) while short OOV words (Demo) stay whole.
// The tracker is the allocator handed to the library (moli takes its
// allocator as an explicit parameter - installing a tracker on
// context alone routes nothing through it), so the closing leak count
// observes the analyzer's full lifecycle: load, tokenize, free, then
// zero live blocks. Numbers + short dictionary-derived surfaces only.
// Run from the repo root:
//   odin run bench/german_trial.odin -file -collection:moli=$(pwd)/src -o:speed
package german_trial

import "core:fmt"
import "core:mem"
import "core:time"
import "moli:moli"

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	tracked := mem.tracking_allocator(&track)

	t0 := time.tick_now()
	a, err := moli.load(.German, "dict/german/german.csv", {}, tracked)
	load_us := time.tick_diff(t0, time.tick_now()) / time.Microsecond
	if err != nil { fmt.printf("load FAILED: %v\n", err); return }
	fmt.printf("loaded in %v us: %v entries, unk rules %v, skipped %v\n",
		load_us, len(a.entries), len(a.unk_def), len(a.skipped_resources))

	arena_buf := make([]u8, 1 << 22, tracked)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)

	sentences := []string{
		"das Museum baut Häuser",
		"ein Haus steht da",
		"Hausmuseum",
		"Museumsplatz",
		"Arbeitsplatz",
		"Demo",
		"zum",
	}
	fmt.println("--- default options ---")
	tokenize_all(&a, &arena, sentences, {})
	fmt.println("--- unk_cost_per_rune = 2300 ---")
	tokenize_all(&a, &arena, sentences, {unk_cost_per_rune = 2300})
	fmt.printf("char_flags[ASCIILetter]: invoke=%v group=%v length=%v\n",
		a.char_flags[int(moli.Char_Class.ASCIILetter)].invoke,
		a.char_flags[int(moli.Char_Class.ASCIILetter)].group,
		a.char_flags[int(moli.Char_Class.ASCIILetter)].length)

	delete(arena_buf, tracked)
	moli.free(&a)

	// The lifecycle is complete: every tracked allocation must be
	// returned for the gate to pass.
	live := 0
	for _, entry in track.allocation_map {
		_ = entry
		live += 1
	}
	fmt.printf("leaks: %v\n", live)
}

tokenize_all :: proc(a: ^moli.Analyzer, arena: ^mem.Arena, sentences: []string, opts: moli.Tokenize_Options) {
	for s in sentences {
		mem.arena_free_all(arena)
		ms, terr := moli.tokenize_opt(a, s, opts, mem.arena_allocator(arena))
		if terr != nil {
			fmt.printf("tokenize FAILED: %v\n", terr)
			return
		}
		fmt.printf("%q -> %v:", s, len(ms))
		for m in ms {
			unk := ""
			if m.is_unknown { unk = "!" }
			fmt.printf(" |%s%s/%s", m.surface, unk, m.pos)
		}
		fmt.println()
	}
}
