import FoundationModels

/// What interpreting a request produced: the plan, plus how long it took and how
/// many tokens it used (tokens are available on macOS 27+, nil otherwise).
struct Interpretation {
    let plan: Plan
    let tokens: Int?
}

/// The structured result the on-device model produces for a natural-language request.
@Generable
struct Plan: Codable {
    @Guide(description: "A single POSIX shell command for macOS that fulfills the request. No markdown, no backticks, no comments, no explanation. One command only.")
    let command: String

    @Guide(description: "true if the command deletes, overwrites, or moves data, needs sudo/root, changes system or network state, or is otherwise irreversible. false only for clearly read-only commands.")
    let risky: Bool

    @Guide(description: "A short, plain-language explanation of what the command does, one sentence.")
    let explanation: String
}
