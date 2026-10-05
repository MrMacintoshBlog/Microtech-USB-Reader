"""Inspect JPEG headers without decoding or modifying recovered photos."""
from pathlib import Path
import hashlib
import json

results = []
for path in sorted(Path("recovery/smartmedia-photos").glob("*.JPG")):
    data = path.read_bytes()
    assert data[:2] == b"\xff\xd8"
    offset = 2
    tables, metadata, dimensions, components = {}, [], None, None
    while offset < len(data):
        assert data[offset] == 255, (path, offset)
        while data[offset] == 255:
            offset += 1
        marker = data[offset]
        offset += 1
        if marker in (0xda, 0xd9):
            break
        length = int.from_bytes(data[offset:offset + 2], "big")
        payload = data[offset + 2:offset + length]
        offset += length
        if marker == 0xdb:
            qoff = 0
            while qoff < len(payload):
                info = payload[qoff]
                qoff += 1
                width = 2 if info >> 4 else 1
                values = [int.from_bytes(payload[qoff + i * width:qoff + (i + 1) * width], "big") for i in range(64)]
                qoff += 64 * width
                tables[str(info & 15)] = values
        if marker in (0xc0, 0xc1, 0xc2):
            dimensions = [int.from_bytes(payload[3:5], "big"), int.from_bytes(payload[1:3], "big")]
            components = list(payload[6:])
        if 0xe0 <= marker <= 0xef or marker == 0xfe:
            metadata.append({"marker": hex(marker), "length": len(payload), "hex": payload.hex(), "printable": "".join(chr(b) if 32 <= b < 127 else "." for b in payload)})
    results.append({"file": path.name, "bytes": len(data), "dimensions": dimensions, "components": components,
                    "quantization_fingerprint": hashlib.sha256(json.dumps(tables, sort_keys=True).encode()).hexdigest(),
                    "quantization_tables": tables, "metadata": metadata})
Path("recovery/quicktake-jpeg-analysis.json").write_text(json.dumps(results, indent=2))
for row in results:
    print(row["file"], row["bytes"], row["dimensions"], row["components"], row["quantization_fingerprint"][:16])
    print("  quantization:", {k: (min(v), max(v), round(sum(v) / 64, 2)) for k, v in row["quantization_tables"].items()})
    print("  metadata:", [(m["marker"], m["length"], m["printable"][:250]) for m in row["metadata"]])
