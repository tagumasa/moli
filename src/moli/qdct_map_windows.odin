#+build windows

// The Windows twin of the mapped-snapshot edge: this platform has no
// portable file mapping in core, and the MSVC-only toolchain means a
// MapViewOfFile arm cannot be verified until a Windows CI lane exists.
// load_qdct_mmap therefore takes a documented read-copy fallback here —
// identical validation and results, but the image is a heap buffer the
// analyzer owns (never marked mapped), so teardown deletes it.
package moli

import "core:mem"

qdct_map_file :: proc(path: string, allocator: mem.Allocator) -> (data: []u8, mapped: bool, err: Load_Err) {
	buf, rerr := qdct_read_file(path, allocator)
	if rerr != nil { return nil, false, rerr }
	return buf, false, nil
}

// qdct_unmap never runs on this platform: the fallback never marks the
// image mapped, so teardown deletes it as an owned buffer instead.
qdct_unmap :: proc(data: []u8) {}
