# Macro-Annotation Arity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the cross-file argument-count check agree with `check_call`'s own
path on macro-wrapped definitions, without losing precision for macros that
provably keep their signature.

**Architecture:** The inventory (layer 1) records what it can read from the CST
— the *literal* argument counts plus the names of the macros wrapping the
definition — and stops asserting whether the macro rewrote the signature. The
consumer in `layer_file_analysis.jl`, which already holds `env`, `meta_dict` and
the module tree, interprets those names: literal counts stand only if every
wrapping macro is a known signature-preserving Base macro that the defining
module has not shadowed. Annotations ride on `MethodArity`, which
`derived_method_arities_index` copies verbatim, so layer 2 needs no changes.

**Tech Stack:** Julia 1.12, CSTParser (vendored fork), Salsa incremental
runtime, TestItemRunner.

## Global Constraints

- Read the spec first: `docs/design/macro-annotation-arity.md`. It carries the
  measurements, the constraint derivation and the rejected alternatives.
- **Layer 1 and layer 2 values must never depend on `derived_environment`**
  (`src/layer_module_tree.jl:10-14`) and must contain only plain data — Symbols,
  Strings, Ints, and collections thereof; no `EXPR`, objectid, or byte offset
  (`src/layer_inventory.jl:1-7`). Every value added by this plan is a
  `Vector{String}` read from the CST, which satisfies both.
- **Run Julia only through the `julia-mcp` tool**, never by spawning `julia` or
  `Pkg.test`. Env: `/home/pfitzseb/git/julia-vscode/scripts/environments/development`.
- **Run tests** with
  `TestItemRunner.run_tests("."; filter=ti->occursin("<name>", ti.name), verbose=true)`
  after `cd`-ing to the package root. Use timeouts ≥600 s; a timeout kills the
  session and all its state.
- **`julia_restart` is required after editing a struct definition** (Task 2
  edits `MethodArity`). Revise cannot apply struct redefinitions; without a
  restart you get `@world`-flavoured MethodErrors.
- **`@testitem` bodies need explicit imports** (`using JuliaWorkspaces: …`);
  TestItemRunner's default usings do not apply on this invocation path.
- `get_hints`/`get_diagnostic` is **vacuously empty for a project-less root**.
  Assert lint firing via `collect_hints` (see `has_error` in
  `test/staticlint/test_staticlint.jl:1430`) or via
  `derived_file_analysis(...).diagnostics` with the `FileAnalysisWS` harness.
- **Baseline suite result** (must not regress): 5648 passed, 0 failed,
  1 errored, 7 broken. The error is `Runic not found in current path`
  (`test/test_formatting.jl`, dev-env gap); the 7 broken are pre-existing
  `@test_broken` markers in `test/test_uris2.jl` (6) and
  `test/staticlint/test_staticlint.jl` (1).
- Commit messages: imperative `fix:`/`feat:`/`test:` prefix, no consumer-specific
  context (this is a generic package), and end with
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.

## Decisions already made (do not re-litigate)

From spec §10, resolved:

1. **Unnameable wrappers** (`@($m) f(x) = 1`, where `_macro_name_string` returns
   `nothing`) push the sentinel `"?"`. It can never equal a real macro name, so
   it never matches the preserving set and forces the permissive answer.
2. **Explicit `@doc` / `Mod.@doc`** is already handled: `is_doc_macrocall`
   (`src/StaticLint/linting/checks.jl`) covers the implicit `globalrefdoc` form
   and both explicit spellings, and is already applied in `func_nargs` and
   `struct_nargs`.
3. **Same-file full resolution** via the call site's `meta_dict` is **out of
   scope**. The name + tree-shadow check in Task 3 covers the case that matters.

## File Structure

| File | Responsibility in this plan |
|---|---|
| `src/StaticLint/linting/checks.jl` | `func_nargs`/`struct_nargs` gain `macro_permissive`; no other behaviour change |
| `src/layer_inventory.jl` | `MethodArity` gains `macro_annotations`; `_macro_annotations` collects them; the three arity-recording sites pass `macro_permissive=false` |
| `src/layer_file_analysis.jl` | `_effective_arity` + `_is_signature_preserving`; wired into the `tree_arities` closure and `_call_cross_file_arities` |
| `test/staticlint/test_staticlint.jl` | Task 1 unit tests for the keyword |
| `test/test_inventory.jl` | Task 2 tests for recorded annotations + literal arity |
| `test/test_file_analysis.jl` | Task 3 end-to-end cross-file tests |

