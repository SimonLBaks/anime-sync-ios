import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Render the existing artwork directly. AppKit's optional 24-bit bitmap context
// can be nil in a command-line process, leaving an apparently valid black PNG.
guard CommandLine.arguments.count == 3 else { fatalError("Usage: RenderAppIcon.swift source.png output.png") }
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
      image.width > 0, image.width == image.height,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: 1024, height: 1024,
                              bitsPerComponent: 8, bytesPerRow: 1024 * 4, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
else { fatalError("Existing app logo could not be decoded or an opaque render context could not be created") }
context.setFillColor(red: 0.01, green: 0.015, blue: 0.07, alpha: 1)
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let rendered = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("App icon image or PNG destination could not be created") }
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("App icon PNG export failed") }
// The build's independent PNG validator checks color/opacity and compares the
// actual exported and asset-catalog PNGs against the original logo.
print("Rendered original \(image.width)×\(image.height) logo to opaque \(rendered.width)×\(rendered.height) PNG")
