import ChunkseeKit
import CoreGraphics
import Foundation
import ImageIO
import simd

/// Decoded pixels have a top-left origin and premultiplied RGBA channels.
nonisolated struct ItemTexture: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(png: Data) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...1024).contains(width), (1...1024).contains(height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let decoded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func rgb(at pixel: SIMD2<Int>) -> UInt32? {
        guard (0..<width).contains(pixel.x), (0..<height).contains(pixel.y) else { return nil }
        let index = (pixel.y * width + pixel.x) * 4
        guard pixels[index + 3] == 255 else { return nil }
        return UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2])
    }
}

/// A small orthographic thumbnail renderer, independent of SwiftUI and the main actor.
/// Kit resolves the format. This client projects its geometry, samples textures and lights faces.
nonisolated enum ItemPictureRenderer {
    static let size = 64

    private struct Face {
        let points: [SIMD3<Float>]
        let uv: [SIMD2<Float>]
        let texture: ItemTexture
        let color: SIMD3<Float>
        var depth: Float { points.reduce(0) { $0 + $1.z } / 4 }
    }

    static func render(_ item: AssetItem, colors: [[UInt32]],
                       texture: (Identifier) -> ItemTexture?) throws -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var retainedTextures: [Identifier: ItemTexture] = [:]
        var textureBytes = 0
        // Composite parts are intentionally ordered. A generated item's layers share its
        // plane; separate depth buffers prevent the first layer from hiding later overlays.
        for (partIndex, part) in item.parts.enumerated() {
            try Task.checkCancellation()
            var faces: [Face] = []
            let model = part.model
            func append(_ vertices: [SIMD3<Float>], material: AssetModel.Material, uv: SIMD4<Float>,
                        rotation: Int, tintIndex: Int?, element: AssetModel.Element?) -> Bool {
                let image: ItemTexture
                if let retained = retainedTextures[material.texture] { image = retained }
                else {
                    guard let loaded = texture(material.texture), loaded.width == loaded.height,
                          textureBytes + loaded.pixels.count <= 16 * 1024 * 1024 else { return false }
                    image = loaded
                    textureBytes += loaded.pixels.count
                    retainedTextures[material.texture] = loaded
                }
                let points = vertices.map { project($0, element: element?.rotation, transform: model.guiTransform) }
                guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return false }
                let normal = simd_cross(points[1] - points[0], points[3] - points[0])
                guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite else { return false }
                guard normal.z > 0.000001 else { return true }
                let light = model.guiLight == .front ? 1 : lighting(normal: simd_normalize(normal), emission: element?.lightEmission ?? 0)
                let tint: UInt32
                if let tintIndex, colors[partIndex].indices.contains(tintIndex) { tint = colors[partIndex][tintIndex] }
                else { tint = 0xFFFFFF }
                let color = SIMD3<Float>(Float((tint >> 16) & 255), Float((tint >> 8) & 255), Float(tint & 255)) / 255 * light
                let corners = [SIMD2<Float>(uv.x, uv.y), SIMD2<Float>(uv.x, uv.w),
                               SIMD2<Float>(uv.z, uv.w), SIMD2<Float>(uv.z, uv.y)]
                let turned = (0..<4).map { corners[($0 + rotation / 90) % 4] / 16 }
                faces.append(Face(points: points, uv: turned, texture: image, color: color))
                return true
            }
            switch model.geometry {
            case .layers(let layers):
                for layer in layers {
                    // A tiny depth offset lets later generated layers win depth tests,
                    // preserving the game's draw-order behavior for coplanar overlays.
                    let z = Float(8.5) + Float(layer.tintIndex) * 0.001
                    guard append([SIMD3(0, 16, z), SIMD3(0, 0, z), SIMD3(16, 0, z), SIMD3(16, 16, z)],
                                 material: layer.material, uv: SIMD4(0, 0, 16, 16), rotation: 0,
                                 tintIndex: layer.tintIndex, element: nil) else { return nil }
                }
            case .elements(let elements):
                for element in elements {
                    try Task.checkCancellation()
                    for direction in AssetModel.Direction.allCases {
                        guard let face = element.faces[direction] else { continue }
                        guard append(vertices(for: direction, from: element.from, to: element.to), material: face.material,
                                     uv: face.uv, rotation: face.rotation, tintIndex: face.tintIndex, element: element) else { return nil }
                    }
                }
            }
            var depths = [Float](repeating: -.infinity, count: size * size)
            // Back-to-front handles transparent texels; a per-pixel depth check also handles
            // intersecting cuboids without drawing a rear face over a nearer opaque surface.
            for face in faces.enumerated().sorted(by: { $0.element.depth == $1.element.depth ? $0.offset < $1.offset : $0.element.depth < $1.element.depth }) {
                try Task.checkCancellation()
                rasterize(face.element, pixels: &pixels, depths: &depths)
            }
        }
        // A resolved empty model intentionally draws nothing; it is distinct from a missing model.
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func rasterize(_ face: Face, pixels: inout [UInt8], depths: inout [Float]) {
        let points = face.points.map { SIMD2<Float>(($0.x + 0.5) * Float(size), (0.5 - $0.y) * Float(size)) }
        let a = points[3] - points[0], b = points[1] - points[0]
        let determinant = a.x * b.y - a.y * b.x
        guard determinant.isFinite, abs(determinant) > 0.000001 else { return }
        let minX = Int(max(0, min(Float(size), floor(points.map(\.x).min()!))))
        let maxX = Int(max(0, min(Float(size), ceil(points.map(\.x).max()!))))
        let minY = Int(max(0, min(Float(size), floor(points.map(\.y).min()!))))
        let maxY = Int(max(0, min(Float(size), ceil(points.map(\.y).max()!))))
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) - points[0]
                let u = (offset.x * b.y - offset.y * b.x) / determinant
                let v = (a.x * offset.y - a.y * offset.x) / determinant
                guard u >= 0, u < 1, v >= 0, v < 1 else { continue }
                let index = y * size + x
                let z = face.points[0].z + u * (face.points[3].z - face.points[0].z) + v * (face.points[1].z - face.points[0].z)
                guard z.isFinite, z >= depths[index] else { continue }
                let uv = face.uv[0] + u * (face.uv[3] - face.uv[0]) + v * (face.uv[1] - face.uv[0])
                guard uv.x.isFinite, uv.y.isFinite else { continue }
                let tx = Int(max(0, min(Float(face.texture.width - 1), floor(uv.x * Float(face.texture.width)))))
                let ty = Int(max(0, min(Float(face.texture.height - 1), floor(uv.y * Float(face.texture.height)))))
                let source = (ty * face.texture.width + tx) * 4
                let alpha = Float(face.texture.pixels[source + 3]) / 255
                guard alpha > 0 else { continue }
                let target = index * 4
                for channel in 0..<3 {
                    let value = Float(face.texture.pixels[source + channel]) * face.color[channel]
                        + Float(pixels[target + channel]) * (1 - alpha)
                    pixels[target + channel] = UInt8(clamping: Int(value.rounded()))
                }
                pixels[target + 3] = UInt8(clamping: Int((alpha * 255 + Float(pixels[target + 3]) * (1 - alpha)).rounded()))
                depths[index] = z
            }
        }
    }

    private static func project(_ vertex: SIMD3<Float>, element: AssetModel.Rotation?, transform: AssetModel.Transform) -> SIMD3<Float> {
        var point = vertex
        if let element {
            let rotation: simd_quatf
            switch element.angles {
            case .axis(let axis, let angle):
                let direction: SIMD3<Float> = axis == .x ? SIMD3(1, 0, 0) : axis == .y ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
                rotation = simd_quatf(angle: angle * .pi / 180, axis: direction)
            case .eulerXYZ(let angles):
                // CuboidRotation applies X, then Y, then Z; GUI transforms use the reverse order.
                let r = angles * .pi / 180
                rotation = simd_quatf(angle: r.z, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: r.y, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: r.x, axis: SIMD3(1, 0, 0))
            }
            var offset = point - element.origin
            if element.rescale {
                // The game's rescale uses the largest component of each rotated unit axis.
                for axis in 0..<3 {
                    var unit = SIMD3<Float>.zero
                    unit[axis] = 1
                    let rotated = abs(rotation.act(unit))
                    offset[axis] /= max(rotated.x, rotated.y, rotated.z)
                }
            }
            point = rotation.act(offset) + element.origin
        }
        return guiRotation(transform.rotation).act((point / 16 - 0.5) * transform.scale) + transform.translation
    }

    private static func guiRotation(_ degrees: SIMD3<Float>) -> simd_quatf {
        let r = degrees * .pi / 180
        return simd_quatf(angle: r.x, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: r.y, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: r.z, axis: SIMD3(0, 0, 1))
    }

    private static func lighting(normal: SIMD3<Float>, emission: Int) -> Float {
        // Fixed thumbnail lighting keeps the same item readable in Light and Dark appearance.
        let key = max(0, simd_dot(normal, simd_normalize(SIMD3<Float>(-0.4, 1, 0.6))))
        let fill = max(0, simd_dot(normal, simd_normalize(SIMD3<Float>(0.6, 0.2, -0.4))))
        return max(Float(emission) / 15, min(1, 0.4 + 0.6 * (key + fill)))
    }

    private static func vertices(for direction: AssetModel.Direction, from a: SIMD3<Float>, to b: SIMD3<Float>) -> [SIMD3<Float>] {
        // FaceInfo's four corners pair with UVs in top-left, bottom-left, bottom-right,
        // top-right order. They retain orientation for nonuniform and rotated textures.
        switch direction {
        case .down: [SIMD3(a.x, a.y, b.z), SIMD3(a.x, a.y, a.z), SIMD3(b.x, a.y, a.z), SIMD3(b.x, a.y, b.z)]
        case .up: [SIMD3(a.x, b.y, a.z), SIMD3(a.x, b.y, b.z), SIMD3(b.x, b.y, b.z), SIMD3(b.x, b.y, a.z)]
        case .north: [SIMD3(b.x, b.y, a.z), SIMD3(b.x, a.y, a.z), SIMD3(a.x, a.y, a.z), SIMD3(a.x, b.y, a.z)]
        case .south: [SIMD3(a.x, b.y, b.z), SIMD3(a.x, a.y, b.z), SIMD3(b.x, a.y, b.z), SIMD3(b.x, b.y, b.z)]
        case .west: [SIMD3(a.x, b.y, a.z), SIMD3(a.x, a.y, a.z), SIMD3(a.x, a.y, b.z), SIMD3(a.x, b.y, b.z)]
        case .east: [SIMD3(b.x, b.y, b.z), SIMD3(b.x, a.y, b.z), SIMD3(b.x, a.y, a.z), SIMD3(b.x, b.y, a.z)]
        }
    }
}
