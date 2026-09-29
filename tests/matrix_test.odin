// Connection matrix coverage: matrix.def parse, dense lookup, default
// cost on missing/out-of-range pairs, i16 saturation.
package tests

import "base:runtime"
import "core:mem"
import "core:testing"
import "moli:moli"

@(test)
matrix_parse_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()

	write_tmp(t, "tmp/matrix_ok.def", "2 2\n0 0 100\n1 1 99999\n")

	imp: moli.Importer
	imp.allocator = allocator
	imp.unk_def = make([dynamic]moli.Unk_Rule, 0, 2, allocator)
	defer delete(imp.unk_def)
	mem.dynamic_arena_init(&imp.scratch)
	defer mem.dynamic_arena_destroy(&imp.scratch)

	err := moli.import_matrix_def(&imp, "tmp/matrix_ok.def", 0)
	if err != nil {
		testing.expectf(t, false, "parse ok file: %v", err)
		return
	}
	defer if imp.conn_matrix.n_left > 0 { delete(imp.conn_matrix.costs) }

	if imp.conn_matrix.n_left != 2 || imp.conn_matrix.n_right != 2 {
		testing.expectf(t, false, "header: %v x %v", imp.conn_matrix.n_left, imp.conn_matrix.n_right)
		return
	}
	// Explicit cells parse; 99999 saturates into i16 max.
	if imp.conn_matrix.costs[0] != 100 {
		testing.expectf(t, false, "cell 0,0: %v", imp.conn_matrix.costs[0])
		return
	}
	if imp.conn_matrix.costs[3] != 32767 {
		testing.expectf(t, false, "cell 1,1 saturation: %v", imp.conn_matrix.costs[3])
		return
	}
	// Missing cells keep the default cost.
	if imp.conn_matrix.costs[1] != moli.CONNECTION_DEFAULT_COST ||
	   imp.conn_matrix.costs[2] != moli.CONNECTION_DEFAULT_COST {
		testing.expectf(t, false, "default cells: %v, %v", imp.conn_matrix.costs[1], imp.conn_matrix.costs[2])
		return
	}

	// Malformed headers and out-of-range ids fail the load.
	write_tmp(t, "tmp/matrix_badhdr.def", "x y\n0 0 100\n")
	imp2: moli.Importer
	imp2.allocator = allocator
	imp2.unk_def = make([dynamic]moli.Unk_Rule, 0, 1, allocator)
	defer delete(imp2.unk_def)
	mem.dynamic_arena_init(&imp2.scratch)
	defer mem.dynamic_arena_destroy(&imp2.scratch)
	if err := moli.import_matrix_def(&imp2, "tmp/matrix_badhdr.def", 0); err == nil {
		testing.expectf(t, false, "malformed header must fail")
		return
	}

	write_tmp(t, "tmp/matrix_oor.def", "2 2\n5 0 100\n")
	if err := moli.import_matrix_def(&imp2, "tmp/matrix_oor.def", 0); err == nil {
		testing.expectf(t, false, "out-of-range id must fail")
		return
	}

	write_tmp(t, "tmp/matrix_nonnum.def", "2 2\n0 x 100\n")
	if err := moli.import_matrix_def(&imp2, "tmp/matrix_nonnum.def", 0); err == nil {
		testing.expectf(t, false, "non-numeric id must fail")
		return
	}
}

@(test)
matrix_dense_lookup_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	costs, merr := make([dynamic]i16, 4, allocator)
	if merr != nil {
		testing.expectf(t, false, "make: %v", merr)
		return
	}
	defer delete(costs)
	costs[0] = 10
	costs[1] = 20
	costs[2] = 30
	costs[3] = 40

	m := moli.Connection_Matrix{costs = costs, n_left = 2, n_right = 2}

	// Dense row-major lookup: costs[left * n_right + right].
	if got := moli.matrix_cost(&m, 0, 0); got != 10 {
		testing.expectf(t, false, "(0,0): %v", got)
		return
	}
	if got := moli.matrix_cost(&m, 0, 1); got != 20 {
		testing.expectf(t, false, "(0,1): %v", got)
		return
	}
	if got := moli.matrix_cost(&m, 1, 0); got != 30 {
		testing.expectf(t, false, "(1,0): %v", got)
		return
	}
	if got := moli.matrix_cost(&m, 1, 1); got != 40 {
		testing.expectf(t, false, "(1,1): %v", got)
		return
	}
}

@(test)
matrix_default_and_saturation_test :: proc(t: ^testing.T) {
	// The no-matrix analyzer answers the default everywhere.
	zero := moli.Connection_Matrix{}
	if got := moli.matrix_cost(&zero, 0, 0); got != moli.CONNECTION_DEFAULT_COST {
		testing.expectf(t, false, "no matrix: %v", got)
		return
	}
	if got := moli.matrix_cost(&zero, 3, 7); got != moli.CONNECTION_DEFAULT_COST {
		testing.expectf(t, false, "no matrix (3,7): %v", got)
		return
	}
	if got := moli.matrix_cost(nil, 0, 0); got != moli.CONNECTION_DEFAULT_COST {
		testing.expectf(t, false, "nil matrix: %v", got)
		return
	}

	// Out-of-range pairs degrade to the default, never index out of
	// bounds.
	allocator := runtime.default_allocator()
	costs, merr := make([dynamic]i16, 1, allocator)
	if merr != nil {
		testing.expectf(t, false, "make: %v", merr)
		return
	}
	defer delete(costs)
	costs[0] = -5
	m := moli.Connection_Matrix{costs = costs, n_left = 1, n_right = 1}
	bad_pairs := [][2]i16{{-1, 0}, {0, -1}, {1, 0}, {0, 1}, {99, 99}, {-32768, 0}}
	for pair in bad_pairs {
		if got := moli.matrix_cost(&m, pair[0], pair[1]); got != moli.CONNECTION_DEFAULT_COST {
			testing.expectf(t, false, "out-of-range (%v,%v): %v", pair[0], pair[1], got)
			return
		}
	}
	if got := moli.matrix_cost(&m, 0, 0); got != -5 {
		testing.expectf(t, false, "in-range (0,0): %v", got)
		return
	}
}

// A header naming exactly one zero dimension is malformed: the
// snapshot validator rejects such a matrix on reload (it would imply a
// cost section with no cells), so the import refuses it too - the two
// validators agree.
@(test)
matrix_zero_one_dimension_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	headers := []string{"0 5\n", "5 0\n"}
	for header in headers {
		write_tmp(t, "tmp/matrix_zodo.def", header)
		imp: moli.Importer
		imp.allocator = allocator
		imp.unk_def = make([dynamic]moli.Unk_Rule, 0, 1, allocator)
		mem.dynamic_arena_init(&imp.scratch)
		err := moli.import_matrix_def(&imp, "tmp/matrix_zodo.def", 0)
		delete(imp.unk_def)
		mem.dynamic_arena_destroy(&imp.scratch)
		testing.expectf(t, err == moli.Load_Fault.Invalid_Format,
			"header %q must be rejected, got %v", header, err)
	}
}
