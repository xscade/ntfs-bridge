// Command init is PID 1 of the NTFS Bridge microVM. It loads the kernel modules
// it needs, then serves file-system requests from the macOS host over vsock.
package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

const (
	version   = "ntfsbridge-guest 3"
	vsockPort = 7000
	nbdPort   = 7001
	device    = "/dev/nbd0"
	maxBody   = 64 << 20
)

var modules = []string{
	"nbd", "vsock", "vmw_vsock_virtio_transport_common",
	"vmw_vsock_virtio_transport", "nls_utf8", "ntfs3", "fuse",
}

func logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "guest: "+format+"\n", args...)
}

func main() {
	if err := setup(); err != nil {
		logf("setup failed: %v", err)
		poweroff()
	}
	if err := serve(); err != nil {
		logf("serve: %v", err)
	}
	poweroff()
}

func setup() error {
	for _, m := range []struct{ src, dst, fs string }{
		{"devtmpfs", "/dev", "devtmpfs"}, {"proc", "/proc", "proc"}, {"sysfs", "/sys", "sysfs"},
	} {
		os.MkdirAll(m.dst, 0o755)
		if err := unix.Mount(m.src, m.dst, m.fs, 0, ""); err != nil && err != unix.EBUSY {
			return fmt.Errorf("mount %s: %w", m.dst, err)
		}
	}
	release := uname()
	for _, name := range modules {
		if err := loadModule(release, name); err != nil {
			return fmt.Errorf("module %s: %w", name, err)
		}
	}
	return attachDisk()
}

func listenVsock(port uint32) (int, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	if err := unix.Bind(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: port}); err != nil {
		return -1, err
	}
	if err := unix.Listen(fd, 1); err != nil {
		return -1, err
	}
	return fd, nil
}

func acceptOne(port uint32) (int, error) {
	lfd, err := listenVsock(port)
	if err != nil {
		return -1, err
	}
	defer unix.Close(lfd)
	cfd, _, err := unix.Accept(lfd)
	return cfd, err
}

func uname() string {
	var u unix.Utsname
	unix.Uname(&u)
	return unix.ByteSliceToString(u.Release[:])
}

func loadModule(release, name string) error {
	path, err := findModule(release, name)
	if err != nil {
		return err
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	image, err := io.ReadAll(zr)
	if err != nil {
		return err
	}
	if err := unix.InitModule(image, ""); err != nil && err != unix.EEXIST {
		return err
	}
	return nil
}

func findModule(release, name string) (string, error) {
	dir := "/lib/modules/" + release
	f, err := os.Open(dir + "/modules.dep")
	if err != nil {
		return "", err
	}
	defer f.Close()
	want := "/" + name + ".ko.gz:"
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if i := strings.Index(line, want); i >= 0 {
			return dir + "/" + line[:i+len(want)-1], nil
		}
	}
	return "", fmt.Errorf("not in modules.dep")
}

func poweroff() {
	unix.Sync()
	unix.Reboot(unix.LINUX_REBOOT_CMD_POWER_OFF)
	select {}
}

func serve() error {
	cfd, err := acceptOne(vsockPort)
	if err != nil {
		return err
	}
	conn := os.NewFile(uintptr(cfd), "vsock")
	return session(conn)
}

var unmounted atomic.Bool

func session(conn *os.File) error {
	in := bufio.NewReaderSize(conn, 1<<20)
	var wmu sync.Mutex
	var wg sync.WaitGroup
	var head [13]byte
	for {
		if _, err := io.ReadFull(in, head[:]); err != nil {
			wg.Wait()
			if unmounted.Load() {
				poweroff()
			}
			if err == io.EOF {
				return nil
			}
			return err
		}
		n := binary.LittleEndian.Uint32(head[0:4])
		id := binary.LittleEndian.Uint64(head[4:12])
		op := head[12]
		if n > maxBody {
			return fmt.Errorf("request body %d exceeds limit", n)
		}
		body := make([]byte, n)
		if _, err := io.ReadFull(in, body); err != nil {
			return err
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			out, errno, detail := dispatch(op, &reader{b: body})
			if errno != 0 {
				var e writer
				e.str(detail)
				out = e.b
			}
			var w writer
			w.u32(uint32(len(out)))
			w.u64(id)
			w.i32(int32(errno))
			w.b = append(w.b, out...)
			wmu.Lock()
			conn.Write(w.b)
			wmu.Unlock()
			if op == opUnmount && errno == 0 {
				// The host half-closes after reading this reply; power off then,
				// or after a grace period if it never does.
				unmounted.Store(true)
				time.AfterFunc(3*time.Second, poweroff)
			}
		}()
	}
}

func runTool(args ...string) (int, string) {
	var out bytes.Buffer
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stdout, cmd.Stderr = &out, &out
	cmd.Env = []string{"LD_LIBRARY_PATH=/usr/lib:/lib"}
	err := cmd.Run()
	if cmd.ProcessState == nil {
		return -1, err.Error()
	}
	return cmd.ProcessState.ExitCode(), out.String()
}
