import SceneKit

extension SCNGeometrySource {
    /// Decodes the source's positions into `SCNVector3`s, handling both 32- and 64-bit
    /// component formats and the source's stride/offset.
    public func decodedVertices() -> [SCNVector3] {
        let count = vectorCount
        let stride = dataStride
        let offset = dataOffset
        let wide = bytesPerComponent == 8
        return data.withUnsafeBytes { raw -> [SCNVector3] in
            var vertices: [SCNVector3] = []
            vertices.reserveCapacity(count)
            for i in 0..<count {
                let base = i * stride + offset
                if wide {
                    let x = raw.loadUnaligned(fromByteOffset: base, as: Float64.self)
                    let y = raw.loadUnaligned(fromByteOffset: base + 8, as: Float64.self)
                    let z = raw.loadUnaligned(fromByteOffset: base + 16, as: Float64.self)
                    vertices.append(SCNVector3(x, y, z))
                } else {
                    let x = raw.loadUnaligned(fromByteOffset: base, as: Float32.self)
                    let y = raw.loadUnaligned(fromByteOffset: base + 4, as: Float32.self)
                    let z = raw.loadUnaligned(fromByteOffset: base + 8, as: Float32.self)
                    vertices.append(SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)))
                }
            }
            return vertices
        }
    }
}

extension SCNGeometryElement {
    /// The vertex indices of a `.line` primitive element (empty for other primitive types),
    /// decoded for whatever index width the element uses.
    public func decodedLineIndices() -> [Int] {
        guard primitiveType == .line else { return [] }
        let indexCount = primitiveCount * 2
        let bytesPerIndex = bytesPerIndex
        return data.withUnsafeBytes { raw -> [Int] in
            var indices: [Int] = []
            indices.reserveCapacity(indexCount)
            for i in 0..<indexCount {
                let base = i * bytesPerIndex
                switch bytesPerIndex {
                case 1: indices.append(Int(raw.loadUnaligned(fromByteOffset: base, as: UInt8.self)))
                case 2: indices.append(Int(raw.loadUnaligned(fromByteOffset: base, as: UInt16.self)))
                case 8: indices.append(Int(raw.loadUnaligned(fromByteOffset: base, as: UInt64.self)))
                default: indices.append(Int(raw.loadUnaligned(fromByteOffset: base, as: UInt32.self)))
                }
            }
            return indices
        }
    }
}
