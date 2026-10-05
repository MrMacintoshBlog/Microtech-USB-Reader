"""Bundle corresponding sources and package only the app, never recovery photos."""
from pathlib import Path
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
app = root / "Microtech USB Reader.app"
source_zip = app / "Contents/Resources/Source Code.zip"
paths = []
for folder in ("App", "Scripts", "Tests"):
    paths.extend(p for p in (root / folder).rglob("*") if p.is_file() and p.suffix != ".pyc")
paths.extend(p for p in (root / "tools").glob("*") if p.suffix in (".c", ".py"))
paths.extend(root / "tools/vendor" / name for name in ("libusb.h", "libusb-1.0.a", "libusb-1.0.29.tar.bz2", "libusb-LGPL.txt"))
with zipfile.ZipFile(source_zip, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for path in paths:
        archive.write(path, "Microtech USB Reader Source/" + str(path.relative_to(root)))
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
target = root / "Microtech USB Reader v1.6.zip"
subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(target)], check=True)
print("Created", target)
print("Corresponding sources included inside app Resources. No recovered photos are packaged.")
