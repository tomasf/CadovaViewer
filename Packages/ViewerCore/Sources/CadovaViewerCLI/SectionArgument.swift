import ArgumentParser
import simd
import ViewerCore

/// A `--section` value: a cutting plane, and which side of it to cut away.
///
/// - `z=12`: the plane z = 12, cutting away the +Z side (everything above). `x`, `y` and `z` work the
///   same way, and a leading minus (`-z=12`) cuts away the other side instead.
/// - `1,1,0@10,0,5`: the plane through the point (10, 0, 5) with normal (1, 1, 0), cutting away the
///   side the normal points to.
struct SectionArgument: ExpressibleByArgument {
    let crossSection: CrossSection

    static let formatHelp = "<axis>=<position> (e.g. z=12, -x=0) or <normal>@<point> (e.g. 1,1,0@10,0,5)"

    init?(argument: String) {
        if let at = argument.firstIndex(of: "@") {
            guard let normal = Self.vector(argument[..<at]),
                  let point = Self.vector(argument[argument.index(after: at)...]),
                  simd_length(normal) > 0
            else { return nil }
            crossSection = CrossSection(origin: point, orientation: CrossSection.orientation(toward: normal))
        } else if let equals = argument.firstIndex(of: "=") {
            var axisName = argument[..<equals].lowercased()
            var sign = 1.0
            if axisName.hasPrefix("-") {
                sign = -1
                axisName.removeFirst()
            } else if axisName.hasPrefix("+") {
                axisName.removeFirst()
            }
            guard let axis = CrossSection.Axis.allCases.first(where: { $0.displayName.lowercased() == axisName }),
                  let position = Double(argument[argument.index(after: equals)...]),
                  position.isFinite
            else { return nil }
            crossSection = CrossSection(origin: axis.unit * position, orientation: CrossSection.orientation(toward: axis.unit * sign))
        } else {
            return nil
        }
    }

    /// Parses `x,y,z` into a finite vector.
    private static func vector(_ text: Substring) -> SIMD3<Double>? {
        let components = text.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard components.count == 3, let x = components[0], let y = components[1], let z = components[2],
              x.isFinite, y.isFinite, z.isFinite
        else { return nil }
        return SIMD3(x, y, z)
    }
}
