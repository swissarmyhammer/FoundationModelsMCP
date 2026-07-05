# The M8 catalog consumer contract

This content now lives in the DocC catalog, as a proper article rather than a
plain markdown file duplicating the doc comments it describes:
`Sources/FoundationModelsMCP/FoundationModelsMCP.docc/CatalogConsumerContract.md`.

Build the docs to read it rendered, with working cross-references to every
symbol it names:

```
swift package generate-documentation --target FoundationModelsMCP
```

Or in Xcode: **Product → Build Documentation**.

This stub is kept (rather than deleted outright) only so a link to this path
from an earlier task or commit still resolves to an explanation of where the
content moved, per the "don't duplicate the DocC catalog" instruction that
retired this file's original body.
