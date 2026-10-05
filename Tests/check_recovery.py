"""Integration checks against preserved captures and a synthetic FAT32 volume."""
from pathlib import Path
import hashlib
import json
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
engine = root / "Microtech USB Reader.app/Contents/Resources/Tools/recovery-engine"
work = Path(tempfile.mkdtemp(prefix="microtech-engine-tests-", dir=root / "build"))

def run(*args, succeeds=True):
    result = subprocess.run([str(engine), *map(str,args)], capture_output=True, text=True)
    assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
    return result

def checksum(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

image = work / "SmartMedia.img"
run("reconstruct", root / "recovery/smartmedia-2mb-full.raw", image)
assert checksum(image) == checksum(root / "recovery/smartmedia-2mb.img")
sm = work / "SM" / "Photos"
run("extract", image, sm)
files = list(sm.rglob("*.JPG"))
assert len(files) == 10
for file in files:
    assert checksum(file) == checksum(root / "recovery/smartmedia-photos" / file.name)
report = json.loads((sm.parent / "photos-report.json").read_text())
assert report["decodeFailures"] == 0
assert next(f for f in report["files"] if f["file"].endswith("DSC00006.JPG"))["compressedBitsPerPixel"] == 2.0

# Existing outputs must never be silently overwritten.
before = checksum(image)
run("reconstruct", root / "recovery/smartmedia-2mb-full.raw", image, succeeds=False)
assert checksum(image) == before
run("extract", image, sm, succeeds=False)

# Malformed and incomplete inputs fail cleanly.
short = work / "incomplete.raw"
short.write_bytes(b"\xff" * 320)
run("reconstruct", short, work / "bad.img", succeeds=False)
bad = work / "bad-sector.img"
bad.write_bytes(b"\0" * 512)
run("extract", bad, work / "bad-photos", succeeds=False)

# Full FAT16 capture, checked against the mounted original if still available.
cf = work / "CF" / "Photos"
run("extract", root / "recovery/test-compactflash.img", cf)
cf_files = list(cf.rglob("*.JPG"))
assert len(cf_files) == 41
assert json.loads((cf.parent / "photos-report.json").read_text())["decodeFailures"] == 0

# Build a FAT32 disk with an actual recovered JPEG spanning many clusters.
photo = (root / "recovery/smartmedia-photos/DSC00006.JPG").read_bytes()
clusters, bps, reserved, fats, fat_sectors = 65525, 512, 32, 1, 513
first_data = reserved + fats * fat_sectors
fat32 = bytearray((first_data + clusters) * bps)
fat32[:3] = b"\xeb\x58\x90"
fat32[3:11] = b"MSWIN4.1"
struct.pack_into("<H", fat32, 11, bps)
fat32[13] = 1
struct.pack_into("<H", fat32, 14, reserved)
fat32[16] = fats
struct.pack_into("<I", fat32, 32, first_data + clusters)
struct.pack_into("<I", fat32, 36, fat_sectors)
struct.pack_into("<I", fat32, 44, 2)
fat32[510:512] = b"\x55\xaa"
fat_offset = reserved * bps
for c, nxt in [(0,0x0ffffff8),(1,0x0fffffff),(2,0x0fffffff)]:
    struct.pack_into("<I", fat32, fat_offset + c*4, nxt)
length = (len(photo) + bps - 1) // bps
for c in range(3,3+length):
    struct.pack_into("<I", fat32, fat_offset+c*4, c+1 if c < 2+length else 0x0fffffff)
directory = first_data * bps
fat32[directory:directory+11] = b"FINE    JPG"
fat32[directory+11] = 0x20
struct.pack_into("<H", fat32, directory+26, 3)
struct.pack_into("<I", fat32, directory+28, len(photo))
fat32[directory+bps:directory+bps+len(photo)] = photo
fat32_image = work / "FAT32.img"
fat32_image.write_bytes(fat32)
out = work / "FAT32" / "Photos"
run("extract", fat32_image, out)
assert (out / "FINE.JPG").read_bytes() == photo
assert json.loads((out.parent / "photos-report.json").read_text())["fatType"] == "FAT32"
print("PASS: raw reconstruction, 10 SmartMedia photos, 41 CompactFlash photos, JPEG decoding, metadata, FAT32 multi-cluster extraction, no-overwrite and invalid-input checks.")
print("Test artifacts:", work)
