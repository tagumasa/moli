// Unknown-word rule coverage: rule matching order, the class-name
// mapping from unk.def column 0 (both column layouts), and the
// locale-specific fallback POS.
package tests

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import "moli:moli"

@(test)
unk_rule_order_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()

	a: moli.Analyzer
	a.allocator = allocator
	a.unk_def = make([dynamic]moli.Unk_Rule, 0, 4, allocator)
	a.unknown_fallback_pos = strings.clone("名詞,普通名詞", allocator)
	defer {
		for _, i in a.unk_def {
			moli.unk_rule_destroy(&a.unk_def[i], allocator)
		}
		delete(a.unk_def)
		delete(a.unknown_fallback_pos, allocator)
	}

	append(&a.unk_def, moli.Unk_Rule{class = .Katakana, left_id = 1, right_id = 2, cost = 3000,
		joined_pos = strings.clone("名詞,一般", allocator)})
	// A later rule for the same class must never win.
	append(&a.unk_def, moli.Unk_Rule{class = .Katakana, cost = 5000,
		joined_pos = strings.clone("名詞,固有名詞", allocator)})
	append(&a.unk_def, moli.Unk_Rule{class = .Hiragana, cost = 2000,
		joined_pos = strings.clone("名詞,普通名詞", allocator)})

	// Declaration order: the first Katakana rule wins.
	pos, cost, left, right := moli.resolve_unk(&a, .Katakana, "アイウ")
	if pos != "名詞,一般" || cost != 3000 || left != 1 || right != 2 {
		testing.expectf(t, false, "katakana first rule: (%s, %v, %v, %v)", pos, cost, left, right)
		return
	}
	pos, cost, _, _ = moli.resolve_unk(&a, .Hiragana, "ひらがな")
	if pos != "名詞,普通名詞" || cost != 2000 {
		testing.expectf(t, false, "hiragana rule: (%s, %v)", pos, cost)
		return
	}
	// No matching rule: the analyzer's fallback POS with zero cost and
	// zero ids.
	pos, cost, left, right = moli.resolve_unk(&a, .Digit, "123")
	if pos != "名詞,普通名詞" || cost != 0 || left != 0 || right != 0 {
		testing.expectf(t, false, "fallback: (%s, %v, %v, %v)", pos, cost, left, right)
		return
	}
}

@(test)
unk_class_name_mapping_test :: proc(t: ^testing.T) {
	// Known char.def category names map onto the enum.
	known := []struct {
		name: string,
		cls:  moli.Char_Class,
	}{
		{name = "DEFAULT", cls = .Symbol},
		{name = "SPACE", cls = .Space},
		{name = "KANJI", cls = .Kanji},
		{name = "HIRAGANA", cls = .Hiragana},
		{name = "KATAKANA", cls = .Katakana},
		{name = "HALFWIDTH_KATAKANA", cls = .HalfwidthKatakana},
		{name = "CHINESE", cls = .Hanzi},
		{name = "BOPOMOFO", cls = .Bopomofo},
		{name = "ALPHA", cls = .ASCIILetter},
		{name = "NUMERIC", cls = .Digit},
		{name = "SYMBOL", cls = .Punct},
	}
	for k in known {
		cls, ok := moli.char_class_from_name(k.name)
		if !ok || cls != k.cls {
			testing.expectf(t, false, "%q: got (%v, %v)", k.name, cls, ok)
			return
		}
	}
	// Custom category names answer (.Unknown, false) - in unk.def that
	// fails the load, in char.def they map to .Unknown.
	if cls, ok := moli.char_class_from_name("私人用"); ok || cls != .Unknown {
		testing.expectf(t, false, "custom name: got (%v, %v)", cls, ok)
		return
	}

	// The unk.def reader accepts the real layout and rejects broken
	// rows and unknown class names.
	allocator := runtime.default_allocator()
	write_tmp(t, "tmp/unk_ok.def", "KATAKANA,1,1,4000,名詞,一般,*\n")

	imp: moli.Importer
	imp.allocator = allocator
	imp.unk_def = make([dynamic]moli.Unk_Rule, 0, 2, allocator)
	mem.dynamic_arena_init(&imp.scratch)
	defer mem.dynamic_arena_destroy(&imp.scratch)

	if err := moli.import_unk_def(&imp, "tmp/unk_ok.def"); err != nil {
		testing.expectf(t, false, "unk_ok: %v", err)
		return
	}
	defer {
		for _, i in imp.unk_def {
			moli.unk_rule_destroy(&imp.unk_def[i], allocator)
		}
		delete(imp.unk_def)
	}

	if len(imp.unk_def) != 1 {
		testing.expectf(t, false, "rules loaded: %v", len(imp.unk_def))
		return
	}
	// The layout is uniform across real dictionaries: ids directly
	// after the class name (ipadic 2.7.0, unidic-mecab 2.1.2, and
	// mecab-jieba 0.1.1 all ship it this way).
	r0 := imp.unk_def[0]
	if r0.class != .Katakana || r0.left_id != 1 || r0.right_id != 1 || r0.cost != 4000 || r0.joined_pos != "名詞,一般" {
		testing.expectf(t, false, "unidic-layout rule: %+v", r0)
		return
	}

	// A trailing-ids row is a broken dictionary (no real unk.def uses
	// that order) and must fail the load.
	write_tmp(t, "tmp/unk_trailing.def", "HIRAGANA,名詞,一般,*,*,*,0,0,5000\n")
	imp1: moli.Importer
	imp1.allocator = allocator
	imp1.unk_def = make([dynamic]moli.Unk_Rule, 0, 1, allocator)
	defer delete(imp1.unk_def)
	mem.dynamic_arena_init(&imp1.scratch)
	defer mem.dynamic_arena_destroy(&imp1.scratch)
	if err := moli.import_unk_def(&imp1, "tmp/unk_trailing.def"); err == nil {
		testing.expectf(t, false, "trailing-ids row must fail the load")
		return
	}

	// An unknown class name in unk.def is a broken dictionary.
	write_tmp(t, "tmp/unk_bad.def", "FOOBAR,1,1,4000,名詞,一般,*\n")
	imp2: moli.Importer
	imp2.allocator = allocator
	imp2.unk_def = make([dynamic]moli.Unk_Rule, 0, 1, allocator)
	defer delete(imp2.unk_def)
	mem.dynamic_arena_init(&imp2.scratch)
	defer mem.dynamic_arena_destroy(&imp2.scratch)
	if err := moli.import_unk_def(&imp2, "tmp/unk_bad.def"); err == nil {
		testing.expectf(t, false, "unknown class name must fail the load")
		return
	}
}

@(test)
unknown_fallback_pos_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()

	cases := []struct {
		lang: moli.Language,
		pos:  string,
	}{
		{lang = .Japanese, pos = "名詞,普通名詞"},
		{lang = .ChineseCN, pos = "n"},
		{lang = .ChineseTW, pos = "n"},
		{lang = .ChineseHK, pos = "n"},
		{lang = .EnglishGB, pos = "NOUN"},
		{lang = .EnglishUS, pos = "NOUN"},
	}
	for c in cases {
		pos, err := moli.fallback_pos(c.lang, allocator)
		if err != nil {
			testing.expectf(t, false, "%v: %v", c.lang, err)
			return
		}
		if pos != c.pos {
			testing.expectf(t, false, "%v: got %q, want %q", c.lang, pos, c.pos)
			delete(pos, allocator)
			return
		}
		delete(pos, allocator)
	}
}
