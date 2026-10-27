import ChunkseeKit
import CoreGraphics
import Foundation
import simd

/// Shared orthographic drawing for item pictures and top-down map colors, off the main actor.
/// Kit resolves the format. This client projects its geometry, samples textures and lights faces.
nonisolated enum GameModelRenderer {
    static let size = 64
    static let blockTextureSide = 16

    /// The missing-image presentation chosen in #430, matching MissingTextureAtlasSprite.
    /// Only confirmed absent resources use this image; unreadable/unsupported art stays unavailable.
    static let missingTexture: ItemTexture = {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                let magenta: UInt8 = (x < side / 2) != (y < side / 2) ? 248 : 0
                pixels[offset] = magenta
                pixels[offset + 2] = magenta
                pixels[offset + 3] = 255
            }
        }
        return ItemTexture(width: side, height: side, pixels: pixels)
    }()

    private struct Face {
        let points: [SIMD3<Float>]
        let uv: [SIMD2<Float>]
        let texture: ItemTexture
        let color: SIMD3<Float>
        var depth: Float { points.reduce(0) { $0 + $1.z } / 4 }
    }

    /// MissingCuboidModel is a full cube with no item transform. It goes through the same
    /// projection, lighting, rasterization and visible-pixel averaging as readable models.
    private static func missingFaces(top: Bool) -> [Face] {
        AssetModel.Direction.allCases.compactMap { direction in
            let points = vertices(for: direction, from: .zero, to: .init(repeating: 16)).map { vertex in
                let point = vertex / 16 - 0.5
                return top ? SIMD3(point.x, -point.z, point.y) : point
            }
            let normal = simd_cross(points[1] - points[0], points[3] - points[0])
            guard normal.z > 0.000001 else { return nil }
            return Face(points: points, uv: [SIMD2(0, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0)],
                        texture: missingTexture,
                        color: .init(repeating: top ? 1 : lighting(normal: simd_normalize(normal), emission: 0)))
        }
    }

    static func missingItem() throws -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        try draw(missingFaces(top: false), into: &pixels)
        return CGImage.rgba(pixels, width: size, height: size)
    }

    static func missingTopColor() throws -> MapColor? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        try draw(missingFaces(top: true), into: &pixels)
        return TopAppearance(pixels: pixels).color
    }

    static func missingTopTexture() throws -> ItemTexture {
        var pixels = [UInt8](repeating: 0, count: blockTextureSide * blockTextureSide * 4)
        try draw(missingFaces(top: true), into: &pixels, side: blockTextureSide)
        return ItemTexture(width: blockTextureSide, height: blockTextureSide, pixels: pixels)
    }

    static func render(_ item: AssetItem, colors: [[UInt32]],
                       texture: (Identifier) -> ItemTexture?) throws -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var retainedTextures: [Identifier: ItemTexture] = [:]
        var retainedMaterials: [AssetModel.Material: ItemTexture] = [:]
        var textureBytes = 0
        func load(_ id: Identifier, aspectRatio: Float?) -> ItemTexture? {
            let retained = retainedTextures[id]
            guard let loaded = retained ?? texture(id),
                  Float(loaded.width) / Float(loaded.height) == (aspectRatio ?? 1) else { return nil }
            // Verified static skins can be rectangular. Ordinary textures retain the existing
            // square-only policy, so an unspecified animation strip is not stretched into a skin.
            if retained == nil {
                guard textureBytes + loaded.pixels.count <= 16 * 1024 * 1024 else { return nil }
                textureBytes += loaded.pixels.count
                retainedTextures[id] = loaded
            }
            return loaded
        }
        func resolve(_ material: AssetModel.Material) throws -> ItemTexture? {
            // The ordinary path keeps its identifier cache and does not hash overlay recipes.
            guard !material.overlays.isEmpty else { return load(material.texture, aspectRatio: material.staticTextureAspectRatio) }
            if let retained = retainedMaterials[material] { return retained }
            guard var image = load(material.texture, aspectRatio: material.staticTextureAspectRatio),
                  textureBytes + image.pixels.count <= 16 * 1024 * 1024 else { return nil }
            // Charge the composed skin while its source textures are loaded, so all retained
            // images share the existing budget. Faces reuse one immutable composed result.
            textureBytes += image.pixels.count
            for overlay in material.overlays {
                try Task.checkCancellation()
                guard let layer = load(overlay.texture, aspectRatio: material.staticTextureAspectRatio),
                      let composed = try image.compositing(layer, color: overlay.color) else { return nil }
                image = composed
            }
            retainedMaterials[material] = image
            return image
        }
        // Composite parts are intentionally ordered. A generated item's layers share its
        // plane; separate depth buffers prevent the first layer from hiding later overlays.
        for (partIndex, part) in item.parts.enumerated() {
            try Task.checkCancellation()
            var faces: [Face] = []
            let model = part.model
            func append(_ vertices: [SIMD3<Float>], material: AssetModel.Material, uv: [SIMD2<Float>],
                        tintIndex: Int?, element: AssetModel.Element?) throws -> Bool {
                guard let image = try resolve(material) else { return false }
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
                faces.append(Face(points: points, uv: uv, texture: image, color: color))
                return true
            }
            switch model.geometry {
            case .layers(let layers):
                for layer in layers {
                    // A tiny depth offset lets later generated layers win depth tests,
                    // preserving the game's draw-order behavior for coplanar overlays.
                    let z = Float(8.5) + Float(layer.tintIndex) * 0.001
                    guard try append([SIMD3(0, 16, z), SIMD3(0, 0, z), SIMD3(16, 0, z), SIMD3(16, 16, z)],
                                 material: layer.material, uv: [SIMD2(0, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0)],
                                 tintIndex: layer.tintIndex, element: nil) else { return nil }
                }
            case .elements(let elements):
                for element in elements {
                    try Task.checkCancellation()
                    for direction in AssetModel.Direction.allCases {
                        guard let face = element.faces[direction] else { continue }
                        guard try append(vertices(for: direction, from: element.from, to: element.to), material: face.material,
                                     uv: face.textureCoordinates, tintIndex: face.tintIndex, element: element) else { return nil }
                    }
                }
            }
            try draw(faces, into: &pixels)
        }
        // A resolved empty model intentionally draws nothing; it is distinct from a missing model.
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func draw(_ faces: [Face], into pixels: inout [UInt8], side: Int = size) throws {
        var depths = [Float](repeating: -.infinity, count: side * side)
        for face in faces.enumerated().sorted(by: { $0.element.depth == $1.element.depth ? $0.offset < $1.offset : $0.element.depth < $1.element.depth }) {
            try Task.checkCancellation()
            rasterize(face.element, pixels: &pixels, depths: &depths, side: side)
        }
    }

    struct TopAppearance {
        let color: MapColor?
        let opacity: Double
        let covers: Bool

        init(pixels: [UInt8]) {
            var sum = SIMD3<Double>.zero, alpha = 0.0, covers = !pixels.isEmpty
            for i in stride(from: 0, to: pixels.count, by: 4) {
                sum += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
                alpha += Double(pixels[i + 3])
                covers = covers && pixels[i + 3] == 255
            }
            self.init(sum: sum, alpha: alpha, pixels: pixels.count / 4, covers: covers)
        }

        fileprivate init(sum: SIMD3<Double>, alpha: Double, pixels: Int, covers: Bool) {
            opacity = pixels == 0 ? 0 : alpha / Double(pixels * 255)
            self.covers = covers
            if alpha > 0 {
                let rgb = sum * (255 / alpha)
                color = MapColor(UInt32(UInt8(clamping: Int(rgb.x.rounded()))) << 16
                    | UInt32(UInt8(clamping: Int(rgb.y.rounded()))) << 8 | UInt32(UInt8(clamping: Int(rgb.z.rounded()))))
            } else { color = nil }
        }
    }

    /// Keep the existing color resolution. Coverage uses the same drawing at the close-up
    /// texture resolution, where every alternative must cover every pixel to hide the ground.
    static func topColor(_ block: AssetBlock, tint: (Int) -> UInt32?,
                         texture: (Identifier) -> ItemTexture?) throws -> MapColor? {
        try topAppearance(block, side: size, tint: tint, texture: texture)?.color
    }

    static func topAppearance(_ block: AssetBlock, side: Int = blockTextureSide, tint: (Int) -> UInt32?,
                              texture: (Identifier) -> ItemTexture?) throws -> TopAppearance? {
        var combinations = 1
        for part in block.parts {
            let count = combinations.multipliedReportingOverflow(by: part.alternatives.count)
            guard !count.overflow, count.partialValue <= 64 else { return nil }
            combinations = count.partialValue
        }
        var sum = SIMD3<Double>.zero, alpha = 0.0, covers = true, readable = true
        var retained: [Identifier: ItemTexture] = [:], textureBytes = 0
        func accumulate(_ part: Int, alternatives: [AssetBlock.Alternative], weight: Double) throws {
            guard readable else { return }
            if part < block.parts.count {
                let choices = block.parts[part].alternatives
                let total = Double(choices.reduce(0) { $0 + $1.weight })
                for choice in choices {
                    try accumulate(part + 1, alternatives: alternatives + [choice], weight: weight * Double(choice.weight) / total)
                }
                return
            }
            guard let image = try topTexture(alternatives, tint: tint, texture: texture, side: side,
                                            retained: &retained, textureBytes: &textureBytes) else {
                readable = false
                return
            }
            for i in stride(from: 0, to: image.pixels.count, by: 4) {
                sum += SIMD3(Double(image.pixels[i]), Double(image.pixels[i + 1]), Double(image.pixels[i + 2])) * weight
                alpha += Double(image.pixels[i + 3]) * weight
                covers = covers && image.pixels[i + 3] == 255
            }
        }
        try accumulate(0, alternatives: [], weight: 1)
        return readable ? TopAppearance(sum: sum, alpha: alpha, pixels: side * side, covers: covers) : nil
    }

    /// Actual chosen models share the top-color geometry/UV path, but preserve individual
    /// pixels instead of averaging them. Sixteen pixels per block matches the supplied jar art.
    static func topTexture(_ alternatives: [AssetBlock.Alternative], tint: (Int) -> UInt32?,
                           texture: (Identifier) -> ItemTexture?, side: Int = blockTextureSide) throws -> ItemTexture? {
        var retained: [Identifier: ItemTexture] = [:], textureBytes = 0
        return try topTexture(alternatives, tint: tint, texture: texture, side: side,
                              retained: &retained, textureBytes: &textureBytes)
    }

    private static func topTexture(_ alternatives: [AssetBlock.Alternative], tint: (Int) -> UInt32?,
                                   texture: (Identifier) -> ItemTexture?, side: Int,
                                   retained: inout [Identifier: ItemTexture], textureBytes: inout Int) throws -> ItemTexture? {
        var faces: [Face] = []
        for alternative in alternatives {
            try Task.checkCancellation()
            guard let prepared = try topFaces(alternative, tint: tint, texture: texture,
                                               retained: &retained, textureBytes: &textureBytes),
                  prepared.count <= 4096 - faces.count else { return nil }
            faces.append(contentsOf: prepared)
        }
        if faces.isEmpty {
            return try uprightTexture(alternatives, tint: tint, texture: texture, side: side,
                                      retained: &retained, textureBytes: &textureBytes)
        }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        try draw(faces, into: &pixels, side: side)
        return ItemTexture(width: side, height: side, pixels: pixels)
    }

    private static func topFaces(_ alternative: AssetBlock.Alternative, tint: (Int) -> UInt32?,
                                 texture: (Identifier) -> ItemTexture?, retained: inout [Identifier: ItemTexture],
                                 textureBytes: inout Int, upright: Bool = false) throws -> [Face]? {
        guard case .elements(let elements) = alternative.model.geometry else { return nil }
        let r = SIMD3<Float>(alternative.rotation) * (-Float.pi / 180)
        let rotation = simd_quatf(angle: r.z, axis: SIMD3(0, 0, 1))
            * simd_quatf(angle: r.y, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: r.x, axis: SIMD3(1, 0, 0))
        var faces: [Face] = []
        for element in elements {
            try Task.checkCancellation()
            for direction in AssetModel.Direction.allCases {
                guard let face = element.faces[direction] else { continue }
                let points = vertices(for: direction, from: element.from, to: element.to).map {
                    let p = rotation.act(rotate($0, by: element.rotation) / 16 - 0.5)
                    return SIMD3<Float>(p.x, -p.z, p.y)
                }
                guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
                let normal = simd_cross(points[1] - points[0], points[3] - points[0])
                if upright {
                    guard abs(normal.z) <= 0.000001, simd_length_squared(normal) > 0.000001 else { continue }
                } else {
                    guard normal.z > 0.000001 else { continue }
                }
                let image: ItemTexture
                if let cached = retained[face.material.texture] { image = cached }
                else {
                    guard let loaded = texture(face.material.texture), loaded.height >= loaded.width,
                          loaded.height % loaded.width == 0,
                          textureBytes + loaded.pixels.count <= 16 * 1024 * 1024 else { return nil }
                    // Block animations are vertical strips; use their first image frame.
                    image = ItemTexture(width: loaded.width, height: loaded.width,
                                        pixels: Array(loaded.pixels.prefix(loaded.width * loaded.width * 4)))
                    textureBytes += loaded.pixels.count
                    retained[face.material.texture] = image
                }
                let rgb: UInt32
                if let index = face.tintIndex {
                    guard let value = tint(index) else { return nil }
                    rgb = value
                } else { rgb = 0xffffff }
                let color = SIMD3<Float>(Float((rgb >> 16) & 255), Float((rgb >> 8) & 255), Float(rgb & 255)) / 255
                faces.append(Face(points: points, uv: alternative.textureCoordinates(for: face, facing: direction),
                                  texture: image, color: color))
            }
        }
        return faces
    }

    /// Edge-on plants have no top pixels. Sample their own UV rectangles through the same
    /// rasterizer and use the area-weighted texture average as a translucent ground tint.
    private static func uprightTexture(_ alternatives: [AssetBlock.Alternative], tint: (Int) -> UInt32?,
                                       texture: (Identifier) -> ItemTexture?, side: Int,
                                       retained: inout [Identifier: ItemTexture], textureBytes: inout Int) throws -> ItemTexture? {
        var sum = SIMD4<Double>.zero, area = 0.0, count = 0
        let square: [SIMD3<Float>] = [SIMD3(-0.5, 0.5, 0), SIMD3(-0.5, -0.5, 0),
                                     SIMD3(0.5, -0.5, 0), SIMD3(0.5, 0.5, 0)]
        for alternative in alternatives {
            guard let faces = try topFaces(alternative, tint: tint, texture: texture, retained: &retained,
                                           textureBytes: &textureBytes, upright: true),
                  faces.count <= 4096 - count else { return nil }
            count += faces.count
            for face in faces {
                let weight = Double(simd_length(simd_cross(face.points[1] - face.points[0], face.points[3] - face.points[0])))
                var pixels = [UInt8](repeating: 0, count: side * side * 4)
                try draw([Face(points: square, uv: face.uv, texture: face.texture, color: face.color)], into: &pixels, side: side)
                for i in stride(from: 0, to: pixels.count, by: 4) {
                    sum += SIMD4(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]), Double(pixels[i + 3])) * weight
                }
                area += weight * Double(side * side)
            }
        }
        let average = area > 0 ? sum / area : .zero
        let rgba = (0..<4).map { UInt8(clamping: Int(average[$0].rounded())) }
        return ItemTexture(width: side, height: side, pixels: Array(repeating: rgba, count: side * side).flatMap { $0 })
    }

    private static func rasterize(_ face: Face, pixels: inout [UInt8], depths: inout [Float], side: Int) {
        let points = face.points.map { SIMD2<Float>(($0.x + 0.5) * Float(side), (0.5 - $0.y) * Float(side)) }
        let a = points[3] - points[0], b = points[1] - points[0]
        let determinant = a.x * b.y - a.y * b.x
        guard determinant.isFinite, abs(determinant) > 0.000001 else { return }
        let minX = Int(max(0, min(Float(side), floor(points.map(\.x).min()!))))
        let maxX = Int(max(0, min(Float(side), ceil(points.map(\.x).max()!))))
        let minY = Int(max(0, min(Float(side), floor(points.map(\.y).min()!))))
        let maxY = Int(max(0, min(Float(side), ceil(points.map(\.y).max()!))))
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) - points[0]
                let u = (offset.x * b.y - offset.y * b.x) / determinant
                let v = (a.x * offset.y - a.y * offset.x) / determinant
                guard u >= 0, u < 1, v >= 0, v < 1 else { continue }
                let index = y * side + x
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
        guiRotation(transform.rotation).act((rotate(vertex, by: element) / 16 - 0.5) * transform.scale) + transform.translation
    }

    private static func rotate(_ vertex: SIMD3<Float>, by element: AssetModel.Rotation?) -> SIMD3<Float> {
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
        return point
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
