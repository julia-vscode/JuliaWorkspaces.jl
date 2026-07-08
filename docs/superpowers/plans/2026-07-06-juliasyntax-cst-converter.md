# JuliaSyntax → CSTParser.EXPR Converter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `CSTConversion.build_cst`, which produces CSTParser-compatible `EXPR` trees from a JuliaSyntax parse, so JuliaWorkspaces parses each buffer exactly once and CSTParser's parser (and eventually the dependency) can be dropped.

**Architecture:** A two-pass converter over JuliaSyntax's lossless `GreenNode` tree: pass 1 flattens tokens and folds trailing trivia into per-token `fullspan`s (matching CSTParser's trivia model); pass 2 recursively assembles `EXPR` nodes, computing spans from absolute leaf positions and re-shaping each syntax form into CSTParser's arg/trivia layout. Correctness is defined by an oracle — `CSTParser.parse(src, true)` — via a structural diff function, first on targeted snippets (unit tests), then on a large corpus (differential harness). Finally the Salsa layer is restructured so *both* trees derive from one `ParseStream`, which is also the seam that lets analysis layers migrate to pure JuliaSyntax trees one query-call at a time.

**Tech Stack:** Julia, JuliaSyntax 0.4.10 (`GreenNode`, `ParseStream`, `Kind`), CSTParser 3.5.0 (`EXPR` as target datastructure and oracle), Salsa derived queries, TestItemRunner.

## Global Constraints

- Working directory for ALL git commands: `/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces` (this package is a git submodule; never run git from the julia-vscode root).
- Run Julia code ONLY via the julia-mcp session (`mcp__julia__julia_eval`, session env=`environments/development`). Never spawn `julia` processes and never run `Pkg.test`.
- Never write anything under `~/.julia`. Corpus files are copied to the scratchpad first.
- Code comments: terse, only for non-obvious constraints. Never reference this plan or spec documents in code or comments.
- `@testitem` bodies are module-scope: `return` does NOT skip the rest — gate with `if/else` only.
- Edit files directly with Edit/Write; no bulk-rewrite scripts over repo files.
- All new test items are named with prefix `cst-conv:` so `JW_TEST_FILTER="cst-conv"` scopes a run to this feature.
- Commit messages end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Oracle definition (used everywhere): `CSTParser.parse(src, true)` — top-level/file mode, matching `derived_julia_legacy_syntax_tree`.
- JuliaSyntax pin: the API used is 0.4.10 (`~/.julia/packages/JuliaSyntax/DHdTk`). CSTParser source of truth: `~/.julia/packages/CSTParser/VyV0S/src`.

## Standard run commands

**Fast red/green loop** (per failing snippet), via `mcp__julia__julia_eval`:

```julia
import JuliaWorkspaces
using JuliaWorkspaces: CSTConversion
CSTConversion.oracle_diff("a + b")   # nothing == pass; otherwise a diff-path string
```

Note: the julia-mcp session runs Revise-style with the dev'd package; if a struct definition changed (not just methods), restart via `mcp__julia__julia_restart` first.

**Test-suite run** (per task, and before every commit), via `mcp__julia__julia_eval`:

```julia
withenv("JW_TEST_FILTER" => "cst-conv") do
    include("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces/test/runtests.jl")
end
```

Expected: a TestItemRunner summary with 0 failures/errors. (For the final integration task, run once with the filter empty to execute the full package suite.)

**Green-tree dump** (the "look at the actual shapes" tool used in every red step):

```julia
using JuliaSyntax
stream = JuliaSyntax.ParseStream("a + b"); JuliaSyntax.parse!(stream; rule=:all)
show(stdout, MIME"text/plain"(), JuliaSyntax.build_tree(JuliaSyntax.GreenNode, stream), "a + b")
# oracle side:
using CSTParser; dump(CSTParser.parse("a + b", true), maxdepth=6)
```

## File Structure

```
src/cst_conversion/CSTConversion.jl   # module: includes, ConvertCtx, build_cst entry points
src/cst_conversion/compare.jl         # first_tree_diff / trees_equal / oracle_diff / check_spans
src/cst_conversion/tokens.jl          # Leaf, flatten_leaves (pass 1: trivia folding)
src/cst_conversion/terminals.jl       # Kind→head tables, terminal_expr
src/cst_conversion/assembly.jl        # Cursor, assemble (pass 2 core), span bookkeeping, fallback
src/cst_conversion/forms.jl           # assemble_form: per-kind arg/trivia layout rules (grows over burn-down tasks)
src/layer_syntax_trees.jl             # (modified, final task) single-parse Salsa queries
test/test_cst_conversion.jl           # @testitem oracle tests, grouped per task
test/cst_corpus.jl                    # corpus differential runner (plain module, driven via julia-mcp)
```

Design rules locked in here:

- `EXPR.fullspan`/`.span` are computed **only** from absolute leaf positions in `assemble` (never via `update_span!`), so span correctness is independent of per-form layout mistakes.
- `assemble_form` receives children **in source order** with their kinds and must return the CSTParser layout; it never touches spans.
- Unknown kinds hit a **generic fallback** (never throw), so the corpus runner always completes and reports "unhandled kind X" statistics.
- Everything is pure functions over `(GreenNode, source::String)` — no Salsa, no URIs — so the module is testable in isolation and reusable by CSTParser upstream later if desired.

### Migration-seam design (why the final tasks look the way they do)

Analysis layers never parse; they obtain trees via Salsa queries. After this plan:

- `derived_julia_green_tree(rt, uri) -> (GreenNode, diagnostics, content)` — the single parse.
- `derived_julia_syntax_tree(rt, uri) -> SyntaxNode` — built from the green tree.
- `derived_julia_legacy_syntax_tree(rt, uri) -> EXPR` — built from the *same* green tree via `build_cst`.

Migrating a layer to pure JuliaSyntax later = changing its query call from `derived_julia_legacy_syntax_tree` to `derived_julia_syntax_tree`, per call site, with both trees guaranteed to describe the same parse. Byte offsets are the shared currency between trees: `JuliaWorkspaces.get_expr1(cst, offset)` (exists, `src/layer_hover.jl:32`) on the EXPR side, `syntax_node_at` (added in Task 12) on the SyntaxNode side.

---

### Task 1: Branch, module scaffold, structural tree diff

**Files:**
- Create: `src/cst_conversion/CSTConversion.jl`
- Create: `src/cst_conversion/compare.jl`
- Modify: `src/JuliaWorkspaces.jl` (add include; find the `include("layer_syntax_trees.jl")` line and add the module include immediately before it)
- Test: `test/test_cst_conversion.jl`

**Interfaces:**
- Produces: `CSTConversion.first_tree_diff(a::EXPR, b::EXPR; path="") -> Union{Nothing,String}`; `CSTConversion.trees_equal(a, b) -> Bool`. Every later task's tests consume these.

- [ ] **Step 1: Create branch**

```bash
cd /home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces
git checkout -b sp/juliasyntax-cst-converter
```

- [ ] **Step 2: Write the failing test**

Create `test/test_cst_conversion.jl`:

