package main

import (
	"errors"
	"io"
	"os"
	"strings"
	"sync"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	opHello = iota + 1
	opMount
	opStatfs
	opGetattr
	opLookup
	opReaddir
	opRead
	opWrite
	opCreate
	opRemove
	opRename
	opSetattr
	opReadlink
	opSync
	opUnmount
	opMkfs
	opCheck
)

const mountPoint = "/mnt"

// paths maps every inode number the host has seen to its current path.
var paths = struct {
	sync.RWMutex
	m       map[uint64]string
	mounted bool
}{m: map[uint64]string{}}

type opError struct {
	errno  unix.Errno
	detail string
}

func (e *opError) Error() string { return e.detail }

func fail(errno unix.Errno, detail string) error { return &opError{errno, detail} }

func dispatch(op uint8, r *reader) (out []byte, errno unix.Errno, detail string) {
	var w writer
	err := handle(op, r, &w)
	if err == nil && r.err != nil {
		err = fail(unix.EINVAL, r.err.Error())
	}
	if err == nil {
		return w.b, 0, ""
	}
	var oe *opError
	var en unix.Errno
	switch {
	case errors.As(err, &oe):
		return nil, oe.errno, oe.detail
	case errors.As(err, &en):
		return nil, en, err.Error()
	default:
		return nil, unix.EIO, err.Error()
	}
}

func handle(op uint8, r *reader, w *writer) error {
	if !paths.mounted {
		switch op {
		case opHello, opMount, opMkfs, opCheck, opUnmount:
		default:
			return fail(unix.ENXIO, "volume is not mounted")
		}
	}
	switch op {
	case opHello:
		w.str(version)
	case opMount:
		return mount(r.u8() != 0, w)
	case opStatfs:
		var s unix.Statfs_t
		if err := unix.Statfs(mountPoint, &s); err != nil {
			return err
		}
		w.statfs(&s)
	case opGetattr:
		p, err := pathOf(r.u64())
		if err != nil {
			return err
		}
		return stat(p, w)
	case opLookup:
		p, err := child(r.u64(), r.str())
		if err != nil {
			return err
		}
		return stat(p, w)
	case opReaddir:
		return readdir(r.u64(), r.u64(), r.u32(), w)
	case opRead:
		return read(r.u64(), r.u64(), r.u32(), w)
	case opWrite:
		return write(r.u64(), r.u64(), r.bytes(), w)
	case opCreate:
		return create(r.u64(), r.str(), r.u8(), r.u32(), r.str(), w)
	case opRemove:
		return remove(r.u64(), r.str(), r.u8() != 0)
	case opRename:
		return rename(r.u64(), r.str(), r.u64(), r.str())
	case opSetattr:
		return setattr(r, w)
	case opReadlink:
		p, err := pathOf(r.u64())
		if err != nil {
			return err
		}
		target, err := os.Readlink(p)
		if err != nil {
			return err
		}
		w.str(target)
	case opSync:
		unix.Sync()
		if nbdFd >= 0 {
			return unix.Fsync(nbdFd)
		}
	case opUnmount:
		if paths.mounted {
			if err := unmountVolume(); err != nil {
				return err
			}
			paths.mounted = false
		}
		return detachDisk()
	case opMkfs:
		if paths.mounted {
			return fail(unix.EBUSY, "refusing to format a mounted volume")
		}
		code, out := runTool("/usr/sbin/mkntfs", "-F", "-Q", "-L", r.str(), device)
		if code != 0 {
			return fail(unix.EIO, out)
		}
		w.str(out)
	case opCheck:
		args := []string{"/usr/bin/ntfsfix", "-n", device}
		if r.u8() != 0 {
			if paths.mounted {
				return fail(unix.EBUSY, "refusing to repair a mounted volume")
			}
			// Repairs $MFTMirr and resets $LogFile. The volume stays marked
			// dirty so Windows runs chkdsk on its next start.
			args = []string{"/usr/bin/ntfsfix", device}
		}
		code, out := runTool(args...)
		w.i32(int32(code))
		w.str(out)
	default:
		return fail(unix.ENOSYS, "unknown op")
	}
	return nil
}

