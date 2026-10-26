#!/usr/bin/env swift

// Renders the app icon set, one per accent theme.
//
// The artwork is generated rather than drawn by hand so it is reproducible and
// reviewable as source. The mark is the namespace itself: the DNS is a tree
// from the root down, which is what the app reads, and no other category of app
// uses it — a magnifying glass would have said "search", which is not the same
// thing and is every other icon in the category.
//
// Only the ground colour changes between themes, so the four read as one app.
//
// Usage: swift Scripts/make-app-icons.swift <output-directory>
//
// Writes <name>-1024.png per theme. iOS masks the corners itself, so these are
// full-bleed squares with no rounding and no alpha.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let size = CGFloat(side)

struct Theme {
    let name: String
    /// Top and bottom of the ground gradient. The bottom carries the same hue
    /// darker, so the mark keeps its contrast across the whole square.
    let top: (CGFloat, CGFloat, CGFloat)
    let bottom: (CGFloat, CGFloat, CGFloat)
}

let themes = [
    Theme(name: "AppIcon", top: (0.00, 0.25, 0.87), bottom: (0.00, 0.10, 0.45)),
    Theme(name: "AppIconGraphite", top: (0.34, 0.36, 0.40), bottom: (0.16, 0.17, 0.20)),
    Theme(name: "AppIconForest", top: (0.16, 0.48, 0.32), bottom: (0.06, 0.22, 0.15)),
    Theme(name: "AppIconPlum", top: (0.50, 0.24, 0.52), bottom: (0.24, 0.10, 0.26))
]

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func dot(_ context: CGContext, _ centre: CGPoint, _ radius: CGFloat) {
    context.addEllipse(in: CGRect(
        x: centre.x - radius,
        y: centre.y - radius,
        width: radius * 2,
        height: radius * 2
    ))
    context.fillPath()
}

/// Root, two labels, four leaves — the shape of a hostname read right to left.
private func drawNamespaceTree(_ context: CGContext) {
    let nodeRadius = size * 0.056
    let edgeWidth = size * 0.034

    let root = CGPoint(x: size * 0.5, y: size * 0.775)
    let labels = [
        CGPoint(x: size * 0.305, y: size * 0.515),
        CGPoint(x: size * 0.695, y: size * 0.515)
    ]
    let leaves = [
        CGPoint(x: size * 0.215, y: size * 0.265),
        CGPoint(x: size * 0.395, y: size * 0.265),
        CGPoint(x: size * 0.605, y: size * 0.265),
        CGPoint(x: size * 0.785, y: size * 0.265)
    ]

    // Edges first, slightly under full white so the nodes stay the emphasis.
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.82))
    context.setLineWidth(edgeWidth)
    context.setLineCap(.round)
    for label in labels {
        context.move(to: root)
        context.addLine(to: label)
        context.strokePath()
    }
    for (index, leaf) in leaves.enumerated() {
        context.move(to: labels[index / 2])
        context.addLine(to: leaf)
        context.strokePath()
    }

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    dot(context, root, nodeRadius * 1.28)
    for label in labels { dot(context, label, nodeRadius) }
    for leaf in leaves { dot(context, leaf, nodeRadius * 0.80) }
}

func render(_ theme: Theme, to url: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw Failure("could not create a bitmap context")
    }

    let colors = [
        CGColor(red: theme.top.0, green: theme.top.1, blue: theme.top.2, alpha: 1),
        CGColor(red: theme.bottom.0, green: theme.bottom.1, blue: theme.bottom.2, alpha: 1)
    ] as CFArray
    guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else {
        throw Failure("could not create the gradient")
    }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    drawNamespaceTree(context)

    guard let image = context.makeImage() else {
        throw Failure("could not render \(theme.name)")
    }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw Failure("could not open \(url.path) for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure("could not write \(url.path)")
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-app-icons.swift <output-directory>\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for theme in themes {
    let url = outputDirectory.appendingPathComponent("\(theme.name)-1024.png")
    try render(theme, to: url)
    print("wrote \(url.lastPathComponent)")
}