```julia
@testitem "cst-conv: tree diff basics" begin
    using CSTParser
    using JuliaWorkspaces: CSTConversion

    a = CSTParser.parse("f(x) = x + 1", true)
    b = CSTParser.parse("f(x) = x + 1", true)
    c = CSTParser.parse("f(x) = x + 2", true)
    d = CSTParser.parse("f(x) = x +  1", true)   # same tree, different trivia width

    @test CSTConversion.trees_equal(a, b)
    @test CSTConversion.first_tree_diff(a, b) === nothing
    @test !CSTConversion.trees_equal(a, c)
    @test CSTConversion.first_tree_diff(a, c) isa String
    @test !CSTConversion.trees_equal(a, d)      # fullspans must be compared
end
```

- [ ] **Step 3: Run test to verify it fails**

Run the test-suite command (see "Standard run commands"). Expected: FAIL/ERROR — `CSTConversion` not defined.

- [ ] **Step 4: Implement module + diff**

Create `src/cst_conversion/CSTConversion.jl`:

```julia
module CSTConversion

using CSTParser
using CSTParser: EXPR
using JuliaSyntax
using JuliaSyntax: GreenNode, Kind, @K_str, kind, haschildren, children, span

include("compare.jl")

end
```

Create `src/cst_conversion/compare.jl`:

```julia
# Structural equality of EXPR trees ignoring parent/meta.
# Returns nothing when equal, else a human-readable path to the first divergence.
function first_tree_diff(a::EXPR, b::EXPR; path::String="□")
    if typeof(a.head) != typeof(b.head)
        return "$path: head type $(typeof(a.head)) vs $(typeof(b.head))"
    end
    if a.head isa Symbol
        a.head === b.head || return "$path: head $(a.head) vs $(b.head)"
    else
        d = first_tree_diff(a.head, b.head; path="$path.head")
        d === nothing || return d
    end
    a.val == b.val || return "$path: val $(repr(a.val)) vs $(repr(b.val))"
    a.fullspan == b.fullspan || return "$path: fullspan $(a.fullspan) vs $(b.fullspan)"
    a.span == b.span || return "$path: span $(a.span) vs $(b.span)"
    for (field, fa, fb) in ((:args, a.args, b.args), (:trivia, a.trivia, b.trivia))
        (fa === nothing) == (fb === nothing) || return "$path: $field nothing-ness differs"
        fa === nothing && continue
        length(fa) == length(fb) || return "$path: $field length $(length(fa)) vs $(length(fb))"
        for i in eachindex(fa)
            d = first_tree_diff(fa[i], fb[i]; path="$path.$field[$i]")
            d === nothing || return d
        end
    end
    return nothing
end

trees_equal(a::EXPR, b::EXPR) = first_tree_diff(a, b) === nothing
```

Modify `src/JuliaWorkspaces.jl`: directly above `include("layer_syntax_trees.jl")` add:

```julia
include("cst_conversion/CSTConversion.jl")
```

- [ ] **Step 5: Run test to verify it passes**

Run the test-suite command. Expected: PASS (the one new testitem, 5 assertions).

- [ ] **Step 6: Commit**

```bash
git add src/cst_conversion src/JuliaWorkspaces.jl test/test_cst_conversion.jl
git commit -m "feat: CSTConversion module with structural EXPR diff"
```

---

### Task 2: Leaf pass — token flattening with trivia folding

**Files:**
- Create: `src/cst_conversion/tokens.jl`
- Modify: `src/cst_conversion/CSTConversion.jl` (add `include("tokens.jl")` after `include("compare.jl")`)
- Test: `test/test_cst_conversion.jl`

**Interfaces:**
- Produces: `struct Leaf{kind::Kind, pos::Int, span::Int, fullspan::Int}` (pos is absolute, 1-based); `flatten_leaves(green::GreenNode, source::AbstractString) -> (Vector{Leaf}, Int)` where the `Int` is file-leading trivia bytes; `is_ws_trivia(k::Kind) -> Bool`. Task 4's `Cursor` consumes `Vector{Leaf}`.

- [ ] **Step 1: Write the failing test**

Append to `test/test_cst_conversion.jl`:

```julia
@testitem "cst-conv: leaf flattening" begin
    using JuliaSyntax
    using JuliaSyntax: @K_str
    using JuliaWorkspaces: CSTConversion

    function leaves_of(src)
        stream = JuliaSyntax.ParseStream(src)
        JuliaSyntax.parse!(stream; rule=:all)
        green = JuliaSyntax.build_tree(JuliaSyntax.GreenNode, stream)
        CSTConversion.flatten_leaves(green, src)
    end

    # "x + 1" → tokens x,+,1 ; ws folded into preceding token's fullspan
    ls, leading = leaves_of("x + 1")
    @test leading == 0
    @test [l.kind for l in ls] == [K"Identifier", K"+", K"Integer"]
    @test [l.pos for l in ls] == [1, 3, 5]
    @test [l.span for l in ls] == [1, 1, 1]
    @test [l.fullspan for l in ls] == [2, 2, 1]

    # comments are trivia too
    ls, _ = leaves_of("x # hi\ny")
    @test [l.kind for l in ls] == [K"Identifier", K"Identifier"]
    @test ls[1].fullspan == 7     # "x # hi\n"
    @test ls[2].pos == 8

    # file-leading trivia is reported separately
    ls, leading = leaves_of("  x")
    @test leading == 2
    @test ls[1].pos == 3

    # invariant: leaves tile the file
    for src in ["f(a; b=1) do x\n  x\nend", "\"str\\n\" * `cmd`", ""]
        ls, lead = leaves_of(src)
        @test lead + sum(l -> l.fullspan, ls; init=0) == sizeof(src)
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run the test-suite command. Expected: FAIL — `flatten_leaves` not defined.

- [ ] **Step 3: Implement**

Create `src/cst_conversion/tokens.jl`:

```julia
struct Leaf
    kind::Kind
    pos::Int       # absolute first byte, 1-based
    span::Int      # bytes of the token itself
    fullspan::Int  # span + trailing trivia bytes
end

is_ws_trivia(k::Kind) = k == K"Whitespace" || k == K"NewlineWs" || k == K"Comment"

# Flattens the green tree into non-trivia tokens, folding each trivia token's
# width into the preceding token's fullspan (CSTParser's trivia model).
function flatten_leaves(green::GreenNode, source::AbstractString)
    leaves = Leaf[]
    leading = _flatten!(leaves, 0, green, 1)[2]
    return leaves, leading
end

function _flatten!(leaves::Vector{Leaf}, leading::Int, node::GreenNode, pos::Int)
    if !haschildren(node)
        w = Int(span(node))
        if is_ws_trivia(kind(node))
            if isempty(leaves)
                leading += w
            else
                l = leaves[end]
                leaves[end] = Leaf(l.kind, l.pos, l.span, l.fullspan + w)
            end
        else
            push!(leaves, Leaf(kind(node), pos, w, w))
        end
        return pos + w, leading
    end
    for c in children(node)
        pos, leading = _flatten!(leaves, leading, c, pos)
    end
    return pos, leading
