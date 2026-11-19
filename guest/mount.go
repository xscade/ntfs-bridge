package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// Exit codes of ntfs-3g.probe (ntfs-3g's NTFS_VOLUME_* values).
const (
	probeOK         = 0
	probeCorrupt    = 13
	probeHibernated = 14
	probeUnclean    = 15
)

const ntfs3Opts = "iocharset=utf8,windows_names"

// fuseExited is closed when the lowntfs-3g process serving the mount exits; nil
// when ntfs3 serves the mount.
var fuseExited chan struct{}

// mountVolume mounts the NTFS volume at mountPoint and reports which driver and
// access mode won, plus a note explaining any downgrade.
//
// Order (read-write requests):
//  1. ntfs-3g.probe --readwrite. A hibernated volume (Windows Fast Startup) is
//     only ever mounted read-only: writing to it is lost or corrupts the volume
//     when Windows resumes. ntfs3 does not check for hibernation itself.
//  2. ntfs3 read-write. ntfs3 refuses volumes whose dirty flag is set.
//  3. lowntfs-3g read-write, which accepts an unclean (dirty) volume.
//  4. ntfs3 read-only, with the reasons from every attempt.
func mountVolume(readOnly bool) (ro bool, driver, note string, err error) {
	os.MkdirAll(mountPoint, 0o755)
	if readOnly {
		return true, "ntfs3", "", mountNTFS3(true)
	}

	code, probeOut := runTool("/usr/bin/ntfs-3g.probe", "--readwrite", device)
	logf("probe exit %d: %s", code, strings.TrimSpace(probeOut))
	if code == probeHibernated {
		note = "Windows hibernated this drive (Fast Startup). It is read-only so Windows can resume safely. " +
			"To write to it, start Windows and choose Shut Down while holding Shift, or turn off Fast Startup."
		return true, "ntfs3", note, mountNTFS3(true)
	}

	err3 := mountNTFS3(false)
	if err3 == nil {
		return false, "ntfs3", "", nil
	}
	reason3 := kernelReason()
	logf("ntfs3 rw refused: %v: %s; trying lowntfs-3g", err3, reason3)

	errFuse := mountLowNTFS3G()
	if errFuse == nil {
		note = "Mounted with ntfs-3g because ntfs3 refused: " + reason3
		if strings.Contains(reason3, "dirty") {
			note = "Windows marked this drive for a disk check, so it is open read & write with ntfs-3g. " +
				"Run chkdsk on it in Windows when convenient."
		}
		if code == probeUnclean {
			note = "Windows didn't shut down cleanly; mounted read & write with ntfs-3g."
		}
		return false, "ntfs-3g", note, nil
	}
	logf("lowntfs-3g refused: %v", errFuse)

	if err := mountNTFS3(true); err != nil {
		return true, "", "", fail(err.(unix.Errno), fmt.Sprintf("ntfs3: %s; ntfs-3g: %v", reason3, errFuse))
	}
	note = fmt.Sprintf("Read-only: ntfs3 refused read-write (%s) and ntfs-3g failed (%v).", reason3, errFuse)
	if code == probeCorrupt {
		note = "Read-only: the volume has errors. Run “chkdsk /f” on it in Windows, then reconnect it."
	}
	return true, "ntfs3", note, nil
}

func mountNTFS3(readOnly bool) error {
	return unix.Mount(device, mountPoint, "ntfs3", flags(readOnly), ntfs3Opts)
}

// mountLowNTFS3G starts lowntfs-3g in the foreground (no_detach) and waits for
// its mount to appear.
func mountLowNTFS3G() error {
	var out strings.Builder
	cmd := exec.Command("/usr/bin/lowntfs-3g", "-o", "windows_names,noatime,no_detach", device, mountPoint)
	cmd.Env = append(os.Environ(), "LD_LIBRARY_PATH=/usr/lib:/lib")
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		return err
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	for i := 0; i < 100; i++ {
		if isMounted(mountPoint) {
			done := make(chan struct{})
			fuseExited = done
			go func() {
				err := <-exited
				logf("lowntfs-3g exited: %v %s", err, strings.TrimSpace(out.String()))
				close(done)
			}()
			return nil
		}
		select {
		case err := <-exited:
			return fmt.Errorf("%v: %s", err, firstLines(out.String(), 2))
		case <-time.After(100 * time.Millisecond):
		}
	}
	cmd.Process.Kill()
	return fmt.Errorf("timed out: %s", firstLines(out.String(), 2))
}

// unmountVolume unmounts and, for ntfs-3g, waits for the driver to finish
// writing and exit before the disk is detached.
func unmountVolume() error {
	unix.Sync()
	if err := unix.Unmount(mountPoint, 0); err != nil {
		return err
	}
	if fuseExited != nil {
		select {
		case <-fuseExited:
		case <-time.After(60 * time.Second):
			return fail(unix.ETIMEDOUT, "ntfs-3g did not finish writing")
		}
		fuseExited = nil
	}
	return nil
}

func isMounted(path string) bool {
	data, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		if f := strings.Fields(line); len(f) > 1 && f[1] == path {
			return true
		}
	}
	return false
}

func firstLines(s string, n int) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.Join(lines, " ")
}
