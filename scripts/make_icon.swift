#!/usr/bin/env swift
// Renders the Pointer app icon at every iconset size.
//
// Usage:
//   scripts/make_icon.swift           # writes to ./build/Pointer.iconset
//   scripts/make_icon.swift /tmp/foo  # writes to /tmp/foo
//
// After running, finalize the .icns:
//   iconutil -c icns build/Pointer.iconset -o assets/Pointer.icns

import AppKit
import CoreGraphics
import CoreText
import UniformTypeIdentifiers
import ImageIO

// AppKit needs to be alive for NSImage(systemSymbolName:) to resolve symbols.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/Pointer.iconset"

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Continuous-curve squircle approximation — ~22.4% corner radius.
let cornerRatio: CGFloat = 0.2237

func render(canvas: CGFloat) -> Data {
    let pixels = Int(canvas)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("couldn't create CGContext at \(pixels)px")
    }

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    defer { NSGraphicsContext.restoreGraphicsState() }

    let body = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    let radius = canvas * cornerRatio
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 1) Background gradient — vibrant indigo top → deep navy bottom.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let top = CGColor(srgbRed: 0.36, green: 0.45, blue: 0.98, alpha: 1.0)
    let bottom = CGColor(srgbRed: 0.16, green: 0.18, blue: 0.50, alpha: 1.0)
    if let bg = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(
            bg,
            start: CGPoint(x: 0, y: canvas),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }

    // 2) Top sheen — soft white highlight on the upper third.
    let sheenTop = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18)
    let sheenBottom = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
    if let sheen = CGGradient(colorsSpace: cs, colors: [sheenTop, sheenBottom] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(
            sheen,
            start: CGPoint(x: 0, y: canvas),
            end: CGPoint(x: 0, y: canvas * 0.55),
            options: []
        )
    }
    ctx.restoreGState()

    // 3) Hairline border to crisp the squircle edge.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.setLineWidth(canvas * 0.003)
    ctx.strokePath()
    ctx.restoreGState()

    // 4) Glyph. The "rays" version reads great at large sizes but smears into
    // illegible dots below 64px — drop the rays and scale the cursor up there.
    let smallSize = canvas <= 64
    let glyphSymbol = smallSize ? "cursorarrow" : "cursorarrow.rays"
    let glyphPoint = canvas * (smallSize ? 0.66 : 0.52)
    let weight: NSFont.Weight = smallSize ? .bold : .semibold
    let baseConfig = NSImage.SymbolConfiguration(pointSize: glyphPoint, weight: weight)
    let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [.white])
    let merged = baseConfig.applying(paletteConfig)

    if let symbol = NSImage(systemSymbolName: glyphSymbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(merged) {
        let s = symbol.size
        let rect = CGRect(
            x: (canvas - s.width) / 2,
            y: (canvas - s.height) / 2,
            width: s.width,
            height: s.height
        )
        ctx.saveGState()
        // Soft shadow under the glyph for depth.
        ctx.setShadow(
            offset: CGSize(width: 0, height: -canvas * 0.006),
            blur: canvas * 0.018,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25)
        )
        // NSImage.draw uses NSGraphicsContext.current.
        symbol.draw(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0)
        ctx.restoreGState()
    } else {
        fputs("WARNING: cursorarrow.rays symbol not available — drawing fallback\n", stderr)
    }

    guard let cgImage = ctx.makeImage() else {
        fatalError("couldn't snapshot CGContext")
    }

    // PNG out via ImageIO.
    let mutableData = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        mutableData,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("couldn't create PNG destination")
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("couldn't finalize PNG")
    }
    return mutableData as Data
}

let sizes: [(name: String, canvas: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, canvas) in sizes {
    let data = render(canvas: canvas)
    let url = URL(fileURLWithPath: "\(outDir)/\(name)")
    try data.write(to: url)
    print("wrote \(url.path) (\(data.count) bytes)")
}

print("\nDone. Now run:\n  iconutil -c icns \(outDir) -o assets/Pointer.icns")
