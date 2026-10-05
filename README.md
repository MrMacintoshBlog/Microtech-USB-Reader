# Microtech USB Reader 1.5

An everyday photo-import app for the MicroTech DPCM-USB / CameraMate reader
(USB 07af:0006). Take pictures, insert your memory card, and copy the photos
to your Apple Silicon Mac.

1. Connect the reader. Insert SmartMedia in the lower slot with gold contacts up,
   or CompactFlash in the upper slot. Select the matching card type.
2. Click the green Check Card button. A green checkmark means the card is ready.
   If the check fails, follow the card-specific insertion instructions.
3. Choose a destination folder and click the now-green Import Photos button.
4. Leave the reader connected while the card is copied and verified.
5. Open Photos or click a thumbnail. Open Import Folder shows the complete import.
6. When the import finishes, remove the card and put it back in the camera.

By default, imports are saved under Pictures/Microtech Imports. Each import
contains a Photos folder, a card copy, a decode/checksum report, and an
import log. SmartMedia additionally preserves Card.raw and its block
mapping report. Originals on the card are read only. No format, write, or erase
commands are implemented. Stop retains any partial backup; partial captures
must not be treated as complete images.

Open Saved Image extracts photos from a FAT disk image, or reconstructs a
SmartMedia .raw file made by this utility. This path does not need a USB reader.
It accepts raw sector .img files and the app's .raw captures, rather than
Apple DMG container formats.

Validated hardware: 2 MiB Toshiba SmartMedia (QuickTake 200) and 32 MB CompactFlash.
The SmartMedia protocol contains geometries for 1–128 MiB cards, but the other
capacities have not been tested on hardware. FAT12, FAT16 and FAT32 extraction
is implemented; saved-photo recovery is not deleted-file carving or NAND ECC
repair. Ambiguous mappings stop automatic reconstruction and retain the backup.
Existing files are copied with their FAT short filenames.

The standalone app bundles native tools and needs no Python, Homebrew, Linux,
administrator password, or installed camera driver. macOS may ask for access
to the destination folder. This local build is ad-hoc signed, not notarized.

Requires an Apple Silicon Mac running macOS 14 or later. Hardware validation
was performed on the current Mac; older OS versions have not been tested.
Rebuild: run Scripts/build_app.sh from this source folder. Requires Xcode's
Swift and Clang tools. The vendored libusb archive targets Apple Silicon.
Scripts/build_libusb.sh rebuilds it from the included upstream source archive.
The app includes a Source Code.zip inside Contents/Resources, with sources,
build scripts, and the original libusb source archive for rebuilding/relinking.
To make a fresh distributable ZIP after rebuilding, run Scripts/package_app.py
with Python 3. Python is only needed for packaging/tests, not for running the app.

Protocol reference: Linux drivers/usb/storage/sddr09.c (GPL-2.0-or-later),
Robert Baruch and Andries Brouwer, with assistance credited in that source.
libusb 1.0.29 is LGPL-2.1-or-later; its upstream source archive is tools/vendor/libusb-1.0.29.tar.bz2.
App source and recovery helpers are supplied under GPL-2.0-or-later.

## Testing

`Tests/check_recovery.py` runs integration checks against private hardware captures
under `recovery/`. Those captures and photos are intentionally excluded from this
repository and all release ZIPs; the test requires your own matching local fixtures.
