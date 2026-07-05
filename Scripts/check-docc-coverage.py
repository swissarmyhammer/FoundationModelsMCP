#!/usr/bin/env python3
"""Fail CI if a public symbol this package declares lacks a doc-comment abstract.

Why this script exists (and `swift package generate-documentation
--warnings-as-errors` alone does not suffice): DocC has no "undocumented
symbol" *warning* class at all. `--warnings-as-errors` only promotes genuine
DocC diagnostics (unresolved ``symbol`` cross-references, malformed
directives, and the like) to build-failing errors — a fully undocumented
public symbol produces zero warning output under that flag, verified
directly by temporarily stripping a public type's doc comment and re-running
the command (exit 0, no warnings). The *only* facility that reports missing
documentation at all is `--experimental-documentation-coverage`, and that
flag's own exit code ignores coverage entirely — it only ever writes a
summary/detailed report to stdout. This script is the actual enforcement
for the "zero missing-documentation warnings for public symbols" acceptance
criterion: it parses that detailed report and fails if anything outside a
short, explicit, documented allowlist is missing an abstract.

Usage:
    swift package generate-documentation --target FoundationModelsMCP \\
        --experimental-documentation-coverage --coverage-summary-level detailed \\
        > docc-coverage.txt
    python3 Scripts/check-docc-coverage.py docc-coverage.txt
"""

import sys

# Kinds DocC synthesizes with no corresponding declaration in this package's
# own source to attach a doc comment to:
#
# - "CollectionGroup": auto-generated "<Protocol> Implementations" navigation
#   pages grouping a type's protocol-conformance members (Equatable, Error,
#   Actor, Tool, MCPToolProvider, MCPToolCalling implementations) — present
#   for every conforming type in any DocC-documented Swift codebase.
# - "Extended Module": the container page DocC creates when this package
#   extends a type from an *external* module (MCP, FoundationModels) — there
#   is no source location for a bare module name to declare a doc comment on.
# - "Article": prose articles' abstract-detection isn't meaningful the same
#   way a symbol's doc-comment first sentence is; DocC's own summary table
#   already excludes articles from the "Types" percentage.
UNFIXABLE_KINDS = {"CollectionGroup", "Extended Module", "Article"}

# (kind, reference-path-suffix) pairs for specific compiler/framework-
# synthesized members that are not declared anywhere in this package's
# source, so there is no `///` comment to add:
#
# - Operator "!=(_:_:)": Swift's `Equatable` protocol extension
#   auto-synthesizes `!=` from `==` for every conforming type.
# - The four `Instance Method`s: the `Actor` protocol's default
#   isolation-checking implementations, inherited by the `MCPServer` actor.
#   Overriding them just to attach a doc comment would be a behavior change
#   with no documentation value.
# - Instance Property "localizedDescription": Foundation's `Error` bridging
#   to `NSError` synthesizes this for every `Error`-conforming type.
# - Type Alias "SessionProperty": the `FoundationModels.Tool` protocol
#   synthesizes a nested `SessionProperty` type on every conforming type;
#   it is not declared anywhere in this package's own source.
# - Extended Type "Elicitation" (bare, no further path segment): the
#   synthesized container one level above `Elicitation.RequestSchema`, which
#   this package *does* document (see the `extension Elicitation.RequestSchema`
#   doc comment in `ElicitationCoordinator.swift`) — there is no
#   `extension Elicitation` of our own to attach a comment to for the bare
#   `Elicitation` namespace itself.
UNFIXABLE_MEMBER_SUFFIXES = [
    ("Operator", "/!=(_:_:)"),
    ("Instance Method", "/assumeIsolated(_:file:line:)"),
    ("Instance Method", "/preconditionIsolated(_:file:line:)"),
    ("Instance Method", "/assertIsolated(_:file:line:)"),
    ("Instance Method", "/withSerialExecutor(_:)"),  # matches both disambiguated overloads (each carries a compiler-generated "-<hash>" suffix after this)
    ("Instance Property", "/localizedDescription"),
    ("Type Alias", "/SessionProperty"),
    ("Extended Type", "/MCP/Elicitation"),
]


def parse_rows(text):
    """Yields (name, kind, has_abstract, reference_path) for each detailed-table data row in `text`."""
    for line in text.splitlines():
        if "|" not in line:
            continue
        fields = [f.strip() for f in line.split("|")]
        # Data rows have exactly 8 pipe-separated fields (Name, Kind,
        # Abstract?, Curated?, Code Listing?, Parameters, Language,
        # Reference Path); the coverage-summary rows (Types/Members/Globals)
        # have 4, and the header row has none (it's space-separated).
        if len(fields) != 8:
            continue
        name, kind, abstract, _curated, _code, _params, _lang, path = fields
        if abstract not in ("true", "false"):
            continue
        yield name, kind, abstract == "true", path


def is_allowlisted(kind, path):
    if kind in UNFIXABLE_KINDS:
        return True
    for allowed_kind, suffix in UNFIXABLE_MEMBER_SUFFIXES:
        if kind == allowed_kind and suffix in path:
            return True
    return False


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <coverage-report-file>", file=sys.stderr)
        return 2

    with open(sys.argv[1], encoding="utf-8") as f:
        text = f.read()

    rows = list(parse_rows(text))
    if not rows:
        print(
            "check-docc-coverage: no detailed-table rows parsed from "
            f"{sys.argv[1]!r} — the report format may have changed; "
            "update this script's parser.",
            file=sys.stderr,
        )
        return 2

    undocumented = [
        (name, kind, path)
        for name, kind, has_abstract, path in rows
        if not has_abstract and not is_allowlisted(kind, path)
    ]

    if undocumented:
        print(
            f"check-docc-coverage: {len(undocumented)} public symbol(s) "
            "are missing a documentation abstract:",
            file=sys.stderr,
        )
        for name, kind, path in undocumented:
            print(f"  {kind}: {name} ({path})", file=sys.stderr)
        return 1

    print(f"check-docc-coverage: OK — {len(rows)} symbols checked, none undocumented outside the allowlist.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
