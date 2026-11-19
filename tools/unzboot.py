"""Extract the raw arm64 Image from an EFI zboot kernel (gzip payload)."""
import gzip
import struct
import sys

src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
if data[4:8] != b"zimg":
    sys.exit(f"{src}: not an EFI zboot image")
offset, size = struct.unpack("<II", data[8:16])
compression = data[24:32].rstrip(b"\0")
if compression != b"gzip":
    sys.exit(f"{src}: unsupported zboot compression {compression!r}")
image = gzip.decompress(data[offset:offset + size])
if image[56:60] != b"ARM\x64":
    sys.exit(f"{src}: payload is not an arm64 Image")
open(dst, "wb").write(image)
