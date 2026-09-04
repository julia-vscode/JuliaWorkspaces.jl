# Lowering-backed lint rules (experiment, behind `input_v2_enabled`).
#
# When the flag is on, this producer TAKES OVER the rules in
# `LOWERING_TAKEOVER_RULES` from StaticLint — the advisory-class ones under the
# same ids/severities, and the load-error-class ones by suppression, superseded
# by the `:lowering_errors` rule (`LOWERING_OWN_RULES`) at `:error`. When the
# flag is off (the default), nothing below the gate is ever demanded and
# diagnostics behave exactly as before.
#
# Query shape mirrors the syntax-rule engine: a position-free per-item query
# that backdates (`derived_item_semantic_findings`), and a volatile per-file
# emission join (`derived_semantic_lint_findings`) that is the only reader of
# the address→range maps.

const LOWERING_TAKEOVER_RULES = Set([
    # Re-emitting takeovers: v2 reports these under the same ids and the same
    # (advisory) severities, from a better engine.
    :unused_binding, :unused_function_argument, :unused_type_parameter,
    :module_name, :relative_import, :unresolved_import, :missing_reference,
    :nothing_comparison, :const_decl, :incorrect_call_args,
    :type_piracy, :invalid_type_declaration, :kw_default_mismatch,
    :incorrect_iter_spec, :pointless_boolean, :const_if_condition,
    :literal_use,
    # SUPPRESSION-ONLY: v1's syntactic approximations of load errors. Under
    # the flag they are silenced and the same shapes surface as
    # `lowering_errors` at `:error` (the lowering IS the ground truth, so the
    # v2 findings deserve the error severity while v1's approximations keep
    # their `:information` defaults for flag-off users). They are NOT
    # re-emitted under their v1 ids — and consequently, disabling
    # `lowering_errors` under the flag silences this whole error class.
    :duplicate_function_argument, :break_continue, :global_const_decl,
])

# Rules this producer OWNS (no StaticLint counterpart, so no suppression):
# checks only JuliaLowering computes.
const LOWERING_OWN_RULES = Set([:lowering_errors, :soft_scope_ambiguity])

# The gate both producers consult. Evaluation order matters: with the flag off
# the only Salsa dependency is the flag input itself, so config edits do not
# even re-verify this query.
Salsa.@derived function derived_lowering_lint_active(rt, uri)
    input_v2_enabled(rt) || return false
    config = derived_effective_lint_config(rt, uri)
    return any(rule_enabled(config, id)
               for id in Iterators.flatten((LOWERING_TAKEOVER_RULES, LOWERING_OWN_RULES)))
end

const SemanticFinding = @NamedTuple{addr::Int32, rule_id::Symbol, msg::String}

"""
    derived_item_semantic_findings(rt, ref) -> Vector{SemanticFinding}

Position-free unused-binding findings for one item, from the lowering
projection. Backdates across position-only edits (its only dependency is the
position-free `derived_item_lowering`). Empty when lowering is unavailable,
errored, or absent — degradation is silence, never noise.
"""
# A bare method-signature shape: a `call`/`dotcall`, possibly under `where` or
# return-`::` wrappers — what the doc system accepts as a signature target.
function _v2_is_bare_signature(bt::BodyTree{V2Kind})
    node = bt
    while node.kind == JS2.K"where" ||
          (node.kind == JS2.K"::" && _v2_nchildren(node) == 2)
        cs = _v2_children(node)
        isempty(cs) && return false
        node = cs[1]
    end
    return node.kind == JS2.K"call" || node.kind == JS2.K"dotcall"
end

Salsa.@derived function derived_item_semantic_findings(rt, ref::V2ItemRef)
    result = SemanticFinding[]
    low = derived_item_lowering(rt, ref)
    low === nothing && return result

    if low.status !== :ok
        # Lowering aborted: bindings/uses are empty, so the unused-* loops
        # below are vacuous — routing the error findings is the only work.
        #
        # Test-block items are materialized inside a synthetic `let`
        # (`_materialize`), which makes module-level constructs — perfectly
        # legal inside the real `@testitem`/`@testset` macro — raise scope
        # errors (`struct` in local scope, `const` in local scope, …). Those
        # are artifacts of the frame, not the user's code: silence, for ALL
        # error findings of such items.
        body = derived_item_lowering_body(rt, ref)
        (body !== nothing && _test_block_target(body) !== nothing) && return result
        # An item enumerated from inside a macrocall's arguments (`@derived
        # function …`, `@kwdef struct …`) may be transformed by the macro, so
        # errors from lowering the bare form are unreliable — silence.
        ref.id in derived_v2_under_macrocall_ids(rt, ref.file) && return result
        # Likewise an item CONTAINING opaque macrocalls: materialization
        # strips them (`function (@main)(args)` loses its name), so structural
        # errors can be artifacts of the stripping.
        isempty(derived_v2_item_expansion_sites(rt, ref)) || return result
        # A documented bare method signature (`"""docs""" f(::A, ::B)`) is a
        # doc-system target, never evaluated — the doc macro swallows the call
        # form whole, so nothing inside it can ever raise at runtime: silence.
        # Only bare call shapes qualify; a documented function/assignment
        # lowers as real code and keeps its errors.
        if body !== nothing && haskey(derived_v2_file_doc_ranges(rt, ref.file), ref.id) &&
           _v2_is_bare_signature(body)
            return result
        end
        # A `$` at top level of an OWN-ROOT, non-entry package file is a code
        # template consumed by a custom loader (ExproniconLite's
        # `__include_generated__` wraps each file in `quote … end` via
        # `include_string`): the file never runs as written, so the error is
        # an artifact of reading a template as a program.
        template_file = _derived_v2_own_root_package_file(rt, ref.file)
        for f in low.findings
            f.addr == Int32(0) && continue   # no user address to report at
            template_file && startswith(f.msg, "`\$` expression outside string or quote") && continue
            push!(result, (addr=f.addr, rule_id=:lowering_errors, msg=f.msg))
        end
        return result
    end

    # One source declaration can produce SEVERAL lowered bindings, because
    # desugaring duplicates a pattern into each closure or method it generates.
    # Two cases pull in opposite directions:
    #
    #   [f(n) for (n, c) in d if g(c)]   -> filter closure + body closure, each
    #                                       binding both names and reading one;
    #                                       the variable IS used.
    #   f(a, b = default) = ...          -> a forwarding method `f(a) = f(a, d)`
    #                                       that reads `a` purely to pass it on;
    #                                       an unused `a` IS still unused.
    #
    # What separates them is WHERE the read happens: a genuine use sits at a
    # different node than the declaration, whereas a synthesized forwarding read
    # is derived from the signature and so carries the declaration's own address.
    # So a declaration counts as used only when one of its bindings is read at
    # some other address.
    decl_of = Dict{Int32,Int32}()
    for b in low.bindings
        b.is_read && (decl_of[b.id] = b.addr)
    end
    used_addrs = Set{Int32}()
    for u in low.uses
        d = get(decl_of, u.binding, Int32(0))
        (d != Int32(0) && u.addr != d) && push!(used_addrs, d)
    end

    emitted = Set{Int32}()
    for b in low.bindings
        b.is_internal && continue
        b.is_read && continue
        b.addr == Int32(0) && continue
        b.addr in used_addrs && continue
        b.addr in emitted && continue
        # `_`-prefixed names are the intentionally-unused convention.
        (isempty(b.name) || startswith(b.name, "_")) && continue
        if b.kind === :local
            push!(emitted, b.addr)
            push!(result, (addr=b.addr, rule_id=:unused_binding,
                msg="Variable `$(b.name)` has been assigned but not used."))
        elseif b.kind === :argument
            push!(emitted, b.addr)
            push!(result, (addr=b.addr, rule_id=:unused_function_argument,
                msg="Argument `$(b.name)` is never used within the function body."))
        end
    end

    # `where`-clause type parameters mint TWO bindings at the declaration
    # address: a `:typevar` whose reads are the SIGNATURE uses, and a
    # `:static_parameter` whose reads are the BODY uses. The parameter is
    # unused only when both are unread. Struct/alias parameters lower as
    # `:local` and are deliberately not covered — matching v1, whose
    # `check_typeparams` fires on `where` clauses only.
    tp_read = Dict{Int32,Bool}()
    tp_name = Dict{Int32,String}()
    for b in low.bindings
        b.kind in (:typevar, :static_parameter) || continue
        b.addr == Int32(0) && continue
        tp_read[b.addr] = get(tp_read, b.addr, false) | b.is_read
        haskey(tp_name, b.addr) || (tp_name[b.addr] = b.name)
    end
    for addr in sort!(collect(keys(tp_read)))
        tp_read[addr] && continue
        addr in used_addrs && continue
        addr in emitted && continue
        name = tp_name[addr]
        (isempty(name) || startswith(name, "_")) && continue
        push!(emitted, addr)
        push!(result, (addr=addr, rule_id=:unused_type_parameter,
            msg="A DataType parameter has been specified but not used."))
    end

    # `nothing_comparison`: a pure shape check over the position-free body —
    # `x == nothing` / `x != nothing` in evaluated positions, including inside
    # macrocall arguments (v1 flags `@test x == nothing`, so this walk does
    # not skip macrocalls). The shadow guard is self-resolving via lowering:
    # any LOCAL binding named `nothing`/`==`/`!=` in the item silences it
    # (v1's ref-resolves-to-Core.nothing check, conservatively).
    if !any(b -> b.kind in (:local, :argument) && b.name in ("nothing", "==", "!="), low.bindings)
        body = derived_item_lowering_body(rt, ref)
        body === nothing || _v2_nothing_comparisons!(result, body, Ref(0), 0)
    end
    return result
end

_v2_ident_val(bt::BodyTree{V2Kind}) =
    bt.children === nothing && bt.kind == JS2.K"Identifier" &&
    bt.val isa Union{Symbol,AbstractString} ? string(bt.val) : nothing

# Plain preorder walk (addresses align with `derived_v2_file_maps` because
# `_materialize` consumes addresses even for subtrees it skips): flag
# `==`/`!=` calls with a bare `nothing` operand, at the OPERATOR's address
# (v1 sets its error on the operator). Quoted code is data — no findings
# inside, but `$` restores evaluated depth.
function _v2_nothing_comparisons!(out::Vector{SemanticFinding}, bt::BodyTree{V2Kind},
                                  addr::Base.RefValue{Int}, qdepth::Int)
    myaddr = (addr[] += 1)
    if qdepth == 0 && bt.kind == JS2.K"call" && bt.children !== nothing && length(bt.children) == 3
        op = _v2_ident_val(bt.children[1])
        if op == "==" || op == "!="
            if _v2_ident_val(bt.children[2]) == "nothing" || _v2_ident_val(bt.children[3]) == "nothing"
                msg = op == "==" ?
                    "Compare against `nothing` using `isnothing` or `===`" :
                    "Compare against `nothing` using `!isnothing` or `!==`"
                push!(out, (addr=Int32(myaddr + 1), rule_id=:nothing_comparison, msg=msg))
            end
        end
    end
    bt.children === nothing && return nothing
    child_depth = _quote_depth(bt.kind, qdepth)
    for c in bt.children
        _v2_nothing_comparisons!(out, c, addr, child_depth)
    end
    return nothing
end

# ── module-tree rules ───────────────────────────────────────────────────────
#
# Rules about module STRUCTURE rather than item bodies: they read the skeleton
# and the module-tree splice prefix, never the lowering. Position-free (item
# ids + preorder addresses); ranges attach in the emission join below, which is
# why commit "Store address maps for module and import rows" exists.

"A structural finding attached to a (possibly bodyless) skeleton row."
const ModuleTreeFinding = @NamedTuple{id::Int64, addr::Int32, rule_id::Symbol, msg::String}

# The module a file's top level splices into, from its best root (v2's own
# root discovery; prefers non-test roots); empty for a plain buffer.
Salsa.@derived function _derived_v2_splice_prefix(rt, uri)
    root = derived_v2_best_root_for_uri(rt, uri)
    root === nothing && return String[]
    path = derived_v2_file_module_path(rt, root, uri)
    return path === nothing ? String[] : path
end

"Module EST children are [bare-flag, name, block]: the name is preorder address 3."
const _V2_MODULE_NAME_ADDR = Int32(3)

Salsa.@derived function derived_module_tree_lint_findings(rt, uri)
    result = ModuleTreeFinding[]
    skel = derived_v2_file_skeleton(rt, uri)
    (isempty(skel.modules) && isempty(skel.imports)) && return result
    splice = _derived_v2_splice_prefix(rt, uri)

    # `module_name`: a module named like its parent. Mild superset of v1
    # (`check_modulename` only sees same-file parents; the splice prefix also
    # catches `module A` in a file included from inside `module A`).
    for m in skel.modules
        parent = vcat(splice, m.parent_module)
        (!isempty(parent) && last(parent) == m.name) || continue
        push!(result, (id=m.id, addr=_V2_MODULE_NAME_ADDR, rule_id=:module_name,
            msg="Module name matches that of its parent."))
    end

    # `relative_import`: more leading dots than available module nesting — the
    # exact unresolved-by-pops condition `_v2_classify_import` uses. Reported
    # at the whole statement (v1 points at the offending `.`; range deviation
    # accepted).
    for imp in skel.imports
        ndots = 0
        while ndots < length(imp.path) && imp.path[ndots + 1] == "."
            ndots += 1
        end
        ndots > 0 || continue
        ndots - 1 > length(splice) + length(imp.parent_module) || continue
        push!(result, (id=imp.id, addr=Int32(1), rule_id=:relative_import,
            msg="Relative import has more leading dots than available module nesting."))
    end

    return result
end

# ── unresolved_import ───────────────────────────────────────────────────────
#
# The first env-dependent takeover rule: an import whose target cannot be
# resolved — external with a missing store, or `:unresolved` that the pass-2
# ledger re-attempt cannot land. Message semantics ported from v1
# (`mark_unresolved_import_stmt!` + lint_emission.jl): the message names the
# FIRST unresolved component, distinguishes a declared-but-unindexed
# dependency from a genuinely unknown one, and states the consequence
# (wildcard `using` disables missing-reference checks in scope; any other form
# just goes unchecked). Reported at the whole statement (v1 anchors the range
# at the failing component; range deviation accepted, as with
# `relative_import`). Deliberately deferred, documented: colon-list MEMBER
# misses (needs the implicit-member fallback first, or `import Base: nothing`
# shapes false-positive) and `:workspace_package` targets whose package root
# is missing.

