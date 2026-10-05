"""Read EXIF TIFF directories and preserve camera metadata for comparison."""
from pathlib import Path
import json
import struct
all_results = []
for file in sorted(Path("recovery/smartmedia-photos").glob("*.JPG")):
    data = file.read_bytes()
    start = data.index(b"Exif\0\0") + 6
    tiff = data[start:]
    order = "<" if tiff[:2] == b"II" else ">"
    rows = []
    def ifd(offset, name):
        count = struct.unpack_from(order + "H", tiff, offset)[0]
        for i in range(count):
            entry = offset + 2 + i * 12
            tag, kind, n = struct.unpack_from(order + "HHI", tiff, entry)
            width = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8}.get(kind, 1)
            valoff = struct.unpack_from(order + "I", tiff, entry + 8)[0]
            raw = tiff[entry + 8:entry + 8 + n * width] if n * width <= 4 else tiff[valoff:valoff + n * width]
            if kind == 2:
                value = raw.rstrip(b"\0").decode("ascii", "replace")
            elif kind in (3, 4, 9):
                value = list(struct.unpack(order + {3: "H", 4: "I", 9: "i"}[kind] * n, raw))
            elif kind in (5, 10):
                value = list(struct.unpack(order + ("I" if kind == 5 else "i") * (n * 2), raw))
            else:
                value = raw.hex()
            rows.append({"directory": name, "tag": hex(tag), "type": kind, "count": n, "value": value})
            if tag in (0x8769, 0x8825):
                ifd(valoff, "Exif" if tag == 0x8769 else "GPS")
            if tag == 0x927c:
                print(file.name, "MakerNote:", raw[:250])
        nextoffset = struct.unpack_from(order + "I", tiff, offset + 2 + count * 12)[0]
        if nextoffset:
            ifd(nextoffset, "thumbnail")
    ifd(struct.unpack_from(order + "I", tiff, 4)[0], "main")
    all_results.append({"file": file.name, "tags": rows})
Path("recovery/quicktake-exif-analysis.json").write_text(json.dumps(all_results, indent=2))
for result in all_results[:1]:
    print(json.dumps(result, indent=2))
print("Differences across photos:")
first = {(r["directory"], r["tag"]): r["value"] for r in all_results[0]["tags"]}
for result in all_results:
    print(result["file"], [(r["directory"], r["tag"], r["value"]) for r in result["tags"] if r["value"] != first.get((r["directory"], r["tag"]))])