---

### Task 1: `macro_permissive` keyword on the arity helpers

Lets a caller with no resolution state ask for the literal count instead of the
permissive one. Behaviour-preserving by default: every existing caller keeps
today's semantics.

**Files:**
- Modify: `src/StaticLint/linting/checks.jl` (`struct_nargs` ~line 179, `func_nargs` ~line 218)
- Test: `test/staticlint/test_staticlint.jl`

**Interfaces:**
- Consumes: `is_doc_macrocall(x::EXPR)::Bool`, already in `checks.jl`.
- Produces:
  - `func_nargs(x::EXPR, env=nothing, meta_dict=nothing; macro_permissive=true) -> (Int, Int, Vector{Symbol}, Bool)`
  - `struct_nargs(x::EXPR, env=nothing, meta_dict=nothing; macro_permissive=true) -> (Int, Int, Vector{Symbol}, Bool)`
  - With `macro_permissive=false`, a macro-wrapped definition yields its literal
    counts rather than `(0, typemax(Int), Symbol[], true)`.

- [ ] **Step 1: Write the failing test**

Add to `test/staticlint/test_staticlint.jl`, immediately before the
`@testitem "a docstring does not hide a wrong-arity call"` item:

```julia
@testitem "arity helpers can report the literal count under a macro" setup=[shared_static_lint] begin
    using JuliaWorkspaces.StaticLint: func_nargs, struct_nargs

    cst, meta_dict, jw = parse_and_pass("""
    macro wrap(ex)
        ex
    end
    @wrap f(x, y) = 1
    @wrap struct S
        a::Int
        b::Int
    end
    """)
    env = get_env(jw)
    fdef = cst.args[2].args[3]        # the `f(x, y) = 1` inside the macrocall
    sdef = cst.args[3].args[3]        # the `struct S … end` inside the macrocall

    # Default: unknowable, because the macro may rewrite the signature.
    @test func_nargs(fdef, env, meta_dict) == (0, typemax(Int), Symbol[], true)
    @test struct_nargs(sdef, env, meta_dict) == (0, typemax(Int), Symbol[], true)

    # Opted out: the literal shape as written.
    @test func_nargs(fdef, env, meta_dict; macro_permissive=false) == (2, 2, Symbol[], false)
    @test struct_nargs(sdef, env, meta_dict; macro_permissive=false) == (2, 2, Symbol[], false)

    # An unwrapped definition is unaffected by the keyword.
    cst2, meta_dict2, jw2 = parse_and_pass("g(x) = 1\n")
    gdef = cst2.args[1]
    @test func_nargs(gdef, get_env(jw2), meta_dict2) ==
          func_nargs(gdef, get_env(jw2), meta_dict2; macro_permissive=false) ==
          (1, 1, Symbol[], false)
end
```

If `cst.args[2].args[3]` is not the wrapped definition, print the tree with
`println(cst.args[2])` in the `julia-mcp` session and adjust the index — a
3-arg macrocall is `[macroname, arg]` plus trivia, so the wrapped item is the
last arg. Do not guess: verify the index before moving on.

- [ ] **Step 2: Run the test and confirm it fails**

```julia
TestItemRunner.run_tests("."; filter=ti->occursin("literal count under a macro", ti.name), verbose=true)
```

Expected: the two `macro_permissive=false` assertions fail, each reporting
`(0, 9223372036854775807, Symbol[], true)` instead of `(2, 2, Symbol[], false)`.
The default-behaviour assertions must already pass — if they don't, the `fdef`/
`sdef` indices are wrong, not the implementation.

- [ ] **Step 3: Add the keyword to `func_nargs`**

In `src/StaticLint/linting/checks.jl`, change the signature and the guard:

