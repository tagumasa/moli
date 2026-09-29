// Failure vocabularies: one closed type per boundary, propagated with
// explicit checks (if err != nil) — never or_return. Panic is reserved
// for startup invariant violations; nothing here is a catchable
// runtime lookup failure.
//
// The boundary types are nil-able plain unions: on this toolchain the
// shared_nil attribute rejects variants without a nil value (enums and
// structs), and there is no optional-type sugar. A plain union accepts
// nil as its no-failure state, a member value constructs it directly,
// and a type switch takes it apart.
package moli

import "core:fmt"
import "core:mem"
import "core:strings"

// Load_Fault is the plain failure enum of the load boundary.
Load_Fault :: enum {
	File_Not_Found, // a required file (the dictionary CSV) is absent
	Invalid_Format, // malformed CSV/unk.def/char.def/matrix.def, unclassifiable schema, bad numeric field, corrupt or unmappable snapshot image
	OutOfMemory,    // allocation failed during load
	Nil_Handle,     // a required ^Analyzer argument was nil - a caller bug surfaced as a fault instead of a dereference
	IO_Read,        // the file exists but could not be read (distinct from Invalid_Format: the read itself failed, the bytes were never seen)
}

// Schema_Mismatch_Error reports a CSV line whose column count differed
// from the detected schema. The load aborts: extra or missing columns
// are never silently ignored.
Schema_Mismatch_Error :: struct {
	line:     int, // 1-based line number in the CSV
	expected: int, // column count implied by the detected schema
	got:      int, // column count observed on the line
}

// Load_Err is the load-boundary failure type: the plain faults plus
// the one context-bearing failure. nil means success; distinguish the
// members by type in a switch.
Load_Err :: union {
	Load_Fault,
	Schema_Mismatch_Error,
}

// Tokenize_Fault is the plain failure enum of the tokenize boundary.
// OutOfMemory means the caller's arena is exhausted (retry with a
// larger one; the arena must still be destroyed normally). Unavailable
// means teardown began while the call was starting (retry on a
// different analyzer; nothing was written).
Tokenize_Fault :: enum {
	OutOfMemory,
	Unavailable,
}

// Malformed_Input_Error reports that strict input (Tokenize_Options.
// strict_utf8) rejected the text: byte_offset is the first invalid
// byte's position in the caller's original text. Nothing was written.
Malformed_Input_Error :: struct {
	byte_offset: int,
}

// Cancelled_Error reports that the call's cancel token fired:
// byte_offset is how far the analysis walk had reached when it
// noticed. Morphemes appended before the unwind stay written (there
// are none when the token fired before the call).
Cancelled_Error :: struct {
	byte_offset: int,
}

// Constraint_Reason is the closed vocabulary of constraint-set
// rejections, carried by Bad_Constraint_Error.
Constraint_Reason :: enum {
	Out_Of_Bounds,          // a token span or boundary offset outside [0, len(text)]
	Empty_Span,             // a token span with start >= end
	Not_Rune_Boundary,      // a span edge or boundary offset not on a UTF-8 rune start
	Token_Overlap,          // two token spans intersecting
	Boundary_Inside_Token,  // a boundary offset strictly inside a token span
	Boundary_At_Token_Edge, // a must-not-exist boundary at a token span edge the pin implies
	Conflicting_Boundaries, // must-exist and must-not-exist at one offset
	Bad_Pos_Pattern,        // a POS pattern with an empty column ("" is the any-pattern; ",x", "x,", "x,,y" are not)
	Normalization_Rescaled, // normalize_nfc changed the bytes the constraint offsets index
}

// Bad_Constraint_Error reports that a Constraints value was rejected
// before any analysis ran. index is the offending constraint's
// position in its own slice (tokens for the span reasons, boundaries
// for the boundary reasons), with start/end carrying that
// constraint's offsets (end -1 for a boundary). The two set-level
// faults carry index -1: Conflicting_Boundaries puts the shared
// offset in start, Normalization_Rescaled leaves both -1. Nothing
// was written.
Bad_Constraint_Error :: struct {
	index:  int,
	start:  int,
	end:    int,
	reason: Constraint_Reason,
}

// Unsatisfiable_Error reports that the constraint mask left the
// lattice without a complete path: no chain of allowed nodes reaches
// EOS. byte_offset is the first text position no live node ends at -
// the earliest position the constraints block. Nothing was written.
Unsatisfiable_Error :: struct {
	byte_offset: int,
}

// Tokenize_Err is the tokenize-boundary failure type: the plain
// faults plus the context-bearing mid-call failures. nil means
// success; distinguish the members by type in a switch.
Tokenize_Err :: union {
	Tokenize_Fault,
	Malformed_Input_Error,
	Cancelled_Error,
	Bad_Constraint_Error,
	Unsatisfiable_Error,
}

// Save_Fault is the plain failure enum of the qdct write boundary.
// IO_Write covers every file-write failure (create, write, flush);
// OutOfMemory covers the transient image build; Unavailable means
// teardown had begun (same contract as the tokenize family).
// Format_Limit means the analyzer's shape exceeds what the .qdct
// record forms can represent (blob size, extras window, alphabet) -
// the save refuses rather than silently narrowing a field the loader
// could not detect.
Save_Fault :: enum {
	IO_Write,
	OutOfMemory,
	Unavailable,
	Format_Limit,
}

