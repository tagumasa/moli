#+build linux, darwin

// The mapped-snapshot edge of the qdct loader. Only this file (and its
// Windows twin) touches the platform mapping API; everything else in
// the package sees one shared rebuild ladder. On these platforms the
// snapshot is mapped with mmap (PROT_READ, MAP_PRIVATE) through the
// POSIX bindings — the analyzer never writes snapshot pages, so a
// private read-only mapping both documents and enforces that.
package moli

import "core:c"
import "core:mem"
import "core:strings"
import "core:sys/posix"

// qdct_map_file maps the snapshot at path read-only. The returned view
// is a private mapping owned by the caller until qdct_unmap releases
// it; mapped is true whenever the image is a mapping. An absent path
// answers .File_Not_Found (the same treatment load_qdct gives every
// open failure); an empty or short file, and one the kernel refuses to
// map, answer .Invalid_Format; ENOMEM answers .OutOfMemory.
qdct_map_file :: proc(path: string, allocator: mem.Allocator) -> (data: []u8, mapped: bool, err: Load_Err) {
	cs, cerr := strings.clone_to_cstring(path, allocator)
	if cerr != nil { return nil, false, .OutOfMemory }
	defer delete(cs, allocator)

	// CLOEXEC keeps the fd out of forked/exec'd children for its
	// short life. open, fstat, and mmap all retry on EINTR - a
	// signal landing mid-load must not read as "file not found" or
	// a corrupt image.
	fd := posix.open(cs, {.CLOEXEC})
	for cast(c.int)fd < 0 && posix.get_errno() == .EINTR {
		fd = posix.open(cs, {.CLOEXEC})
	}
	if cast(c.int)fd < 0 { return nil, false, .File_Not_Found }

	st: posix.stat_t
	fs := posix.fstat(fd, &st)
	for fs == .FAIL && posix.get_errno() == .EINTR { fs = posix.fstat(fd, &st) }
	if fs != .OK {
		posix.close(fd)
		return nil, false, .Invalid_Format
	}
	size := st.st_size
	if cast(i64)size < i64(QDCT_HEADER_SIZE + QDCT_SECTION_TABLE_SIZE) {
		posix.close(fd)
		return nil, false, .Invalid_Format
	}

	p := posix.mmap(nil, cast(c.size_t)size, {.READ}, {.PRIVATE}, fd)
	for p == posix.MAP_FAILED && posix.get_errno() == .EINTR {
		p = posix.mmap(nil, cast(c.size_t)size, {.READ}, {.PRIVATE}, fd)
	}
	if p == posix.MAP_FAILED {
		oom := posix.get_errno() == .ENOMEM
		posix.close(fd)
		if oom { return nil, false, .OutOfMemory }
		return nil, false, .Invalid_Format
	}
	// A file truncated between fstat and mmap maps pages past the new
	// end; touching those would SIGBUS, so the size is re-checked under
	// the mapping before it is trusted.
	st2: posix.stat_t
	fs2 := posix.fstat(fd, &st2)
	for fs2 == .FAIL && posix.get_errno() == .EINTR { fs2 = posix.fstat(fd, &st2) }
	if fs2 != .OK || st2.st_size != size {
		posix.munmap(p, cast(c.size_t)size)
		posix.close(fd)
		return nil, false, .Invalid_Format
	}
	posix.close(fd)
	return mem.slice_ptr(cast(^u8)p, int(size)), true, nil
}

// qdct_unmap releases a mapping taken by qdct_map_file. Called only on
// the teardown path, where a munmap failure has nothing left to do.
qdct_unmap :: proc(data: []u8) {
	if len(data) == 0 { return }
	posix.munmap(&data[0], len(data))
}