end
```

Add `include("tokens.jl")` to `CSTConversion.jl` after the compare include.

- [ ] **Step 4: Run test to verify it passes**

Run the test-suite command. Expected: PASS. If the token kinds differ from the test's expectation (e.g. `K"+"` spelled differently in 0.4.10), use the green-tree dump command to see actual kinds and fix the *test* to match reality — the invariants (positions, tiling) are the contract.

- [ ] **Step 5: Commit**

```bash
git add src/cst_conversion test/test_cst_conversion.jl
git commit -m "feat: green-tree leaf flattening with trivia folding"
```

---

### Task 3: Terminal EXPR construction, `:file` assembly, `build_cst` entry

**Files:**
- Create: `src/cst_conversion/terminals.jl`
- Modify: `src/cst_conversion/CSTConversion.jl` (include + export `build_cst`, add `oracle_diff` to compare.jl)
- Modify: `src/cst_conversion/compare.jl` (add `oracle_diff`)
- Test: `test/test_cst_conversion.jl`

**Interfaces:**
- Consumes: `Leaf`, `flatten_leaves` (Task 2).
- Produces: `terminal_expr(leaf::Leaf, source::String) -> EXPR`; `build_cst(source::AbstractString) -> EXPR` and `build_cst(green::GreenNode, source::AbstractString) -> EXPR` (temporary flat implementation, replaced by Task 4's recursion); `oracle_diff(src::AbstractString) -> Union{Nothing,String}` — THE assertion helper for all later tasks.

- [ ] **Step 1: Read the authoritative head tables**

Read `~/.julia/packages/CSTParser/VyV0S/src/spec.jl` — specifically `literalmap` (~line 287) and `tokenkindtoheadmap` — and note the exact Symbol each Tokenize kind maps to (`:IDENTIFIER`, `:INTEGER`, `:FLOAT`, `:STRING`, `:CHAR`, `:TRUE`, `:FALSE`, keyword and punctuation heads, `:OPERATOR`). The `TERMINAL_HEADS` table in Step 4 must mirror these, keyed by JuliaSyntax `Kind` instead of Tokenize kind.

- [ ] **Step 2: Write the failing test**

Append to `test/test_cst_conversion.jl`:

```julia
@testitem "cst-conv: terminals via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in ["x", "1", "1.5", "0x1f", "0b101", "0o17", "true", "false",
                "'a'", "\"str\"", "x ", "  x", "# only a comment", ""]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run the test-suite command. Expected: FAIL — `oracle_diff` not defined.

- [ ] **Step 4: Implement**

Append to `src/cst_conversion/compare.jl`:

```julia
# Compare converter output against CSTParser for the same source.
oracle_diff(src::AbstractString) = first_tree_diff(build_cst(src), CSTParser.parse(src, true))
```

