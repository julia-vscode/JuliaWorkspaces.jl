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
oracle equality with a real fix rather than a shim.

Two corpus-discovered items are **not** gate-blocking divergences but are
worth flagging for later tasks:

- **Cmd-literal `$(...)` interpolation is reconstructed by a best-effort
  re-scan, not a real divergence but an approximation**: JuliaSyntax's green
  tree never decomposes backtick-literal interpolation at all (a `CmdString`
  leaf's raw text can contain a literal unescaped `$` with no child node —
  real Julia defers `$`-splitting in cmd literals to the `@cmd` macro at
  expansion time), unlike double-quoted strings where the green tree already
  splits real children. The converter's `split_cmd_dollar` (terminals.jl)
  manually re-scans the raw leaf text and recursively re-parses `$(...)`
  groups via `build_cst`, verified correct against the oracle for the gate
  snippet and for a real corpus example (`CloudIndex/driver.jl`'s
  multi-interpolation `inner = \`...\`` cmd literal). The paren-matching is
  naive (depth-counting only, no awareness of nested strings/comments
  containing parens) — a `$(f("("))`-style case inside a cmd literal would
  mis-scan. Not hit by the current corpus; flagged rather than hardened,
  since fixing it generally requires the same tokenizer JuliaSyntax itself
  uses for the inner re-parse boundary.
- **Raw/regex string macros (`raw"..."`, `r"..."`) get the same unconditional
  `_rm_escaped_newlines`/`_unescape_string_expr` pass as plain strings** —
  pre-existing since Task 3/4's `merge_quoted`, unchanged by Task 9 (still
  called on every simple/collapsed `K"string"` chunk regardless of which
  macro wraps it). This is invisible when the literal has no backslashes
  (the Task 9 gate's `raw"no $interp"` has none) but corrupts content for a
  real corpus regex like `r"[/\\]+"` (`src/compat.jl`) and
  `r"^(julia)?manifest(-v\d+...)?\.toml$"` (`src/fileio.jl`), both surfaced
  once Task 9 removed the crashes that had been masking these files
  entirely. Not fixed here (out of Task 9's scope — strings/cmd/operators,
  not macro-name-conditional unescaping); handoff for Task 10/11.