func mount(readOnly bool, w *writer) error {
	if paths.mounted {
		return fail(unix.EBUSY, "already mounted")
	}
	ro, driver, note, err := mountVolume(readOnly)
	if err != nil {
		return err
	}
	logf("mounted with %s readOnly=%v %s", driver, ro, note)
	paths.mounted = true
	w.u8(boolByte(ro))
	w.str(volumeLabel())
	w.str(note)
	if err := stat(mountPoint, w); err != nil {
		return err
	}
	var s unix.Statfs_t
	if err := unix.Statfs(mountPoint, &s); err != nil {
		return err
	}
	w.statfs(&s)
	return nil
}

func flags(readOnly bool) uintptr {
	f := uintptr(unix.MS_NOATIME | unix.MS_NODEV | unix.MS_NOSUID)
	if readOnly {
		f |= unix.MS_RDONLY
	}
	return f
}

func boolByte(b bool) uint8 {
	if b {
		return 1
	}
	return 0
}

// kernelReason returns the last ntfs3 line from the kernel log, which says why
// a mount failed (for example a dirty or hibernated volume).
func kernelReason() string {
	buf := make([]byte, 1<<16)
	n, err := unix.Klogctl(unix.SYSLOG_ACTION_READ_ALL, buf)
	if err != nil {
		return "unknown"
	}
	lines := strings.Split(string(buf[:n]), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if strings.Contains(lines[i], "ntfs3") {
			if j := strings.Index(lines[i], "ntfs3"); j >= 0 {
				return strings.TrimSpace(lines[i][j:])
			}
		}
	}
	return "unknown"
}

func volumeLabel() string {
	f, err := os.Open(mountPoint)
	if err != nil {
		return ""
	}
	defer f.Close()
	var label [256]byte
	const fsIocGetFsLabel = 0x81009431
	_, _, e := unix.Syscall(unix.SYS_IOCTL, f.Fd(), fsIocGetFsLabel, uintptr(unsafe.Pointer(&label[0])))
	if e != 0 {
		return ""
	}
	return unix.ByteSliceToString(label[:])
}

func pathOf(ino uint64) (string, error) {
	paths.RLock()
	p, ok := paths.m[ino]
	paths.RUnlock()
	if !ok {
		return "", fail(unix.ESTALE, "unknown inode")
	}
	return p, nil
}

func validName(name string) bool {
	return name != "" && name != "." && name != ".." && !strings.ContainsAny(name, "/\x00")
}

func child(parent uint64, name string) (string, error) {
	if !validName(name) {
		return "", fail(unix.EINVAL, "invalid name")
	}
	dir, err := pathOf(parent)
	if err != nil {
		return "", err
	}
	return dir + "/" + name, nil
}

func statx(p string) (*unix.Statx_t, error) {
	var st unix.Statx_t
	err := unix.Statx(unix.AT_FDCWD, p, unix.AT_SYMLINK_NOFOLLOW,
		unix.STATX_BASIC_STATS|unix.STATX_BTIME, &st)
	if err != nil {
		return nil, err
	}
	paths.Lock()
	paths.m[st.Ino] = p
	paths.Unlock()
	return &st, nil
}

func stat(p string, w *writer) error {
	st, err := statx(p)
	if err != nil {
		return err
	}
	w.attr(st)
	return nil
}

func readdir(ino, cookie uint64, max uint32, w *writer) error {
	dir, err := pathOf(ino)
	if err != nil {
		return err
	}
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	names, err := f.Readdirnames(-1)
	f.Close()
	if err != nil {
		return err
	}
	var entries writer
	n := uint32(0)
	i := cookie
	for ; i < uint64(len(names)) && n < max; i++ {
		st, err := statx(dir + "/" + names[i])
		if err != nil {
			continue
		}
		entries.str(names[i])
		entries.u64(i + 1)
		entries.attr(st)
		n++
	}
	w.u8(boolByte(i >= uint64(len(names))))
	w.u32(n)
	w.b = append(w.b, entries.b...)
	return nil
}

