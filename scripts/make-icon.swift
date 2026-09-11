// Draws the app icon: a dark rounded square with a waveform. Run once; the output is
// committed so a build does not pay for it.
//   swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let canvas = 1024

// Drawn into an explicit 1024px bitmap — NSImage.lockFocus would double it on Retina.
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: an 824pt body centred on 1024, leaving room for the shadow.
let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                        xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSGradient(colors: [
    NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.23, alpha: 1),
    NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.09, alpha: 1),
])!.draw(in: body, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Seven bars, symmetric, the middle one warm — the HUD's waveform, frozen.
let heights: [CGFloat] = [0.24, 0.44, 0.70, 0.94, 0.70, 0.44, 0.24].map { $0 * 470 }
let width: CGFloat = 56, gap: CGFloat = 34
var x = 512 - (CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap) / 2
for (index, height) in heights.enumerated() {
    let bar = NSRect(x: x, y: 512 - height / 2, width: width, height: height)
    (index == 3
        ? NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.36, alpha: 1)
        : NSColor(calibratedWhite: 0.95, alpha: 1)).setFill()
    NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
    x += width + gap
}
NSGraphicsContext.restoreGraphicsState()

// iconutil wants every size in an .iconset folder, then packs it.
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = iconset.appending(path: "master.png")
try! rep.representation(using: .png, properties: [:])!.write(to: master)

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "\(tool) failed")
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        run("/usr/bin/sips", ["-z", "\(points * scale)", "\(points * scale)",
                              master.path, "--out", iconset.appending(path: name).path])
    }
}
try! FileManager.default.removeItem(at: master)
try? FileManager.default.createDirectory(
    at: URL(fileURLWithPath: output).deletingLastPathComponent(), withIntermediateDirectories: true)
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output])
// A copy to look at, since an .icns does not open in most viewers.
try? rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))
print("wrote \(output)")
