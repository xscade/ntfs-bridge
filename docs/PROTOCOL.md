# NTFS Bridge wire protocol

The macOS host talks to the guest agent (`/init` in the Linux microVM) over one
virtio-vsock stream. The guest listens on port 7000. All integers are little-endian.
Strings and byte blobs are a `u32` length followed by the bytes.

Request frame:  `u32 bodyLen | u64 id | u8 op | body`
Response frame: `u32 bodyLen | u64 id | i32 errno | body`

`bodyLen` counts only `body`. `errno` is a Linux errno, 0 on success; on error the
body is a string with detail. The guest serves requests concurrently, so responses
can arrive in any order and are matched by `id`.

Files are named by inode number (`ino`, the NTFS MFT record number). The guest maps
each `ino` it has returned to a path below the mount point.

## Records

`Attr`: `u64 ino, u32 mode, u32 nlink, u32 uid, u32 gid, u64 size, u64 allocated,
i64 atimeNs, i64 mtimeNs, i64 ctimeNs, i64 btimeNs`

`Statfs`: `u64 blockSize, u64 blocks, u64 blocksFree, u64 blocksAvail, u64 files,
u64 filesFree, u32 nameMax`

## Operations

| op | name     | request body                                                     | response body |
|----|----------|------------------------------------------------------------------|---------------|
| 1  | HELLO    | (none)                                                           | `str version` |
| 2  | MOUNT    | `u8 readOnly`                                                    | `u8 readOnly, str label, str note, Attr root, Statfs` |
| 3  | STATFS   | (none)                                                           | `Statfs` |
| 4  | GETATTR  | `u64 ino`                                                        | `Attr` |
| 5  | LOOKUP   | `u64 parent, str name`                                           | `Attr` |
| 6  | READDIR  | `u64 ino, u64 cookie, u32 max`                                   | `u8 eof, u32 n, n x (str name, u64 nextCookie, Attr)` |
| 7  | READ     | `u64 ino, u64 offset, u32 length`                                | `bytes data` |
| 8  | WRITE    | `u64 ino, u64 offset, bytes data`                                | `u32 written` |
| 9  | CREATE   | `u64 parent, str name, u8 kind, u32 mode, str linkTarget`        | `Attr` |
| 10 | REMOVE   | `u64 parent, str name, u8 isDir`                                 | (none) |
| 11 | RENAME   | `u64 srcParent, str srcName, u64 dstParent, str dstName`         | (none) |
| 12 | SETATTR  | `u64 ino, u32 mask, u32 mode, u32 uid, u32 gid, u64 size, i64 atimeNs, i64 mtimeNs` | `Attr` |
| 13 | READLINK | `u64 ino`                                                        | `str target` |
| 14 | SYNC     | (none)                                                           | (none) |
| 15 | UNMOUNT  | (none)                                                           | (none); the guest then powers off |
| 16 | MKFS     | `str label`                                                      | `str output` (formats the whole disk; test images only) |
| 17 | CHECK    | `u8 repair`                                                      | `i32 exitCode, str output` (`ntfsfix -n`; `ntfsfix` when repair=1) |

`kind`: 1 file, 2 directory, 3 symlink. `cookie` 0 starts a listing.
SETATTR `mask` bits: 1 mode, 2 uid, 4 gid, 8 size, 16 atime, 32 mtime.
