

import Foundation

/// Utility for extracting a JSON object from a mixed LLM response.
/// Used when the model may return plain text questions and a FINAL JSON result.
enum JSONExtractor {

    /// Extracts the first valid JSON object `{ ... }` from the given text.
    /// - Parameter text: Raw text returned by the LLM
    /// - Returns: JSON string if found, otherwise `nil`
    static func extractFirstJSONObject(from text: String) -> String? {
        let characters = Array(text)
        var startIndex: Int? = nil
        var braceDepth = 0

        for index in characters.indices {
            let char = characters[index]

            if char == "{" {
                if startIndex == nil {
                    startIndex = index
                }
                braceDepth += 1
            } else if char == "}" {
                guard startIndex != nil else { continue }
                braceDepth -= 1

                if braceDepth == 0, let start = startIndex {
                    return String(characters[start...index])
                }
            }
        }
        return nil
    }
}
