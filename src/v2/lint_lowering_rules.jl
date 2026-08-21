# Lowering-backed lint rules (experiment, behind `input_lowering_lint`).
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
    :module_name, :relative_import,
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
const LOWERING_OWN_RULES = Set([:lowering_errors])

# The gate both producers consult. Evaluation order matters: with the flag off
# the only Salsa dependency is the flag input itself, so config edits do not
# even re-verify this query.
Salsa.@derived function derived_lowering_lint_active(rt, uri)
    input_lowering_lint(rt) || return false
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
        for f in low.findings
            f.addr == Int32(0) && continue   # no user address to report at
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
    return result
end

# ── module-tree rules ───────────────────────────────────────────────────────
#
# Rules about module STRUCTURE rather than item bodies: they read the skeleton
# and the module-tree splice prefix, never the lowering. Position-free (item
# ids + preorder addresses); ranges attach in the emission join below, which is
# why commit "Store address maps for module and import rows" exists.

"A structural finding attached to a (possibly bodyless) skeleton row."
const ModuleTreeFinding = @NamedTuple{id::Int64, addr::Int32, rule_id::Symbol, msg::String}

# The module a file's top level splices into, from its first root (the
# layer_expansion.jl precedent for multi-root files); empty for a plain buffer.
Salsa.@derived function _derived_v2_splice_prefix(rt, uri)
    roots = derived_roots_for_uri(rt, uri)
    isempty(roots) && return String[]
    path = derived_v2_file_module_path(rt, first(roots), uri)
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

    for row in derived_v2_file_skeleton(rt, uri).items
        item_findings = derived_item_semantic_findings(rt, V2ItemRef(uri, row.id))
        isempty(item_findings) && continue
        ranges = get(maps, row.id, nothing)
        ranges === nothing && continue
        for f in item_findings
            f.rule_id === :lowering_errors && has_syntax_errors && continue
            1 <= f.addr <= length(ranges) || continue
            push!(result, LintFinding(ranges[f.addr], f.rule_id, f.msg, nothing, "JuliaWorkspaces.jl"))
        end
    end

    # Module-tree findings attach to module/import rows, whose maps commit 1
    # of this milestone started storing.
    for f in derived_module_tree_lint_findings(rt, uri)
        ranges = get(maps, f.id, nothing)
        ranges === nothing && continue
        1 <= f.addr <= length(ranges) || continue
        push!(result, LintFinding(ranges[f.addr], f.rule_id, f.msg, nothing, "JuliaWorkspaces.jl"))
    end
    return result
end
