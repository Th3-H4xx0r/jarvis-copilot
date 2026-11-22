#!/usr/bin/env bash
# Renders the Jarvis Glasses camera's "Glasses not streaming" cards for the PC camera
# (windows_app/JarvisGlassesCam/Cards/*.png) with the Mac camera's own drawing code
# (GlassesPlaceholder in mac_app/.../GlassesCameraKit.swift), so both cameras look the same.
# Run on a Mac after changing the card's look or words.
set -euo pipefail
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
out="$root/windows_app/JarvisGlassesCam/Cards"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/main.swift" <<'SWIFT'
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

let detail = "Start live on your iPhone and turn on Send to computer camera."
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, size) in [("card-portrait", GlassesCameraSpec.portrait), ("card-landscape", GlassesCameraSpec.landscape)] {
    guard let buffer = GlassesCameraBuffers.buffer(from: GlassesCameraBuffers.pool(size, minimum: 1)) else { fatalError("no buffer") }
    GlassesPlaceholder.render(into: buffer, detail: detail)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let image = ctx.makeImage()!
    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    let url = dir.appendingPathComponent(name + ".png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("couldn't write \(url.path)") }
    print(url.path)
}
SWIFT
mkdir -p "$out"
swiftc -O "$root/mac_app/JarvisMac/Sources/GlassesCamera/GlassesCameraKit.swift" "$work/main.swift" -o "$work/cards"
"$work/cards" "$out"