# The first unresolved component's name, or `nothing` when the import
# resolves. Mirrors the visibility layer's own resolution rules exactly —
# including the pass-2 re-attempt — so this rule can never contradict what
# visibility actually bound.
function _v2_unresolved_import_name(rt, root, path::Vector{String}, ri::V2ResolvedImport)
    t = ri.target
    if t.sort === :external
        # A standard library is always loadable where `@stdlib` is on the
        # load path (scripts, test files); only package code must declare it.
        # Its store may not be indexed for this project: unknown ⇒ silent.
        (t.path[1] in derived_stdlib_names(rt) && derived_file_stdlibs_visible(rt, root)) &&
            return nothing
        # `import A.B.c` (whole-path import, no colon list) binds the LAST
        # segment, which may be any member of `A.B` — a function, a constant
        # (`import QuadGK.quadgk`) — not only a module. `using A.B` keeps the
        # module-only walk.
        if ri.kind === :import && isempty(ri.symbols) && length(t.path) >= 2
            missing_mod = derived_v2_external_first_missing_segment(rt, root, t.path[1:end-1])
            missing_mod === nothing || return missing_mod
            mk = derived_v2_external_module_member_kind(rt, root, t.path[1:end-1], t.path[end])
            return mk === :absent ? t.path[end] : nothing
        end
        return derived_v2_external_first_missing_segment(rt, root, t.path)
    elseif t.sort === :unresolved
        # `Main` is the REPL/script namespace: what a `using ..Main: x` from a
        # test helper included into it finds there is not knowable here.
        first_seg = findfirst(s -> s != ".", t.path)
        first_seg !== nothing && t.path[first_seg] == "Main" && return nothing
        re = _v2_reattempt_unresolved(rt, root, path, ri, Set{URI}())
        if re === nothing
            # Locate the first stuck segment for the message, the same way the
            # re-attempt walks: anchor, then the deepest tree prefix.
            split = _v2_unresolved_anchor_and_segs(rt, root, path, t.path)
            if split === nothing
                i = findfirst(s -> s != ".", t.path)
                return i === nothing ? nothing : t.path[i]
            end
            anchor, segs = split
            k = _v2_deepest_tree_prefix(rt, root, anchor, segs)
            k >= length(segs) && return nothing   # the full path IS tree-resolvable
            cand = segs[k + 1]
            # v1's resolves-to-a-binding rule: when the stuck segment names a
            # ledgered EXTERNAL binding (`using AutoHashEquals` in the parent,
            # `using ..AutoHashEquals` here), the relative statement resolved
            # lexically — the ORIGIN statement already carries the missing-store
            # diagnosis, and repeating it at every relative re-import is noise.
            _, modtargets = _v2_visible_names_pass1(rt, root, vcat(anchor, segs[1:k]), Set{URI}())
            mt = get(modtargets, cand, nothing)
            (mt !== nothing && mt.sort === :external) && return nothing
            return cand
        end
        re.sort === :external &&
            return derived_v2_external_first_missing_segment(rt, root, re.path)
        return nothing
    end
    return nothing   # :tree and :workspace_package targets resolve
end

# The names a file's environment declares as dependencies: the env project's
# own, plus — for a nested package whose environment is the project deving
# it (a monorepo's `lib/<Pkg>` against the root manifest) — the package's
# own `[deps]`, which a stale root manifest may not carry yet.
Salsa.@derived function derived_v2_declared_dep_names(rt, root, uri)
    deps = Set{String}(derived_v2_env_project_deps(rt, root))
    pkg_folder = derived_package_for_file(rt, uri)
    if pkg_folder !== nothing
        pkg = derived_package(rt, pkg_folder)
        if pkg !== nothing
            pf = derived_project_file(rt, pkg.project_file_uri)
            if pf !== nothing
                union!(deps, keys(pf.deps))
                # Test files draw on `[extras]` / `[targets] test`; a merged
                # test environment whose materialization only partly
                # succeeded lacks some of them — declared, not unknown.
                if _file_needs_test_env(rt, uri2filepath(pkg_folder), uri)
                    union!(deps, keys(pf.extras))
                    for names in values(pf.targets)
                        union!(deps, names)
                    end
                end
            end
        end
    end
    return deps
end

# `module X` declarations in the package's test files (any file under
# `<pkg>/test/`): test suites define helper modules in files they `include`
# into Main and then `using X` them by bare name.
Salsa.@derived function derived_v2_test_local_module_names(rt, uri)
    names = Set{String}()
    pkg_folder = derived_package_for_file(rt, uri)
    pkg_folder === nothing && return names
    prefix = lowercase(joinpath(uri2filepath(pkg_folder), "test")) * Base.Filesystem.path_separator
    for f in derived_v2_all_julia_files(rt)
        fp = uri2filepath(f)
        fp === nothing && continue
        startswith(lowercase(fp), prefix) || continue
        for m in derived_v2_file_skeleton(rt, f).modules
            push!(names, m.name)
        end
    end
    return names
end

Salsa.@derived function derived_v2_unresolved_import_findings(rt, uri)
    result = ModuleTreeFinding[]
    skel = derived_v2_file_skeleton(rt, uri)
    isempty(skel.imports) && return result
    root = derived_v2_best_root_for_uri(rt, uri)
    root === nothing && return result
    splice = _derived_v2_splice_prefix(rt, uri)
    deps = nothing   # project deps demanded only once a finding exists

    # Iterate the RESOLVED imports of each module this file's statements splice
    # into, filtered back to this file's rows — a comma-list statement
    # (`import A, B, C`) is one item id but SEVERAL resolved imports, so a
    # per-skeleton-row walk would conflate them (each path gets its own
    # finding, exactly as v1 marks each path expression separately).
    # Only imports the user WROTE: the expanded tree also carries imports
    # harvested from macro expansions (keyed by the macrocall's id), and a
    # finding on those would surface at the macrocall once the DJP settles,
    # about a statement that is not in the source.
    written = Set{Int64}(imp.id for imp in skel.imports)
    for path in unique!([vcat(splice, imp.parent_module) for imp in skel.imports])
        for ri in derived_v2_module_imports(rt, root, path)
            ri.from.file == uri || continue
            ri.from.id in written || continue
            # Dots exceeding the nesting are `relative_import`'s finding — v1's
            # no-double-diagnosis rule (`first_unresolved_import_component`
            # skips paths already carrying errors). `:unresolved` targets keep
            # the raw written segments, dots included.
            if ri.target.sort === :unresolved
                raw = ri.target.path
                ndots = 0
                while ndots < length(raw) && raw[ndots + 1] == "."
                    ndots += 1
                end
                ndots > 0 && ndots - 1 > length(path) && continue
            end

            name = _v2_unresolved_import_name(rt, root, path, ri)
            name === nothing && continue
            # A module the package's own test files define (`module TestSetup`
            # in test/testsetup.jl, `include`d into Main before `using
            # TestSetup`) is not a package to resolve.
            derived_file_stdlibs_visible(rt, uri) && name in derived_v2_test_local_module_names(rt, uri) &&
                continue
            deps === nothing && (deps = derived_v2_declared_dep_names(rt, root, uri))
            cause = name in deps ?
                "`$name` is a declared dependency but its symbols could not be indexed." :
                "Failed to resolve `$name`."
            consequence = ri.kind === :using && isempty(ri.symbols) ?
                "Missing-reference checks are disabled in this scope and all nested scopes." :
                "Anything imported through this statement is assumed to exist and will not be checked."
            push!(result, (id=ri.from.id, addr=Int32(1), rule_id=:unresolved_import,
                msg="$cause $consequence"))
        end
    end
    return result
end

# ── const_decl (intra-module) ───────────────────────────────────────────────
#
# Declaration conflicts at module scope, from the module tree's raw ordered
# decl-event stream — which sees the whole module ACROSS files (v1's check is
# scope-local, so cross-file redefinitions are new coverage). The LOCAL-scope
# shapes v1's rule also caught (`const` on a local; `x = 1; x() = 2` inside
# one function) are LoweringErrors and already surface as
# `lowering_errors:error` under the flag.
#
# Exemptions, all silence-direction: conditional rows (only one `if` branch
# runs — the `@static if` platform-const idiom; conservative superset of v1's
# same-branch pairing), under-macrocall and non-interpretable rows, module
# events (participate as representatives, never flagged), same-item events,
# and the same-definition-twice exemption via structural body-hash equality.

_v2_const_like(k::Symbol) = _v2_is_datatype_kind(k) || k === :const || k === :enum_member

# Whether an item is a parametric type alias assignment (`Name{T} = …`,
# possibly `const`-wrapped): its name denotes a TYPE, so later constructor
# methods extend it rather than redefine it.
function _v2_is_curly_alias_item(rt, ref::V2ItemRef)
    body = derived_item_lowering_body(rt, ref)
    body === nothing && return false
    node = body
    while (node.kind == JS2.K"const" || node.kind == JS2.K"global") && _v2_nchildren(node) >= 1
        node = _v2_children(node)[1]
    end
    (node.kind == JS2.K"=" && _v2_nchildren(node) >= 1) || return false
    return _v2_children(node)[1].kind == JS2.K"curly"
end

Salsa.@derived function derived_v2_module_const_decl_findings(rt, root, path)
    result = @NamedTuple{ref::V2ItemRef, msg::String}[]
    events = derived_v2_module_decl_events(rt, root, path)
    isempty(events) && return result

    skels = Dict{URI,Any}()
    skel_of(uri) = get!(() -> derived_v2_file_skeleton(rt, uri), skels, uri)
    # Files spliced through a conditional include (`@static if` gates picking
    # one of several implementation files) carry the same only-one-branch-runs
    # exemption as items that are themselves conditional.
    cond_files = derived_v2_module_tree(rt, root).conditional_files
    function usable_item(ref::V2ItemRef)
        ref.file in cond_files && return false
        for r in skel_of(ref.file).items
            # Declarations harvested from a macro EXPANSION (the opaque row)
            # are visible names, not statements the source spells: a macro
            # re-emitting a `const` the file already has (ArrayLayouts'
            # `@layoutmul`), or a guarded `const` inside its expansion
            # (Blink's `@init`), is the macro author's business — never a
            # conflict to report here.
            r.id == ref.id &&
                return r.interpretable && !r.under_macrocall && !r.conditional &&
                       r.kind !== :opaque_macrocall
        end
        return false   # not an item row (a module event): representative-only
    end

    # Running representative per name, mirroring `_v2_declare!` (a datatype
    # survives a later function/assignment — method extension).
    rep = Dict{String,Tuple{Symbol,V2ItemRef}}()
    for (name, kind, ref) in events
        prev = get(rep, name, nothing)
        is_item = kind !== :module
        ok = is_item && usable_item(ref)
        if prev !== nothing && ok && usable_item(prev[2]) && prev[2] != ref
            pk = prev[1]
            same_def = (h1 = derived_v2_item_body_hash(rt, ref);
                        h2 = derived_v2_item_body_hash(rt, prev[2]);
                        h1 !== nothing && h1 == h2)
            if !same_def
                if _v2_const_like(kind)
                    push!(result, (ref=ref,
                        msg="Cannot declare constant `$name`; it already has a value."))
                elseif (kind === :function || kind === :macro) && pk in (:assignment, :global) &&
                       !_v2_is_curly_alias_item(rt, prev[2])
                    # `Make0{T} = Make{T,Tuple{}}` then `Make0{T}() where {T} = …`:
                    # a parametric type alias plus a constructor method on it
                    # (RandomExtensions) — legal, not a redefinition.
                    push!(result, (ref=ref,
                        msg="Cannot define function `$name`; it already has a value."))
                elseif kind in (:assignment, :global) && _v2_const_like(pk)
                    push!(result, (ref=ref,
                        msg="Invalid redefinition of constant `$name`."))
                end
            end
        end
        # Representative update (method-extension rule as in `_v2_declare!`).
        if prev === nothing || !(_v2_is_datatype_kind(prev[1]) && kind in (:function, :assignment))
            rep[name] = (kind, ref)
        end
    end
    return result
end

Salsa.@derived function derived_v2_const_decl_findings(rt, uri)
    result = ModuleTreeFinding[]
    skel = derived_v2_file_skeleton(rt, uri)
    isempty(skel.items) && return result
    root = derived_v2_best_root_for_uri(rt, uri)
    root === nothing && return result
    splice = _derived_v2_splice_prefix(rt, uri)
    for path in unique!([vcat(splice, r.parent_module) for r in skel.items])
        for f in derived_v2_module_const_decl_findings(rt, root, path)
            f.ref.file == uri || continue
            push!(result, (id=f.ref.id, addr=Int32(1), rule_id=:const_decl, msg=f.msg))
        end
    end
    return result
end

# ── soft_scope_ambiguity ────────────────────────────────────────────────────
#
# Julia's soft-scope ambiguity warning, statically: an un-annotated assignment
# inside a top-level `for`/`while`/`try` to a name that is also a plain
# module global. In a file Julia warns at run time and makes a NEW LOCAL (the
# REPL silently assigns the global) — this rule predicts that warning without
# running anything. The signal is JuliaLowering's own `is_ambiguous_local`,
# which requires the conflicting global to EXIST in the lowered-into module —
# so this producer runs `_lower_item_soft_scope`, a separate lowering into an
# anchor seeded with the module's plain-global names (`:assignment`/`:global`
# kinds only: consts, functions and datatypes never soft-scope-warn, matching
# `is_defined_and_owned_global`'s PARTITION_KIND_GLOBAL test). Kept separate
# so `derived_item_lowering` stays body-only pure.

