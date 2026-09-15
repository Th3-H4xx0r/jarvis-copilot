// Renders the phone's orb (ios_app/…/OrbShader.metal, `setupOrb`) into frames for the
// Jarvis Ball's screen, so the ball shows the same orb rather than an imitation.
//
//   swiftc -O -o render_orb render_orb.swift
//   ./render_orb <OrbShader.metal> <out.bin> <preview.png> [frames=64] [frame=160] [orb=130]
//
// Output: "ORB1", u32 frame count, u32 width, u32 height (little endian), then frames of
// RGB565 little endian, composited over black. One loop of the shader's 38.4 s cycle.
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: render_orb <OrbShader.metal> <out.bin> <preview.png> [frames] [frame] [orb]")
    exit(2)
}
let frames = args.count > 4 ? Int(args[4])! : 64
let side = args.count > 5 ? Int(args[5])! : 160
let orb = args.count > 6 ? Double(args[6])! : 130
let period = 38.4

var source = try String(contentsOfFile: args[1], encoding: .utf8)
source = source.replacingOccurrences(of: "#include <SwiftUI/SwiftUI_Metal.h>", with: "")
source = source.replacingOccurrences(of: "[[ stitchable ]]", with: "")
source = "#include <metal_stdlib>\nusing namespace metal;\n" + source + """

kernel void renderOrb(texture2d<half, access::write> out [[texture(0)]],
                      constant float& t [[buffer(0)]],
                      constant float& slot [[buffer(1)]],
                      constant float& offset [[buffer(2)]],
                      uint2 gid [[thread_position_in_grid]]) {
    // VoiceOrb draws the shader in a slot the orb fills 53% of; crop the frame around it.
    float2 pos = float2(gid) + 0.5 + offset;
    half4 c = setupOrb(pos, half4(1.0), float2(slot, slot), t);
    out.write(half4(c.rgb, 1.0), gid);  // premultiplied over black
}
"""

let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(source: source, options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "renderOrb")!)
let queue = device.makeCommandQueue()!
let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: false)
descriptor.usage = [.shaderWrite, .shaderRead]
let texture = device.makeTexture(descriptor: descriptor)!

var out = Data()
func appendU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
out.append(contentsOf: Array("ORB1".utf8))
appendU32(UInt32(frames))
appendU32(UInt32(side))
appendU32(UInt32(side))

var slot = Float(orb / 0.53)
var offset = Float((Double(slot) - Double(side)) / 2)
var rgba = [UInt8](repeating: 0, count: side * side * 4)
for i in 0..<frames {
    var t = Float(period * Double(i) / Double(frames))
    let buffer = queue.makeCommandBuffer()!
    let encoder = buffer.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(texture, index: 0)
    encoder.setBytes(&t, length: MemoryLayout<Float>.size, index: 0)
    encoder.setBytes(&slot, length: MemoryLayout<Float>.size, index: 1)
    encoder.setBytes(&offset, length: MemoryLayout<Float>.size, index: 2)
    encoder.dispatchThreads(MTLSize(width: side, height: side, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    encoder.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
    texture.getBytes(&rgba, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
    for p in 0..<(side * side) {
        let r = UInt16(rgba[p * 4]), g = UInt16(rgba[p * 4 + 1]), b = UInt16(rgba[p * 4 + 2])
        let v = (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)
        out.append(UInt8(v & 0xFF))
        out.append(UInt8(v >> 8))
    }
    if i == frames / 4 {
        let ctx = CGContext(data: &rgba, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}
try out.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(frames) frames \(side)x\(side) (\(out.count) bytes) to \(args[2])")
