import Foundation

/// Holds the two `Uniforms` declarations together.
///
/// The shader's copy is source text compiled at launch, so it can never be the
/// same declaration as the Swift one — but it can be *checked* against it. The
/// struct is all-`Float` on purpose, which means declaration order is the
/// memory layout, which means a reorder on one side silently feeds every field
/// after it to the wrong parameter. A size check does not catch that; comparing
/// the names in order does.
public enum UniformContract {
    public struct Mismatch {
        public let index: Int
        public let swift: String?
        public let metal: String?

        public var describe: String {
            "position \(index): swift \(swift ?? "—") vs metal \(metal ?? "—")"
        }
    }

    /// Field names of `struct Uniforms` as declared in BlackHole.metal, in
    /// order. Empty if the struct could not be found at all.
    public static func metalFields(in source: String) -> [String] {
        guard let start = source.range(of: "struct Uniforms") else { return [] }
        guard let open = source.range(of: "{", range: start.upperBound..<source.endIndex),
              let close = source.range(of: "}", range: open.upperBound..<source.endIndex)
        else { return [] }

        var names: [String] = []
        for rawLine in source[open.upperBound..<close.lowerBound].split(separator: "\n") {
            // Strip a trailing line comment before looking for declarations.
            let line = rawLine.components(separatedBy: "//")[0]
                .trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("float ") else { continue }
            let body = line.dropFirst("float ".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
            names += body.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
        return names
    }

    /// Every position where the two declarations disagree. Empty means they are
    /// the same struct spelled twice.
    public static func check(metalSource: String) -> [Mismatch] {
        let swift = Uniforms.fieldNames
        let metal = metalFields(in: metalSource)
        var out: [Mismatch] = []
        for i in 0..<max(swift.count, metal.count) {
            let a = i < swift.count ? swift[i] : nil
            let b = i < metal.count ? metal[i] : nil
            if a != b { out.append(Mismatch(index: i, swift: a, metal: b)) }
        }
        return out
    }

    public static func fieldCounts(metalSource: String) -> (swift: Int, metal: Int) {
        (Uniforms.fieldNames.count, metalFields(in: metalSource).count)
    }
}
