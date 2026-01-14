

import Foundation

// MARK: - Local tools available for the agent
// These tools are called locally (no backend) and can be extended later.

enum LocalTools {

    // MARK: Time tool
    static func currentTimeISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: Simple calculator
    static func calculate(_ expression: String) -> String {
        let exp = NSExpression(format: expression)
        if let result = exp.expressionValue(with: nil, context: nil) {
            return "\(result)"
        } else {
            return "Error"
        }
    }

    // MARK: Tool dispatcher (used by the agent)
    static func run(tool: String, arguments: [String: String]) -> String {
        switch tool {
        case "time":
            return currentTimeISO()
        case "calc":
            return calculate(arguments["expression"] ?? "0")
        default:
            return "Unknown tool"
        }
    }
}
