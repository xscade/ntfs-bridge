# Architecture

NTFS Bridge has four parts:

| Directory | What it is | Language |
|---|---|---|
| `app/App` | The menu bar app. It watches Disk Arbitration for NTFS partitions, mounts them, and shows their state. | Swift, SwiftUI |
| `app/Extension` | The FSKit file system extension. macOS loads it to mount an NTFS volume. | Swift |
| `host/Sources/NTFSBridgeCore` | Shared code that boots the Linux microVM, serves the disk to it, and talks to the guest agent. Compiled into the extension, and into the `ntfsb` command-line tool. | Swift |
| `guest` | The guest agent: PID 1 of the microVM. It mounts the volume with `ntfs3` or `ntfs-3g` and answers file requests. | Go |

Two developer tools sit beside them: `host/Sources/ntfsb` (a command-line client
for testing against disk images) and `probe` (lists FSKit modules and whether
they are enabled).

## Mounting a drive

1. Disk Arbitration reports a partition. FSKit asks the extension to **probe** it.
   `FileSystem.swift` reads the boot sector, checks for the `NTFS    ` OEM ID,
   reads the volume label from MFT record 3, and derives a stable UUID from the
   volume serial number.
2. FSKit asks the extension to **load** the volume. `Volume.swift` creates a
   `GuestVM`. Virtualization.framework boots the Linux kernel (`Image`) with the
   initrd (`initrd.gz`) that holds the guest agent, kernel modules and ntfs-3g.
3. The guest loads `nbd`, `vsock`, `ntfs3` and `fuse`, then attaches `/dev/nbd0`
   to the host's `NBDServer` on vsock port 7001. The kernel's NBD client only
   accepts TCP or Unix sockets, so the agent gives it one end of a socketpair
   and relays the other end over vsock. Every block read or write the guest
   makes is served by `DeviceBackend`, which reads and writes the real partition
   through FSKit. File requests use a second connection, on port 7000.
4. The extension sends `MOUNT`. The guest agent (`guest/mount.go`) picks a
   driver, in this order for a read-write request:
   1. `ntfs-3g.probe --readwrite`. A hibernated volume (Windows Fast Startup) is
      only ever mounted read-only, because writes are lost or corrupt the volume
      when Windows resumes. `ntfs3` does not check for hibernation itself.
   2. `ntfs3` read-write. It refuses volumes whose dirty flag is set.
   3. `lowntfs-3g` read-write, which accepts an unclean volume.
   4. `ntfs3` read-only, with the reasons from every failed attempt.

   The reply says which driver and mode won, plus a note explaining any downgrade.
   The extension saves that note in the shared app group so the menu bar app can
   show it.
5. FSKit then forwards every file operation (lookup, read, write, create,
   rename, remove, enumerate, and so on) to `Volume.swift`, which turns each one
   into a request to the guest agent.

## Unmounting

The extension sends `UNMOUNT`, and the guest unmounts the file system and
flushes the NBD device. The host then half-closes the vsock connection, the guest
powers off, and the extension stops the VM. If the guest stops by itself (a crash
or kernel panic), the extension logs the reason and further file requests fail
until the drive is remounted.

## Checks and repairs

Disk Arbitration runs a quick check (`fsck -q`) before every mount, which only
validates the boot sector. Disk Utility's First Aid runs a full check (`-n`),
and the guest runs `ntfsfix -n`. A repair (`-y`, `diskutil repairVolume`) runs
`ntfsfix`, which repairs `$MFTMirr` and resets the journal. The volume stays
marked dirty so Windows runs `chkdsk` on its next start.

## The automatic take-over

`DriveStore.swift` in the app watches Disk Arbitration. When a new external NTFS
partition appears and automatic mounting is on, it unmounts whatever driver mounted it
(macOS's built-in read-only driver, or another NTFS app) and mounts it again
through NTFS Bridge. Each drive is tried once per connection, and a drive the
user ejected stays unmounted until it's unplugged.

## The guest image

`tools/build-guest.sh` builds the two guest files from Alpine Linux packages,
each pinned by version and SHA-256:

- `build/guest/Image`: Alpine's `linux-virt` kernel, decompressed to a raw arm64
  image by `tools/unzboot.py` (Virtualization.framework needs it uncompressed).
- `build/guest/initrd.gz`: the Go agent as `/init`, the kernel modules listed
  above, musl, and the ntfs-3g programs.

Xcode copies both into the extension's resources.

## Wire protocol

The host and guest exchange length-prefixed binary frames over one vsock
stream. Requests are served concurrently and matched to replies by ID. The format
and every operation are documented in [PROTOCOL.md](PROTOCOL.md).
