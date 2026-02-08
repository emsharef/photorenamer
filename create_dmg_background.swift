#!/usr/bin/env swift
import Cocoa
import CoreText

let width = 660
let height = 400
let output = "dmg_background.png"

// Create bitmap context
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: width * 4,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Failed to create context")
}

// Background gradient
let gradientColors = [
    CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1.0),
    CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
] as CFArray
let gradient = CGGradient(colorsSpace: cs, colors: gradientColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: CGFloat(height)),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// Helper to draw centered text
let cx = CGFloat(width) / 2.0

func drawCenteredText(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor, fontName: String = "Helvetica Neue") {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
    ]
    let attrStr = NSAttributedString(string: text, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attrStr)
    let bounds = CTLineGetBoundsWithOptions(line, [])
    let tx = x - bounds.width / 2
    let ty = y - bounds.height / 2

    ctx.saveGState()
    ctx.textPosition = CGPoint(x: tx, y: ty)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// Draw a large arrow character in the center
let arrowColor = CGColor(red: 0.45, green: 0.45, blue: 0.50, alpha: 0.55)
let arrowY = CGFloat(height) / 2.0 + 15
drawCenteredText("\u{27A1}", x: cx, y: arrowY, size: 48, color: arrowColor)

// Draw instruction text below
drawCenteredText(
    "Drag to Applications to install",
    x: cx, y: 38,
    size: 13,
    color: CGColor(red: 0.4, green: 0.4, blue: 0.45, alpha: 0.9)
)

// Save as PNG
guard let image = ctx.makeImage() else { fatalError("Failed to create image") }
let url = URL(fileURLWithPath: output)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Failed to create image destination")
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("Created \(output) (\(width)x\(height))")
