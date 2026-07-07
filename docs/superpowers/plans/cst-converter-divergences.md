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
