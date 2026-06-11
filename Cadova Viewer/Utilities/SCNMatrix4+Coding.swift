import SceneKit

extension SCNMatrix4 {
    /// A `Codable` representation of a matrix as its four columns, used to persist camera
    /// transforms in `ViewOptions`.
    struct CodingWrapper: Codable {
        let columns: [[Double]]

        init(_ matrix: SCNMatrix4) {
            let simdMatrix = matrix_double4x4(matrix)
            columns = (0..<4).map { a in
                (0..<4).map { b in
                    simdMatrix[a][b]
                }
            }
        }

        var scnMatrix4: SCNMatrix4 {
            var simdMatrix = matrix_double4x4()
            for a in 0..<4 {
                for b in 0..<4 {
                    simdMatrix[a][b] = columns[a][b]
                }
            }
            return SCNMatrix4(simdMatrix)
        }
    }
}
