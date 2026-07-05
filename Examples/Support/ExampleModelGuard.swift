import FoundationModels

/// Checks `SystemLanguageModel` availability for `exampleName` and prints a
/// clean, non-crashing message if it's unavailable — the guard every
/// `Examples/` target's model-dependent runtime path runs first, so a
/// machine without Apple Intelligence never crashes running any of them.
///
/// - Parameters:
///   - exampleName: The example's display name, named in the printed
///     message.
///   - isAvailable: Whether the system language model is available. Defaults
///     to `SystemLanguageModel.default.isAvailable`; overridable so this
///     function is directly testable without a real model.
/// - Returns: `true` if `isAvailable`; otherwise prints a message naming
///   `exampleName` and returns `false`.
public func checkSystemLanguageModelAvailable(
    exampleName: String,
    isAvailable: Bool = SystemLanguageModel.default.isAvailable
) -> Bool {
    guard isAvailable else {
        print(
            "SystemLanguageModel is not available on this machine; \(exampleName) requires Apple Intelligence (see SystemLanguageModel.default.isAvailable)."
        )
        return false
    }
    return true
}
