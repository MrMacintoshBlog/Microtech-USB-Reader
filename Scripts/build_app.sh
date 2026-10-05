#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app='Microtech USB Reader.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Tools" "$app/Contents/Resources/Licenses" build
clang -O2 -mmacosx-version-min=14.0 -Wall -Wextra -Itools/vendor tools/microtech_probe.c tools/vendor/libusb-1.0.a -framework IOKit -framework CoreFoundation -framework Security -o "$app/Contents/Resources/Tools/microtech_probe"
clang -O2 -mmacosx-version-min=14.0 -Wall -Wextra -Itools/vendor tools/microtech_smartmedia.c tools/vendor/libusb-1.0.a -framework IOKit -framework CoreFoundation -framework Security -o "$app/Contents/Resources/Tools/microtech_smartmedia"
swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 App/RecoveryEngine.swift -o "$app/Contents/Resources/Tools/recovery-engine"
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx14.0 App/MicroTechPhotoRescue.swift -o "$app/Contents/MacOS/Microtech USB Reader"
cp App/Info.plist "$app/Contents/Info.plist"
cp App/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp tools/vendor/libusb-LGPL.txt "$app/Contents/Resources/Licenses/libusb-LGPL.txt"
cp App/README.md "$app/Contents/Resources/README.md"
cp App/LICENSE.txt "$app/Contents/Resources/Licenses/Recovery-GPL.txt"
cp App/GPL-2.0.txt "$app/Contents/Resources/Licenses/GPL-2.0.txt"
codesign --force --deep --sign - "$app"
printf 'Built %s\n' "$app"