```julia
function func_nargs(x::EXPR, env=nothing, meta_dict=nothing; macro_permissive=true)
    # early return for macro-wrapped functions, unless we know the macro does
    # not modify the signature (requires env + meta_dict to resolve the macro).
    # A doc wrapper is exempt: it is a macrocall, but it cannot rewrite the
    # signature it wraps, so a docstring must not stop the arity being checked.
    # `macro_permissive=false` opts out entirely: the caller records the wrapping
    # macro separately and interprets it itself (see the inventory).
    if macro_permissive && env !== nothing && meta_dict !== nothing && parentof(x) isa EXPR &&
            CSTParser.ismacrocall(parentof(x)) && !is_doc_macrocall(parentof(x))
        macroname = parentof(x).args[1]
        any(n -> _points_to_Base_macro(macroname, n, env, meta_dict), SIGNATURE_PRESERVING_MACROS) ||
            return 0, typemax(Int), Symbol[], true
    end
```

- [ ] **Step 4: Add the keyword to `struct_nargs`**

Same file, `struct_nargs`. Change the signature, the macro early return, and the
inner-constructor delegation:

```julia
function struct_nargs(x::EXPR, env=nothing, meta_dict=nothing; macro_permissive=true)
    # struct defs wrapped in macros are likely to have some arbirtary additional
    # constructors, so lets allow anything — except behind a doc wrapper, which
    # adds no constructors (see `func_nargs`), or when the caller opts out.
    macro_permissive && parentof(x) isa EXPR && CSTParser.ismacrocall(parentof(x)) &&
        !is_doc_macrocall(parentof(x)) && return 0, typemax(Int), Symbol[], true
```

and inside the `inner_constructors` loop, forward the keyword:

```julia
            imin, imax, ikws, ikwsplat = func_nargs(args.args[i], env, meta_dict; macro_permissive)
```

- [ ] **Step 5: Run the test and confirm it passes**

```julia
TestItemRunner.run_tests("."; filter=ti->occursin("literal count under a macro", ti.name), verbose=true)
```

Expected: all assertions pass.

- [ ] **Step 6: Confirm nothing else moved**

```julia
TestItemRunner.run_tests("."; filter=ti->occursin("docstring does not hide", ti.name) || occursin("inner constructor", ti.name) || occursin("cross-file argument-count", ti.name) || occursin("method arity", ti.name), verbose=true)
```

Expected: all pass. These cover both arity helpers' existing callers.

- [ ] **Step 7: Commit**

```bash
git add src/StaticLint/linting/checks.jl test/staticlint/test_staticlint.jl
git commit -m "$(cat <<'EOF'
feat: let arity helpers report the literal count under a macro

`func_nargs`/`struct_nargs` answer "unknowable" for a macro-wrapped definition
unless they can resolve the macro, which needs env + meta_dict. A caller that
has neither but records the wrapping macro name itself needs the literal count
instead. Default behaviour is unchanged.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: record macro annotations in the inventory

The inventory stops asserting permissiveness and instead records the literal
arity plus the names of the wrapping macros.

**Files:**
- Modify: `src/layer_inventory.jl` (`MethodArity` ~line 21, docstring ~line 9-20, new `_macro_annotations` next to `_macro_name_string` ~line 541, recording sites ~lines 691, 759, 787)
- Test: `test/test_inventory.jl`

**Interfaces:**
- Consumes: `func_nargs`/`struct_nargs`'s `macro_permissive` keyword from Task 1;
  `_macro_name_string(x)::Union{Nothing,String}` (`layer_inventory.jl:541`);
  `_doc_wrapped_item(x)::Union{Nothing,EXPR}` (`layer_inventory.jl:137`).
- Produces:
  - `MethodArity(minargs::Int, maxargs::Int, kws::Vector{Symbol}, kwsplat::Bool, macro_annotations::Vector{String})`
  - `MethodArity(minargs, maxargs, kws, kwsplat)` — back-compat, annotations `String[]`
  - `_macro_annotations(x::CSTParser.EXPR)::Vector{String}` — `@`-prefixed names, innermost→outermost, `"?"` for an unnameable wrapper
  - `InventoryItem.arity.macro_annotations` is what Task 3 reads.

- [ ] **Step 1: Write the failing test**

Add to `test/test_inventory.jl` (end of file is fine; match the file's existing
`@testitem` style):

```julia
@testitem "inventory: macro annotations and literal arity" begin
    using JuliaWorkspaces
    using JuliaWorkspaces.URIs2: URI

    function arity_of(source, name)
        uri = URI("file:///annot/test.jl")
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(source, "julia")))
        inv = JuliaWorkspaces.derived_file_inventory(jw.runtime, uri)
        idx = findfirst(it -> it.name == name, inv.items)
        idx === nothing ? nothing : inv.items[idx].arity
    end

    # Unwrapped: literal arity, no annotations.
    a = arity_of("f(x) = 1\n", "f")
    @test (a.minargs, a.maxargs, a.kwsplat) == (1, 1, false)
    @test a.macro_annotations == String[]

    # Wrapped: literal arity is still recorded; the wrapper is recorded beside it.
    @test arity_of("@inline f(x) = 1\n", "f").macro_annotations == ["@inline"]
    @test arity_of("Base.@inline f(x) = 1\n", "f").macro_annotations == ["@inline"]
    @test arity_of("@wrap f(x) = 1\n", "f").macro_annotations == ["@wrap"]
    let a2 = arity_of("@wrap f(x, y) = 1\n", "f")
        @test (a2.minargs, a2.maxargs, a2.kwsplat) == (2, 2, false)
    end

    # Nested wrappers, innermost first.
    @test arity_of("@inline @propagate_inbounds f(x) = 1\n", "f").macro_annotations ==
          ["@propagate_inbounds", "@inline"]

    # A doc wrapper is transparent — it cannot rewrite a signature.
    @test arity_of("\"docs\"\nf(x) = 1\n", "f").macro_annotations == String[]
    @test arity_of("\"docs\"\n@inline f(x) = 1\n", "f").macro_annotations == ["@inline"]

    # An unnameable wrapper records the sentinel, which matches no real macro.
    @test arity_of("@(m) f(x) = 1\n", "f").macro_annotations == ["?"]

    # Structs record their wrapper too, and keep their literal field arity.
    let s = arity_of("@kwdef struct S\n    a::Int\n    b::Int\nend\n", "S")
        @test (s.minargs, s.maxargs) == (2, 2)
        @test s.macro_annotations == ["@kwdef"]
    end
