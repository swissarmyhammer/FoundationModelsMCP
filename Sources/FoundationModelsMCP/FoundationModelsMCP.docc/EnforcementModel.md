# The enforcement model: declare vs. enforce

This bridge never drives generation. It **declares** each tool's argument
shape; the session's model **enforces** it while arguments are generated.

## Overview

An MCP tool call is, fundamentally, "produce a JSON object that conforms to
the tool's `inputSchema`." `FoundationModels` enforces **constrained
decoding** at the tool-call boundary: when the model emits a tool call, it is
forced *at the token level* to produce arguments matching that tool's
`parameters: GenerationSchema` — a formal guarantee that arguments are
schema-valid whenever a call is produced at all.

``SchemaConverter`` is what makes that guarantee tight. It is not merely
*describing* the expected shape to the model — its output *is* the constraint
that generation is checked against. ``SchemaConverter/parse(_:name:onDrop:)``
walks an MCP tool's raw `inputSchema` into ``SchemaIR``, an inspectable
intermediate representation, and ``SchemaConverter/emit(_:)`` turns that into
the `DynamicGenerationSchema` / `GenerationSchema` FoundationModels actually
constrains against. Two levers this conversion pulls, both **hard**
constraints enforced by the model's own constrained decoding — not
description hints:

- **Structure:** types, `required`, nesting, arrays, and `enum` (mapped to a
  named choice schema in ``SchemaIR/object(name:description:properties:)`` and
  ``SchemaIR/enumeration(name:description:values:)``).
- **Guides:** JSON Schema `minimum`/`maximum`, `pattern`, and
  `minItems`/`maxItems` become real `GenerationGuide` values, layered onto a
  structural base via ``SchemaIR/guided(base:guide:)``.

A JSON Schema construct with no `DynamicGenerationSchema` equivalent (e.g.
`anyOf`/`oneOf` unions, `patternProperties`) degrades to
``SchemaIR/unknown`` — a permissive string schema — and is logged via the
caller-supplied ``SchemaConversionLogHandler`` rather than silently
misrepresented.

## Who enforces what

*Which* engine performs the constrained decoding depends on the model backing
the `LanguageModelSession` — Apple's built-in guided generation on
`SystemLanguageModel`, or an xgrammar-constrained engine under an MLX-backed
session supplied by a host or by `FoundationModelsRouter`/
`FoundationModelsMultitool`. This package depends on neither; the
`FoundationModels` `Tool` protocol is the seam, so any conforming session
enforces the declared schema identically as far as this bridge is concerned.

By the time ``MCPTool/call(arguments:)`` runs, the arguments were already
generated (and constrained) upstream — the adapter is a pass-through: encode
arguments, call `client.callTool`, render the result via
``ToolContentRenderer``. There is deliberately **no validation or repair
layer** inside the tool itself. Two consequences follow directly from that:

- **The MCP server is the real validator.** A malformed or semantically
  invalid call is the server's `isError` result to report, not this
  package's to pre-empt. That result bubbles back to the model, which can
  adjust and retry with full conversational context — see
  ``ToolContentRenderer/render(result:outputSchema:budget:)``, which renders
  an `isError` result as a marked `"Error:"` paragraph rather than hiding it.
- **``ToolContentRenderer`` validates only a narrow, declared subset — never
  the tool's actual argument-time contract.** When a tool declares an
  `outputSchema`, `render(result:outputSchema:budget:)` checks
  `structuredContent` against the pinned type/required/enum subset that
  validation covers; a mismatch is surfaced to the model as a note in the
  rendered text, not thrown or hidden. This is **shallow, best-effort
  observability on the way out**, not enforcement — it exists so a
  server that violates its own declared `outputSchema` is visible to the
  model, not so callers can rely on it as a guarantee. It has no bearing on
  the argument-generation guarantee above, which is the model's constrained
  decoding, not anything this renderer checks.

## The raw schema is always available too

Alongside the converted `GenerationSchema`, every ``ToolDescriptor`` exposes
the **original MCP `inputSchema` verbatim** as plain data. The
`GenerationSchema` mapping in this package is necessarily lossy for
constructs `DynamicGenerationSchema` cannot express (see ``SchemaIR/unknown``
above); a driver that owns its own generation — e.g.
`FoundationModelsMultitool`, constraining calls with xgrammar at full JSON
Schema fidelity (`anyOf`/`oneOf`/`additionalProperties` included) — can
compile the raw schema directly instead of going through this package's
mapping. Declaration bounds only what *this* bridge asserts to the model; it
never bounds what a schema-fidelity-preserving external driver can do with
the same tool.
