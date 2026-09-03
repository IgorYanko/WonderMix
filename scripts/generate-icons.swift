#!/usr/bin/env swift
import AppKit
import Foundation

_ = NSApplication.shared

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = NSImage(contentsOf: sourceURL),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    fputs("Não foi possível ler \(sourceURL.path)\n", stderr)
    exit(1)
}

func writePNG(_ image: NSImage, to url: URL, pixelSize: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func makeAppIconCanvas(side: Int) -> NSImage {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: side,
        pixelsHigh: side,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    let padding = CGFloat(side) * 0.08
    let maxSide = CGFloat(side) - padding * 2
    let srcSize = NSSize(width: sourceCG.width, height: sourceCG.height)
    let scale = min(maxSide / srcSize.width, maxSide / srcSize.height)
    let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)
    let origin = NSPoint(
        x: (CGFloat(side) - drawSize.width) / 2,
        y: (CGFloat(side) - drawSize.height) / 2
    )
    let srcImage = NSImage(cgImage: sourceCG, size: srcSize)
    srcImage.draw(
        in: NSRect(origin: origin, size: drawSize),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: NSSize(width: side, height: side))
    image.addRepresentation(rep)
    return image
}

func makeTemplateImage() -> NSImage {
    let width = sourceCG.width
    let height = sourceCG.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width, minY = height, maxX = 0, maxY = 0
    for y in 0..<height {
        for x in 0..<width {
            let i = y * bytesPerRow + x * 4
            let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
            let isBackground = r < 28 && g < 28 && b < 28
            if isBackground {
                pixels[i] = 0
                pixels[i + 1] = 0
                pixels[i + 2] = 0
                pixels[i + 3] = 0
            } else {
                pixels[i] = 255
                pixels[i + 1] = 255
                pixels[i + 2] = 255
                pixels[i + 3] = 255
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }

    let crop = CGRect(
        x: max(minX - 8, 0),
        y: max(minY - 8, 0),
        width: min(maxX - minX + 16, width),
        height: min(maxY - minY + 16, height)
    )
    let full = ctx.makeImage()!
    let cropped = full.cropping(to: crop)!
    return NSImage(cgImage: cropped, size: NSSize(width: crop.width, height: crop.height))
}

func writeMenuBarIcon(_ image: NSImage, to url: URL, pixelWidth: Int) {
    let aspect = image.size.height / max(image.size.width, 1)
    let pixelHeight = max(1, Int((CGFloat(pixelWidth) * aspect).rounded()))
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let appIconSet = root.appendingPathComponent("WonderMix/Assets.xcassets/AppIcon.appiconset")
let menuBarSet = root.appendingPathComponent("WonderMix/Assets.xcassets/MenuBarIcon.imageset")

let canvas = makeAppIconCanvas(side: 1024)
let appSizes: [(String, Int)] = [
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
for (name, size) in appSizes {
    writePNG(canvas, to: appIconSet.appendingPathComponent(name), pixelSize: size)
}

let template = makeTemplateImage()
writeMenuBarIcon(template, to: menuBarSet.appendingPathComponent("MenuBarIcon.png"), pixelWidth: 22)
writeMenuBarIcon(template, to: menuBarSet.appendingPathComponent("MenuBarIcon@2x.png"), pixelWidth: 44)

print("Ícones gerados em \(appIconSet.path) e \(menuBarSet.path)")
