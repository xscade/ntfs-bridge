package main

import (
	"encoding/binary"
	"errors"
	"golang.org/x/sys/unix"
)

var errShort = errors.New("short request")

type reader struct {
	b   []byte
	err error
}

func (r *reader) take(n int) []byte {
	if r.err != nil || n < 0 || len(r.b) < n {
		r.err = errShort
		return make([]byte, max(n, 0))
	}
	v := r.b[:n]
	r.b = r.b[n:]
	return v
}

func (r *reader) u8() uint8   { return r.take(1)[0] }
func (r *reader) u32() uint32 { return binary.LittleEndian.Uint32(r.take(4)) }
func (r *reader) u64() uint64 { return binary.LittleEndian.Uint64(r.take(8)) }
func (r *reader) i64() int64  { return int64(r.u64()) }
func (r *reader) bytes() []byte {
	return r.take(int(r.u32()))
}
func (r *reader) str() string { return string(r.bytes()) }

type writer struct{ b []byte }

func (w *writer) u8(v uint8)   { w.b = append(w.b, v) }
func (w *writer) u32(v uint32) { w.b = binary.LittleEndian.AppendUint32(w.b, v) }
func (w *writer) i32(v int32)  { w.u32(uint32(v)) }
func (w *writer) u64(v uint64) { w.b = binary.LittleEndian.AppendUint64(w.b, v) }
func (w *writer) i64(v int64)  { w.u64(uint64(v)) }
func (w *writer) bytes(v []byte) {
	w.u32(uint32(len(v)))
	w.b = append(w.b, v...)
}
func (w *writer) str(v string) { w.bytes([]byte(v)) }

func nsOf(t unix.StatxTimestamp) int64 { return t.Sec*1e9 + int64(t.Nsec) }

func (w *writer) attr(st *unix.Statx_t) {
	w.u64(st.Ino)
	w.u32(uint32(st.Mode))
	w.u32(st.Nlink)
	w.u32(st.Uid)
	w.u32(st.Gid)
	w.u64(st.Size)
	w.u64(st.Blocks * 512)
	w.i64(nsOf(st.Atime))
	w.i64(nsOf(st.Mtime))
	w.i64(nsOf(st.Ctime))
	if st.Mask&unix.STATX_BTIME != 0 {
		w.i64(nsOf(st.Btime))
	} else {
		w.i64(nsOf(st.Mtime))
	}
}

func (w *writer) statfs(s *unix.Statfs_t) {
	w.u64(uint64(s.Bsize))
	w.u64(s.Blocks)
	w.u64(s.Bfree)
	w.u64(s.Bavail)
	w.u64(s.Files)
	w.u64(s.Ffree)
	w.u32(uint32(s.Namelen))
}
