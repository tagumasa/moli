// cedar_build OOM regression: every builder allocation
// failure must surface as Load_Fault.OutOfMemory — never a dropped -1
// child index or an unchecked array append that lets place_node write
// out of bounds. The no-resize allocator lets fresh allocations
// through (maps, exact-capacity makes) and fails only growth, which
// makes grow_arrays the first fallible builder step; a growth failure
// answered anywhere but by tearing down and returning .OutOfMemory
// would write b.cedar.check[t] past the un-grown arrays. The
// make sweep below covers the fresh-allocation failures the no-resize
// allocator cannot reach.
package tests

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import "moli:moli"

@(test)
cedar_build_oom_test :: proc(t: ^testing.T) {
	nr := No_Resize_Allocator{backing = runtime.default_allocator()}
	allocator := mem.Allocator{data = &nr, procedure = no_resize_proc}

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)

	words := []string{"Haus", "Museum", "Haustür"}
	entries := make([dynamic]moli.Dictionary_Entry, 0, len(words), allocator)
	defer {
		for _, i in entries {
			e := entries[i]
			moli.dictionary_entry_destroy(&e, allocator)
		}
		delete(entries)
	}
	for w in words {
		append(&entries, moli.Dictionary_Entry{
			surface          = strings.clone(w, allocator),
			joined_pos       = strings.clone("NOUN", allocator),
			lemma            = strings.clone(w, allocator),
			reading          = strings.clone("*", allocator),
			reading_jyutping = strings.clone("*", allocator),
		})
	}

	cedar: moli.Cedar
	builder: moli.Cedar_Builder
	builder.cedar = &cedar
	builder.allocator = allocator
	builder.scratch_allocator = mem.dynamic_arena_allocator(&scratch)
	builder.entries = entries[:]

	err := moli.cedar_build(&builder)
	testing.expectf(t, err == moli.Load_Fault.OutOfMemory,
		"builder allocation failure must surface as .OutOfMemory, got %v", err)

	// The caller owns the partial state; release it through the same
	// allocator (the error path is under the zero-leak discipline too).
	// A bare delete on a nil [dynamic] no-ops, and a partially filled
	// inverse (made, first append failed) still frees its backing.
	delete(cedar.base)
	delete(cedar.check)
	delete(cedar.terminals)
	delete(cedar.group_count)
	delete(builder.char_map.forward)
	delete(builder.char_map.inverse)
}

// A fresh-allocation failure inside cedar_build (the makes themselves,
// not growth) must surface as .OutOfMemory: before the fix the same
// failures reached the sentinel writes as out-of-bounds panics. A
// budget sweep starves every allocation point of a small build in
// turn; each iteration releases whatever the builder left behind
// through the same (still-living) allocator, so the leak gate polices
// both the failure legs and the release.
@(test)
cedar_build_make_oom_test :: proc(t: ^testing.T) {
	entries := make([dynamic]moli.Dictionary_Entry, 0, 3, runtime.default_allocator())
	defer {
		for _, i in entries {
			e := entries[i]
			moli.dictionary_entry_destroy(&e, runtime.default_allocator())
		}
		delete(entries)
	}
	words := []string{"Haus", "Museum", "Haustür"}
	for w in words {
		append(&entries, moli.Dictionary_Entry{
			surface          = strings.clone(w, runtime.default_allocator()),
			joined_pos       = strings.clone("NOUN", runtime.default_allocator()),
			lemma            = strings.clone(w, runtime.default_allocator()),
			reading          = strings.clone("*", runtime.default_allocator()),
			reading_jyutping = strings.clone("*", runtime.default_allocator()),
		})
	}

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)

	saw_oom := false
	loaded := false
	for budget in 0 ..< 12 {
		b := Budget_Allocator{backing = context.allocator, remaining = budget}
		allocator := mem.Allocator{data = &b, procedure = budget_allocator_proc}

		cedar: moli.Cedar
		builder: moli.Cedar_Builder
		builder.cedar = &cedar
		builder.allocator = allocator
		builder.scratch_allocator = mem.dynamic_arena_allocator(&scratch)
		builder.entries = entries[:]

		err := moli.cedar_build(&builder)
		if err == nil {
			loaded = true
		} else {
			testing.expectf(t, err == moli.Load_Fault.OutOfMemory,
				"budget %d: cedar_build must fail with .OutOfMemory, got %v", budget, err)
			saw_oom = true
		}
		delete(cedar.base)
		delete(cedar.check)
		delete(cedar.terminals)
		delete(cedar.group_count)
		delete(builder.char_map.forward)
		delete(builder.char_map.inverse)
		delete(builder.char_map.bmp, allocator)
	}
	testing.expectf(t, saw_oom && loaded,
		"the sweep must cover both failure and success (oom=%v loaded=%v)", saw_oom, loaded)
}
