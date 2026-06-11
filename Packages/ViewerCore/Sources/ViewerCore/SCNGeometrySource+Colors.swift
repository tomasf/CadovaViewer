import SceneKit

extension SCNGeometrySource {
    /// A per-vertex color source from RGBA vectors.
    public static func colors(_ array: [SCNVector4]) -> Self {
        array.withUnsafeBufferPointer { bufferPointer in
            Self(
                data: Data(buffer: bufferPointer),
                semantic: .color,
                vectorCount: array.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<CGFloat>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SCNVector4>.stride
            )
        }
    }
}