# Names bound as `catch` exception variables. A catch var is ALWAYS a new
# local — but desugaring writes it as an assignment inside the permeable catch
# scope (see JuliaLowering `expand_try`), so `is_ambiguous_local` marks it
# against a same-named seeded global. Never a genuine soft-scope hazard.
function _v2_collect_catch_vars!(out::Set{String}, bt::BodyTree{V2Kind})
    # Parse-level `try` is flisp-shaped: children are blocks with the catch
    # variable as a bare `Identifier` DIRECT child between them (`false` when
    # absent) — there is no `K"catch"` wrapper node at this layer.
    if bt.kind == JS2.K"try" && bt.children !== nothing
        for v in bt.children
            if v.children === nothing && v.kind == JS2.K"Identifier" &&
               v.val isa Union{Symbol,AbstractString}
                push!(out, string(v.val))
            end
        end
    end
    bt.children === nothing && return out
    for c in bt.children
        _v2_collect_catch_vars!(out, c)
    end
    return out
end

"Item-row order for `id` in `skel`, or `nothing` when `id` has no item row."
_v2_item_order(skel, id) =
    (i = findfirst(r -> r.id == id, skel.items); i === nothing ? nothing : skel.items[i].order)

# The soft (permeable) scope shapes: desugaring mints `neutral_scope` for
# for/while and try blocks only; function bodies and `let` are hard scope.
function _v2_has_soft_scope_shape(bt::BodyTree{V2Kind}, qdepth::Int=0)
    if qdepth == 0 &&
       (bt.kind == JS2.K"for" || bt.kind == JS2.K"while" || bt.kind == JS2.K"try")
        return true
    end
    bt.children === nothing && return false
    child_depth = _quote_depth(bt.kind, qdepth)
    return any(c -> _v2_has_soft_scope_shape(c, child_depth), bt.children)
end

Salsa.@derived function derived_item_soft_scope_findings(rt, ref::V2ItemRef)
    result = SemanticFinding[]
    low = derived_item_lowering(rt, ref)
    (low === nothing || low.status !== :ok) && return result
    ref.id in derived_v2_under_macrocall_ids(rt, ref.file) && return result
    body = derived_item_lowering_body(rt, ref)
    body === nothing && return result
    # Test blocks materialize let-wrapped (hard scope) — the flag cannot fire,
    # but skipping saves the second lowering.
    _test_block_target(body) !== nothing && return result
    _v2_has_soft_scope_shape(body) || return result

    root = derived_v2_best_root_for_uri(rt, ref.file)
    root === nothing && return result
    skel = derived_v2_file_skeleton(rt, ref.file)
    any(t -> t.id == ref.id, skel.testitems) && return result
    idx = findfirst(r -> r.id == ref.id, skel.items)
    idx === nothing && return result
    path = vcat(_derived_v2_splice_prefix(rt, ref.file), skel.items[idx].parent_module)

    # Only globals declared BEFORE this item can make its soft-scope
    # assignments ambiguous: when the loop runs, a textually later global does
    # not exist yet, so Julia itself binds a new local without any warning.
    # Same-file events compare item order; events from other spliced files
    # keep the seed conservatively (their relative order is include-dependent).
    item_order = skel.items[idx].order
    seed_set = Set{String}()
    for (n, k, eref) in derived_v2_module_decl_events(rt, root, path)
        (k === :assignment || k === :global) || continue
        n in seed_set && continue
        if eref.file == ref.file
            eorder = _v2_item_order(skel, eref.id)
            (eorder === nothing || eorder < item_order) || continue
        end
        push!(seed_set, n)
    end
    isempty(seed_set) && return result
    seeds = sort!(collect(seed_set))

    catch_vars = _v2_collect_catch_vars!(Set{String}(), body)
    for (addr, name) in _lower_item_soft_scope(body, derived_item_expansions(rt, ref), seeds)
        name in catch_vars && continue
        push!(result, (addr=addr, rule_id=:soft_scope_ambiguity,
            msg="Assignment to `$name` in soft scope is ambiguous because a global " *
                "variable by the same name exists: `$name` will be treated as a new local. " *
                "Disambiguate by using `local $name` to suppress this warning or " *
                "`global $name` to assign to the existing global variable."))
    end
    return result
end

# ── missing_reference ───────────────────────────────────────────────────────
#
# A post-pass join, no lowering changes: every free identifier in an item
# surfaces as an anchor-module `:global` binding (`"JWLoweringAnchor"`), so a
# read-never-assigned global whose name neither the module's visible names nor
# the implicit Base/Core scope answer for is a missing reference — reported at
# each use site. Lowering already resolved locals/arguments/shadows away, and
# a qualified `A.b` reads only `A` (member checks are deliberately absent this
# milestone). Conservative-first: every gate errs toward silence, and the
# corpus differential's zero-undeclared-v2-only rule is the backstop.
#
# Deviations from v1, all in the silent direction: the `scope = "symbols"`
# option behaves as `"all"` (v2 checks identifiers only — no quoted-getfield
# marks); the isdefined/VERSION guard gate is ITEM-level where v1's is
# branch-level (branch intervals are computable position-free the same way as
# the macrocall intervals below — a noted relaxation); own-root files under a
# package's test/ folder are suppressed wholesale where v1 suppresses only
# files actually spliced into a `@testitem` body (v2's walker records no
# includes inside test items, so those helpers are indistinguishable orphan
# roots here).

# Preorder-address intervals whose reads are synthetic or unreliable, with
# `_materialize`'s exact address accounting (transparent unwrap, test-block
# descent, quote depth): each qdepth-0 OPAQUE MACROCALL (its fabricated
# argument-identifier reads carry real addresses inside the subtree, and v1
# likewise never reports macrocall arguments) and each qdepth-0→1 QUOTE (its
# fabricated reads all anchor at the quote's own address; `$`-interpolated
# reads inside are conservatively silenced with it). A subtree at address `a`
# with `n` nodes occupies exactly `[a, a+n-1]`.
function _v2_missing_ref_intervals!(out::Vector{UnitRange{Int32}}, bt::BodyTree{V2Kind},
                                    addr::Base.RefValue{Int}, qdepth::Int)
    myaddr = (addr[] += 1)
    if qdepth == 0
        target = _transparent_macro_target(bt)
        if target !== nothing
            for c in bt.children[1:end-1]
                addr[] += bt_node_count(c)
            end
            return _v2_missing_ref_intervals!(out, target, addr, qdepth)
        end
        test_block = _test_block_target(bt)
        if test_block !== nothing
            for c in bt.children[1:end-1]
                addr[] += bt_node_count(c)
            end
            return _v2_missing_ref_intervals!(out, test_block, addr, qdepth)
        end
        if _is_opaque_macrocall(bt)
            push!(out, Int32(myaddr):Int32(myaddr + bt_node_count(bt) - 1))
            addr[] += bt_node_count(bt) - 1
            return nothing
        end
    end
    bt.children === nothing && return nothing
    child_depth = _quote_depth(bt.kind, qdepth)
    if qdepth == 0 && child_depth > qdepth
        push!(out, Int32(myaddr):Int32(myaddr + bt_node_count(bt) - 1))
        addr[] += bt_node_count(bt) - 1
        return nothing
    end
    for c in bt.children
        _v2_missing_ref_intervals!(out, c, addr, child_depth)
    end
    return nothing
end

# Whether `bt` (outside quotes) contains a macrocall whose name is not in the
# effects tables and for which `expansions` holds no parsed expansion (keyed
# by the site's hash, as `_materialize` splices it).
function _v2_has_unexpanded_unknown_macro(bt::BodyTree{V2Kind}, expansions, qdepth::Int)
    if qdepth == 0 && _is_opaque_macrocall(bt)
        mc = bt.kind == JS2.K"do" ? bt.children[1] : bt
        _v2_macrocall_effects_unknown(mc) && !haskey(expansions, bt.hash) && return true
    end
    bt.children === nothing && return false
    cd = _quote_depth(bt.kind, qdepth)
    return any(c -> _v2_has_unexpanded_unknown_macro(c, expansions, cd), bt.children)
end

# Whether the module at `path` has a whole-module `using` of a tree or
# workspace-package module whose own names are incomplete (opaque macrocall,
# eval marker, computed include). One level only: blindness is a property of
# the used module, and this checks it directly rather than through its own
# imports, so there is no recursion through `using` cycles.
function _v2_uses_blind_module(rt, root, path)
    for ri in derived_v2_module_imports(rt, root, path)
        (ri.kind === :using && isempty(ri.symbols)) || continue
        if ri.target.sort === :tree
            _v2_module_is_blind(rt, root, ri.target.path) && return true
        elseif ri.target.sort === :workspace_package
            entry = get(derived_v2_workspace_package_roots(rt), ri.target.path[1], nothing)
            entry === nothing && continue
            _v2_module_is_blind(rt, entry, ri.target.path) && return true
        end
    end
    return false
end

# Blind for the purpose of `using M`: M's EXPORT list may be incomplete. A
# top-level opaque macrocall or a computed include can add exports; a runtime
# `@eval` inside a function body cannot (PlotsBase's backend loops blind
# PlotsBase itself, not the `Annotations` submodule that `using`s it).
_v2_module_is_blind(rt, root, path) =
    derived_v2_module_has_toplevel_opaque_macrocall(rt, root, path) ||
    derived_v2_module_has_computed_include(rt, root, path)

# The item-level existence-guard gate: a body that mentions `isdefined`,
# `@isdefined`, or `VERSION` anywhere is skipped whole (v1 exempts only the
# guarded branch; whole-item is the conservative superset).
function _v2_mentions_existence_guard(bt::BodyTree{V2Kind})
    if bt.children === nothing
        bt.kind == JS2.K"Identifier" || return false
        bt.val isa Union{Symbol,AbstractString} || return false
        s = string(bt.val)
        return s == "isdefined" || s == "@isdefined" || s == "VERSION"
    end
    return any(_v2_mentions_existence_guard, bt.children)
end

# Whether any file under `folder` has an include the walk cannot resolve —
# the v2 analog of v1's `derived_folder_has_computed_include`, off skeleton
# rows.
Salsa.@derived function _derived_v2_package_has_computed_include(rt, folder)
    prefix = string(folder)
    for uri in derived_v2_all_julia_files(rt)
        startswith(string(uri), prefix) || continue
        skel = derived_v2_file_skeleton(rt, uri)
        for inc in skel.includes
            inc.path === nothing && return true
            derived_v2_include_target(rt, uri, inc.path) === nothing && return true
        end
        # Includes inside item bodies (function/loop) splice at runtime — the
        # ColorSchemes shape: 37 data files loaded from inside a function.
        for r in skel.items
            any(m -> m.kind === :computed_include,
                derived_v2_item_body_markers(rt, V2ItemRef(uri, r.id))) && return true
        end
    end
    return false
end

# File-level suppression (v1's fourth + fifth cases): an OWN-ROOT file that is
# not a recognized entry point is either a standalone script, the target of a
# computed include (real module context unknown), or — under a package's
# test/ folder — a helper a `@testitem` includes at runtime (which also runs
# `using Test` + the package under test, none of it visible here). Bare
# missing-ref reporting against the bare context is unreliable in all three.
Salsa.@derived function _derived_v2_missing_ref_file_suppressed(rt, uri)
    root = derived_v2_best_root_for_uri(rt, uri)
    root == uri || return false
    fp = uri2filepath(uri)
    fp === nothing && return true   # untitled buffers: no root context at all
    name = lowercase(basename(fp))
    dir = lowercase(basename(dirname(fp)))
    (name == "runtests.jl" && dir == "test") && return false
    (name == "make.jl" && dir == "docs") && return false
    pkg_folder = derived_package_for_file(rt, uri)
    if pkg_folder !== nothing
        pkg = derived_package(rt, pkg_folder)
        if pkg !== nothing
            entry = joinpath(uri2filepath(pkg_folder), "src", "$(pkg.name).jl")
            lowercase(fp) == lowercase(entry) && return false
        end
        any(seg -> lowercase(seg) == "test", splitpath(dirname(fp))) && return true
        _derived_v2_package_has_computed_include(rt, pkg_folder) && return true
    end
    return false
end

# An own-root file INSIDE a package folder that is not the package's entry
# point (nor runtests/make): a file nothing statically includes, reached only
# through a loader the linter cannot follow — the shape under which a top-level
# `$` marks a code template (ExproniconLite's `include_string`-wrapped sources).
Salsa.@derived function _derived_v2_own_root_package_file(rt, uri)
    derived_v2_best_root_for_uri(rt, uri) == uri || return false
    fp = uri2filepath(uri)
    fp === nothing && return false
    name = lowercase(basename(fp))
    dir = lowercase(basename(dirname(fp)))
    (name == "runtests.jl" && dir == "test") && return false
    (name == "make.jl" && dir == "docs") && return false
    pkg_folder = derived_package_for_file(rt, uri)
    pkg_folder === nothing && return false
    pkg = derived_package(rt, pkg_folder)
    pkg === nothing && return false
    entry = joinpath(uri2filepath(pkg_folder), "src", "$(pkg.name).jl")
    return lowercase(fp) != lowercase(entry)
end