func read(ino, off uint64, length uint32, w *writer) error {
	p, err := pathOf(ino)
	if err != nil {
		return err
	}
	f, err := os.Open(p)
	if err != nil {
		return err
	}
	defer f.Close()
	buf := make([]byte, min(length, 8<<20))
	n, err := f.ReadAt(buf, int64(off))
	if err != nil && n == 0 && !errors.Is(err, io.EOF) {
		return err
	}
	w.bytes(buf[:n])
	return nil
}

func write(ino, off uint64, data []byte, w *writer) error {
	p, err := pathOf(ino)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(p, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	n, err := f.WriteAt(data, int64(off))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	w.u32(uint32(n))
	return nil
}

func create(parent uint64, name string, kind uint8, mode uint32, target string, w *writer) error {
	p, err := child(parent, name)
	if err != nil {
		return err
	}
	switch kind {
	case 1:
		fd, err := unix.Open(p, unix.O_CREAT|unix.O_EXCL|unix.O_WRONLY|unix.O_CLOEXEC, mode&0o7777)
		if err != nil {
			return err
		}
		unix.Close(fd)
	case 2:
		if err := unix.Mkdir(p, mode&0o7777); err != nil {
			return err
		}
	case 3:
		if err := unix.Symlink(target, p); err != nil {
			return err
		}
	default:
		return fail(unix.EINVAL, "unknown kind")
	}
	return stat(p, w)
}

func remove(parent uint64, name string, isDir bool) error {
	p, err := child(parent, name)
	if err != nil {
		return err
	}
	st, _ := statx(p)
	if isDir {
		err = unix.Rmdir(p)
	} else {
		err = unix.Unlink(p)
	}
	if err != nil {
		return err
	}
	if st != nil {
		paths.Lock()
		delete(paths.m, st.Ino)
		paths.Unlock()
	}
	return nil
}

func rename(srcParent uint64, srcName string, dstParent uint64, dstName string) error {
	src, err := child(srcParent, srcName)
	if err != nil {
		return err
	}
	dst, err := child(dstParent, dstName)
	if err != nil {
		return err
	}
	if err := unix.Rename(src, dst); err != nil {
		return err
	}
	paths.Lock()
	for ino, p := range paths.m {
		if p == dst {
			delete(paths.m, ino)
		}
	}
	for ino, p := range paths.m {
		if p == src {
			paths.m[ino] = dst
		} else if strings.HasPrefix(p, src+"/") {
			paths.m[ino] = dst + p[len(src):]
		}
	}
	paths.Unlock()
	return nil
}

func setattr(r *reader, w *writer) error {
	ino, mask, mode, uid, gid := r.u64(), r.u32(), r.u32(), r.u32(), r.u32()
	size, atime, mtime := r.u64(), r.i64(), r.i64()
	if r.err != nil {
		return fail(unix.EINVAL, r.err.Error())
	}
	p, err := pathOf(ino)
	if err != nil {
		return err
	}
	if mask&1 != 0 {
		if err := unix.Fchmodat(unix.AT_FDCWD, p, mode&0o7777, 0); err != nil {
			return err
		}
	}
	if mask&6 != 0 {
		u, g := -1, -1
		if mask&2 != 0 {
			u = int(uid)
		}
		if mask&4 != 0 {
			g = int(gid)
		}
		if err := unix.Lchown(p, u, g); err != nil && err != unix.EPERM {
			return err
		}
	}
	if mask&8 != 0 {
		if err := unix.Truncate(p, int64(size)); err != nil {
			return err
		}
	}
	if mask&48 != 0 {
		ts := []unix.Timespec{{Nsec: unix.UTIME_OMIT}, {Nsec: unix.UTIME_OMIT}}
		if mask&16 != 0 {
			ts[0] = unix.NsecToTimespec(atime)
		}
		if mask&32 != 0 {
			ts[1] = unix.NsecToTimespec(mtime)
		}
		if err := unix.UtimesNanoAt(unix.AT_FDCWD, p, ts, unix.AT_SYMLINK_NOFOLLOW); err != nil {
			return err
		}
	}
	return stat(p, w)
}
