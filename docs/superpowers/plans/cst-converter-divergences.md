# CST converter: JuliaSyntax/CSTParser divergence log

Cases where the converter cannot (or does not yet) reproduce CSTParser's
output because the two parsers genuinely disagree at the structural level,
not just in layout. Used sparingly — most oracle diffs are layout gaps in
the converter, fixed directly rather than logged here.

## Task 9

No gate snippet required a `@test_broken` entry — all 29 brief snippets plus
the inherited concerns (cmd literals, triple-quoted strings, multi-chunk
line-continuation strings, compound assignment/short-circuit, dotted
macrocalls, comparison chains, juxtaposition, standalone braces) reached
oracle equality with a real fix rather than a shim. Two round-2 review
findings (raw/regex string escape corruption; bare-string-literal `$(...)`
losing its `:string` wrapper) were likewise FIXED, not logged: the raw case
turned out to be flag-detectable (`RAW_STRING_FLAG` on the `K"string"` node
mirrors CSTParser's `prefixed != false` path exactly), so no macro-name
heuristic was needed.

One approximation remains flagged (not gate-blocking, no known failing
input):

- **Cmd-literal `$(...)` interpolation is reconstructed by a best-effort
  re-scan**: JuliaSyntax's green tree never decomposes backtick-literal
  interpolation at all (a `CmdString` leaf's raw text can contain a literal
  unescaped `$` with no child node — real Julia defers `$`-splitting in cmd
  literals to the `@cmd` macro at expansion time), unlike double-quoted
  strings where the green tree already splits real children. The converter's
  `split_cmd_dollar` (terminals.jl) manually re-scans the raw leaf text and
  recursively re-parses `$(...)` groups via `build_cst`, verified correct
  against the oracle for the gate snippets and for a real corpus example
  (`CloudIndex/driver.jl`'s multi-interpolation `inner = \`...\`` cmd
  literal). The paren-matching is naive (depth-counting only, no awareness
  of nested strings/comments containing parens) — a `$(f("("))`-style case
  inside a cmd literal would mis-scan. Not hit by the current corpus;
  flagged rather than hardened, since fixing it generally requires the same
  tokenizer JuliaSyntax itself uses for the inner re-parse boundary.

## Task 10

- **A file that begins with a `;` before any statement** (e.g. `"; a"`) — a
  genuine structural disagreement, not a layout gap. JuliaSyntax nests the
  leading `;` and the following statement in ONE `K"toplevel"` green node
  (`toplevel[;, a]`), whereas CSTParser splits them across two file-level
  slots: an empty leading statement wrapped in its own nested toplevel, then
  the real statement as a sibling — `file[ toplevel[NOTHING], a ]`. The
  converter cannot produce that split from the single flat green node without
  re-deriving CSTParser's statement-grouping pass. It DOES synthesize the
  leading `NOTHING` placeholder (so widths balance and `check_spans` passes,
  and the pure-`;` degenerate `;;` matches the oracle exactly), but `"; a"`
  still reports `args length 1 vs 2`. This input never occurs in real
  code (a source file cannot meaningfully start with `;`); zero corpus files
  hit it. Resolution: accept drift — downstream never sees leading-`;` files.

- **Suffixed comparison operators in a chain** (e.g. `a ==ᵥ b == c`) — a
  genuine parser disagreement. JuliaSyntax classifies the suffixed `==ᵥ` as
  comparison-precedence and emits ONE flat `K"comparison"` node
  (`comparison[a, ==ᵥ, b, ==, c]`), whereas CSTParser does not recognise the
  suffixed operator as comparison-class and parses right-to-left into nested
  binary `:call`s (`(==)((==ᵥ)(a,b), c)`). Reproducing CSTParser's shape would
  require re-deriving its operator-precedence table for arbitrary suffixed
  unicode operators — information absent from the green tree. 1 corpus file
  (`BlockArrays/test/test_blockindices.jl`). `check_spans` passes.
  Resolution: accept drift.

- **CSTParser is stricter than JuliaSyntax on a few malformed/edge inputs and
  emits `:errortoken`/`:error` where JuliaSyntax accepts (or vice versa).**
  These are inputs no valid program contains; the converter follows
  JuliaSyntax (it has no error node to mirror). Confirmed cases, all
  `check_spans`-clean, each in 1 corpus test file:
  - `@async try … finally … catch e … end` — a `finally` clause BEFORE
    `catch` (invalid order). CSTParser wraps the stray `catch` in an
    `:errortoken`; JuliaSyntax parses the clauses in the given order.
    (`JSONRPC/test/test_json_serialization.jl`)
  - `@SVector[…]'` — postfix adjoint applied to a `[...]`-macrocall. CSTParser
    wraps the whole thing in an `:errortoken`; JuliaSyntax produces the plain
    adjoint call. (`StaticArrays/test/linalg.jl`)
  - `\b` as a bare expression — an invalid use of `\`. CSTParser emits an
    `:errortoken`; JuliaSyntax makes a `:call`.
    (`BlockBandedMatrices/examples/finitedifference_2d.jl`)
  Resolution: accept drift.

- **Deep context-dependent span/arg discrepancies** (3 corpus files:
  `StaticArrays/src/blas.jl` — `@eval`-block RHS inside a nested cartesian
  `for (a,b) in …, (c,d) in …`; `StaticArrays/test/broadcast.jl` — a nested
  `@testset`/`@test`/`@inferred`/`SA[…]` stack; `CodeTracking/test/script.jl`
  — a file-level statement count off by one around a `'\n'` char literal + `;`).
  Each fails only when embedded in its full surrounding context; every minimal
  extraction of the construct converts identically to the oracle, and all
  three are `check_spans`-clean. Not reduced to a fixable rule within this
  task's budget; documented as remaining loop state rather than a claimed
  divergence.