// Save_Err wraps Save_Fault in a nil-able union matching the other
// boundaries' shape. The single-member union is deliberate: enums are
// not nil-able on their own, and a context-bearing save failure joins
// here later without touching call sites.
Save_Err :: union {
	Save_Fault,
}

// --- classification and canonical rendering -------------------------
// Every boundary failure collapses to one fault tag, and every failure
// renders to one canonical text. Bindings and logs translate or
// prefix these; they never re-derive the wording, so the library's
// error semantics exist in exactly one place. Each classifier takes a
// non-nil failure (callers check err != nil first); each renderer
// returns a fresh clone in the allocator - delete(result, allocator) - so the
// ownership contract is uniform across members. An allocation failure
// inside a renderer answers "" (error paths must not grow their own
// error paths). Tokenize has no classifier: its context members
// (Malformed_Input_Error, Cancelled_Error) are distinct outcomes, not
// context for a fault.

// load_fault classifies any load-boundary failure to its fault tag.
// The schema-mismatch context is an Invalid_Format flavor: the load
// aborted on malformed input.
load_fault :: proc(e: Load_Err) -> Load_Fault {
	switch v in e {
	case Load_Fault:            return v
	case Schema_Mismatch_Error: return .Invalid_Format
	}
	return .Invalid_Format // unreachable: the switch is total
}

// save_fault classifies any save-boundary failure to its fault tag.
// Today the union holds only the fault itself; the classifier exists
// so a context member joins without touching its callers.
save_fault :: proc(e: Save_Err) -> Save_Fault {
	switch v in e {
	case Save_Fault: return v
	}
	return .IO_Write // unreachable: the switch is total
}

// load_error_message renders the canonical text of a load-boundary
// failure (e must be non-nil). The operation prefix ("load: ") and
// call-site context (the path) belong to the reporting boundary.
load_error_message :: proc(e: Load_Err, allocator: mem.Allocator) -> string {
	b: strings.Builder
	strings.builder_init_len_cap(&b, 0, 64, allocator)
	defer strings.builder_destroy(&b)

	switch v in e {
	case Schema_Mismatch_Error:
		fmt.sbprintf(&b, "schema mismatch at line {} (expected {} columns, got {})",
			v.line, v.expected, v.got)
	case Load_Fault:
		switch v {
		case .File_Not_Found: fmt.sbprint(&b, "file not found")
		case .Invalid_Format: fmt.sbprint(&b, "invalid format")
		case .OutOfMemory:    fmt.sbprint(&b, "out of memory")
		case .Nil_Handle:     fmt.sbprint(&b, "nil analyzer handle")
		case .IO_Read:        fmt.sbprint(&b, "read failed")
		}
	}
	out, cerr := strings.clone(strings.to_string(b), allocator)
	if cerr != nil { return "" }
	return out
}

// tokenize_error_message renders the canonical text of a
// tokenize-boundary failure (e must be non-nil).
tokenize_error_message :: proc(e: Tokenize_Err, allocator: mem.Allocator) -> string {
	b: strings.Builder
	strings.builder_init_len_cap(&b, 0, 48, allocator)
	defer strings.builder_destroy(&b)

	switch v in e {
	case Malformed_Input_Error:
		fmt.sbprintf(&b, "malformed UTF-8 at byte offset {}", v.byte_offset)
	case Cancelled_Error:
		fmt.sbprintf(&b, "cancelled at byte offset {}", v.byte_offset)
	case Bad_Constraint_Error:
		fmt.sbprintf(&b, "bad constraint {}: {} (start {}, end {})", v.index, v.reason, v.start, v.end)
	case Unsatisfiable_Error:
		fmt.sbprintf(&b, "constraints unsatisfiable at byte offset {}", v.byte_offset)
	case Tokenize_Fault:
		switch v {
		case .OutOfMemory:  fmt.sbprint(&b, "out of memory")
		case .Unavailable:  fmt.sbprint(&b, "unavailable (free raced the call)")
		}
	}
	out, cerr := strings.clone(strings.to_string(b), allocator)
	if cerr != nil { return "" }
	return out
}

// save_error_message renders the canonical text of a save-boundary
// failure (e must be non-nil).
save_error_message :: proc(e: Save_Err, allocator: mem.Allocator) -> string {
	b: strings.Builder
	strings.builder_init_len_cap(&b, 0, 32, allocator)
	defer strings.builder_destroy(&b)

	switch save_fault(e) {
	case .IO_Write:     fmt.sbprint(&b, "write failed")
	case .OutOfMemory:  fmt.sbprint(&b, "out of memory")
	case .Unavailable:  fmt.sbprint(&b, "unavailable (free raced the call)")
	case .Format_Limit: fmt.sbprint(&b, "format limit exceeded")
	}
	out, cerr := strings.clone(strings.to_string(b), allocator)
	if cerr != nil { return "" }
	return out
}