"""
    derived_item_missing_reference_findings(rt, ref) -> Vector{SemanticFinding}

Missing-reference findings for one item. A separate query from
`derived_item_semantic_findings` on purpose: this one depends on the module's
visible names and (through them) the environment, so env or sibling-file edits
re-execute it — while the unused-binding query keeps depending on nothing but
the item's own lowering.
"""
Salsa.@derived function derived_item_missing_reference_findings(rt, ref::V2ItemRef)
    result = SemanticFinding[]
    low = derived_item_lowering(rt, ref)
    (low === nothing || low.status !== :ok) && return result
    ref.id in derived_v2_under_macrocall_ids(rt, ref.file) && return result
    # A documented bare method signature (`"""docs""" f(::A, x)`) is a
    # doc-system target that never evaluates: its argument names are not
    # reads of anything.
    if haskey(derived_v2_file_doc_ranges(rt, ref.file), ref.id)
        b = derived_item_lowering_body(rt, ref)
        b !== nothing && _v2_is_bare_signature(b) && return result
    end
    body = derived_item_lowering_body(rt, ref)
    body === nothing && return result
    _test_block_target(body) !== nothing && return result
    _v2_mentions_existence_guard(body) && return result
    # The item-level twin of module blindness: a macrocall in the body whose
    # effects are not modeled AND whose expansion is unavailable (no DJP,
    # failed, unparseable, pending) may bind any name the rest of the item
    # then reads (MacroTools' `@capture(ex, f_(args__))` idiom) — the
    # identifier fallback cannot know, so the item is silent.
    _v2_has_unexpanded_unknown_macro(body, derived_item_expansions(rt, ref), 0) && return result

    root = derived_v2_best_root_for_uri(rt, ref.file)
    root === nothing && return result
    skel = derived_v2_file_skeleton(rt, ref.file)
    any(t -> t.id == ref.id, skel.testitems) && return result
    idx = findfirst(r -> r.id == ref.id, skel.items)
    idx === nothing && return result
    path = vcat(_derived_v2_splice_prefix(rt, ref.file), skel.items[idx].parent_module)

    # Module blindness: any way unseen code could define names in this module
    # silences the whole module (pollution does not cross module boundaries).
    derived_v2_module_unresolved_wildcard_using(rt, root, path) && return result
    derived_v2_module_has_computed_include(rt, root, path) && return result
    derived_v2_module_has_opaque_macrocall(rt, root, path) && return result
    # A `using`/`import` inside a try/if body may bring any name — this rule's
    # blindness only (imports add no methods to already-visible names).
    derived_v2_module_has_guarded_import(rt, root, path) && return result
    # A whole-module `using` of a workspace module that is itself blind
    # brings in an export list the walk cannot complete (MLStyle's own
    # `@reexport` computes `export …` at expansion time): the same blindness,
    # one `using` away.
    _v2_uses_blind_module(rt, root, path) && return result
    # An extension file whose triggers resolve in no reachable environment:
    # `using Trigger` brought in names the store does not have — blind (the
    # import itself is the opt-in boundary notice).
    isempty(derived_extension_blind_triggers(rt, ref.file)) || return result

    visible = derived_v2_module_visible_names_idfree(rt, root, path)
    implicit = derived_v2_implicit_scope_names(rt, root, derived_v2_module_is_bare(rt, root, path))
    intervals = UnitRange{Int32}[]
    _v2_missing_ref_intervals!(intervals, body, Ref(0), 0)

    for b in low.bindings
        b.kind === :global || continue
        b.mod == "JWLoweringAnchor" || continue
        b.is_read || continue
        b.is_assigned && continue
        name = b.name
        (isempty(name) || startswith(name, "_") || startswith(name, "@")) && continue
        # `var"weird name"` strings and bare operators are exempt (v1 exempts
        # `var` shapes; an unexported operator read is overwhelmingly a method
        # extension target, not a typo).
        Base.isidentifier(name) || continue
        haskey(visible, name) && continue
        insorted(name, implicit) && continue
        for u in low.uses
            u.binding == b.id || continue
            u.addr == Int32(0) && continue
            any(iv -> u.addr in iv, intervals) && continue
            push!(result, (addr=u.addr, rule_id=:missing_reference,
                msg="Missing reference: $name"))
        end
    end
    return result
end

# The upper bound a generic constructor `(::Type{C})(…) where {C<:Bound}`
# applies to, as a name (`"Any"` when unbounded), or `nothing` when the body
# is not such a definition — a callable-object method on a `Type{…}`
# instance (`where`/return-type wrappers looked through). The walker
# classifies such items as declaring nothing, so this looks at the body.
function _v2_generic_type_constructor_bound(body::BodyTree{V2Kind})
    node = body
    while (node.kind == JS2.K"const" || node.kind == JS2.K"global") && _v2_nchildren(node) >= 1
        node = _v2_children(node)[1]
    end
    (node.kind == JS2.K"function" || node.kind == JS2.K"=") && _v2_nchildren(node) >= 1 || return nothing
    sig = _v2_children(node)[1]
    bounds = Dict{String,String}()   # typevar → bound name
    while (sig.kind == JS2.K"where" || sig.kind == JS2.K"::") && _v2_nchildren(sig) >= 1
        if sig.kind == JS2.K"where"
            for tv in _v2_children(sig)[2:end]
                if tv.kind == JS2.K"<:" && _v2_nchildren(tv) == 2
                    v = _v2_leaf_string(_v2_children(tv)[1])
                    _, b = _v2_qualified_name(_v2_unwrap_to_name(_v2_children(tv)[2]))
                    (v === nothing || b === nothing) || (bounds[v] = b)
                else
                    v = _v2_leaf_string(tv)
                    v === nothing || (bounds[v] = "Any")
                end
            end
        end
        sig = _v2_children(sig)[1]
    end
    (sig.kind == JS2.K"call" && _v2_nchildren(sig) >= 1) || return nothing
    callee = _v2_children(sig)[1]
    (callee.kind == JS2.K"::" && _v2_nchildren(callee) >= 1) || return nothing
    t = _v2_children(callee)[end]
    (t.kind == JS2.K"curly" && _v2_nchildren(t) == 2 &&
        _v2_leaf_string(_v2_children(t)[1]) == "Type") || return nothing
    tv = _v2_leaf_string(_v2_children(t)[2])
    tv === nothing && return "Any"                    # `(::Type{<:Foo})` shapes: be conservative
    return get(bounds, tv, "Any")
end

"The bounds of every generic `(::Type{C})(…)` constructor spliced into `root`'s tree."
Salsa.@derived function derived_v2_root_generic_constructor_bounds(rt, root)
    bounds = Set{String}()
    tree = derived_v2_module_tree(rt, root)
    for uri in sort!(collect(keys(tree.file_modules)); by=string)
        for row in derived_v2_file_skeleton(rt, uri).items
            (row.kind === :function || row.kind === :assignment) || continue
            body = derived_v2_item_body(rt, V2ItemRef(uri, row.id))
            body === nothing && continue
            b = _v2_generic_type_constructor_bound(body)
            b === nothing || push!(bounds, b)
        end
    end
    return bounds
end

# The declared supertype name of a `struct`/`abstract type` body, or `nothing`.
function _v2_declared_supertype(body::BodyTree{V2Kind})
    node = body
    while (node.kind == JS2.K"const" || node.kind == JS2.K"global") && _v2_nchildren(node) >= 1
        node = _v2_children(node)[1]
    end
    head = if node.kind == JS2.K"struct" && _v2_nchildren(node) >= 2
        _v2_children(node)[2]
    elseif (node.kind == JS2.K"abstract" || node.kind == JS2.K"primitive") && _v2_nchildren(node) >= 1
        _v2_children(node)[1]
    else
        return nothing
    end
    (head.kind == JS2.K"<:" && _v2_nchildren(head) == 2) || return nothing
    _, sup = _v2_qualified_name(_v2_unwrap_to_name(_v2_children(head)[2]))
    return sup
end

# Whether a generic `(::Type{C})(…) where {C<:Bound}` constructor in the
# root applies to the workspace type `name` declared at `path`: the bound is
# `Any`, or the type's declared supertype chain (through the workspace's own
# abstract types) reaches it.
# Whether `name` in module `path` names something the workspace does not
# declare: a `using`ed external face, or an implicit Base/Core name.
function _v2_name_is_external(rt, root, path::Vector{String}, name::String)
    face = get(derived_v2_module_visible_names_idfree(rt, root, path), name, nothing)
    face === nothing || return face.origin === :using_external
    bare = derived_v2_module_is_bare(rt, root, path)
    return insorted(name, derived_v2_implicit_scope_names(rt, root, bare))
end

function _v2_generic_constructor_covers(rt, root, path::Vector{String}, name::String)
    bounds = derived_v2_root_generic_constructor_bounds(rt, root)
    isempty(bounds) && return false
    "Any" in bounds && return true
    current = name
    cur_path = path
    for _ in 1:8
        ref = get(derived_v2_module_declared(rt, root, cur_path), current, nothing)
        if ref === nothing
            # Not declared here. An implicit Base/Core name or a `using`ed
            # external type (`FileBuffer <: IO`) continues its ancestry
            # OUTSIDE the workspace, where a workspace-declared bound can never
            # appear: only a bound that is itself external (`T<:IO`) could
            # still cover it, and that declines. Anything else is unknown
            # ancestry: decline.
            _v2_name_is_external(rt, root, cur_path, current) || return true
            declared_here = derived_v2_module_declared(rt, root, cur_path)
            return any(b -> get(declared_here, b, nothing) === nothing, bounds)
        end
        body = derived_v2_item_body(rt, ref)
        body === nothing && return true
        sup = _v2_declared_supertype(body)
        sup === nothing && return false         # `<: Any`: no bound but "Any" applies
        sup in bounds && return true
        current = sup
        # The supertype is looked up in the same module (the common case);
        # anything else is unknown ancestry.
    end
    return true
end

# The store's arities for an external callee. A callee that is a type is a
# constructor call: the store lists a plain type's own constructor methods
# (`DomainError()` with no arguments IS a real mismatch), but never the
# generic `(::Type{T})(…)` families a parametric type or an alias inherits
# (StaticArrays' `Point2f(x, y)` in SciMLBase's Makie extension) — those
# decline.
function _v2_external_function_arities(rt, root, mod::Vector{String}, name::String)
    if derived_v2_external_module_member_kind(rt, root, mod, name) === :datatype
        derived_v2_external_ctor_arity_reliable(rt, root, mod, name) || return nothing
    end
    return derived_v2_external_method_arities(rt, root, mod, name)
end

# ── incorrect_call_args / function_has_no_methods ───────────────────────────
#
# The arity half of v1's method-call check — deliberately arity-ONLY: v1's own
# per-file tree path checks cross-file callees from the same `MethodArity`
# plain data, so this reproduces the shipped cross-file semantics; the
# positional-TYPE arm is not ported (needs types v2 does not compute). Both
# codes live under the `:incorrect_call_args` rule id, exactly as v1's
# `LintRule` groups them.
#
# Every gate errs toward silence (the zero-v2-only corpus differential is the
# backstop): do-blocks, definition signatures, splatted calls, dotted/broadcast
# callees, locally-shadowed callees (via `BindingUse`), unresolvable callees,
# aliased imports, names with a partial method view (extended external stores,
# import-then-extend), blind modules, test blocks, quoted code, and macrocall
# arguments whose effects the analyzer does not model.

# Names whose full method set this root cannot see: (a) qualified extensions
# whose qualifier resolves to no tree module (`Base.push!(…)` — the store's
# view is now partial), and (b) names bound by an import (colon list, or the
# trailing segment of a whole-path `import A.b`) that are ALSO declared
# unqualified somewhere in the tree — the import-then-extend idiom, whose
# methods span the import target and the extending module. A call to such a
# name is declined everywhere in the root (a superset of v1's per-callee
# `tree_extended` decline; supersets of declines are the safe direction).
Salsa.@derived function derived_v2_partial_method_names(rt, root)
    tree = derived_v2_module_tree(rt, root)
    modpaths = Set{Vector{String}}(n.path for n in tree.modules)
    declared_anywhere = Set{String}()
    for n in tree.modules
        for (name, _, _) in n.decl_events
            push!(declared_anywhere, name)
        end
    end

    result = Set{String}()
    _v2_walk_spliced_items!(rt, root, String[], Set{URI}([root])) do _, item, loc
        isempty(item.qualifier) && return
        item.kind in _V2_METHOD_ITEM_KINDS || return
        _v2_resolve_extension_qualifier(modpaths, loc, item.qualifier) === nothing &&
            push!(result, item.name)
    end
    for n in tree.modules
        for ri in n.imports
            for s in ri.symbols
                nm = s.alias === nothing ? s.name : s.alias
                nm in declared_anywhere && push!(result, nm)
            end
            if isempty(ri.symbols) && ri.kind === :import && length(ri.target.path) >= 2
                nm = ri.alias === nothing ? last(ri.target.path) : ri.alias
                nm in declared_anywhere && push!(result, nm)
            end
        end
    end
    return result
end

"The `call_nargs` port: (minargs, maxargs, kws) of a call site."
function _v2_call_nargs(call::BodyTree{V2Kind})
    minargs, maxargs, kws = 0, 0, Symbol[]
    cs = _v2_children(call)
    for i in 2:length(cs)
        c = cs[i]
        if c.kind == JS2.K"parameters"
            for p in _v2_children(c)
                # A kw splat in the parameters is ignored, exactly as v1's
                # `call_nargs` ignores it — fewer recorded kws only ever makes
                # the comparison MORE accepting.
                p.kind == JS2.K"kw" || continue
                n = _v2_arity_arg_name(p)
                n !== nothing && push!(kws, Symbol(n))
            end
        elseif c.kind == JS2.K"kw"
            n = _v2_arity_arg_name(c)
            n !== nothing && push!(kws, Symbol(n))
        elseif c.kind == JS2.K"..."
            maxargs = typemax(Int)
        else
            minargs += 1
            maxargs !== typemax(Int) && (maxargs += 1)
        end
    end
    return (minargs, maxargs, kws)
end

"Positional splat directly in the call (parameters splats don't count — v1 parity)."
_v2_call_has_splat(call::BodyTree{V2Kind}) =
    any(c -> c.kind == JS2.K"...", _v2_children(call))

"The `compare_f_call` port, verbatim."
function _v2_compare_f_call(ref::MethodArity, (act_min, act_max, act_kws))
    if act_max == typemax(Int)
        act_min <= act_max < ref.minargs && return false
    else
        (ref.minargs <= act_min <= act_max <= ref.maxargs) || return false
    end
    ref.kwsplat && return true
    length(act_kws) > length(ref.kws) && return false
    all(kw in ref.kws for kw in act_kws) || return false
    return true
end

# Render the arity constraint of a method set as the UNION of the methods'
# ranges ("2 to 3 or 5"), never their hull: "Expected 2 to 5 arguments, got
# 4" (DataFrames, methods of arity 2–3 and 5) was self-contradictory.
function _v2_arity_desc(arities::Vector{MethodArity})
    any(a.maxargs == typemax(Int) for a in arities) &&
        return string("at least ", minimum(a.minargs for a in arities))
    ivs = sort!(unique!([(a.minargs, a.maxargs) for a in arities]))
    merged = Tuple{Int,Int}[]
    for (lo, hi) in ivs
        if !isempty(merged) && lo <= merged[end][2] + 1
            merged[end] = (merged[end][1], max(merged[end][2], hi))
        else
            push!(merged, (lo, hi))
        end
    end
    parts = [lo == hi ? string(lo) : string(lo, " to ", hi) for (lo, hi) in merged]
    length(parts) == 1 && return parts[1]
    return join(parts[1:end-1], ", ") * " or " * parts[end]
