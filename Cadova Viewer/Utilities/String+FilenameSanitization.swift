import Foundation

extension String {
    /// A filesystem-safe form of the string: runs of path separators and control characters
    /// (which can appear in freely user-authored 3MF object names) collapse to a single hyphen.
    func sanitizedForFilename() -> String {
        let disallowed = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        return components(separatedBy: disallowed)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
    }
}
