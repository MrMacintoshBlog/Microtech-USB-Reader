import Foundation
// Copy the approved icon artwork into the build preview location.
// App/AppIcon.png is the source artwork; App/AppIcon.icns is the packaged icon.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let artwork = URL(fileURLWithPath: "App/AppIcon.png")
try Data(contentsOf: artwork).write(to: output.appendingPathComponent("icon-1024.png"))