end

# The specific reason sentence for a non-matching call, or `nothing` for the
# generic wording. Arity-only (no type arm): count mismatch first, then an
# unsupported keyword against the arity-matching candidates.
function _v2_call_mismatch_reason(arities::Vector{MethodArity}, (act_min, act_max, act_kws))
    act_max == typemax(Int) && return nothing
    nargs = act_min   # no splat ⇒ min == max
    arity_ok = [a for a in arities if a.minargs <= nargs <= a.maxargs]
    if isempty(arity_ok)
        desc = _v2_arity_desc(arities)
        return string("Expected ", desc, " argument", desc == "1" ? "" : "s",
                      ", got ", nargs, ".")
    end
    for kw in act_kws
        any(a -> a.kwsplat || kw in a.kws, arity_ok) ||
            return string("Unsupported keyword `", kw, "`.")
    end
    return nothing
end

# The partial-method names of the file's package ENTRY root (`src/<Pkg>.jl`):
# every qualified extension and import-then-extend written anywhere in the
# package's static include tree, visible from any other root of the package.
"""
    derived_v2_package_extension_roots(rt, pkg_folder) -> Vector{URI}

The entry files of the package's declared `[extensions]` that exist in the
workspace (`ext/<Name>.jl` or `ext/<Name>/<Name>.jl`) — roots of their own
whose definitions extend the package's functions.
"""
Salsa.@derived function derived_v2_package_extension_roots(rt, pkg_folder)
    pkg = derived_package(rt, pkg_folder)
    pkg === nothing && return URI[]
    pf = derived_project_file(rt, pkg.project_file_uri)
    (pf === nothing || isempty(pf.extensions)) && return URI[]
    base = uri2filepath(pkg_folder)
    base === nothing && return URI[]
    roots = URI[]
    for name in sort!(collect(keys(pf.extensions)))
        for cand in (joinpath(base, "ext", "$(name).jl"), joinpath(base, "ext", name, "$(name).jl"))
            u = filepath2uri(cand)
            if derived_has_file(rt, u)
                push!(roots, u)
                break
            end
        end
    end
    return roots
end

# The package's partial-method names across ALL of its roots: the entry root
# plus every extension entry. A stub in `src/` whose methods live in an
# extension (`Parent.f(x, y) = …` in `ext/ParentBarExt.jl`) is partial from
# the package's point of view — a call to it anywhere in the package declines.
Salsa.@derived function _derived_v2_package_partial_method_names(rt, uri)
    pkg_folder = derived_package_for_file(rt, uri)
    pkg_folder === nothing && return Set{String}()
    pkg = derived_package(rt, pkg_folder)
    pkg === nothing && return Set{String}()
    result = Set{String}()
    entry = filepath2uri(joinpath(uri2filepath(pkg_folder), "src", "$(pkg.name).jl"))
    derived_has_file(rt, entry) && union!(result, derived_v2_partial_method_names(rt, entry))
    for ext_root in derived_v2_package_extension_roots(rt, pkg_folder)
        union!(result, derived_v2_partial_method_names(rt, ext_root))
    end
    return result
end

# The store's canonical function name behind an unqualified external callee
# when it is an alias (`≈` → `isapprox`), else `nothing`. Only the implicit
# Base/Core scope and `using`-brought names are consulted — the two ways an
# alias reaches a call site unqualified.
function _v2_callee_canonical_name(rt, root, path::Vector{String},
                                   qual::Vector{String}, name::String)
    isempty(qual) || return nothing
    face = get(derived_v2_module_visible_names_idfree(rt, root, path), name, nothing)
    modpath = if face === nothing
        bare = derived_v2_module_is_bare(rt, root, path)
        insorted(name, derived_v2_implicit_scope_names(rt, root, bare)) || return nothing
        derived_v2_external_module_member_kind(rt, root, ["Base"], name) === :absent ?
            ["Core"] : ["Base"]
    elseif face.origin === :using_external && face.kind === :external_symbol
        face.origin_module
    else
        return nothing
    end
    canon = derived_v2_external_canonical_name(rt, root, modpath, name)
    return canon == name ? nothing : canon
end

# Seam arities are plain named tuples (the seam file cannot name v2 types);
# lift them into the `MethodArity` vocabulary the comparison uses.
_v2_lift_store_arities(ext) =
    MethodArity[MethodArity(a.minargs, a.maxargs, a.kws, a.kwsplat) for a in ext]

# Resolve a callee to its full arity set: `nothing` declines, an empty vector
# means "workspace-declared with zero methods" (`function f end`). The second
# return distinguishes the workspace/external provenance — only a workspace
# empty set may claim FunctionHasNoMethods.
function _v2_callee_arities(rt, root, path::Vector{String},
                            qual::Vector{String}, name::String)
    if isempty(qual)
        face = get(derived_v2_module_visible_names_idfree(rt, root, path), name, nothing)
        if face === nothing
            # An undeclared name is `missing_reference`'s business; an implicit
            # Base/Core name is checked against the store.
            bare = derived_v2_module_is_bare(rt, root, path)
            insorted(name, derived_v2_implicit_scope_names(rt, root, bare)) || return nothing
            # Core is consulted only when Base LACKS the name: a Base member
            # that declines (`Vector`, a parametric alias) must not fall
            # through to Core's re-export of it, whose constructor
            # `FunctionStore` hides the parameters.
            owner = derived_v2_external_module_member_kind(rt, root, ["Base"], name) in (:absent, :missing_store) ? ["Core"] : ["Base"]
            ext = _v2_external_function_arities(rt, root, owner, name)
            (ext === nothing || isempty(ext)) && return nothing
            return (_v2_lift_store_arities(ext), false)
        end
        if face.origin === :declared || face.origin === :using_tree
            face.kind in _V2_METHOD_ITEM_KINDS || return nothing
            # A constructor call while the root defines a generic constructor
            # `(::Type{C})(…) where {C<:Abstract}` (BangBang's collectors,
            # Transducers' executors): every subtype gains that method, and
            # which types are subtypes is not known here — decline.
            _v2_is_datatype_kind(face.kind) &&
                _v2_generic_constructor_covers(rt, root, face.origin_module, name) && return nothing
            ws = derived_v2_method_arities(rt, root, face.origin_module, name)
            ws === nothing && return nothing
            return (ws, true)
        elseif face.origin === :using_external || face.origin === :import_binding
            face.kind === :external_symbol || return nothing
            # An `as`-renamed import binds a name the store knows under another
            # one — resolving the bound name against the store would fetch the
            # wrong (or no) method set. Decline renamed bindings.
            for ri in derived_v2_module_imports(rt, root, path)
                any(s -> s.alias == name && s.name != name, ri.symbols) && return nothing
                ri.alias == name && return nothing
            end
            ext = _v2_external_function_arities(rt, root, face.origin_module, name)
            (ext === nothing || isempty(ext)) && return nothing
            return (_v2_lift_store_arities(ext), false)
        end
        return nothing
    end

    # Qualified callee `Q.f(…)` / `A.B.f(…)`: the first segment resolves
    # through the module-target ledger (declared child modules and
    # module-valued import bindings alike), the rest as nested modules.
    _, modtargets = _v2_visible_names_pass1(rt, root, path, Set{URI}())
    mt = get(modtargets, qual[1], nothing)
    if mt === nothing
        # `Base.foo(…)`/`Core.foo(…)` without any import: the qualifier is an
        # implicitly-visible name — resolve the written path against the store.
        bare = derived_v2_module_is_bare(rt, root, path)
        insorted(qual[1], derived_v2_implicit_scope_names(rt, root, bare)) || return nothing
        ext = _v2_external_function_arities(rt, root, qual, name)
        (ext === nothing || isempty(ext)) && return nothing
        return (_v2_lift_store_arities(ext), false)
    end
    if mt.sort === :tree
        resolved = copy(mt.path)
        tree = derived_v2_module_tree(rt, root)
        modpaths = Set{Vector{String}}(n.path for n in tree.modules)
        for seg in qual[2:end]
            push!(resolved, seg)
            resolved in modpaths || return nothing
        end
        ws = derived_v2_method_arities(rt, root, resolved, name)
        ws === nothing && return nothing
        return (ws, true)
    elseif mt.sort === :external
        ext = _v2_external_function_arities(rt, root, vcat(mt.path, qual[2:end]), name)
        (ext === nothing || isempty(ext)) && return nothing
        return (_v2_lift_store_arities(ext), false)
    end
    return nothing
end

# The body walk: preorder addresses aligned with `derived_v2_file_maps`
# (`_materialize` consumes addresses even for skipped subtrees). Skips —
# advancing the counter across the whole subtree — quoted code and macrocall
# arguments the analyzer does not model (`@test_throws` explicitly: its body
# is EXPECTED to error). Definition signatures and do-block callees are
# call-shaped but not calls; they are registered in `skip` at the parent, so
# nested calls inside them (defaults, arguments) stay checked.
function _v2_call_sites!(emit, bt::BodyTree{V2Kind}, addr::Base.RefValue{Int},
                         qdepth::Int, skip::Base.IdSet{BodyTree{V2Kind}})
    myaddr = (addr[] += 1)
    k = bt.kind
    if qdepth == 0 && k == JS2.K"macrocall"
        nm = _v2_macrocall_name(bt)
        if nm === nothing || nm == "@test_throws" || !_v2_macro_name_effects_known(nm)
            addr[] += bt_node_count(bt) - 1
            return nothing
        end
    end
    child_depth = _quote_depth(k, qdepth)
    if qdepth == 0 && child_depth > qdepth
        addr[] += bt_node_count(bt) - 1
        return nothing
    end
    bt.children === nothing && return nothing
    # Calls under a version/existence gate (`if VERSION < v"0.7"`, `@static if
    # isdefined(Base, :f)`) target an API that only exists on the gated Julia;
    # checking them against today's store is meaningless — skip the branch.
    if qdepth == 0 && (k == JS2.K"if" || k == JS2.K"elseif") && !isempty(bt.children) &&
       _v2_mentions_existence_guard(bt.children[1])
        addr[] += bt_node_count(bt) - 1
        return nothing
    end
    if k == JS2.K"function" || k == JS2.K"macro" || k == JS2.K"="
        sig = _v2_func_sig(bt)
        sig !== nothing && push!(skip, sig)
    elseif k == JS2.K"do" && !isempty(bt.children)
        push!(skip, bt.children[1])   # TODO v1 parity: count do-block args
    end
    if qdepth == 0 && k == JS2.K"call" && !(bt in skip)
        emit(bt, myaddr)
    end
    for c in bt.children
        _v2_call_sites!(emit, c, addr, child_depth, skip)
    end
    return nothing
end

"""
    derived_item_call_args_findings(rt, ref) -> Vector{SemanticFinding}

`incorrect_call_args` (arity arm) and its no-methods sibling for one item.
Separate from `derived_item_semantic_findings` for the same reason
`missing_reference` is: it depends on visibility, the arity funnel and
(through the seam) the environment.
"""
Salsa.@derived function derived_item_call_args_findings(rt, ref::V2ItemRef)
    result = SemanticFinding[]
    low = derived_item_lowering(rt, ref)
    (low === nothing || low.status !== :ok) && return result
    ref.id in derived_v2_under_macrocall_ids(rt, ref.file) && return result
    body = derived_item_lowering_body(rt, ref)
    body === nothing && return result
    # Test blocks run with `using Test` + the package under test — context the
    # bare module view cannot reproduce, so callee resolution there is
    # unreliable in BOTH directions. Declined wholesale (v1 checks them with
    # its prebuilt test scopes; the lost findings land in the differential's
    # v1-only ratchet class).
    _test_block_target(body) !== nothing && return result

    root = derived_v2_best_root_for_uri(rt, ref.file)
    root === nothing && return result
    skel = derived_v2_file_skeleton(rt, ref.file)
    any(t -> t.id == ref.id, skel.testitems) && return result
    idx = findfirst(r -> r.id == ref.id, skel.items)
    idx === nothing && return result
    path = vcat(_derived_v2_splice_prefix(rt, ref.file), skel.items[idx].parent_module)

    # A blind module may gain methods from code the walk cannot see (an opaque
    # macrocall's expansion, an unresolvable include, an unresolved wildcard),
    # making every "no matching arity" unreliable.
    derived_v2_module_unresolved_wildcard_using(rt, root, path) && return result
    derived_v2_module_has_computed_include(rt, root, path) && return result
    derived_v2_module_has_opaque_macrocall(rt, root, path) && return result
    # An item inside an `if VERSION < …`/`@static if` branch calls into the
    # Julia (or platform) it targets, whose method tables this environment
    # need not have (MatrixFactorizations' `checknonsingular(info, ::RowMaximum)`
    # under `if VERSION < v"1.11-"`): decline.
    skel.items[idx].conditional && return result

    binding_of = Dict{Int32,LoweredBinding}(b.id => b for b in low.bindings)
    uses_at = Dict{Int32,Vector{Int32}}()
    for u in low.uses
        push!(get!(() -> Int32[], uses_at, u.addr), u.binding)
    end

    partial = nothing   # demanded lazily, once a candidate call exists
    pkg_partial = nothing
    _v2_call_sites!(body, Ref(0), 0, Base.IdSet{BodyTree{V2Kind}}()) do call, call_addr
        _v2_call_has_splat(call) && return
        callee = _v2_children(call)[1]
        qual, name = _v2_qualified_name(callee)
        (name === nothing || isempty(name) || startswith(name, ".")) && return

        if isempty(qual)
            # A callee resolved by lowering to a local/argument (a closure, a
            # parameter) fully shadows any same-named global — its method set
            # is unknowable here. Only an anchor-module global callee that the
            # item itself never assigns proceeds to visibility resolution.
            # Desugaring can pin SEVERAL bindings at the callee's address (a
            # kwarg call mints internal `func`/`kw_container` locals there), so
            # the test is over every non-internal binding read at it: at least
            # one must be the callee's own anchor global, and none may be a
            # real local/argument.
            ok = false
            for uid in get(uses_at, Int32(call_addr + 1), Int32[])
                b = get(binding_of, uid, nothing)
                b === nothing && continue
                b.is_internal && continue
                if b.kind === :global && b.mod == "JWLoweringAnchor" &&
                   b.name == name && !b.is_assigned
                    ok = true
                elseif b.kind === :local || b.kind === :argument
                    ok = false
                    break
                end
            end
            ok || return
        end

        # A qualifier that is a LOCAL of this item (`Metal = get_extension(…);
        # Metal.functional()`) is a value, not a module: unknowable, decline.
        if !isempty(qual) &&
           any(b -> !b.is_internal && (b.kind === :local || b.kind === :argument) &&
                    b.name == qual[1], low.bindings)
            return
        end

        partial === nothing && (partial = derived_v2_partial_method_names(rt, root))
        name in partial && return
        # An aliased callee (`≈` is `const ≈ = isapprox` in Base) shares its
        # method table with the canonical name; a workspace extension of THAT
        # name (`Base.isapprox(x, y, config)`) makes the alias partial too.
        canon = _v2_callee_canonical_name(rt, root, path, qual, name)
        canon !== nothing && canon in partial && return
        # Cross-root visibility: a package's own extension of an external
        # function (`Base.delete!(::Token)` in DataStructures' src/,
        # `size(::MatrixDistribution, i)` in Distributions) must count from
        # EVERY root under that package — test files and computed-include
        # orphans are their own roots and would otherwise resolve the callee
        # to the store alone, flagging calls the package itself makes valid.
        pkg_partial === nothing && (pkg_partial = _derived_v2_package_partial_method_names(rt, ref.file))
        (name in pkg_partial || (canon !== nothing && canon in pkg_partial)) && return

        resolved = _v2_callee_arities(rt, root, path, qual, name)
        resolved === nothing && return
        arities, workspace = resolved
        if isempty(arities)
            workspace || return
            push!(result, (addr=Int32(call_addr), rule_id=:incorrect_call_args,
                msg="Called function has no methods."))
            return
        end
        cc = _v2_call_nargs(call)
        any(a -> _v2_compare_f_call(a, cc), arities) && return
        reason = _v2_call_mismatch_reason(arities, cc)
        push!(result, (addr=Int32(call_addr), rule_id=:incorrect_call_args,
            msg=reason === nothing ? "Possible method call error." :
                "Possible method call error. $reason"))
    end
    return result
