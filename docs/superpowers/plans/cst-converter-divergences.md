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

- **Statement group split at a mid-file `;` after a block form** — same
  structural family as the leading-`;` entry above. `CodeTracking/test/
  script.jl` reduces to:

  ```julia
  struct S
  end;1
  ```

  Oracle (CSTParser) hoists the post-`;` statement to a FILE-level sibling,
  wrapping only the pre-`;` group in a nested toplevel:

  ```
  file
    toplevel            fs=13 s=12
      struct …end
    INTEGER "1"         fs=1 s=1
  ```

  Ours (from the single flat green `toplevel[struct, ;, 1]` node):

  ```
  file
    toplevel            fs=14 s=14
      struct …end
      INTEGER "1"
  ```

  Reproducing the split would require re-deriving CSTParser's file-level
  statement-grouping pass (which decides per-`;` whether the run continues
  the group or starts a file sibling) — information not represented in the
  green tree. `check_spans` passes. Resolution: accept drift.
  (Task-10 round-2 note: this was initially misfiled as "context-dependent /
  resists reduction"; the reviewer reduced it to the two-liner above.)

- **JuliaSyntax's parser overflows on a file CSTParser parses fine** —
  `JuliaSyntax/src/tokenize_utils.jl` (a deeply-nested chained-`||`
  expression): `CSTParser.parse(src, true)` succeeds, but our pipeline's
  `JuliaSyntax.parse!` throws `StackOverflowError` before the converter ever
  runs. This is NOT a tree-shape divergence — it is a **pipeline availability
  gap and a Task 12 backend-flip liability**: after the flip, any file whose
  nesting depth overflows JuliaSyntax's recursive-descent parser regresses
  from "parsed" to "unparseable", a regression surface CSTParser's parser
  does not have (or hits at a different depth). Needs either a bigger parse
  stack (e.g. parsing on a dedicated task with an enlarged stack) or an
  upstream JuliaSyntax fix before the flip. Resolution: converter cannot shim
  it; flag for Task 12.
  (Task-11.5 re-check under the vendored 1.0.2 fork: `parse!` STILL
  overflows at the default task stack — the fork does not change this. On
  an enlarged-stack task (`Task(f, 512*1024*1024)`) the file both parses
  AND converts to full oracle equality (`first_tree_diff === nothing`), so
  no tree-shape issue hides behind the overflow; an enlarged-stack parse
  task is a verified-workable Task 12 integration fix. Entry stays open.)

- **One genuinely context-dependent case** — `StaticArrays/test/broadcast.jl`
  (an `::`/`==` binding inside a macro arg that diverges only in the full
  nested `@testset`/`@test`/`@inferred`/`SA[…]` context; every minimal
  extraction converts identically). Reviewer-confirmed as genuinely
  context-dependent in the round-2 review. `check_spans`-clean. Left as
  remaining loop state.
  (Round-2 correction: the earlier claim that a "trio" of files shared this
  character was wrong for 2 of 3 — `StaticArrays/src/blas.jl` was a real
  converter bug, fixed in round 2 [qualified-macrocall span quirk not
  propagating through a nesting macrocall, `x = @eval M.@m(a)`], and
  `CodeTracking/test/script.jl` reduced to the statement-group split logged
  above.)
  (Task-11.5 update: under JuliaSyntax 1.x this is no longer
  context-dependent — it reduces to `@test @inferred(f(x))   ::T == y`
  (whitespace before the `::`). CSTParser splits the space-separated
  `::T == y` off as a SECOND macro arg (a prefix-`::` expression), while
  JuliaSyntax binds the `::` to the preceding macrocall result —
  and `Meta.parse` agrees with JuliaSyntax, so CSTParser deviates from
  real Julia here. Genuine parser disagreement; accept drift. Without the
  whitespace the two parsers agree and the converter matches.)

## Task 11.5 (retarget to JuliaSyntax 1.x)

All Task-10 entries above were re-verified under the vendored JuliaSyntax
1.0.2 fork with the vendored CSTParser 3.5.1-DEV oracle; every reduction
still reproduces (some corpus diff signatures shifted — e.g. the
catch-after-finally file now surfaces as `IDENTIFIER vs FALSE` because 1.x
emits a `Placeholder` catch-var where CSTParser errortokens the stray
`catch` — but the root causes are unchanged). No entry dissolved; no new
divergence was introduced by the retarget. Depot corpus: 1154/1161, the
same six accepted-drift files plus the StackOverflow file as before.

## Task 11.5 (JuliaSyntax 1.x retarget) — reviewer addendum

- The `(…;…) ->` brackets-vs-tuple heuristic is oracle-pinned for all corpus
  and common spellings, with one degenerate gap: an EMPTY `;`-group after a
  splat (`(a...;) -> a`) converts as `:tuple` where CSTParser says
  `:brackets`. Here the converter matches real Julia (`Meta.parse` gives a
  tuple LHS) and CSTParser is the deviant; corpus-clean. Accept drift.

## Task 12 (Salsa single-parse integration + backend flip)

Backend-flip regression sweep (full package test suite, both
`JW_CST_BACKEND` values) surfaced two real converter bugs, both fixed, plus
two genuine parser-level (not converter) divergences left as accepted drift.

- **Fixed**: `a.end`/`a.begin` as a dot-getfield field name converted to the
  `:END`/`:BEGIN` index-context literal instead of plain `:IDENTIFIER`.
  `terminal_expr` maps any Identifier-kinded `end`/`begin` leaf to the index
  literal head unconditionally; the getfield/quotenode forms already demoted
  `:BEGIN` back to `:IDENTIFIER` for quoted-field context (`wrap_field_atom`,
  the `K"quote"` form) but were missing the matching `:END` demotion. Fixed
  by adding the same demotion for `:END` in both spots
  (`src/cst_conversion/forms.jl`).
- **Fixed**: a `module`/`baremodule` whose closing `end` is missing entirely
  (e.g. mid-edit `module M\nBase.\nend\n` where the dangling `Base.` consumes
  the literal `end` as its field name, autocompletion's classic trigger
  shape) produced a 4th `:module` arg (the raw green error-recovery leaf)
  instead of CSTParser's own convention: an `:errortoken` wrapping a
  zero-width, val-less `:END` placeholder filed as `trivia[2]`. The stray
  4th arg broke CSTParser's own `_module` iterate accessor (`x.args[2]`
  assumed a 3-slot arg list), crashing any StaticLint/completions code that
  walks the module via CSTParser's iteration protocol (not just `.args`
  directly) with a `BoundsError`. Fixed by synthesizing the oracle-shaped
  `errortoken`/`:END` placeholder in `trivia` instead of appending to `args`
  (`src/cst_conversion/forms.jl`, the `K"module"` form). Two more
  truncated-module edge cases (`"module A\n"` with an entirely empty body,
  and an unterminated call before a stray `end`) still show narrow arg-shape
  diffs; both are `check_spans`-clean and not exercised by any real test —
  left as further loop state rather than chased with no failing test to
  pin them.
