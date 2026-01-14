

import Foundation

/// Parsed FINAL response returned by the agent
/// Used only when the model decides that enough data is collected
/// and emits a FINAL JSON object.
struct AgentResponse: Codable, Identifiable {

    /// Stable identifier for SwiftUI lists
    var id: String { time + "|" + title }

    /// ISO-8601 timestamp
    let time: String

    /// Main payload (e.g. FINAL_TZ text)
    let answer: String

    /// Semantic tags returned by the agent
    let key_tags: [String]

    /// Title of the response (e.g. FINAL_TZ)
    let title: String

    /// Role of the AI (always "assistant")
    let ai_role: String
}