end

# ── type_piracy / invalid_type_declaration ──────────────────────────────────
#
# Both rules read a definition's SIGNATURE, so they share one per-item
# producer over the item's own top-level def (nested closures are not visited
# — v1 reaches them but their bindings are local there too, so its checks
# rarely fire; the difference is silence-direction).
#
# `NotEqDef` is a pure shape (a def named `!=`). `TypePiracy` is v1's
# import-then-extend rule: a method added to a name this module imports from
# an external target, where NO signature argument mentions a workspace-owned
# type (a `where`-bound typevar counts as owned, exactly as v1's Binding test
# does); an argument type that resolves nowhere declines the whole definition
# (v1 counts it as foreign — the silent direction is chosen instead).
# `InvalidTypeDeclaration` flags `x::T` signature declarations whose `T` is a
# literal, a workspace function/macro, or an external non-datatype (the
# seam's `:datatype` member kind is the arbiter); alias chains and everything
# unresolvable decline.

# The signature of the item's own def with ADDRESSES: `(call, call_addr,
# where_names)`, or `nothing`. Mirrors `_v2_func_sig`'s unwrap chain, keeping
# the preorder-address arithmetic (each unwrap step descends to child 1 =
# +1) and collecting the `where`-clause type parameter names on the way.
function _v2_sig_with_addr(def::BodyTree{V2Kind}, def_addr::Int)
    (def.kind == JS2.K"function" || def.kind == JS2.K"macro" || def.kind == JS2.K"=") ||
        return nothing
    _v2_nchildren(def) >= 1 || return nothing
    node = _v2_children(def)[1]
    a = def_addr + 1
    wnames = String[]
    while true
        if node.kind == JS2.K"where" && _v2_nchildren(node) >= 1
            cs = _v2_children(node)
            for c in cs[2:end]
                n = c
                while (n.kind == JS2.K"<:" || n.kind == JS2.K">:") && _v2_nchildren(n) >= 1
                    n = _v2_children(n)[1]
                end
                s = _v2_leaf_string(n)
                s !== nothing && push!(wnames, s)
            end
            node = cs[1]
            a += 1
        elseif node.kind == JS2.K"::" && _v2_nchildren(node) == 2 &&
               (_v2_children(node)[1].kind == JS2.K"call" ||
                _v2_children(node)[1].kind == JS2.K"where")
            node = _v2_children(node)[1]
            a += 1
        else
            break
        end
    end
    node.kind == JS2.K"call" || return nothing
    return (node, a, wnames)
end

# Every name a type expression mentions: identifiers, the tails of qualified
# names (with their qualifier), and everything inside curly parameters —
# mirroring `refers_to_nonimported_type`'s recursion. Pushes `(qual, name)`.
function _v2_type_expr_names!(out::Vector{Tuple{Vector{String},String}}, t::BodyTree{V2Kind})
    k = t.kind
    if k == JS2.K"curly" || k == JS2.K"where"
        for c in _v2_children(t)
            _v2_type_expr_names!(out, c)
        end
    elseif (k == JS2.K"<:" || k == JS2.K">:" || k == JS2.K"::") && _v2_nchildren(t) >= 1
        _v2_type_expr_names!(out, _v2_children(t)[end])
    else
        q, n = _v2_qualified_name(t)
        n !== nothing && push!(out, (q, n))
    end
    return out
end

# Where a type name comes from: `(:workspace, declared_kind)`,
# `(:external, store_path)`, or `(:unknown, nothing)`. As-renamed imports and
# every unhandled shape land in `:unknown` — both consumers treat that as a
# decline.
function _v2_type_provenance(rt, root, path::Vector{String},
                             qual::Vector{String}, name::String)
    if isempty(qual)
        face = get(derived_v2_module_visible_names_idfree(rt, root, path), name, nothing)
        if face === nothing
            bare = derived_v2_module_is_bare(rt, root, path)
            insorted(name, derived_v2_implicit_scope_names(rt, root, bare)) ||
                return (:unknown, nothing)
            mk = derived_v2_external_module_member_kind(rt, root, ["Base"], name)
            return mk === :absent ? (:external, ["Core"]) : (:external, ["Base"])
        end
        (face.origin === :declared || face.origin === :using_tree) &&
            return (:workspace, face.kind)
        # Inside an extension, the parent package's names are the
        # extension's own (`using Parent` brings them): a method on a parent
        # type is not piracy, a parent type in an annotation is a type.
        if _v2_face_from_extension_parent(rt, root, face)
            return (:workspace, face.kind)
        end
        if face.kind === :external_symbol
            for ri in derived_v2_module_imports(rt, root, path)
                any(s -> s.alias == name && s.name != name, ri.symbols) &&
                    return (:unknown, nothing)
                ri.alias == name && return (:unknown, nothing)
            end
            return (:external, face.origin_module)
        end
        return (:unknown, nothing)
    end
    _, modtargets = _v2_visible_names_pass1(rt, root, path, Set{URI}())
    mt = get(modtargets, qual[1], nothing)
    if mt === nothing
        bare = derived_v2_module_is_bare(rt, root, path)
        insorted(qual[1], derived_v2_implicit_scope_names(rt, root, bare)) ||
            return (:unknown, nothing)
        return (:external, qual)
    end
    if mt.sort === :tree
        resolved = copy(mt.path)
        tree = derived_v2_module_tree(rt, root)
        modpaths = Set{Vector{String}}(n.path for n in tree.modules)
        for seg in qual[2:end]
            push!(resolved, seg)
            resolved in modpaths || return (:unknown, nothing)
        end
        kind = get(derived_v2_module_names(rt, root, resolved), name, nothing)
        return kind === nothing ? (:unknown, nothing) : (:workspace, kind)
    elseif mt.sort === :external
        return (:external, vcat(mt.path, qual[2:end]))
    end
    return (:unknown, nothing)
end

const _V2_DATATYPE_DECL_KINDS = (:struct, :mutable_struct, :abstract, :primitive, :enum)

# ── kw_default_mismatch ─────────────────────────────────────────────────────
#
# v1 compares a literal keyword default against a `Core.<builtin>` annotation
# by store identity and CST literal head. The EST carries TYPED literal
# values (`0x01` parses as a `UInt8`), so every head/digit-count rule
# collapses into a check on `typeof(default value)` — including v1's
# unsigned-width digit arithmetic, which is exactly how Julia's own parser
# picks the literal's width. `nothing` from a checker means "flag".
const _V2_KW_DEFAULT_CHECKS = Dict{String,Function}(
    "String" => v -> v isa String,
    # Any LITERAL default for a `::Symbol` annotation mismatches (`:sym` is a
    # quote node, not a literal — never checked, exactly as v1's guard).
    "Symbol" => v -> false,
    "Int" => v -> v isa Int,
    "Bool" => v -> v isa Bool,
    "Char" => v -> v isa Char,
    "Float64" => v -> v isa Float64,
    "Float32" => v -> v isa Float32,
    "UInt8" => v -> v isa UInt8,
    "UInt16" => v -> v isa UInt16,
    "UInt32" => v -> v isa UInt32,
    "UInt64" => v -> v isa UInt64,
    "UInt128" => v -> v isa UInt128,
    # Signed literals always parse at the native width (or 64/128 via
    # suffix-less magnitude), so a non-native signed annotation can never be
    # satisfied by a plain literal — v1's rule, width for width.
    "Int8" => v -> false,
    "Int16" => v -> false,
    "Int32" => v -> Sys.WORD_SIZE == 32 && v isa Int32,
    "Int64" => v -> Sys.WORD_SIZE == 64 && v isa Int64,
    "Int128" => v -> false,
)

# The kind gate matters: a `K"Identifier"` leaf carries its NAME as a `String`
# in `val`, so without it an identifier default (`x::Int = SOME_CONST`) would
# masquerade as a String literal and always "mismatch".
_v2_literal_value(bt::BodyTree{V2Kind}) =
    bt.children === nothing && _v2_is_literal_kind(bt.kind) &&
    bt.val isa Union{Integer,AbstractFloat,String,Char} ?
    bt.val : nothing

_v2_is_literal_kind(k) =
    k == JS2.K"Integer" || k == JS2.K"Float" || k == JS2.K"String" ||
    k == JS2.K"string" || k == JS2.K"Char" || k == JS2.K"Bool" ||
    k == JS2.K"cmdstring" || k == JS2.K"CmdString" || k == JS2.K"HexInt" ||
    k == JS2.K"OctInt" || k == JS2.K"BinInt" || k == JS2.K"Float32"

# Is the item's own definition extending a name this module imports from an
# EXTERNAL target (`import Base: sin` / `import Base.sin`, alias-bound names
# included)? The piracy precondition, matching v1's
# `overwrites_imported_function`.
function _v2_extends_external_import(rt, root, path::Vector{String}, name::String)
    for ri in derived_v2_module_imports(rt, root, path)
        ri.target.sort === :external || continue
        for s in ri.symbols
            (s.alias === nothing ? s.name : s.alias) == name && return true
        end
        if isempty(ri.symbols) && ri.kind === :import && length(ri.target.path) >= 2
            (ri.alias === nothing ? last(ri.target.path) : ri.alias) == name && return true
        end
    end
    return false
end

