// Locale classification coverage: GB/US spelling heuristics and
// CN/TW/HK traditional-block heuristics.
package tests

import "core:testing"
import "moli:moli"

@(test)
locale_gb_us_test :: proc(t: ^testing.T) {
	a := moli.Analyzer{lang = .EnglishGB}
	us := moli.Analyzer{lang = .EnglishUS}

	if got := moli.classify_locale(&a, "the colour of defence"); got != .GB {
		testing.expectf(t, false, "gb text: got %v", got)
		return
	}
	if got := moli.classify_locale(&us, "the color of defense at the center"); got != .US {
		testing.expectf(t, false, "us text: got %v", got)
		return
	}
	if got := moli.classify_locale(&a, "the cat sat on the mat"); got != .None {
		testing.expectf(t, false, "neutral text: got %v", got)
		return
	}
	// Equal hits on both sides are ambiguous.
	if got := moli.classify_locale(&a, "colour and color"); got != .None {
		testing.expectf(t, false, "tied text: got %v", got)
		return
	}
}

@(test)
locale_cn_tw_hk_test :: proc(t: ^testing.T) {
	a := moli.Analyzer{lang = .ChineseCN}

	// A Bopomofo rune is the traditional-script marker: TW. ㆠ is in
	// the Bopomofo Extended block (U+31A0-U+31BF).
	if got := moli.classify_locale(&a, "ㄅㄆㄇ注音符號"); got != .TW {
		testing.expectf(t, false, "bopomofo text: got %v", got)
		return
	}
	if got := moli.classify_locale(&a, "ㆠㄝㄧ"); got != .TW {
		testing.expectf(t, false, "bopomofo extended text: got %v", got)
		return
	}
	// Plain Han text without a marker is genuinely ambiguous between
	// CN, TW, and HK: .None, never a guess.
	if got := moli.classify_locale(&a, "武汉市"); got != .None {
		testing.expectf(t, false, "markerless text: got %v", got)
		return
	}
	if got := moli.classify_locale(&a, ""); got != .None {
		testing.expectf(t, false, "empty text: got %v", got)
		return
	}

	// Japanese analyzers answer .None outright.
	jp := moli.Analyzer{lang = .Japanese}
	if got := moli.classify_locale(&jp, "犬が歩く"); got != .None {
		testing.expectf(t, false, "japanese text: got %v", got)
		return
	}
}

// The trailing returns behind the full switches are the corrupt-enum
// contract: an unchecked Language value answers .None, never a panic.
@(test)
locale_invalid_enum_test :: proc(t: ^testing.T) {
	bad_lang := cast(moli.Language)(0x7F)
	a := moli.Analyzer{lang = bad_lang}
	if got := moli.classify_locale(&a, "anything"); got != moli.Locale.None {
		testing.expectf(t, false, "classify_locale(cast): got %v", got)
		return
	}
	if got := moli.dict_locale_for(bad_lang); got != moli.Locale.None {
		testing.expectf(t, false, "dict_locale_for(cast): got %v", got)
		return
	}
}
