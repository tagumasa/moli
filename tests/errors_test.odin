// The error vocabulary's classification and canonical rendering: every
// fault member classifies through load_fault/save_fault, every failure
// renders to its pinned text, and the rendered string carries the
// documented ownership (delete(result, allocator) under the leak gate).
package tests

import "core:mem"
import "core:testing"
import "moli:moli"

// The plain faults classify to themselves.
@(test)
load_fault_classifier_test :: proc(t: ^testing.T) {
	faults := []moli.Load_Fault{.File_Not_Found, .Invalid_Format, .OutOfMemory, .Nil_Handle, .IO_Read}
	for f in faults {
		if got := moli.load_fault(moli.Load_Err(f)); got != f {
			testing.expectf(t, false, "load_fault(%v): %v", f, got)
			return
		}
	}
	// The schema-mismatch context is an Invalid_Format flavor.
	schema := moli.Schema_Mismatch_Error{line = 7, expected = 13, got = 9}
	if got := moli.load_fault(schema); got != .Invalid_Format {
		testing.expectf(t, false, "load_fault(schema): %v", got)
		return
	}
}

// Save faults classify to themselves (the union holds only the fault
// today; this pins the classifier for when a context member joins).
@(test)
save_fault_classifier_test :: proc(t: ^testing.T) {
	faults := []moli.Save_Fault{.IO_Write, .OutOfMemory, .Unavailable, .Format_Limit}
	for f in faults {
		if got := moli.save_fault(moli.Save_Err(f)); got != f {
			testing.expectf(t, false, "save_fault(%v): %v", f, got)
			return
		}
	}
}

// Every load failure renders to its canonical text - the single source
// of the wording that bindings translate instead of re-deriving.
@(test)
load_error_message_test :: proc(t: ^testing.T) {
	cases := []struct {
		err:  moli.Load_Err,
		want: string,
	}{
		{moli.Load_Fault.File_Not_Found, "file not found"},
		{moli.Load_Fault.Invalid_Format, "invalid format"},
		{moli.Load_Fault.OutOfMemory,    "out of memory"},
		{moli.Load_Fault.Nil_Handle,     "nil analyzer handle"},
		{moli.Load_Fault.IO_Read,        "read failed"},
		{moli.Schema_Mismatch_Error{line = 7, expected = 13, got = 9},
			"schema mismatch at line 7 (expected 13 columns, got 9)"},
	}
	for c in cases {
		msg := moli.load_error_message(c.err, context.allocator)
		if msg != c.want {
			testing.expectf(t, false, "load_error_message(%v): %q", c.err, msg)
			return
		}
		delete(msg, context.allocator)
	}
}

@(test)
tokenize_error_message_test :: proc(t: ^testing.T) {
	cases := []struct {
		err:  moli.Tokenize_Err,
		want: string,
	}{
		{moli.Tokenize_Fault.OutOfMemory,  "out of memory"},
		{moli.Tokenize_Fault.Unavailable,  "unavailable (free raced the call)"},
		{moli.Malformed_Input_Error{byte_offset = 12}, "malformed UTF-8 at byte offset 12"},
		{moli.Cancelled_Error{byte_offset = 3},        "cancelled at byte offset 3"},
		{moli.Bad_Constraint_Error{index = 1, start = 0, end = 6, reason = .Token_Overlap},
			"bad constraint 1: Token_Overlap (start 0, end 6)"},
		{moli.Unsatisfiable_Error{byte_offset = 9},    "constraints unsatisfiable at byte offset 9"},
	}
	for c in cases {
		msg := moli.tokenize_error_message(c.err, context.allocator)
		if msg != c.want {
			testing.expectf(t, false, "tokenize_error_message(%v): %q", c.err, msg)
			return
		}
		delete(msg, context.allocator)
	}
}

@(test)
save_error_message_test :: proc(t: ^testing.T) {
	cases := []struct {
		err:  moli.Save_Err,
		want: string,
	}{
		{moli.Save_Fault.IO_Write,     "write failed"},
		{moli.Save_Fault.OutOfMemory,  "out of memory"},
		{moli.Save_Fault.Unavailable,  "unavailable (free raced the call)"},
		{moli.Save_Fault.Format_Limit, "format limit exceeded"},
	}
	for c in cases {
		msg := moli.save_error_message(c.err, context.allocator)
		if msg != c.want {
			testing.expectf(t, false, "save_error_message(%v): %q", c.err, msg)
			return
		}
		delete(msg, context.allocator)
	}
}
