"""Reconstruct this Toshiba 2 MiB/256-byte-page capture without changing it."""
import hashlib
import json
import sys
from pathlib import Path

source, target = map(Path, sys.argv[1:3])
raw = source.read_bytes()
page_size, stride, block_pages = 256, 320, 16
if len(raw) != 8192 * stride:
    raise SystemExit("Expected exactly 8192 captured pages for NAND ID 98:64")
block_size = page_size * block_pages
image = bytearray(500 * block_size)
mapping, duplicates = {}, []
for pba in range(512):
    spare = raw[pba * block_pages * stride + page_size:][:8]
    if spare[:6] != b"\xff" * 6 or spare[6] >> 4 != 1:
        continue
    if (spare[6] ^ spare[7]).bit_count() % 2:
        continue
    lba = ((spare[6] << 8 | spare[7]) & 0x7ff) >> 1
    if lba >= 500:
        continue
    if lba in mapping:
        duplicates.append([lba, mapping[lba], pba])
        continue
    mapping[lba] = pba
    for page in range(block_pages):
        start = (pba * block_pages + page) * stride
        offset = lba * block_size + page * page_size
        image[offset:offset + page_size] = raw[start:start + page_size]
if duplicates:
    raise SystemExit(f"Ambiguous logical block mappings: {duplicates}")
with target.open("xb") as out:
    out.write(image)
report = {
    "source": str(source), "source_sha256": hashlib.sha256(raw).hexdigest(),
    "image_bytes": len(image), "image_sha256": hashlib.sha256(image).hexdigest(),
    "mapped_blocks": len(mapping), "mapping": mapping,
    "unmapped_blocks_filled_with_zero": [i for i in range(500) if i not in mapping],
    "notes": "Reader address stride is 512 bytes for 256-byte NAND pages. Raw capture retains 64 control bytes per page; only first 8 are physical spare bytes. Unmapped blocks remain available in original capture."
}
with target.with_suffix(".map.json").open("x") as out:
    json.dump(report, out, indent=2)
print(f"Created {target}: {len(image)} bytes, {len(mapping)} mapped blocks")