"""
    derived_item_sig_rule_findings(rt, ref) -> Vector{SemanticFinding}

`type_piracy` (NotEqDef + the import-then-extend rule) and
`invalid_type_declaration` for one item's own definition signature.
"""
Salsa.@derived function derived_item_sig_rule_findings(rt, ref::V2ItemRef)
    result = SemanticFinding[]
    body = derived_item_lowering_body(rt, ref)
    body === nothing && return result
    ref.id in derived_v2_under_macrocall_ids(rt, ref.file) && return result
    _test_block_target(body) !== nothing && return result

    sig = _v2_sig_with_addr(body, 1)
    sig === nothing && return result
    call, call_addr, wnames = sig
    cs = _v2_children(call)
    isempty(cs) && return result

    # NotEqDef: a definition named `!=`, qualified or not — pure shape.
    _, fname = _v2_qualified_name(_v2_unwrap_to_name(cs[1]))
    if fname == "!="
        push!(result, (addr=Int32(1), rule_id=:type_piracy,
            msg="`!=` is defined as `const != = !(==)` and should not be overloaded. " *
                "Overload `==` instead."))
        return result
    end

    root = derived_v2_best_root_for_uri(rt, ref.file)
    root === nothing && return result
    skel = derived_v2_file_skeleton(rt, ref.file)
    any(t -> t.id == ref.id, skel.testitems) && return result
    idx = findfirst(r -> r.id == ref.id, skel.items)
    idx === nothing && return result
    path = vcat(_derived_v2_splice_prefix(rt, ref.file), skel.items[idx].parent_module)
    derived_v2_module_has_opaque_macrocall(rt, root, path) && return result

    arg_addrs = _v2_child_addresses(call, call_addr)

    # ── invalid_type_declaration over every binary `::` declaration ─────────
    function check_decl!(node::BodyTree{V2Kind}, addr::Int)
        (node.kind == JS2.K"::" && _v2_nchildren(node) == 2) || return
        t = _v2_children(node)[2]
        if _v2_is_literal_kind(t.kind)
            push!(result, (addr=Int32(addr), rule_id=:invalid_type_declaration,
                msg="A non-DataType has been used in a type declaration statement."))
            return
        end
        # A string macro in type position (`m::MIME"text/html"`) produces a
        # type at expansion time: unknown here, accept (PlutoUI ×61).
        t.kind == JS2.K"macrocall" && return
        q, n = _v2_qualified_name(t)
        n === nothing && return
        (isempty(q) && n in wnames) && return
        prov, info = _v2_type_provenance(rt, root, path, q, n)
        # Flag only what is PROVEN not to be a type; every unknown accepts
        # (v1's `is_never_datatype` polarity — its fallback returns `false`).
        flag = false
        if prov === :workspace && (info === :function || info === :macro)
            # The winner kind can be a constructor method shadowing a `const`
            # alias of the same name (`const Categorical{..} = ..` plus
            # `Categorical(p) = ..` — the FillArrays pattern v1 escapes via
            # `_defines_constructor_method`). Consult the raw event stream:
            # flag only when the name is declared in THIS module and every
            # declaration is function/macro-like; a name that never appears
            # here (e.g. brought in via a workspace `using`) stays unknown.
            saw_local = false
            proven_nontype = true
            for (en, ek, _) in derived_v2_module_decl_events(rt, root, path)
                en == n || continue
                saw_local = true
                if !(ek === :function || ek === :macro)
                    proven_nontype = false
                    break
                end
            end
            flag = saw_local && proven_nontype
            # A name this module also IMPORTS and then extends with methods
            # (`import IJulia: Comm` + `Comm(target, …) = …`): the local
            # events are all function-like, but the type lives at the import
            # target — unknown here, accept.
            if flag
                for ri in derived_v2_module_imports(rt, root, path)
                    if any(s -> (s.alias === nothing ? s.name : s.alias) == n, ri.symbols) ||
                       (isempty(ri.symbols) && ri.kind === :import &&
                        !isempty(ri.target.path) && last(ri.target.path) == n)
                        flag = false
                        break
                    end
                end
            end
        elseif prov === :external
            flag = derived_v2_external_module_member_kind(rt, root, info, n) === :value
        end
        flag && push!(result, (addr=Int32(addr), rule_id=:invalid_type_declaration,
            msg="A non-DataType has been used in a type declaration statement."))
        return
    end
    # ── kw_default_mismatch over `x::T = literal` entries ───────────────────
    function check_kw!(kw::BodyTree{V2Kind}, kw_addr::Int)
        (kw.kind == JS2.K"kw" && _v2_nchildren(kw) == 2) || return
        decl, dflt = _v2_children(kw)
        (decl.kind == JS2.K"::" && _v2_nchildren(decl) == 2) || return
        v = _v2_literal_value(dflt)
        v === nothing && return
        t = _v2_children(decl)[2]
        q, n = _v2_qualified_name(t)
        n === nothing && return
        checker = get(_V2_KW_DEFAULT_CHECKS, n, nothing)
        checker === nothing && return
        (isempty(q) && n in wnames) && return
        prov, info = _v2_type_provenance(rt, root, path, q, n)
        # Only the genuine Core builtin (reached through Base/Core) carries
        # the rule; a same-named workspace type or alias declines.
        (prov === :external && !isempty(info) && info[1] in ("Base", "Core")) || return
        checker(v) && return
        push!(result, (addr=Int32(kw_addr + 1 + bt_node_count(decl)),
            rule_id=:kw_default_mismatch,
            msg="The default value provided does not match the specified argument type."))
        return
    end

    for (i, arg0) in enumerate(cs)
        i == 1 && continue
        arg, aaddr = arg0, arg_addrs[i]
        if arg.kind == JS2.K"parameters"
            for (j, p) in enumerate(_v2_children(arg))
                paddr = _v2_child_addresses(arg, aaddr)[j]
                if p.kind == JS2.K"kw" && _v2_nchildren(p) >= 1
                    check_decl!(_v2_children(p)[1], paddr + 1)
                    check_kw!(p, paddr)
                else
                    check_decl!(p, paddr)
                end
            end
            continue
        end
        if arg.kind == JS2.K"kw" && _v2_nchildren(arg) >= 1
            check_kw!(arg, aaddr)
            arg, aaddr = _v2_children(arg)[1], aaddr + 1
        end
        check_decl!(arg, aaddr)
    end

    # ── type_piracy (import-then-extend) ────────────────────────────────────
    (fname === nothing || !isempty(_v2_qualified_name(_v2_unwrap_to_name(cs[1]))[1])) &&
        return result
    # A definition inside a version/feature-gated branch (`@static if
    # !isdefined(Downloads, :url_filename)` → own definition; the import sits
    # in the other branch) owns its name on the Julia it targets — the
    # import-then-extend reading is meaningless across branches.
    skel.items[idx].conditional && return result
    _v2_extends_external_import(rt, root, path, fname) || return result
    for (i, arg0) in enumerate(cs)
        i == 1 && continue
        arg0.kind == JS2.K"parameters" && continue
        arg = _v2_unwrap_nospecialize(arg0)
        (arg.kind == JS2.K"kw" && _v2_nchildren(arg) >= 1) && (arg = _v2_children(arg)[1])
        (arg.kind == JS2.K"..." && _v2_nchildren(arg) >= 1) && (arg = _v2_children(arg)[1])
        t = _v2_arg_decl_type(arg)
        t === nothing && continue
        # `rrule(::typeof(f), …)` for a function `f` this module declares:
        # `typeof(f)` is a singleton type the module owns (the ChainRulesCore
        # idiom) — not piracy.
        _v2_typeof_owned_function(rt, root, path, t) && return result
        names = _v2_type_expr_names!(Tuple{Vector{String},String}[], t)
        for (q, n) in names
            (isempty(q) && n in wnames) && return result   # typevar-typed: owned
            prov, _ = _v2_type_provenance(rt, root, path, q, n)
            prov === :workspace && return result           # owned type: not piracy
            prov === :unknown && return result             # unresolvable: decline
        end
    end
    push!(result, (addr=Int32(1), rule_id=:type_piracy,
        msg="An imported function has been extended without using module defined typed arguments."))
    return result
end

# The parent package's name when `root` is an extension entry (or a file of
# an extension), else `nothing`.
Salsa.@derived function _v2_extension_parent_name(rt, root)
    ext = derived_extension_for_file(rt, root)
    ext === nothing && return nothing
    pkg = derived_package(rt, ext.package_folder)
    return pkg === nothing ? nothing : pkg.name
end

# Whether a declared argument type is `typeof(f)` (or `Type{typeof(f)}`) for
# a name declared in the module at `path` — or, inside an extension, one the
# parent package declares — an owned singleton type.
function _v2_typeof_owned_function(rt, root, path, t::BodyTree{V2Kind})
    node = t
    if node.kind == JS2.K"curly" && _v2_nchildren(node) == 2 &&
       _v2_leaf_string(_v2_children(node)[1]) == "Type"
        node = _v2_children(node)[2]
    end
    node.kind == JS2.K"call" || return false
    cs = _v2_children(node)
    (length(cs) == 2 && _v2_leaf_string(cs[1]) == "typeof") || return false
    q, n = _v2_qualified_name(_v2_unwrap_to_name(cs[2]))
    (n === nothing || !isempty(q)) && return false
    haskey(derived_v2_module_names(rt, root, path), n) && return true
    face = get(derived_v2_module_visible_names_idfree(rt, root, path), n, nothing)
    return face !== nothing && _v2_face_from_extension_parent(rt, root, face)
end

# Whether a visible name reached an extension's module from its parent
# package — through `using Parent` (exports) or `using Parent: x` /
# `import Parent: x` (a workspace-package member binding).
function _v2_face_from_extension_parent(rt, root, face)
    parent = _v2_extension_parent_name(rt, root)
    parent === nothing && return false
    (face.origin === :using_workspace_package || face.origin === :import_binding) || return false
    face.kind === :external_symbol && return false
    return !isempty(face.origin_module) && face.origin_module[1] == parent
end

# ── the shape rules: pointless_boolean / const_if_condition / literal_use ───
#
# Pure syntax shapes — no lowering, no visibility, no env — so their producer
# depends on nothing but the item's body (and the under-macrocall gate). One
# preorder walk with the standard address accounting and the standard skips
# (unknown-effect macrocalls, `@test_throws`, quoted code — v1 lints quotes;
# skipping them is the same declared narrowing `nothing_comparison` made).
# Test-block bodies stay COVERED: these rules need no resolution context, so
# the v1 parity that other producers decline on is free here.
#
# Ported deltas, both documented in the survey:
# - `EqInIfConditional` (`if x = 1`) is NOT ported: that shape is a parse
#   error in JuliaSyntax v2 (error nodes), so `syntax_errors` already reports
#   the real problem.
# - The `@static if` exemption is by NAME (a direct `if` argument of a
#   macrocall spelled `@static`), where v1 resolves the macro to Base by
#   identity — the name rule also exempts a user macro shadowing `@static`,
#   the silence direction.
# - Top-level `if true … end` chains are invisible here: the walker is
#   transparent through top-level `if` branches (their statements are
#   separate conditional items), so only `if`s INSIDE an item body are
#   checked — v1-only residue in the differential.

_v2_bool_literal(bt::BodyTree{V2Kind}) =
    bt.children === nothing && bt.kind == JS2.K"Bool"

# `static_arg` marks a node that is a DIRECT argument of an `@static`
# macrocall — its `if` is a deliberate compile-time toggle, not an accidental
# constant condition.
function _v2_shape_rules!(out::Vector{SemanticFinding}, bt::BodyTree{V2Kind},
                          addr::Base.RefValue{Int}, qdepth::Int, static_arg::Bool)
    myaddr = (addr[] += 1)
    k = bt.kind
    if qdepth == 0 && k == JS2.K"macrocall"
        nm = _v2_macrocall_name(bt)
        if nm === nothing || nm == "@test_throws" || !_v2_macro_name_effects_known(nm)
            addr[] += bt_node_count(bt) - 1
            return nothing
        end
    end
    child_depth = _quote_depth(k, qdepth)
    if qdepth == 0 && child_depth > qdepth
        addr[] += bt_node_count(bt) - 1
        return nothing
    end
    bt.children === nothing && return nothing
    cs = bt.children

    if qdepth == 0
        # Inside an `@static` condition a boolean literal is load-bearing:
        # `@static (cond && true) && isa(...)` is the idiom that turns a
        # version/isdefined check into a compile-time Bool (JuliaInterpreter).
        if !static_arg && k == JS2.K"||" && length(cs) >= 1 && _v2_bool_literal(cs[1])
            push!(out, (addr=Int32(myaddr), rule_id=:pointless_boolean,
                msg="The first argument of a `||` call is a boolean literal."))
        elseif !static_arg && k == JS2.K"&&" && length(cs) >= 2 &&
               (_v2_bool_literal(cs[1]) || _v2_bool_literal(cs[2]))
            push!(out, (addr=Int32(myaddr), rule_id=:pointless_boolean,
                msg="An argument of a `&&` call is a boolean literal."))
        elseif k == JS2.K"if" && !static_arg && !isempty(cs) && _v2_bool_literal(cs[1])
            # Ternaries parse as K"if" too and are flagged, exactly as v1's
            # `:if`-headed check does; `elseif` conditions are exempt in both
            # engines (a distinct kind here, a distinct head there). The
            # finding sits at the CONDITION node (child 1 = myaddr + 1).
            push!(out, (addr=Int32(myaddr + 1), rule_id=:const_if_condition,
                msg="A boolean literal has been used as the conditional of an " *
                    "if statement - it will either always or never run."))
        end
        _v2_literal_use!(out, bt, myaddr)
    end

    # `@static`'s argument is the whole boolean expression that follows it
    # (`@static (cond && true) && isa(x, T)` parses with the outer `&&` as the
    # macro's argument), often parenthesized: the flag passes through parens
    # and `&&`/`||` nodes so every literal in that condition counts as
    # load-bearing. It does NOT pass into `if` bodies — those are ordinary code.
    child_static = (qdepth == 0 && k == JS2.K"macrocall" && _v2_macrocall_name(bt) == "@static") ||
                   (static_arg && (k == JS2.K"parens" || k == JS2.K"&&" || k == JS2.K"||"))
    for c in cs
        _v2_shape_rules!(out, c, addr, child_depth, child_static)
    end
    return nothing
end

# A "bad literal" (v1's `isbadliteral`): a literal string/char/bool/number
# LEAF. Interpolated strings are compound nodes and don't count, matching
# v1's `isliteral` gate; cmd strings are excluded in both engines.
function _v2_bad_literal(bt::BodyTree{V2Kind})
    bt.children === nothing || return false
    k = bt.kind
    (k == JS2.K"String" || k == JS2.K"Char" || k == JS2.K"Bool") && return true
    return k != JS2.K"Identifier" && bt.val isa Union{Integer,AbstractFloat}
end

# The `check_use_of_literal` port — a bad literal as: a struct /
# abstract / primitive NAME, an assignment or kwarg LHS, a declaration RHS
# (`x::1`), or an `isa` RHS. The finding sits at the literal, as v1 marks it.
# The module-name arm is NOT ported: v2 module rows carry no body to walk
# (vanishingly rare — declared v1-only residue).
function _v2_literal_use!(out::Vector{SemanticFinding}, bt::BodyTree{V2Kind}, myaddr::Int)
    cs = bt.children
    cs === nothing && return nothing
    k = bt.kind
    target = 0
    if (k == JS2.K"=" || k == JS2.K"kw") && length(cs) >= 1 && _v2_bad_literal(cs[1])
        target = 1
    elseif k == JS2.K"::" && length(cs) == 2 && _v2_bad_literal(cs[2])
        target = 2
    elseif k == JS2.K"call" && length(cs) == 3 &&
           _v2_leaf_string(cs[1]) == "isa" && _v2_bad_literal(cs[3])
        target = 3
    elseif k == JS2.K"struct" && length(cs) >= 2 && _v2_bad_literal(cs[2])
        target = 2
    elseif (k == JS2.K"abstract" || k == JS2.K"primitive") && length(cs) >= 1 &&
           _v2_bad_literal(cs[1])
        target = 1
    end
    target == 0 && return nothing
    push!(out, (addr=Int32(_v2_child_addresses(bt, myaddr)[target]),
        rule_id=:literal_use,
        msg="You really shouldn't be using a literal value here."))
    return nothing
end

"""
    derived_item_shape_findings(rt, ref) -> Vector{SemanticFinding}

`pointless_boolean` / `const_if_condition` / `literal_use` for one item —
position-free, body-only (see the section header for the ported deltas).
"""
Salsa.@derived function derived_item_shape_findings(rt, ref::V2ItemRef)
    result = SemanticFinding[]
    body = derived_item_lowering_body(rt, ref)
    body === nothing && return result
    ref.id in derived_v2_under_macrocall_ids(rt, ref.file) && return result
    _v2_shape_rules!(result, body, Ref(0), 0, false)
    return result