end
```

If `@(m) f(x) = 1` does not parse to a macrocall whose name yields `nothing`
from `_macro_name_string`, drop that one assertion and instead assert the
sentinel via a unit call: `_macro_annotations` on a hand-built tree is not worth
the effort — note the gap in the commit message rather than inventing a shape.

- [ ] **Step 2: Run the test and confirm it fails**

```julia
TestItemRunner.run_tests("."; filter=ti->occursin("macro annotations and literal arity", ti.name), verbose=true)
```

Expected: fails at the first `macro_annotations` access with
`FieldError: type MethodArity has no field macro_annotations`.

- [ ] **Step 3: Add the field and the back-compat constructor**

`src/layer_inventory.jl`, replacing the current struct:

```julia
@auto_hash_equals struct MethodArity
    minargs::Int
    maxargs::Int
    kws::Vector{Symbol}
    kwsplat::Bool
    macro_annotations::Vector{String}
end

# Back-compat: store methods (`func_nargs(::MethodStore)`) and definitions with
# no macro wrapper carry no annotations. Keeps every
# `MethodArity(func_nargs(x)...)` splat working.
MethodArity(minargs, maxargs, kws, kwsplat) =
    MethodArity(minargs, maxargs, kws, kwsplat, String[])
```

Extend the docstring above it (currently `layer_inventory.jl:9-20`) with:

```
`macro_annotations` names the macros wrapping the definition (innermost→outermost,
`@`-prefixed, `"?"` for a name that cannot be read statically). The recorded
counts are LITERAL — whether a wrapping macro rewrote the signature is not
decidable here, so a consumer holding `env`/`meta_dict` resolves these names and
widens the arity itself (`layer_file_analysis.jl`'s `_effective_arity`).
```

- [ ] **Step 4: Restart the Julia session**

```
julia_restart(env_path="/home/pfitzseb/git/julia-vscode/scripts/environments/development")
```

Then re-`using` and `cd` as usual. Revise cannot redefine a struct; skipping
this produces confusing MethodErrors.

- [ ] **Step 5: Add the collector**

`src/layer_inventory.jl`, immediately after `_is_enum_macro` (~line 558):

```julia
# The macro names directly wrapping a definition, innermost→outermost. Doc
# wrappers are transparent: they cannot rewrite a signature. Only a direct chain
# of macrocall parents counts — `@static if … end` puts an `if`/`block` between
# the macrocall and the definition, and such a definition is not macro-wrapped
# for arity purposes (matching `func_nargs`' own parent test). A name that
# cannot be read statically (`@($m) f() = 1`) records `"?"`, which matches no
# real macro and so always forces the permissive answer downstream.
function _macro_annotations(x::CSTParser.EXPR)
    names = String[]
    p = CSTParser.parentof(x)
    while p isa CSTParser.EXPR && CSTParser.ismacrocall(p)
        if _doc_wrapped_item(p) === nothing
            nm = _macro_name_string(p.args[1])
            push!(names, nm === nothing ? "?" : nm)
        end
        p = CSTParser.parentof(p)
    end
    return names
end
```

- [ ] **Step 6: Record it at the three arity sites**

`src/layer_inventory.jl` line ~691 (the `:function` branch of
`_classify_macrocall!`-reached defs) and line ~759 (the
`:function`/`:macro` branch), replacing the arity expression:

```julia
(StaticLint._is_real_method(x) ?
    MethodArity(StaticLint.func_nargs(x; macro_permissive=false)..., _macro_annotations(x)) :
    nothing)
```

and line ~787 (the struct branch):

```julia
        arity = CSTParser.defines_struct(x) ?
            MethodArity(StaticLint.struct_nargs(x; macro_permissive=false)..., _macro_annotations(x)) :
            nothing
```

Note `func_nargs(x; macro_permissive=false)` — positional `env`/`meta_dict` stay
defaulted to `nothing`, exactly as today.

- [ ] **Step 7: Run the test and confirm it passes**

```julia
TestItemRunner.run_tests("."; filter=ti->occursin("macro annotations and literal arity", ti.name), verbose=true)
```

Expected: all assertions pass.

- [ ] **Step 8: Run the inventory and module-tree suites**

```julia
TestItemRunner.run_tests("."; filter=ti->occursin("inventory", lowercase(ti.name)) || occursin("method arity", ti.name) || occursin("module", lowercase(ti.name)), verbose=true)
```

Expected: all pass. `derived_method_arities` assertions in
`test/test_module_tree.jl` compare whole `MethodArity` values against index
entries, which stay consistent because both sides gain the field.

- [ ] **Step 9: Commit**

```bash
git add src/layer_inventory.jl test/test_inventory.jl
git commit -m "$(cat <<'EOF'
feat: record wrapping macro names in the inventory

The inventory cannot resolve a macro — layer 1 and 2 must not depend on the env,
the inventory is keyed per-file, and resolution needs a meta_dict that is
downstream of it — so it stops deciding whether a macro-wrapped definition kept
its signature. It records the literal arity plus the wrapping macro names as
plain data; the consumer that holds env and meta_dict interprets them.

Annotations ride on MethodArity so derived_method_arities_index carries them to
the consumer with no layer 2 changes.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: resolve annotations at the consumer

Where the divergence is actually fixed: the literal counts stand only if every
wrapping macro is a known signature-preserving Base macro that the defining
module has not shadowed.

**Files:**
- Modify: `src/layer_file_analysis.jl` (new helpers near `_call_cross_file_arities` ~line 512; the `tree_arities` closure ~line 765)
- Test: `test/test_file_analysis.jl`

**Interfaces:**
- Consumes: `MethodArity.macro_annotations` from Task 2;
  `StaticLint.SIGNATURE_PRESERVING_MACROS::Vector{Symbol}` (`checks.jl:194`);
  `derived_module_visible_names_idfree(rt, root, path)::Dict{String,VisibleNameFace}`
  (`layer_visibility.jl:699`); `derived_method_arities(rt, root, path, name)::Vector{MethodArity}`.
- Produces: `_effective_arity(rt, root, defining_path::Vector{String}, a::MethodArity)::MethodArity`
  and `_is_signature_preserving(rt, root, defining_path::Vector{String}, nm::String)::Bool`.

- [ ] **Step 1: Write the failing tests**

Add to `test/test_file_analysis.jl`, next to the other cross-file arity items:

```julia
@testitem "derived_file_analysis: a macro-wrapped definition's arity is judged by the macro" setup=[FileAnalysisWS] begin
    mm(fa) = [d.message for d in fa.diagnostics if occursin("No method matching", d.message)]
    root_src = "module MainPkg\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n"

    # An unknown macro may rewrite the signature, so the call cannot be judged —
    # matching what check_call's own path does for the same definition.
    jw = ws_with(Dict(
        ROOT => root_src,
        A => "macro wrap(ex)\n    ex\nend\n@wrap f(x) = x\n",
        B => "g() = f(1, 2)\n",
    ))
    @test isempty(mm(JuliaWorkspaces.derived_file_analysis(jw.runtime, ROOT, B)))

    # `@inline` provably keeps the signature, so the arity is still checked.
    jw2 = ws_with(Dict(
        ROOT => root_src,
        A => "@inline h(x) = x\n",
        B => "g() = h(1, 2)\n",
    ))
    d2 = mm(JuliaWorkspaces.derived_file_analysis(jw2.runtime, ROOT, B))
    @test length(d2) == 1
    @test occursin("Expected 1 argument, got 2", d2[1])

    # ... and a correct call to it is not flagged.
    jw3 = ws_with(Dict(
        ROOT => root_src,
        A => "@inline h(x) = x\n",
        B => "g() = h(1)\n",
    ))
    @test isempty(mm(JuliaWorkspaces.derived_file_analysis(jw3.runtime, ROOT, B)))

    # A workspace macro shadowing the name `@inline` makes it unknowable again:
    # the name alone is not enough.
    jw4 = ws_with(Dict(
        ROOT => root_src,
        A => "macro inline(ex)\n    ex\nend\n@inline h(x) = x\n",
        B => "g() = h(1, 2)\n",
    ))
    @test isempty(mm(JuliaWorkspaces.derived_file_analysis(jw4.runtime, ROOT, B)))

    # A macro-wrapped struct stays permissive (`@kwdef` turns fields into kwargs).
    jw5 = ws_with(Dict(
        ROOT => root_src,
        A => "Base.@kwdef struct S\n    a::Int\n    b::Int\nend\n",
        B => "g() = S(1, 2, 3)\n",
    ))
    @test isempty(mm(JuliaWorkspaces.derived_file_analysis(jw5.runtime, ROOT, B)))
end
```

- [ ] **Step 2: Run the tests and confirm they fail**

```julia
TestItemRunner.run_tests("."; filter=ti->occursin("judged by the macro", ti.name), verbose=true)
```

Expected: after Task 2 the inventory records literal counts, so the **first**
assertion fails (the `@wrap` call is flagged "Expected 1 argument, got 2" — the
false positive this task removes) and the **fourth** fails (the shadowed
`@inline` call is flagged). The `@inline` assertions already pass, because the
literal count happens to be right for that macro — they are here to stop a
blanket-wildcard implementation from satisfying the suite.

- [ ] **Step 3: Add the resolution helpers**

`src/layer_file_analysis.jl`, immediately above `_call_cross_file_arities`:

```julia
# A macro wrapping a definition is known not to rewrite its signature only if it
# is one of StaticLint's signature-preserving Base macros AND the defining module
# has not shadowed that name. The inventory records the name (it cannot resolve
# it — see docs/design/macro-annotation-arity.md); this is where it is judged.
# Macros are keyed `@`-prefixed in the visibility index, so a workspace
# `macro inline(ex)` or a `using MyPkg: @inline` appears as "@inline".
_is_signature_preserving(rt, root, defining_path::Vector{String}, nm::String) =
    Symbol(nm) in StaticLint.SIGNATURE_PRESERVING_MACROS &&
    !haskey(derived_module_visible_names_idfree(rt, root, defining_path), nm)

# Interpret an inventory-recorded arity: literal counts stand only if every
# wrapping macro is signature-preserving, else the arity is unknowable and must
# accept any call (the same answer `check_call`'s own path gives).
function _effective_arity(rt, root, defining_path::Vector{String}, a::MethodArity)
    isempty(a.macro_annotations) && return a
    all(nm -> _is_signature_preserving(rt, root, defining_path, nm), a.macro_annotations) && return a
    return MethodArity(0, typemax(Int), Symbol[], true)
end
```

- [ ] **Step 4: Wire it into the flag path**

`src/layer_file_analysis.jl`, the `tree_arities` closure (~line 765):

```julia
    tree_arities = (name, x) -> begin
        p = vcat(path, _in_file_module_names(x, meta_dict))
        [_effective_arity(rt, root, p, a) for a in derived_method_arities(rt, root, p, name)]
    end
```

- [ ] **Step 5: Wire it into the message path**

Same file, the last line of `_call_cross_file_arities` (~line 526). Both paths
must use the identical predicate or the rendered reason can contradict the flag:

```julia
    return [_effective_arity(rt, root, p, a) for a in derived_method_arities(rt, root, p, name)]
```

- [ ] **Step 6: Run the tests and confirm they pass**

```julia
TestItemRunner.run_tests("."; filter=ti->occursin("judged by the macro", ti.name), verbose=true)
```

Expected: all five groups pass.

- [ ] **Step 7: Run every arity-related suite**

```julia
TestItemRunner.run_tests("."; filter=ti->occursin("arit", lowercase(ti.name)) || occursin("argument-count", ti.name) || occursin("method matching", lowercase(ti.name)) || occursin("docstring does not hide", ti.name) || occursin("inner constructor", ti.name), verbose=true)
```

Expected: all pass.

- [ ] **Step 8: Run the full suite**

```julia
TestItemRunner.run_tests("."; verbose=true)
```

Expected: 0 failed; only the baseline `Runic not found` error and 7 pre-existing
broken. Total passing count will be higher than the 5648 baseline by the tests
added in Tasks 1-3.

- [ ] **Step 9: Mark the spec implemented**

In `docs/design/macro-annotation-arity.md`, change the `Status:` line to
`Status: implemented (§4-§6, §8); §11 follow-ups still open.` and delete §10
(the decisions are recorded in this plan and now in the code).

- [ ] **Step 10: Commit**

```bash
git add src/layer_file_analysis.jl test/test_file_analysis.jl docs/design/macro-annotation-arity.md
git commit -m "$(cat <<'EOF'
fix: judge a macro-wrapped definition's cross-file arity by its macro

For a tree-visible workspace callee, check_call consults the inventory's arities
and returns, so the inventory's answer is the only judge. It recorded a literal
count for a macro-wrapped definition while check_call's own path treated the
same definition as unknowable — so an @wrap-wrapped f(x) called as f(1, 2) in a
sibling file was flagged, where the local path declined to judge it.

Resolve the recorded macro names where env, meta_dict and the tree are all
available: literal counts stand only for a signature-preserving Base macro the
defining module has not shadowed. The shadow check makes this stricter than the
previous literal count, which trusted the macro name blindly.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage.** §4 data model → Task 2 Steps 3, 6. §5 collection (chain walk,
doc transparency, qualified names, sentinel) → Task 2 Steps 1, 5 and the
`macro_permissive` keyword in Task 1. §6 resolution, both consumer sites, shadow
check, per-file ceiling → Task 3 Steps 3-5. §7 doc wrappers → already shipped
before this plan (`is_doc_macrocall` in `func_nargs` and `struct_nargs`); Task 1
Step 6 and Task 3 Step 7 re-run its tests. §8 test plan → T2 is Task 2 Step 1;
T3/T4/T5/T6/T7 are Task 3 Step 1 (T6's message assertion is the `occursin`
check on `d2[1]`); T0/T1 shipped with §7. §9 Salsa notes → Task 2 Step 4
(restart) and the Global Constraints. §10 → resolved above. §11 stays out of
scope.

**Placeholder scan.** No TBDs. Two places tell the implementer to verify rather
than guess (Task 1 Step 1's CST indices, Task 2 Step 1's `@($m)` shape); both
name the exact check to run and what to do with the result, rather than deferring
a decision.

**Type consistency.** `MethodArity`'s 5th field is `macro_annotations::Vector{String}`
everywhere; `_macro_annotations` returns `Vector{String}`;
`_is_signature_preserving` takes `nm::String` and compares `Symbol(nm)` against
`SIGNATURE_PRESERVING_MACROS::Vector{Symbol}`; `_effective_arity` takes and
returns `MethodArity`. `defining_path` is `Vector{String}` in both helpers and is
the same `p` the `tree_arities` closure and `_call_cross_file_arities` already
build.
