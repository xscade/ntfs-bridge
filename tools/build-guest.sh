#!/bin/bash
# Builds the microVM guest: build/guest/Image (raw arm64 kernel) and
# build/guest/initrd.gz (Go agent as /init, kernel modules, NTFS tools).
# Inputs are Alpine Linux packages pinned by version and SHA-256 below.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

alpine=https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64
packages=(
  "linux-virt-6.18.63-r0 151e6d7998d8a9b3648804ef689e7e8f765ada5b7db50f579cec87e371f40bfb"
  "musl-1.2.6-r3 2e17864102278d9049c3a56f1bceed9e8cf287065617e579325123443daed8a5"
  "libuuid-2.42.3-r1 9ce20c7ffe2ccaa7c321893c10564abbca13c3f2edb82f60a35f1f68e004f86c"
  "ntfs-3g-libs-2026.2.25-r0 79b8977aef432f78fa5f82c6213095e405bb6ffd1925c5563ba35e3f5977ea9b"
  "ntfs-3g-progs-2026.2.25-r0 ee288d45bbe864bc00a2c36e5cc3315bffff8a2864b71de057f02e32e78e9eab"
  "ntfs-3g-2026.2.25-r0 4008cc5d7920ebc5a2552b7617898411754f9db7837a310018fe41fd5ef69883"
)
modules=(nbd vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport nls_utf8 ntfs3 fuse)

cache=build/cache
stage=build/stage
out=build/guest
mkdir -p "$cache" "$out"
rm -rf "$stage" && mkdir -p "$stage/pkgs" "$stage/root"

for entry in "${packages[@]}"; do
  read -r name sum <<<"$entry"
  file="$cache/$name.apk"
  [[ -f "$file" ]] || curl -fsSL -o "$file" "$alpine/$name.apk"
  actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
  if [[ "$actual" != "$sum" ]]; then
    echo "checksum mismatch for $name: $actual" >&2
    exit 1
  fi
  tar -xzf "$file" -C "$stage/pkgs" 2>/dev/null
done

python3 -I tools/unzboot.py "$stage/pkgs/boot/vmlinuz-virt" "$out/Image"

r="$stage/root"
mkdir -p "$r"/{dev,proc,sys,mnt,lib,usr/lib,usr/bin,usr/sbin}
release=$(ls "$stage/pkgs/lib/modules")
mdir="lib/modules/$release"
mkdir -p "$r/$mdir"
: >"$r/$mdir/modules.dep"
for m in "${modules[@]}"; do
  line=$(grep -E "/$m\.ko\.gz:" "$stage/pkgs/$mdir/modules.dep")
  path=${line%%:*}
  mkdir -p "$r/$mdir/$(dirname "$path")"
  cp "$stage/pkgs/$mdir/$path" "$r/$mdir/$path"
  echo "$line" >>"$r/$mdir/modules.dep"
done

cp -P "$stage/pkgs/lib/"ld-musl-aarch64.so.1 "$stage/pkgs/lib/"libc.musl-aarch64.so.1 "$r/lib/"
cp -P "$stage/pkgs/usr/lib/"libntfs-3g.so* "$stage/pkgs/usr/lib/"libuuid.so* "$r/usr/lib/"
cp "$stage/pkgs/usr/sbin/mkntfs" "$r/usr/sbin/"
cp "$stage/pkgs/usr/bin/ntfsfix" "$stage/pkgs/usr/bin/ntfs-3g.probe" "$r/usr/bin/"
cp "$stage/pkgs/bin/lowntfs-3g" "$r/usr/bin/"

(cd guest && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$root/$r/init" .)

(cd "$r" && find . -mindepth 1 | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet) | gzip -9 -n >"$out/initrd.gz"
rm -rf "$stage"
ls -la "$out"