end

# ── incorrect_iter_spec (literal arm) ───────────────────────────────────────
#
# v1's `check_incorrect_iter_spec` has three arms; only the env-light two are
# ported — a bare numeric literal as the iterated value (`for i in 5`), and a
# bare `length(...)` call resolving to Base (`for i in length(v)`). The strict
# `<:Number`-typed-variable arm needs type inference and is DEFERRED. The
# `1:length(x)` `index_from_length` shape is commit 7's subject.

# Emit each `for`/`generator` iteration-spec `=` node with its address, under
# the standard macro/quote address accounting.
function _v2_iter_specs!(emit, bt::BodyTree{V2Kind}, addr::Base.RefValue{Int}, qdepth::Int)
    myaddr = (addr[] += 1)
    k = bt.kind
    if qdepth == 0 && k == JS2.K"macrocall"
        nm = _v2_macrocall_name(bt)
        if nm === nothing || nm == "@test_throws" || !_v2_macro_name_effects_known(nm)
            addr[] += bt_node_count(bt) - 1
            return nothing
        end
    end
    child_depth = _quote_depth(k, qdepth)
    if qdepth == 0 && child_depth > qdepth
        addr[] += bt_node_count(bt) - 1
        return nothing
    end
    bt.children === nothing && return nothing
    if qdepth == 0 && (k == JS2.K"for" || k == JS2.K"generator")
        caddrs = _v2_child_addresses(bt, myaddr)
        specs = k == JS2.K"for" ? (1:min(1, length(bt.children))) : (2:length(bt.children))
        for i in specs
            c = bt.children[i]
            if c.kind == JS2.K"="
                emit(c, caddrs[i])
            elseif c.kind == JS2.K"block"   # `for i = …, j = …`
                baddrs = _v2_child_addresses(c, caddrs[i])
                for (j, s) in enumerate(_v2_children(c))
                    s.kind == JS2.K"=" && emit(s, baddrs[j])
                end
            end
        end
    end
    for c in bt.children
        _v2_iter_specs!(emit, c, addr, child_depth)
    end
    return nothing
end

"""
    derived_item_iter_spec_findings(rt, ref) -> Vector{SemanticFinding}

`incorrect_iter_spec`, literal arm, for one item.
"""
Salsa.@derived function derived_item_iter_spec_findings(rt, ref::V2ItemRef)
    result = SemanticFinding[]
    low = derived_item_lowering(rt, ref)
    (low === nothing || low.status !== :ok) && return result
    ref.id in derived_v2_under_macrocall_ids(rt, ref.file) && return result
    body = derived_item_lowering_body(rt, ref)
    body === nothing && return result
    _test_block_target(body) !== nothing && return result
    # A local named `length` anywhere in the item shadows the Base callee.
    any(b -> !b.is_internal && b.kind in (:local, :argument) && b.name == "length",
        low.bindings) && return result

    root = derived_v2_best_root_for_uri(rt, ref.file)
    root === nothing && return result
    skel = derived_v2_file_skeleton(rt, ref.file)
    any(t -> t.id == ref.id, skel.testitems) && return result
    idx = findfirst(r -> r.id == ref.id, skel.items)
    idx === nothing && return result
    path = vcat(_derived_v2_splice_prefix(rt, ref.file), skel.items[idx].parent_module)
    derived_v2_module_has_opaque_macrocall(rt, root, path) && return result

    _v2_iter_specs!(body, Ref(0), 0) do spec, spec_addr
        _v2_nchildren(spec) == 2 || return
        rng = _v2_children(spec)[2]
        flag = false
        # A bare numeric literal iterator (`for x in 2.1`) is LEGAL
        # one-element iteration — a deliberate idiom in SLEEFPirates' tests —
        # so only the `length(x)` shape (iterating a single Int by mistake,
        # e.g. `for i in length(a)` — three real bugs in the sweep) remains.
        if rng.kind == JS2.K"call" && _v2_nchildren(rng) >= 1
            q, n = _v2_qualified_name(_v2_children(rng)[1])
            if n == "length"
                prov, info = _v2_type_provenance(rt, root, path, q, n)
                flag = prov === :external && !isempty(info) && info[1] in ("Base", "Core")
            end
        end
        flag && push!(result, (addr=Int32(spec_addr), rule_id=:incorrect_iter_spec,
            msg="Iterating over `length(x)` iterates the single integer once; use `1:length(x)` or `eachindex(x)` to iterate the elements."))
    end
    return result
end

# ── analysis_boundary ───────────────────────────────────────────────────────
#
# One notice per construct the linter cannot see through, so silence about the
# suppressed rules is never mistaken for a clean bill. Computed includes keep
# their existing `include_errors`/ComputedInclude notice (v1 machinery, emitted
# under v2 too); this rule covers the `@eval`/`eval` boundaries, which had none.

# The semantic rules that early-return on the module blindness flags —
# keep in sync with the `derived_v2_module_has_*` gates in this file.
const _V2_BOUNDARY_SUPPRESSED_RULES =
    "missing_reference, incorrect_call_args, type_piracy, " *
    "invalid_type_declaration, kw_default_mismatch and incorrect_iter_spec"

const _V2_BOUNDARY_EVAL_MSG =
    "This `eval` cannot be analyzed statically: whatever it defines is " *
    "invisible to the linter, so $(_V2_BOUNDARY_SUPPRESSED_RULES) are not " *
    "applied in this module."

const _V2_BOUNDARY_IMPORT_MSG =
    "This conditional `using`/`import` may bring in names the linter cannot " *
    "see, so missing_reference is not applied in this module."

# Whether a top-level macrocall body is one the walker records as an opaque
# row for its NAME (an unmodelled macro) — as opposed to the isolating test
# macros, `@enum`, and the interpolating `@eval` handled separately.
function _v2_is_unmodelled_macro_body(body::BodyTree{V2Kind})
    body.kind == JS2.K"macrocall" || return false
    name = _v2_macrocall_name(body)
    name === nothing && return false
    name == "@enum" && return false
    name in V2_ISOLATED_SCOPE_MACROS && return false
    return _v2_macrocall_effects_unknown(body)
end

# The notice for an opaque top-level macrocall that did NOT clear through
# expansion, or `nothing` (cleared, or still pending — settles later).
function _v2_macro_boundary_msg(rt, ref::V2ItemRef, body::BodyTree{V2Kind})
    derived_v2_item_expansion_decls(rt, ref) === nothing || return nothing
    st = derived_v2_item_expansion_status(rt, ref)
    st.status === :pending && return nothing
    reason = if st.status === :failed
        isempty(st.error) ? "its expansion failed" : "its expansion failed: " * st.error
    elseif st.status === :disabled
        "macro expansion is disabled"
    elseif st.status === :no_env
        "there is no environment to expand it in"
    elseif st.status === :ok
        "it expands to code the linter cannot model"
    else
        "its expansion is unavailable"
    end
    name = something(_v2_macrocall_name(body), "?")
    return "Macro `$name` cannot be analyzed statically ($reason): whatever it " *
           "defines is invisible to the linter, so $(_V2_BOUNDARY_SUPPRESSED_RULES) " *
           "are not applied in this module."
end

"One `analysis_boundary` finding per opaque `@eval`/`eval`, unexpanded macro, or guarded import in the item."
Salsa.@derived function derived_item_boundary_findings(rt, ref::V2ItemRef)
    result = SemanticFinding[]
    body = derived_item_lowering_body(rt, ref)
    body === nothing && return result
    if body.kind == JS2.K"macrocall" && body.children !== nothing &&
       !isempty(body.children) && _macro_name_string(body.children[1]) == "eval"
        # A top-level interpolated `@eval`, recorded as an opaque row.
        push!(result, (addr=Int32(1), rule_id=:analysis_boundary, msg=_V2_BOUNDARY_EVAL_MSG))
    elseif _v2_is_unmodelled_macro_body(body)
        # An opaque top-level macrocall is a boundary only while the DJP has
        # not expanded it (failed, unavailable) — a clean expansion makes its
        # definitions ordinary rows. Its arguments' inner items report their
        # own body markers.
        msg = _v2_macro_boundary_msg(rt, ref, body)
        msg === nothing || push!(result, (addr=Int32(1), rule_id=:analysis_boundary, msg=msg))
    else
        for m in derived_v2_item_body_markers(rt, ref)
            if m.kind === :opaque_eval
                push!(result, (addr=m.addr, rule_id=:analysis_boundary, msg=_V2_BOUNDARY_EVAL_MSG))
            elseif m.kind === :guarded_import
                push!(result, (addr=m.addr, rule_id=:analysis_boundary, msg=_V2_BOUNDARY_IMPORT_MSG))
            end
        end
    end
    return result
end

"""
    derived_semantic_lint_findings(rt, uri) -> Vector{LintFinding}

The volatile emission join: per-item findings reattached to byte ranges via
`derived_v2_file_maps`. Volatile by design (recomputes on every reparse, like
`derived_item_positions`); only `derived_diagnostics` may depend on it. Returns
an empty vector without demanding ANY lowering machinery when the feature flag
is off or no takeover rule is enabled.

Iterates the v2 SKELETON, which carries exactly one row per item id. (v1's
`items` can carry several rows for one id — one per name of a tuple destructure
or `@enum` — which made this loop query, and emit, the same findings repeatedly.)
"""
Salsa.@derived function derived_semantic_lint_findings(rt, uri)
    result = LintFinding[]
    derived_lowering_lint_active(rt, uri) || return result

    maps = derived_v2_file_maps(rt, uri)
    isempty(maps) && return result

    # A file with syntax errors lowers RECOVERED trees, so LoweringErrors near
    # the error region are recovery artifacts — and `syntax_errors` already
    # reports the real problem. Only the catch-all id is filtered; routed
    # takeover findings keep flowing (v1 parity: the legacy engine lints broken
    # files too). File-level and volatile, so it lives in this join, never in
    # the backdating per-item query.
    has_syntax_errors = any(d -> d.severity === :error, derived_julia_syntax_diagnostics(rt, uri))

    # `missing_reference` is env-and-visibility-heavy, so its per-item query
    # runs only when the rule is on, its `scope` option isn't `"none"`, and
    # the file isn't suppressed wholesale (own-root helper/orphan files).
    config = derived_effective_lint_config(rt, uri)
    missing_refs_on = missingrefs_from_config(config) !== :none &&
        !_derived_v2_missing_ref_file_suppressed(rt, uri)
    soft_scope_on = rule_enabled(config, :soft_scope_ambiguity)
    call_args_on = rule_enabled(config, :incorrect_call_args)
    # Materialization filters disabled rules anyway; this gate only avoids
    # demanding the signature machinery when both are off.
    sig_rules_on = rule_enabled(config, :type_piracy) ||
        rule_enabled(config, :invalid_type_declaration) ||
        rule_enabled(config, :kw_default_mismatch)
    iter_spec_on = rule_enabled(config, :incorrect_iter_spec)
    shape_rules_on = rule_enabled(config, :pointless_boolean) ||
        rule_enabled(config, :const_if_condition) ||
        rule_enabled(config, :literal_use)
    boundary_on = rule_enabled(config, :analysis_boundary)

    for row in derived_v2_file_skeleton(rt, uri).items
        ref = V2ItemRef(uri, row.id)
        item_findings = derived_item_semantic_findings(rt, ref)
        if missing_refs_on
            mr = derived_item_missing_reference_findings(rt, ref)
            isempty(mr) || (item_findings = vcat(item_findings, mr))
        end
        if soft_scope_on
            ss = derived_item_soft_scope_findings(rt, ref)
            isempty(ss) || (item_findings = vcat(item_findings, ss))
        end
        if call_args_on
            ca = derived_item_call_args_findings(rt, ref)
            isempty(ca) || (item_findings = vcat(item_findings, ca))
        end
        if sig_rules_on
            sr = derived_item_sig_rule_findings(rt, ref)
            isempty(sr) || (item_findings = vcat(item_findings, sr))
        end
        if iter_spec_on
            it = derived_item_iter_spec_findings(rt, ref)
            isempty(it) || (item_findings = vcat(item_findings, it))
        end
        if shape_rules_on
            sh = derived_item_shape_findings(rt, ref)
            isempty(sh) || (item_findings = vcat(item_findings, sh))
        end
        if boundary_on
            bf = derived_item_boundary_findings(rt, ref)
            isempty(bf) || (item_findings = vcat(item_findings, bf))
        end
        isempty(item_findings) && continue
        ranges = get(maps, row.id, nothing)
        ranges === nothing && continue
        for f in item_findings
            f.rule_id === :lowering_errors && has_syntax_errors && continue
            1 <= f.addr <= length(ranges) || continue
            push!(result, LintFinding(ranges[f.addr], f.rule_id, f.msg, nothing, "JuliaWorkspaces.jl"))
        end
    end

    # Module-tree findings attach to module/import rows, whose maps the
    # Harvest milestone started storing.
    for f in derived_module_tree_lint_findings(rt, uri)
        ranges = get(maps, f.id, nothing)
        ranges === nothing && continue
        1 <= f.addr <= length(ranges) || continue
        push!(result, LintFinding(ranges[f.addr], f.rule_id, f.msg, nothing, "JuliaWorkspaces.jl"))
    end

    # `unresolved_import` touches the env seam and visibility, and `const_decl`
    # walks whole-module decl streams — each producer runs only when its rule
    # is actually on (materialize would filter anyway; this skips demanding
    # the machinery at all).
    if rule_enabled(config, :unresolved_import)
        for f in derived_v2_unresolved_import_findings(rt, uri)
            ranges = get(maps, f.id, nothing)
            ranges === nothing && continue
            1 <= f.addr <= length(ranges) || continue
            push!(result, LintFinding(ranges[f.addr], f.rule_id, f.msg, nothing, "JuliaWorkspaces.jl"))
        end
    end
    if rule_enabled(config, :const_decl)
        for f in derived_v2_const_decl_findings(rt, uri)
            ranges = get(maps, f.id, nothing)
            ranges === nothing && continue
            1 <= f.addr <= length(ranges) || continue
            push!(result, LintFinding(ranges[f.addr], f.rule_id, f.msg, nothing, "JuliaWorkspaces.jl"))
        end
    end
    return result
end