Create `src/cst_conversion/terminals.jl` (fill `TERMINAL_HEADS` from Step 1's reading; the entries below are the shape, not the complete table):

```julia
# Mirrors CSTParser's literalmap/tokenkindtoheadmap, keyed by JuliaSyntax kind.
const TERMINAL_HEADS = Dict{Kind,Symbol}(
    K"Identifier" => :IDENTIFIER,
    K"Integer"    => :INTEGER,
    K"Float"      => :FLOAT,
    K"HexInt"     => :HEXINT,
    K"BinInt"     => :BININT,
    K"OctInt"     => :OCTINT,
    K"Char"       => :CHAR,
    K"String"     => :STRING,
    K"true"       => :TRUE,
    K"false"      => :FALSE,
    # ... complete from CSTParser's tables during red/green iteration
)

token_text(leaf::Leaf, source::String) = source[leaf.pos:prevind(source, leaf.pos + leaf.span)]

function terminal_expr(leaf::Leaf, source::String)
    k = leaf.kind
    if JuliaSyntax.is_operator(k)
        return EXPR(:OPERATOR, leaf.fullspan, leaf.span, token_text(leaf, source))
    elseif JuliaSyntax.is_keyword(k)
        return EXPR(Symbol(uppercase(string(k))), leaf.fullspan, leaf.span, nothing)
    elseif haskey(TERMINAL_HEADS, k)
        return EXPR(TERMINAL_HEADS[k], leaf.fullspan, leaf.span, token_text(leaf, source))
    else
        return EXPR(punctuation_head(k), leaf.fullspan, leaf.span, nothing)
    end
end

# Mirrors tokenkindtoheadmap's punctuation entries; extend as kinds show up
# in oracle diffs (unmapped kinds fail loudly with a KeyError, which is wanted
# during burn-down — the corpus runner catches and reports it).
const PUNCTUATION_HEADS = Dict{Kind,Symbol}(
    K"(" => :LPAREN,   K")" => :RPAREN,
    K"[" => :LSQUARE,  K"]" => :RSQUARE,
    K"{" => :LBRACE,   K"}" => :RBRACE,
    K"," => :COMMA,    K";" => :SEMICOLON,
    K"@" => :ATSIGN,   K"." => :DOT,
)
punctuation_head(k::Kind) = PUNCTUATION_HEADS[k]
```

Add a temporary `build_cst` to `CSTConversion.jl` (replaced in Task 4) that handles only single-token-or-empty files, plus the entry point:

```julia
function build_cst(source::AbstractString)
    stream = JuliaSyntax.ParseStream(source; version=VERSION)
    JuliaSyntax.parse!(stream; rule=:all)
    build_cst(JuliaSyntax.build_tree(GreenNode, stream), source)
end

function build_cst(green::GreenNode, source::AbstractString)
    leaves, leading = flatten_leaves(green, source)
    file = EXPR(:file, EXPR[], nothing, 0, 0)
    for leaf in leaves
        push!(file, terminal_expr(leaf, String(source)))  # CSTParser extends Base.push! with span updates
    end
    attach_leading!(file, leading)
    return file
end

# Default rule: leading file trivia widens the first token's fullspan.
# Step 5's oracle dump decides whether this or a file-level attachment is
# what CSTParser actually does — fix here if the "  x" oracle test diffs.
function attach_leading!(file::EXPR, leading::Int)
    leading == 0 && return file
    if file.args !== nothing && !isempty(file.args)
        file.args[1].fullspan += leading
    end
    file.fullspan += leading
    return file
end
```

- [ ] **Step 5: Pin the leading-trivia and val conventions against the oracle**

The two conventions this task must discover empirically (do this BEFORE guessing at `attach_leading!`):

```julia
using CSTParser
dump(CSTParser.parse("  x", true), maxdepth=3)              # where do 2 leading bytes go?
dump(CSTParser.parse("# only a comment", true), maxdepth=3) # file with no tokens at all
dump(CSTParser.parse("\"str\"", true), maxdepth=4)           # is val quoted source text or unescaped?
dump(CSTParser.parse("0x1f", true), maxdepth=3)              # literal val formatting
```

Encode exactly what the oracle shows: `attach_leading!` implements the observed rule (wherever CSTParser puts leading bytes — typically widening the first child's fullspan or the file node itself); string/char/number `val`s match the observed convention (adjust `terminal_expr` for kinds whose val is not the raw token text).

- [ ] **Step 6: Run test to verify it passes**

Run the fast-loop `oracle_diff` on each snippet, then the test-suite command. Expected: PASS for all 14 snippets. Any remaining diff string tells you the exact path and field to fix.

- [ ] **Step 7: Commit**

```bash
git add src/cst_conversion test/test_cst_conversion.jl
git commit -m "feat: terminal EXPR construction with oracle-pinned conventions"
```

---

### Task 4: Recursive assembly core + first structural forms

**Files:**
- Create: `src/cst_conversion/assembly.jl`
- Create: `src/cst_conversion/forms.jl`
- Modify: `src/cst_conversion/CSTConversion.jl` (includes; replace temporary `build_cst(green, source)`)
- Test: `test/test_cst_conversion.jl`

**Interfaces:**
- Consumes: `Leaf`, `flatten_leaves`, `terminal_expr`, `is_ws_trivia`.
- Produces: `mutable struct Cursor{leaves::Vector{Leaf}, i::Int, src::String}`; `assemble(node::GreenNode, cur::Cursor) -> EXPR` (spans computed here, universally); `assemble_form(k::Kind, node::GreenNode, kids::Vector{EXPR}, kkinds::Vector{Kind}, cur::Cursor) -> EXPR` (layout only — every burn-down task adds branches here); `generic_form(k, kids, kkinds) -> EXPR` fallback. `UNHANDLED_KINDS::Set{Kind}` populated by the fallback (read by the corpus runner).

- [ ] **Step 1: Write the failing test**

Append to `test/test_cst_conversion.jl`:

```julia
@testitem "cst-conv: core forms via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        "a = 1",                 # binary syntax: op is the EXPR head
        "a + b",                 # infix call: op moves to args[1]
        "a + b + c",             # chained infix
        "a * b",
        "a == b",
        "(a)",                   # brackets with paren trivia
        "begin\na\nend",         # block with keyword trivia
        "a\nb\nc",               # multi-expression file
        "a; b",
        "f(x)",                  # prefix call
        "f()",
        "f(x, y)",               # comma trivia
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run the test-suite command. Expected: FAIL — multi-token sources hit the Task 3 flat `build_cst` (or `assemble` not defined once you start replacing it).

- [ ] **Step 3: Implement the assembly core**

Create `src/cst_conversion/assembly.jl`:

```julia
mutable struct Cursor
    leaves::Vector{Leaf}
    i::Int
    src::String
end

const UNHANDLED_KINDS = Set{Kind}()

function assemble(node::GreenNode, cur::Cursor)::EXPR
    if !haschildren(node)
        leaf = cur.leaves[cur.i]
        cur.i += 1
        return terminal_expr(leaf, cur.src)
    end
    first_i = cur.i
    kids = EXPR[]
    kkinds = Kind[]
    for c in children(node)
        is_ws_trivia(kind(c)) && continue
        push!(kids, assemble(c, cur))
        push!(kkinds, kind(c))
    end
    ex = assemble_form(kind(node), node, kids, kkinds, cur)
    # Spans from absolute leaf positions: independent of per-form layout.
    if cur.i > first_i
        first_leaf = cur.leaves[first_i]
        last_leaf = cur.leaves[cur.i - 1]
        ex.fullspan = (last_leaf.pos + last_leaf.fullspan) - first_leaf.pos
        ex.span = (last_leaf.pos + last_leaf.span) - first_leaf.pos
    end
    return ex
end

# Fallback: args = non-token children in source order, tokens into trivia.
# Wrong layout for anything CSTParser consumers pattern-match, but keeps the
# corpus runner alive and counts what still needs a real rule.
function generic_form(k::Kind, kids::Vector{EXPR}, kkinds::Vector{Kind})
    push!(UNHANDLED_KINDS, k)
    args = EXPR[]
    trivia = EXPR[]
    for (ex, ck) in zip(kids, kkinds)
        if JuliaSyntax.is_keyword(ck) || ex.head in (:LPAREN, :RPAREN, :COMMA,
            :LBRACE, :RBRACE, :LSQUARE, :RSQUARE, :SEMICOLON, :AT_SIGN, :DOT)
            push!(trivia, ex)
        else
            push!(args, ex)
        end
    end
    EXPR(Symbol(lowercase(string(k))), args, trivia, 0, 0)
end
```

Create `src/cst_conversion/forms.jl`:

```julia
function assemble_form(k::Kind, node::GreenNode, kids::Vector{EXPR}, kkinds::Vector{Kind}, cur::Cursor)::EXPR
    if k == K"toplevel"
        return EXPR(:file, kids, nothing, 0, 0)
    elseif k == K"call" && JuliaSyntax.is_infix_op_call(JuliaSyntax.head(node))
        # a + b (+ c ...) → (:call, [op, a, b, c...]); extra op tokens → trivia
        op = kids[2]
        args = EXPR[op, kids[1]]
        trivia = EXPR[]
        for j in 3:length(kids)
            if isodd(j)
                push!(args, kids[j])
            else
                push!(trivia, kids[j])   # repeated ops in chained calls
            end
        end
        return EXPR(:call, args, isempty(trivia) ? nothing : trivia, 0, 0)
    elseif k == K"call"
        # f(x, y) → (:call, [f, x, y], trivia=[lparen, commas..., rparen])
        args = EXPR[]
        trivia = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            if ck == K"(" || ck == K")" || ck == K","
                push!(trivia, ex)
            else
                push!(args, ex)
            end
        end
        return EXPR(:call, args, trivia, 0, 0)
    elseif k == K"=" && length(kids) == 3
        # binary syntax: operator EXPR becomes the head
        return EXPR(kids[2], EXPR[kids[1], kids[3]], nothing, 0, 0)
    elseif k == K"block"
        args = EXPR[]
        trivia = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            (ck == K"begin" || ck == K"end" || ck == K";") ? push!(trivia, ex) : push!(args, ex)
        end
        return EXPR(:block, args, isempty(trivia) ? nothing : trivia, 0, 0)
    elseif k == K"parens"
        trivia = EXPR[kids[1], kids[end]]
        return EXPR(:brackets, kids[2:end-1], trivia, 0, 0)
    end
    return generic_form(k, kids, kkinds)
end
```

Replace the Task 3 `build_cst(green, source)` in `CSTConversion.jl`:

```julia
function build_cst(green::GreenNode, source::AbstractString)
    src = String(source)
    leaves, leading = flatten_leaves(green, src)
    cur = Cursor(leaves, 1, src)
    ex = assemble(green, cur)
    if headof(ex) !== :file
        ex = EXPR(:file, EXPR[ex], nothing, ex.fullspan, ex.span)
    end
    attach_leading!(ex, leading)
    return ex
end
```

(`headof` comes from CSTParser; add `using CSTParser: headof` to the module.)

- [ ] **Step 4: Iterate red/green per snippet**

For each still-failing snippet, run the green-tree dump and oracle dump side by side, then fix the corresponding `assemble_form` branch. Expected end state: all 12 snippets return `nothing` from `oracle_diff`. Layout details this step is expected to correct against the oracle: whether `:file` wraps single expressions, exact trivia ordering in chained infix calls, where semicolons go in blocks, and the JuliaSyntax 0.4.10 kind for parenthesized expressions (dump `"(a)"` to see whether it is `K"parens"` or flag-based — adjust the branch to the real kind).

- [ ] **Step 5: Run full cst-conv suite, verify Tasks 1–3 still pass**

Run the test-suite command. Expected: PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add src/cst_conversion test/test_cst_conversion.jl
git commit -m "feat: recursive EXPR assembly with core form layouts"
```

---

### Task 5: Span invariant checker + corpus differential runner

**Files:**
- Modify: `src/cst_conversion/compare.jl` (add `check_spans`)
- Create: `test/cst_corpus.jl`
- Test: `test/test_cst_conversion.jl`

**Interfaces:**
- Consumes: `build_cst`, `first_tree_diff`, `UNHANDLED_KINDS`.
- Produces: `check_spans(x::EXPR) -> Union{Nothing,String}` (violated invariant description); `CSTCorpus.run_corpus(files::Vector{String}; report_path::String) -> NamedTuple{(:total,:passed,:failed,:errored)}` writing a markdown report grouped by diff signature. Tasks 6–11 consume the report format; Task 11 consumes `check_spans`.

- [ ] **Step 1: Write the failing test**

Append to `test/test_cst_conversion.jl`:

```julia
@testitem "cst-conv: span invariants and corpus smoke" begin
    using JuliaWorkspaces: CSTConversion
    include(joinpath(@__DIR__, "cst_corpus.jl"))

    # invariants hold on converter output for valid and broken code
    for src in ["f(x) = x + 1", "function f(", "a +", ""]
        ex = CSTConversion.build_cst(src)
        @test ex.fullspan == sizeof(src)
        @test CSTConversion.check_spans(ex) === nothing
    end

    # corpus runner runs end to end on this package's own test file
    report = joinpath(mktempdir(), "report.md")
    stats = CSTCorpus.run_corpus([@__FILE__]; report_path=report)
    @test stats.total == 1
    @test stats.errored == 0
    @test isfile(report)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run the test-suite command. Expected: FAIL — `check_spans` / `cst_corpus.jl` missing.

- [ ] **Step 3: Implement**

Append to `src/cst_conversion/compare.jl`:

```julia
# EXPR span bookkeeping invariants; layout-independent sanity for broken code
# where no oracle equality is possible.
function check_spans(x::EXPR; path::String="□")
    x.span <= x.fullspan || return "$path: span $(x.span) > fullspan $(x.fullspan)"
    x.args === nothing && return nothing
    childsum = sum(c -> c.fullspan, x.args; init=0) +
               (x.trivia === nothing ? 0 : sum(c -> c.fullspan, x.trivia; init=0)) +
               (x.head isa EXPR ? x.head.fullspan : 0)
    childsum == x.fullspan || return "$path: children sum $childsum != fullspan $(x.fullspan)"
    for (i, c) in enumerate(x.args)
        d = check_spans(c; path="$path.args[$i]")
        d === nothing || return d
    end
    if x.trivia !== nothing
        for (i, c) in enumerate(x.trivia)
            d = check_spans(c; path="$path.trivia[$i]")
            d === nothing || return d
        end
    end
    return nothing
end
```

Create `test/cst_corpus.jl`:

```julia
module CSTCorpus

using CSTParser
using JuliaWorkspaces: CSTConversion

# One corpus file's outcome: :pass, or a diff signature for grouping.
function check_file(path::String)
    src = read(path, String)
    ours = try
        CSTConversion.build_cst(src)
    catch err
        return (:errored, "converter threw: $(typeof(err))")
    end
    oracle = try
        CSTParser.parse(src, true)
    catch err
        return (:pass, nothing)   # oracle itself fails: out of scope
    end
    d = CSTConversion.first_tree_diff(ours, oracle)
    d === nothing && return (:pass, nothing)
    # signature = diff with indices stripped, so identical shapes group together
    return (:failed, replace(d, r"\[\d+\]" => "[]", r"\d+" => "N"))
end

function run_corpus(files::Vector{String}; report_path::String)
    empty!(CSTConversion.UNHANDLED_KINDS)
    passed = 0; failures = Dict{String,Vector{String}}(); errors = Dict{String,Vector{String}}()
    for f in files
        outcome, sig = check_file(f)
        if outcome == :pass
            passed += 1
        elseif outcome == :failed
            push!(get!(Vector{String}, failures, sig), f)
        else
            push!(get!(Vector{String}, errors, sig), f)
        end
    end
    open(report_path, "w") do io
        total = length(files)
        println(io, "# CST conversion corpus report\n")
        println(io, "$passed / $total files identical to oracle\n")
        println(io, "## Unhandled kinds\n")
        for k in sort!(string.(collect(CSTConversion.UNHANDLED_KINDS)))
            println(io, "- `", k, "`")
        end
        for (title, group) in (("Diffs", failures), ("Converter errors", errors))
            println(io, "\n## $title\n")
            for (sig, fs) in sort!(collect(group); by=p -> -length(p.second))
                println(io, "- **$(length(fs))×** `$sig`\n  - e.g. `$(first(fs))`")
            end
        end
    end
    return (total=length(files), passed=passed,
            failed=sum(length, values(failures); init=0),
            errored=sum(length, values(errors); init=0))
end

julia_files(dir::String) = String[joinpath(r, f) for (r, _, fs) in walkdir(dir) for f in fs if endswith(f, ".jl")]

end
```

- [ ] **Step 4: Run test to verify it passes**

Run the test-suite command. Expected: PASS. Note: `stats.failed` for the smoke file may be 1 at this stage — the test only asserts `errored == 0`; that is intended.

- [ ] **Step 5: Baseline corpus run over this package's own source**

Via `mcp__julia__julia_eval`:

```julia
include("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces/test/cst_corpus.jl")
files = CSTCorpus.julia_files("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces/src")
CSTCorpus.run_corpus(files; report_path="/tmp/claude-13471954/-home-pfitzseb-git-julia-vscode-scripts-packages-JuliaWorkspaces/1b3c5b3f-4373-46ef-b6f2-294a49002962/scratchpad/corpus_report.md")
```

Record the pass count in the commit message body. This report drives Tasks 6–10.

- [ ] **Step 6: Commit**

```bash
git add src/cst_conversion/compare.jl test/cst_corpus.jl test/test_cst_conversion.jl
git commit -m "feat: span invariant checker and corpus differential runner"
```

---

### Task 6: Burn-down — definitions

**Files:**
- Modify: `src/cst_conversion/forms.jl`
- Test: `test/test_cst_conversion.jl`

**Interfaces:**
- Consumes/extends: `assemble_form` (adds branches). No new names.

- [ ] **Step 1: Write the failing test**

Append to `test/test_cst_conversion.jl`:

```julia
@testitem "cst-conv: definitions via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        "function f() end",
        "function f(x, y=1; z) x end",
        "function f(x::Int)::Int x end",
        "f(x) = x",
        "x -> x + 1",
        "function (x) x end",
        "struct A end",
        "struct A{T} <: B\n    x::T\nend",
        "mutable struct A x end",
        "abstract type A end",
        "abstract type A{T} <: B end",
        "primitive type A 8 end",
        "macro m(x) x end",
        "module A\nf() = 1\nend",
        "baremodule A end",
        "f(x::T) where T = x",
        "f(x::T) where {T <: Number} = x",
        "const x = 1",
        "global x = 1",
        "local x = 1",
        "mutable struct A\n    const x::Int\nend",
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end
```

- [ ] **Step 2: Run to verify failures and capture shapes**

Run the test-suite command; expect several failures. For each failing snippet run the green-tree dump + oracle dump pair to see both shapes.

- [ ] **Step 3: Implement `assemble_form` branches**

The uniform recipe for every branch (this is the same recipe every burn-down task uses):

1. Dump both trees for the failing snippet.
2. Identify which source-order children are CSTParser `args` vs `trivia`, and their order in each vector (CSTParser stores args in `Expr`-order, which for definitions is usually signature-then-body; keywords like `function`/`end` and punctuation are trivia in source order).
3. Add an `elseif k == K"..."` branch mapping `kids`/`kkinds` accordingly, mirroring Task 4's `K"call"` branch style.
4. Re-run `oracle_diff(snippet)`; the diff path pinpoints any remaining field.

Representative branch to write first (function definitions), matching CSTParser's `(:function, [sig, block], trivia=[FUNCTION_kw, END_kw])` layout:

```julia
    elseif k == K"function"
        trivia = EXPR[]
        args = EXPR[]
        for (ex, ck) in zip(kids, kkinds)
            (ck == K"function" || ck == K"end") ? push!(trivia, ex) : push!(args, ex)
        end
        return EXPR(:function, args, trivia, 0, 0)
```

Then `K"struct"` (check `mutable` handling — the oracle dump shows whether CSTParser uses `:struct`/`:mutable` heads or a trivia keyword), `K"abstract"`, `K"primitive"`, `K"macro"`, `K"module"`, `K"where"`, `K"::"` (declaration: binary-syntax head like `=`), `K"->"`, `K"const"`, `K"global"`, `K"local"`.

- [ ] **Step 4: Run test to verify all 21 snippets pass**

Run the test-suite command. Expected: PASS.

- [ ] **Step 5: Re-run the src/ corpus, confirm pass count increased, commit**

Re-run the Task 5 Step 5 corpus command; the pass count must be ≥ the recorded baseline.

```bash
git add src/cst_conversion/forms.jl test/test_cst_conversion.jl
git commit -m "feat: cst conversion for definition forms"
```

---

### Task 7: Burn-down — call syntax in full generality

**Files:**
- Modify: `src/cst_conversion/forms.jl`
- Test: `test/test_cst_conversion.jl`

**Interfaces:** extends `assemble_form` only.

- [ ] **Step 1: Write the failing test**

Append to `test/test_cst_conversion.jl`:

```julia
@testitem "cst-conv: call syntax via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        "f(x; y=1)",             # parameters node
        "f(x, y=1; z=2, w)",
        "f(x...)",
        "f(; x)",
        "f.(x)",                 # dotcall
        "a.b",                   # getfield with quotenode
        "a.b.c",
        "a.:b",
        "A{T}",                  # curly
        "A{T} where T",
        "a[1]",                  # ref
        "a[1, 2]",
        "a[end]",
        "@m x y",                # macrocall
        "@m(x)",
        "m\"str\"",              # string macro
        "f(x) do y\n    y\nend", # do
        "g(f, xs) do y; y; end",
        "x |> f",
        "a ∘ b",
        "f(g(x))",
        "(f)(x)",
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end
```

- [ ] **Step 2–4: Red/green loop per snippet, same recipe as Task 6 Step 3**

Branches to add: `K"parameters"`, `K"..."` (splat), `K"dotcall"`, `K"."` (getfield — oracle shows the `:quotenode` wrapper CSTParser builds around the field name; replicate it exactly, it is what `is_getfield_w_quotenode` pattern-matches), `K"curly"`, `K"ref"`, `K"macrocall"` (macro name representation differs between the parsers — the oracle dump for `"@m x"` shows CSTParser's `[@-sign, name]` vs JuliaSyntax's fused `MacroName`; split the fused token into the two EXPRs CSTParser expects, using source text offsets from the leaf), `K"do"`, `K"string_macro"`/`K"cmd_macro"` kinds as dumped.

Expected: all 22 snippets pass `oracle_diff`.

- [ ] **Step 5: Corpus re-run (count must increase) + commit**

```bash
git add src/cst_conversion/forms.jl test/test_cst_conversion.jl
git commit -m "feat: cst conversion for call syntax"
```

---

### Task 8: Burn-down — control flow and containers

**Files:**
- Modify: `src/cst_conversion/forms.jl`
- Test: `test/test_cst_conversion.jl`

**Interfaces:** extends `assemble_form` only.

- [ ] **Step 1: Write the failing test**

Append to `test/test_cst_conversion.jl`:

```julia
@testitem "cst-conv: control flow and containers via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        "if a\nb\nend",
        "if a\nb\nelse\nc\nend",
        "if a\nb\nelseif c\nd\nelse\ne\nend",
        "a ? b : c",
        "while a\nb\nend",
        "for i in xs\ni\nend",
        "for i = 1:10, j in ys\nend",
        "for (a, b) in xs end",
        "try\na\ncatch\nend",
        "try\na\ncatch err\nb\nfinally\nc\nend",
        "try\na\ncatch e\nb\nelse\nc\nend",
        "let x = 1\nx\nend",
        "let\nend",
        "return",
        "return x",
        "break",
        "continue",
        "(a, b)",
        "(a,)",
        "(;a=1)",
        "[1, 2]",
        "[1 2]",
        "[1 2; 3 4]",
        "[1; 2;; 3; 4]",
        "Int[1, 2]",
        "[x for x in xs]",
        "[x for x in xs if x > 0]",
        "(x for x in xs)",
        "[x + y for x in xs, y in ys]",
        "Dict(a => b)",
        "a:b",
        "a:b:c",
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end
```

- [ ] **Step 2–4: Red/green loop, same recipe as Task 6 Step 3**

Branches: `K"if"`/`K"elseif"` (CSTParser nests elseif as a child `:elseif` with specific trivia distribution — dump `"if a\nb\nelseif c\nd\nelse\ne\nend"` carefully), `K"?"` ternary, `K"while"`, `K"for"` + `K"iteration"`/`K"in"` (the iteration spec: oracle shows whether `in`/`=` becomes an operator-headed binary or `:iteration`), `K"try"` (all 4 clause combinations in the snippets), `K"let"`, `K"return"`, `K"break"`/`K"continue"`, `K"tuple"` (incl. trailing comma and named-tuple `(;a=1)`), `K"vect"`, `K"hcat"`, `K"vcat"`, `K"row"`, `K"ncat"`/`K"nrow"`, `K"typed_vect"`/`K"typed_hcat"`, `K"comprehension"`, `K"generator"`, `K"filter"`, and range colon-calls (these are infix `K"call"`; verify the Task 4 branch covers `a:b:c`'s 5 children).

Expected: all 32 snippets pass.

- [ ] **Step 5: Corpus re-run (count must increase) + commit**

```bash
git add src/cst_conversion/forms.jl test/test_cst_conversion.jl
git commit -m "feat: cst conversion for control flow and containers"
```

---

### Task 9: Burn-down — strings, operators, remaining expression forms

**Files:**
- Modify: `src/cst_conversion/forms.jl`, `src/cst_conversion/terminals.jl`
- Test: `test/test_cst_conversion.jl`

**Interfaces:** extends `assemble_form` and terminal tables only.

- [ ] **Step 1: Write the failing test**

Append to `test/test_cst_conversion.jl`:

```julia
@testitem "cst-conv: strings and operators via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        "\"a\$b c\"",            # interpolation: CSTParser splits chunks differently
        "\"a\$(b + c)d\"",
        "\"\"\"\ntriple \$x\n\"\"\"",
        "`cmd \$x`",
        "```\ncmd\n```",
        "raw\"no \$interp\"",
        "'\\n'",
        "\"esc\\\"aped\"",
        "-x",                    # unary call
        "!x",
        "+x",
        "x'",                    # postfix adjoint
        "x''",
        "a .+ b",                # broadcast infix
        ".!x",
        "a && b",
        "a || b && c",
        "a <: B",
        "a >: B",
        "a === b",
        "x...",
        "&x",
        "::Int",
        "2x",                    # juxtaposition
        "2(x + 1)",
        "a = b = c",             # right-assoc chained assignment
        "a += 1",
        "a .= b",
        "x = \"\"\"\n a\n\"\"\"",
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end
```

- [ ] **Step 2–4: Red/green loop, same recipe as Task 6 Step 3**

This group's known hard spots, each pinned by dumping both sides:

- **String nodes** (`K"string"`, `K"cmdstring"`): CSTParser and JuliaSyntax split interpolated strings into different chunk sequences and CSTParser keeps quote tokens as trivia. If chunk boundaries genuinely disagree (not just layout), rebuild CSTParser's chunking from the leaf byte ranges and source text inside the `K"string"` branch — the leaves carry exact positions, so CSTParser's chunk spans can be reconstituted by re-slicing the source between the quote tokens. If a case appears where that is impossible, record it in `docs/superpowers/plans/cst-converter-divergences.md` (created in this task) instead of forcing it, and move on.
- **Unary/postfix** (`K"call"` with `PREFIX_OP_FLAG`/`POSTFIX_OP_FLAG`): extend the Task 4 call branch using `JuliaSyntax.is_prefix_op_call`/`is_postfix_op_call`; postfix `'` in CSTParser is an operator-headed EXPR (see `update_span!`'s `is_prime` special case — head EXPR, trailing).
- **Short-circuit** `K"&&"`/`K"||"` and comparisons-as-syntax (`<:`, `>:`, `===`?): oracle dump decides operator-head-vs-call per operator; encode exactly that.
- **Juxtaposition** (`K"juxtapose"`): CSTParser emits an implicit `*` call; the oracle dump shows whether the synthesized `*` EXPR has zero span — replicate.
- **Dotted ops** (`K"dotcall"` infix, `.=` as dotted assignment): distinct CSTParser layouts; dump each.

Expected: all 29 snippets pass, except any recorded in the divergence log (each such test line moves into a `@test_broken` with a comment-free reference by snippet only).

- [ ] **Step 5: Corpus re-run + commit**

```bash
git add src/cst_conversion test/test_cst_conversion.jl docs/superpowers/plans/cst-converter-divergences.md
git commit -m "feat: cst conversion for strings and operator forms"
```

---

### Task 10: Burn-down — imports, docstrings, full-corpus loop to zero

**Files:**
- Modify: `src/cst_conversion/forms.jl`
- Create: `docs/superpowers/plans/cst-converter-divergences.md` (if Task 9 didn't)
- Test: `test/test_cst_conversion.jl`

**Interfaces:** extends `assemble_form`. Produces the divergence decision list (USER CHECKPOINT).

- [ ] **Step 1: Write the failing test**

Append to `test/test_cst_conversion.jl`:

```julia
@testitem "cst-conv: imports and docstrings via oracle" begin
    using JuliaWorkspaces: CSTConversion
    for src in [
        "using A",
        "using A, B",
        "using A: x, y",
        "using A.B.C",
        "import A",
        "import A as B",
        "import A: x as y",
        "import ..A",
        "export a, b",
        "\"\"\"\ndoc\n\"\"\"\nf(x) = x",
        "\"doc\"\nmodule A end",
        "@doc \"x\" f",
        "quote\nx\nend",
        ":(x + y)",
        ":x",
        "\$x",
        "\$(x)",
        "x where {T, S}",
        "GC.@preserve a f(a)",
        "if VERSION > v\"1.6\" end",
    ]
        @test CSTConversion.oracle_diff(src) === nothing
    end
end
```

- [ ] **Step 2–3: Red/green loop, same recipe as Task 6 Step 3**

Branches: `K"using"`/`K"import"` (with `K"importpath"`, `K":"` selective-import layout, `K"as"`), `K"export"` (and `K"public"` if the pinned JuliaSyntax emits it), `K"doc"` (docstring macrocall — CSTParser represents it as a `:macrocall` with a synthesized `@doc` name; dump to replicate), `K"quote"` (block form and `:(...)` form differ), `K"$"` interpolation, `K"braces"`/`K"bracescat"`.

- [ ] **Step 4: Build the big corpus (copied, never in-place) and loop to zero**

```bash
mkdir -p /tmp/claude-13471954/-home-pfitzseb-git-julia-vscode-scripts-packages-JuliaWorkspaces/1b3c5b3f-4373-46ef-b6f2-294a49002962/scratchpad/corpus
cp -r ~/.julia/packages /tmp/claude-13471954/-home-pfitzseb-git-julia-vscode-scripts-packages-JuliaWorkspaces/1b3c5b3f-4373-46ef-b6f2-294a49002962/scratchpad/corpus/packages
```

Then via `mcp__julia__julia_eval`:

```julia
include("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces/test/cst_corpus.jl")
files = CSTCorpus.julia_files("/tmp/claude-13471954/-home-pfitzseb-git-julia-vscode-scripts-packages-JuliaWorkspaces/1b3c5b3f-4373-46ef-b6f2-294a49002962/scratchpad/corpus/packages")
CSTCorpus.run_corpus(files; report_path=".../scratchpad/corpus_report.md")  # same scratchpad dir
```

Loop: pick the highest-count diff signature from the report → reduce one example file to a minimal snippet → add it to the nearest-themed testitem above → fix the branch → re-run corpus. Repeat until the report shows either 100% pass or only signatures caused by **genuine parser divergence** (the two parsers disagree about structure, not layout).

STOP criteria for this step: (a) zero non-divergence diffs remain, AND (b) every remaining signature is written into `docs/superpowers/plans/cst-converter-divergences.md` as: snippet, both tree dumps (truncated), and a proposed resolution (converter shims it / downstream adapts / accept drift).

- [ ] **Step 5: USER CHECKPOINT — commit and pause**

```bash
git add src/cst_conversion test/test_cst_conversion.jl docs/superpowers/plans/cst-converter-divergences.md
git commit -m "feat: cst conversion for imports and docstrings; corpus at parity

Corpus: <N>/<M> files identical to oracle; remaining signatures documented
in cst-converter-divergences.md"
```

Present `cst-converter-divergences.md` to the user for decisions before Task 12's backend flip. Task 11 can proceed meanwhile.

---

### Task 11: Error recovery mapping

**Files:**
- Modify: `src/cst_conversion/forms.jl`, `src/cst_conversion/terminals.jl`
- Test: `test/test_cst_conversion.jl`

**Interfaces:** extends `assemble_form` with `K"error"`; no oracle equality here — the contract is: never throw, spans tile the source, error subtrees are traversable.

- [ ] **Step 1: Write the failing test**

Append to `test/test_cst_conversion.jl`:

```julia
@testitem "cst-conv: broken code invariants" begin
    using CSTParser
    using JuliaWorkspaces: CSTConversion
    for src in [
        "function f(",
        "a +",
        "f(x,",
        "if a",
        "struct",
        "a.b.",
        "\"unterminated",
        "x = @",
        "function f() en",
        "a ? b",
        "[1, 2",
        "module A function g() end",
    ]
        ex = CSTConversion.build_cst(src)
        @test ex isa CSTParser.EXPR
        @test ex.fullspan == sizeof(src)
        @test CSTConversion.check_spans(ex) === nothing
        # error subtrees must be traversable by StaticLint-style recursion
        count = Ref(0)
        walk(x) = begin
            count[] += 1
            x.args === nothing || foreach(walk, x.args)
        end
        walk(ex)
        @test count[] > 0
    end
end
```

- [ ] **Step 2: Run to verify failures** (converter throws or spans don't tile on some inputs).

- [ ] **Step 3: Implement**

Add to `assemble_form` (before the fallback):

```julia
    elseif k == K"error"
        # CSTParser marks recovery with :errortoken; children stay reachable
        # so downstream traversal and spans keep working.
        return EXPR(:errortoken, kids, nothing, 0, 0)
```

And in `terminals.jl`, map error-kind leaves (`JuliaSyntax.is_error(k)`) to `EXPR(:errortoken, fullspan, span, token_text(...))`. Also handle `K"TOMBSTONE"`/zero-width leaves if they appear: emit zero-span `:errortoken` EXPRs rather than skipping, so span tiling holds.

- [ ] **Step 4: Run test to verify it passes**, then also re-run the full cst-conv suite.

- [ ] **Step 5: Commit**

```bash
git add src/cst_conversion test/test_cst_conversion.jl
git commit -m "feat: map JuliaSyntax error recovery to errortoken EXPRs"
```

---

### Task 12: Salsa single-parse integration + backend flip

**Files:**
- Modify: `src/layer_syntax_trees.jl`
- Modify: `src/public.jl` (add `syntax_node_at`; export next to the existing tree accessors around `public.jl:463`)
- Test: `test/test_cst_conversion.jl`

**Interfaces:**
- Produces: `derived_julia_green_tree(rt, uri) -> Tuple{GreenNode, Vector{JuliaSyntax.Diagnostic}, String}`; `derived_julia_legacy_syntax_tree` now converter-backed with `CST_BACKEND` override; `JuliaWorkspaces.syntax_node_at(node::SyntaxNode, byte::Int) -> SyntaxNode` (deepest node containing byte — the SyntaxNode counterpart of `get_expr1` for cross-tree migration).

- [ ] **Step 1: Write the failing test**

Append to `test/test_cst_conversion.jl`:

```julia
@testitem "cst-conv: single-parse salsa integration" begin
    using CSTParser, JuliaSyntax
    using JuliaSyntax: kind, @K_str
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, URI

    content = "f(x) = x + 1\n"
    jw = JuliaWorkspace()
    uri = URI("file:///a.jl")
    add_file!(jw, TextFile(uri, SourceText(content, "julia")))

    cst = JuliaWorkspaces.get_legacy_cst(jw, uri)
    @test cst isa CSTParser.EXPR
    @test JuliaWorkspaces.CSTConversion.trees_equal(cst, CSTParser.parse(content, true))

    sn = JuliaWorkspaces.get_julia_syntax_tree(jw, uri)
    @test JuliaWorkspaces.syntax_node_at(sn, 1) isa JuliaSyntax.SyntaxNode
    @test kind(JuliaWorkspaces.syntax_node_at(sn, 8)) == K"Identifier"  # byte 8 = 'x'
end
```

(Workspace-construction idiom copied from `test/test_documents.jl:3-8`; accessors are `get_julia_syntax_tree` at `public.jl:458` and `get_legacy_cst` at `public.jl:651`. If `URI`/`TextFile`/`SourceText` aren't importable exactly as written, mirror the imports at the top of `test/test_documents.jl`.)

- [ ] **Step 2: Run to verify it fails** (`derived_julia_green_tree`, `syntax_node_at` undefined).

- [ ] **Step 3: Implement**

In `src/layer_syntax_trees.jl`, replace lines 1–54 (`derived_julia_parse_result` / `derived_julia_syntax_tree` / `derived_julia_legacy_syntax_tree`) with:

```julia
Salsa.@derived function derived_julia_green_tree(rt, uri)
    @debug "derived_julia_green_tree" uri=uri
    tf = derived_text_file_content(rt, uri)
    content = tf.content.content
    stream = JuliaSyntax.ParseStream(content; version=VERSION)
    JuliaSyntax.parse!(stream; rule=:all)
    green = JuliaSyntax.build_tree(JuliaSyntax.GreenNode, stream)
    return green, stream.diagnostics, content
end

Salsa.@derived function derived_julia_parse_result(rt, uri)
    green, diagnostics, content = derived_julia_green_tree(rt, uri)
    tree = SyntaxNode(JuliaSyntax.SourceFile(content), green)
    return tree, diagnostics
end

Salsa.@derived function derived_julia_syntax_tree(rt, uri)
    return derived_julia_parse_result(rt, uri)[1]
end

# Backend escape hatch while the converter soaks; read once at load time.
const CST_BACKEND = Ref(get(ENV, "JW_CST_BACKEND", "juliasyntax"))

Salsa.@derived function derived_julia_legacy_syntax_tree(rt, uri)
    @debug "derived_julia_legacy_syntax_tree" uri=uri
    if CST_BACKEND[] == "cstparser"
        tf = derived_text_file_content(rt, uri)
        return CSTParser.parse(tf.content.content, true)
    end
    green, _, content = derived_julia_green_tree(rt, uri)
    return CSTConversion.build_cst(green, content)
end
```

(Verify the `SyntaxNode(::SourceFile, ::GreenNode)` constructor exists in the pinned 0.4.10 — `~/.julia/packages/JuliaSyntax/DHdTk/src/syntax_tree.jl`; if the signature differs, adapt to what `build_tree(SyntaxNode, ...)` does internally at `syntax_tree.jl:262`.)

In `src/public.jl`, next to the existing syntax-tree accessor (`public.jl:463`):

```julia
function syntax_node_at(node::SyntaxNode, byte::Int)
    while haschildren(node)
        found = false
        for c in children(node)
            if first_byte(c) <= byte <= last_byte(c)
                node = c
                found = true
                break
            end
        end
        found || break
    end
    return node
end
```

- [ ] **Step 4: Run the cst-conv suite** — expected PASS.

- [ ] **Step 5: Run the FULL package suite, both backends**

Via `mcp__julia__julia_eval` (empty filter = everything):

```julia
withenv("JW_TEST_FILTER" => "") do
    include("/home/pfitzseb/git/julia-vscode/scripts/packages/JuliaWorkspaces/test/runtests.jl")
end
```

Then set `JuliaWorkspaces.CST_BACKEND[] = "cstparser"` and repeat. Expected: identical results (0 failures both ways; if the pre-existing suite has known failures on main, the two runs must fail identically). Any test passing under `cstparser` but failing under `juliasyntax` is a converter bug: reduce to a snippet, add to the themed testitem, fix, re-run.

- [ ] **Step 6: Commit**

```bash
git add src/layer_syntax_trees.jl src/public.jl test/test_cst_conversion.jl
git commit -m "feat: single JuliaSyntax parse feeding both syntax trees

derived_julia_legacy_syntax_tree now builds EXPR via CSTConversion from
the shared green tree; JW_CST_BACKEND=cstparser restores the old parser."
```

---

### Task 13: Soak gate + finish

**Files:** none new.

- [ ] **Step 1: Full-suite verification run** — both backends again from a fresh julia-mcp restart (`mcp__julia__julia_restart`), to rule out Revise artifacts. Record outputs.

- [ ] **Step 2: Resolve the divergence list** — confirm the user has answered `cst-converter-divergences.md` (Task 10 checkpoint); implement any "converter shims it" decisions as new testitem snippets + `forms.jl` branches, same recipe as Task 6 Step 3.

- [ ] **Step 3: Finish the branch** — use the superpowers:finishing-a-development-branch skill (merge vs PR decision belongs to the user). Note for the PR body: CSTParser remains a dependency (EXPR datastructure + predicates + oracle in tests); *parsing* now happens exactly once via JuliaSyntax. Dropping the dependency entirely (vendoring EXPR + predicates) and porting `layer_completions.jl`'s Tokenize usage are follow-up projects, deliberately out of scope here.
