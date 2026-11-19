package main

import (
	"fmt"
	"io"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// Linux NBD ioctls (include/uapi/linux/nbd.h) and transmission flags.
const (
	nbdSetSock       = 0xab00
	nbdSetBlksize    = 0xab01
	nbdDoIt          = 0xab03
	nbdClearSock     = 0xab04
	nbdSetSizeBlocks = 0xab07
	nbdDisconnect    = 0xab08
	nbdSetTimeout    = 0xab09
	nbdSetFlags      = 0xab0a

	nbdFlagHasFlags  = 1 << 0
	nbdFlagReadOnly  = 1 << 1
	nbdFlagSendFlush = 1 << 2
)

var nbdFd = -1

// diskParams reads the geometry the host passes on the kernel command line:
// ntfsb.size=<bytes> ntfsb.bs=<logical block size> ntfsb.ro=<0|1>.
func diskParams() (size, bs uint64, ro bool, err error) {
	raw, err := os.ReadFile("/proc/cmdline")
	if err != nil {
		return 0, 0, false, err
	}
	for _, f := range strings.Fields(string(raw)) {
		k, v, _ := strings.Cut(f, "=")
		switch k {
		case "ntfsb.size":
			size, err = strconv.ParseUint(v, 10, 64)
		case "ntfsb.bs":
			bs, err = strconv.ParseUint(v, 10, 64)
		case "ntfsb.ro":
			ro = v == "1"
		}
		if err != nil {
			return 0, 0, false, fmt.Errorf("%s: %w", k, err)
		}
	}
	if size == 0 || bs == 0 || size%bs != 0 {
		return 0, 0, false, fmt.Errorf("bad disk geometry size=%d bs=%d", size, bs)
	}
	return size, bs, ro, nil
}

// attachDisk turns the host's NBD connection on vsock into /dev/nbd0. The host
// side speaks only the NBD transmission phase, so no handshake is needed.
func attachDisk() error {
	size, bs, ro, err := diskParams()
	if err != nil {
		return err
	}
	host, err := acceptOne(nbdPort)
	if err != nil {
		return fmt.Errorf("nbd accept: %w", err)
	}
	// The kernel NBD client accepts only TCP or Unix sockets, so it gets one end
	// of a socketpair and the other end is relayed to the host over vsock.
	pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return err
	}
	sock := pair[0]
	relay(os.NewFile(uintptr(pair[1]), "nbd-relay"), os.NewFile(uintptr(host), "nbd-host"))
	fd, err := unix.Open(device, unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	flags := uint64(nbdFlagHasFlags | nbdFlagSendFlush)
	if ro {
		flags |= nbdFlagReadOnly
	}
	for _, c := range []struct {
		req uint
		arg uint64
	}{
		{nbdSetBlksize, bs}, {nbdSetSizeBlocks, size / bs}, {nbdSetTimeout, 0},
		{nbdSetFlags, flags}, {nbdSetSock, uint64(sock)},
	} {
		if _, _, e := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), uintptr(c.req), uintptr(c.arg)); e != 0 {
			return fmt.Errorf("nbd ioctl %#x: %w", c.req, e)
		}
	}
	nbdFd = fd
	go func() {
		runtime.LockOSThread()
		_, _, e := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), nbdDoIt, 0)
		logf("nbd transmission ended: %v", e)
	}()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		b, _ := os.ReadFile("/sys/block/nbd0/size")
		if s := strings.TrimSpace(string(b)); s != "" && s != "0" {
			tuneQueue()
			return nil
		}
		time.Sleep(10 * time.Millisecond)
	}
	return fmt.Errorf("nbd0 did not come up")
}

// detachDisk flushes every cached block to the host, then ends the NBD session.
func detachDisk() error {
	if nbdFd < 0 {
		return nil
	}
	unix.Sync()
	if err := unix.Fsync(nbdFd); err != nil {
		return fmt.Errorf("flush nbd0: %w", err)
	}
	unix.Syscall(unix.SYS_IOCTL, uintptr(nbdFd), nbdDisconnect, 0)
	unix.Syscall(unix.SYS_IOCTL, uintptr(nbdFd), nbdClearSock, 0)
	nbdFd = -1
	return nil
}

func relay(local, host *os.File) {
	go func() { io.CopyBuffer(host, local, make([]byte, 1<<20)) }()
	go func() { io.CopyBuffer(local, host, make([]byte, 1<<20)) }()
}

// tuneQueue raises read-ahead so sequential reads keep the next request in
// flight while the current one transfers; a USB 2.0 hard disk otherwise idles
// between requests. Values are KiB.
func tuneQueue() {
	for file, value := range map[string]string{
		"/sys/block/nbd0/queue/read_ahead_kb":  "4096",
		"/sys/block/nbd0/queue/max_sectors_kb": "1024",
	} {
		if err := os.WriteFile(file, []byte(value), 0); err != nil {
			logf("tune %s: %v", file, err)
		}
	}
}
