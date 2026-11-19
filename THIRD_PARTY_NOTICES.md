# Third-party notices

NTFS Bridge's own code is licensed under the [GNU GPL v3.0](LICENSE).

The released app also contains a small Linux system, the "guest", that runs
inside a virtual machine. It's built by `tools/build-guest.sh` from the Alpine
Linux 3.24 packages below, used unmodified, plus the Go guest agent from this
repository. The full license texts are in [`LICENSES/`](LICENSES).

| Component | Version | License | Where it's used |
|---|---|---|---|
| [Linux kernel](https://www.kernel.org) (Alpine `linux-virt`) | 6.18.63 | GPL-2.0-only | `Image`, and the kernel modules in `initrd.gz` |
| [ntfs-3g](https://github.com/tuxera/ntfs-3g) (`ntfs-3g`, `ntfs-3g-libs`, `ntfs-3g-progs`) | 2026.2.25 | GPL-2.0-only | `lowntfs-3g`, `ntfs-3g.probe`, `ntfsfix`, `mkntfs` and `libntfs-3g` in `initrd.gz` |
| [musl](https://musl.libc.org) | 1.2.6 | MIT | C library in `initrd.gz` |
| [libuuid](https://github.com/util-linux/util-linux) (util-linux) | 2.42.3 | BSD-3-Clause | Library in `initrd.gz` |
| [Go](https://go.dev) standard library and [golang.org/x/sys](https://pkg.go.dev/golang.org/x/sys) | Go 1.27.4, x/sys 0.50.0 | BSD-3-Clause | Compiled into the guest agent (`/init`) |

## Corresponding source for the GPL components

Every GitHub release has the complete corresponding source for the GPL
components in that release's disk image, attached as `ntfs-bridge-<version>-gpl-sources.tar`.
For 0.1.0 it contains:

| File | What it is |
|---|---|
| `linux-6.18.tar.xz`, `patch-6.18.63.xz` | Upstream kernel source and the stable patch to 6.18.63, from kernel.org |
| `aports-linux-lts-aabe3e5.tar.gz` | Alpine's build recipe, patches and kernel config (`lts.aarch64.config`) for `linux-lts` 6.18.63-r0, at aports commit `aabe3e5ce3d1b3469580a931ce1746e05dc95c01` |
| `ntfs-3g_ntfsprogs-2026.2.25.tgz` | Upstream ntfs-3g source |
| `aports-ntfs-3g-6e0f4ac.tar.gz` | Alpine's build recipe for `ntfs-3g` 2026.2.25-r0, at aports commit `6e0f4ace9c11c2ce0a132d763507d1898e707ba2` |

Each upstream file matches the SHA-512 recorded in Alpine's recipe. The scripts
that turn these packages into the guest image (`tools/build-guest.sh` and
`tools/unzboot.py`) are in this repository.

If a release asset is ever missing, open an issue and the maintainer will
provide the source, for at least three years after the release was published.

## Trademarks

NTFS, Windows and Microsoft are trademarks of Microsoft Corporation. NTFS Bridge
is not affiliated with or endorsed by Microsoft, Tuxera or Alpine Linux.