- **Accept drift**: `if x = 1 end` / `if a || x = 1 end` / `if x = 1 && b
  end` (assignment used directly as an `if` condition) parses as a genuine
  syntax error under JuliaSyntax 1.x — this vendored fork's parser rejects
  bare `=` in condition position (`"unexpected \`=\`"` diagnostic, then
  cascading error recovery), whereas CSTParser accepts it leniently as a
  normal assignment expression. Confirmed via green-tree inspection: the
  divergence originates in the parse itself, not the conversion — the
  converter faithfully mirrors JuliaSyntax's error-recovery shape. Surfaces
  as 3 failing StaticLint `check_if_conds` tests
  (`test/staticlint/test_staticlint.jl`) that assert the (pre-flip) lenient
  parse; out of converter scope.
- **Accept drift**: `[i for i in length(1) end]` (a test fixture with a
  stray, syntactically-invalid `end` inside a list-comprehension literal)
  recovers differently between parsers — CSTParser folds the stray `end`
  into an `hcat` alongside the comprehension; JuliaSyntax closes the
  comprehension cleanly and leaves the `end`+`]` as trailing errortokens one
  level up. Again a parser-level error-recovery difference, not a converter
  bug. Surfaces as 2 erroring StaticLint tests
  (`test/staticlint/test_inference.jl`,
  `error_list_comp_incorrect_iter_specs`); out of converter scope.

Full-suite backend-flip regression (custom broad run excluding vendored
`packages/*` subpackage suites and `testdata/` fixtures, both backends):
2195 total both ways; identical except for exactly the 5 tests above
(2178/10/1/6 under `cstparser` vs 2173/13/3/6 under `juliasyntax`). All
other non-identical-seeming counts (Runic package missing, cache-infra
rclone sandbox gate, `test_uris2.jl` broken markers) are pre-existing
environment gaps, confirmed identical between backends.
