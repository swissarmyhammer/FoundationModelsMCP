import MCP

/// Renders any scalar `Value` (string/int/double/bool) to its string form.
///
/// Shared by ``SchemaConverter``'s `enum` choice construction (JSON Schema
/// `enum` values are not necessarily strings, so `enum: [1, 2, 3]` still
/// needs to produce sensible choices) and ``ToolContentRenderer``'s
/// `enum`-membership validation, which otherwise duplicated this exact
/// switch. Non-scalar values (array/object/null/data) have no defined string
/// form and return `nil`.
///
/// - Parameter value: The value to render.
/// - Returns: The value's string form, or `nil` if it is not a scalar
///   (string/int/double/bool).
func scalarString(_ value: Value) -> String? {
    switch value {
    case .string(let string): return string
    case .int(let int): return String(describing: int)
    case .double(let double): return String(describing: double)
    case .bool(let bool): return String(describing: bool)
    default: return nil
    }
}
