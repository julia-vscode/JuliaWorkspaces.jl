# The v2 include analysis, behind `input_v2_enabled`: the twins of
# `derived_file_include_data` and `derived_include_diagnostics`
# (layer_includes.jl gates to them). The walker is a module-qualified copy of
# StaticLint's `_walk_include_calls` with three differences — quoted code is
# skipped (an `include` inside `quote … end` is data), `module` blocks and
# `@safetestset` bodies scope duplicate detection like the testitem family,
# and a function-body include carries its literal target as a runtime target
# so it can be existence-checked and reported as a runtime boundary. The
# boundary notices (computed / runtime include) route to `analysis_boundary`
# through the diagnostic's `code`; the include-graph errors stay
# `include_errors`. src/StaticLint/** itself is untouched.
#
# Placed after StaticLint/StaticLint.jl (it needs StaticLint's and CSTParser's
# names) and before the diagnostics layers that consume it.

# `@safetestset` (SafeTestsets.jl) wraps its body in a fresh module, so it
# scopes include duplicates exactly like the testitem family does.
function _is_safetestset_macro_v2(x)
    CSTParser.is_getfield_w_quotenode(x) && return _is_safetestset_macro_v2(x.args[2].args[1])
    return CSTParser.isidentifier(x) && StaticLint.valofid(x) == "@safetestset"
end

function _is_safetestset_macrocall_v2(x::CSTParser.EXPR)
    CSTParser.ismacrocall(x) || return false
    (x.args === nothing || isempty(x.args)) && return false
    name = x.args[1]
    return name isa CSTParser.EXPR && _is_safetestset_macro_v2(name)
end

# Shared walker for include-call analyses. Calls `f(x, pos, target, in_function,
# guarded, testitem_ctx)` for every `include(...)`/`includet(...)` call, where
# `pos` is the 0-based byte offset of the call EXPR, `target` the resolved target
# `URI` or `nothing`, and `guarded` whether the call sits under an
# existence-guarded conditional (see below). `testitem_ctx` is `nothing` for
# ordinary calls, or the byte offset of the enclosing testitem-family macrocall
# for a call inside one — each such body is its own module at runtime, so
# duplicate-include detection scopes to it instead of to the include graph as a
# whole. `file_dir` may be `nothing` (a file without a filesystem path, e.g. an
# unsaved buffer), in which case only absolute include paths resolve.
#
# Calls inside function/macro bodies are reported with `in_function = true` and
# always `target = nothing`: a runtime `include` splices into whichever module
# the enclosing function is called from, so even a literal path has no static
# splice context — it must never become an include-graph edge, but it IS the
# "file structure not statically resolvable" signal (ComputedInclude). The
# *signature* of such a definition is excluded, so custom `include` methods
# (`include(p::AbstractPath) = ...`, FilePathsBase-style) are not reported.
function _walk_include_calls_v2(f, x::CSTParser.EXPR, file_dir, pos, in_function::Bool=false, skip::Union{Nothing,CSTParser.EXPR}=nothing, guarded::Bool=false, testitem_ctx::Union{Nothing,Int}=nothing)
    x === skip && return nothing

    if (CSTParser.fcall_name(x) == "include" || CSTParser.fcall_name(x) == "includet") && length(x.args) == 2
        resolved = nothing
        path = StaticLint.get_path(x, file_dir, nothing)
        if path !== nothing
            if isabspath(path)
                resolved = filepath2uri(path)
            elseif file_dir !== nothing
                resolved = filepath2uri(joinpath(file_dir, path))
            end
        end
        # A function-body include splices at run time: it never becomes an
        # include-graph edge (`target` stays `nothing`), but its resolved
        # literal target still travels as `runtime_target` so the diagnostics
        # pass can existence-check it and report it as a runtime boundary
        # rather than a "path could not be determined" computed include.
        target = in_function ? nothing : resolved
        f(x, pos, target, in_function, guarded, testitem_ctx, in_function ? resolved : nothing)
    elseif StaticLint.quoted(x)
        # Quoted code is data: an `include` inside `quote … end` / `:( … )`
        # runs elsewhere (if at all) and must not become an edge, a duplicate,
        # or a boundary of THIS file.
        return nothing
    elseif CSTParser.defines_function(x) || CSTParser.defines_macro(x)
        sig = try
            CSTParser.get_sig(x)
        catch
            nothing
        end
        # `get_sig` returns the `where` wrapper for `f(x) where T` — unwrap to
        # the call node so identity comparison excludes the signature itself.
        while sig isa CSTParser.EXPR && CSTParser.headof(sig) === :where && sig.args !== nothing && !isempty(sig.args)
            sig = sig.args[1]
        end

        p = pos
        for i in 1:length(x)
            _walk_include_calls_v2(f, x[i], file_dir, p, true, sig, guarded, testitem_ctx)
            p += x[i].fullspan
        end
    elseif !(CSTParser.headof(x) === :export || CSTParser.headof(x) === :public)
        # A conditional whose test mentions an existence/definedness check
        # (`isfile(deps) && include(deps)`, `@isdefined(X) || include("x.jl")`,
        # `if isfile(cfg) include(cfg) else include("default.jl") end`) makes
        # file structure runtime-dependent. The condition isn't evaluated
        # statically, so no arm is judged: every child except the condition
        # itself descends with `guarded = true` and the diagnostics pass
        # abstains from MissingFile/DuplicateInclude/ComputedInclude there.
        # The graph edges are unaffected.
        cond = nothing
        if CSTParser.headof(x) in (:if, :elseif) && x.args !== nothing && length(x.args) >= 1 &&
                x.args[1] isa CSTParser.EXPR && StaticLint._is_include_guard(x.args[1])
            cond = x.args[1]
        elseif CSTParser.isbinarysyntax(x) && (CSTParser.valof(CSTParser.headof(x)) == "&&" || CSTParser.valof(CSTParser.headof(x)) == "||") &&
                length(x.args) == 2 && x.args[1] isa CSTParser.EXPR && StaticLint._is_include_guard(x.args[1])
            cond = x.args[1]
        end

        # Each testitem-family body, `@safetestset` body and `module` block is
        # evaluated in a fresh module, so includes below this point belong to
        # that module rather than to the enclosing file — including one file
        # into two different modules is legitimate, not a duplicate. Nested
        # contexts keep the outermost one: the inner body is part of the same
        # runtime module for duplicate-detection purposes.
        child_ctx = testitem_ctx === nothing &&
            (StaticLint._is_testitem_family_macrocall(x) || _is_safetestset_macrocall_v2(x) || CSTParser.headof(x) === :module) ?
            pos : testitem_ctx

        p = pos
        for i in 1:length(x)
            child_guarded = guarded || (cond !== nothing && x[i] !== cond)
            _walk_include_calls_v2(f, x[i], file_dir, p, in_function, skip, child_guarded, child_ctx)
            p += x[i].fullspan
        end
    end

    return nothing
end

"""
    collect_include_analysis_v2(cst::CSTParser.EXPR, file_path::Union{Nothing,String})

Single-pass include analysis for one file. Walks `cst` once and returns a
`NamedTuple` with three products:

  - `edges::Set{URI}` — the resolved include targets (the file's include-graph
    edges).
  - `include_dict::Dict{UInt64,URI}` — maps the `objectid` of each resolved
    include-call EXPR to its target, for use by the semantic pass while
    traversing this exact CST instance. These objectids are only valid for the
    CST they were built from and must not outlive it.
  - `records::Vector` — `(offset, span, target, guarded, testitem_ctx)` tuples
    for every include call (including unresolved ones), in source order, for
    include-graph diagnostics. `guarded` marks calls under an existence guard
    (`isfile`/`isdefined`/`@isdefined` condition): they are conditional at
    runtime, so MissingFile/DuplicateInclude/ComputedInclude are not reported
    for them. `testitem_ctx` is the offset of the enclosing testitem-family
    macrocall (`@testitem`/`@testmodule`/`@testsnippet`) for calls inside one
    and `nothing` otherwise, so duplicate detection can scope to that body.
  - `computed_ids::Set{UInt64}` — the `objectid`s of include-call EXPRs whose
    path could NOT be determined statically (computed includes), for the
    semantic pass to mark the enclosing module scope. Same lifetime caveat as
    `include_dict`.
"""
function collect_include_analysis_v2(cst::CSTParser.EXPR, file_path::Union{Nothing,String})
    edges = Set{URI}()
    include_dict = Dict{UInt64,URI}()
    records = Tuple{Int,Int,Union{URI,Nothing},Bool,Union{Nothing,Int}}[]
    computed_ids = Set{UInt64}()
    # Function-body includes, keyed by offset: the resolved literal target (for
    # the diagnostics pass to existence-check and report as a runtime boundary)
    # or `nothing` when the path was computed as well.
    runtime_targets = Dict{Int,Union{Nothing,URI}}()
    _walk_include_calls_v2(cst, StaticLint._include_file_dir(file_path), 0) do x, pos, target, in_function, guarded, testitem_ctx, runtime_target
        # Function-body includes carry `target === nothing` by construction
        # (see `_walk_include_calls_v2`), so they land in `records` as computed
        # includes — boundary diagnostics + suppression signals — but never
        # become include-graph edges.
        push!(records, (pos, x.span, target, guarded, testitem_ctx))
        in_function && (runtime_targets[pos] = runtime_target)
        if target !== nothing
            push!(edges, target)
            include_dict[UInt64(objectid(x))] = target
        else
            push!(computed_ids, UInt64(objectid(x)))
        end
    end
    return (; edges, include_dict, records, computed_ids, runtime_targets)
end

"""
    derived_file_include_data_v2(rt, uri)

The v2 twin of `derived_file_include_data` (which gates to it): the same
fused include analysis, run by the v2 walker `_walk_include_calls_v2` (quoted
code skipped, `module`/`@safetestset` bodies scoping duplicates, function-body
includes carrying their literal target as `runtime_targets`).

  - `edges` — the file's resolved include-graph edges,
  - `include_dict` — `objectid`→target map for the semantic pass, and
  - `records` — `(offset, span, target, guarded, testitem_ctx)` tuples for
    include diagnostics.

The three are exposed through the thin selectors below. Keeping the selectors
separate is what preserves Salsa's early-exit: `include_dict` churns on every
reparse (objectids are fresh), but `derived_includes` /
`derived_file_include_records` back-date whenever the edges/records compare equal.
"""
Salsa.@derived function derived_file_include_data_v2(rt, uri)
    @debug "derived_file_include_data_v2" uri=uri

    tf = derived_text_file_content(rt, uri)
    tf === nothing && return (edges=Set{URI}(), include_dict=Dict{UInt64,URI}(), records=Tuple{Int,Int,Union{URI,Nothing},Bool,Union{Nothing,Int}}[], computed_ids=Set{UInt64}(), runtime_targets=Dict{Int,Union{Nothing,URI}}())

    cst = derived_julia_legacy_syntax_tree(rt, uri)

    # `file_path` may be `nothing` (an unsaved buffer): absolute include paths
    # still resolve, relative ones come back as `nothing` targets.
    file_path = uri2filepath(uri)

    return collect_include_analysis_v2(cst, file_path)
end

# The analysis-boundary notices of the v2 include diagnostics. Not StaticLint
# codes: they are v2's own, routed to the `analysis_boundary` rule by the
# diagnostic's `code`, while the include-graph errors keep StaticLint's codes
# and descriptions under `include_errors`.
const _INCLUDE_BOUNDARY_NOTICES_V2 = Dict{Symbol,String}(
    :computed => "The include path could not be determined statically. The included file is analyzed without this module's context, and missing_reference, incorrect_call_args, type_piracy, invalid_type_declaration, kw_default_mismatch and incorrect_iter_spec are not applied in this module.",
    :runtime => "This `include` runs inside a function body, so its target is spliced at run time rather than analyzed in this module's context; missing_reference, incorrect_call_args, type_piracy, invalid_type_declaration, kw_default_mismatch and incorrect_iter_spec are not applied in this module.",
)

function _include_diagnostic_v2(offset, span, code)
    rng = (offset + 1):(offset + span + 1)
    if code isa Symbol
        return Diagnostic(rng, :warning, _INCLUDE_BOUNDARY_NOTICES_V2[code], nothing, Symbol[], "StaticLint.jl", :analysis_boundary)
    end
    description = StaticLint.LintCodeDescriptions[code]
    return Diagnostic(rng, :warning, description, nothing, Symbol[], "StaticLint.jl", :include_errors)
end

function _collect_include_diagnostics_v2!(rt, uri, stack, visited, guarded_visited, result)
    push!(stack, uri)

    # A `@testitem`/`@testmodule`/`@testsnippet` body runs in a module of its
    # own, so including a file there says nothing about whether the same file
    # was included elsewhere: each body gets its own visited sets, keyed by the
    # macrocall offset. Including the same file twice *within* one body is
    # still a duplicate, and so is a repeat further down that body's include
    # subtree, which inherits these sets.
    testitem_visited = Dict{Int,Tuple{Set{URI},Set{URI}}}()
    runtime_targets = derived_file_include_data_v2(rt, uri).runtime_targets

    for (offset, span, target, guarded, testitem_ctx) in derived_file_include_records(rt, uri)
        seen, guarded_seen = testitem_ctx === nothing ?
            (visited, guarded_visited) :
            get!(() -> (Set{URI}(), Set{URI}()), testitem_visited, testitem_ctx)

        if target === nothing
            # An unattributable include: the target is analyzed without this
            # module's context and bare missing-reference checking is
            # unreliable in this module (see
            # `derived_module_has_computed_include`). One honest notice here
            # replaces the storm of false missing_reference positives the
            # unattributed file would otherwise produce. Guarded includes
            # (`const depsjl = joinpath(...); isfile(depsjl) && include(depsjl)`)
            # abstain like the rest; the missing-reference relaxation applies
            # either way.
            #
            # Two flavors: a LITERAL path inside a function body (spliced at
            # run time — the SciML `@safetestset … include("x.jl")` thunks) is
            # a runtime boundary whose target can still be existence-checked;
            # everything else is a computed path.
            rtarget = get(runtime_targets, offset, nothing)
            if !guarded
                code = if rtarget !== nothing
                    derived_text_file_content(rt, rtarget) === nothing ?
                        StaticLint.MissingFile : :runtime
                else
                    :computed
                end
                push!(get!(result, uri, Diagnostic[]), _include_diagnostic_v2(offset, span, code))
            end
            continue
        end

        if derived_text_file_content(rt, target) === nothing
            # A guarded include's condition makes file structure runtime-
            # dependent (`isfile(deps) && include(deps)`, the standard shape
            # for Pkg.build-generated deps.jl files): whether the target
            # should exist statically is unknowable, so abstain.
            guarded || push!(get!(result, uri, Diagnostic[]), _include_diagnostic_v2(offset, span, StaticLint.MissingFile))
            continue
        end

        if target in stack
            push!(get!(result, uri, Diagnostic[]), _include_diagnostic_v2(offset, span, StaticLint.IncludeLoop))
            continue
        end

        if target in seen
            if guarded || target in guarded_seen
                # Abstain when either side of the duplication is conditional:
                # this include is guarded (`@isdefined(X) || include("x.jl")`
                # is idiomatic double-inclusion protection), or every prior
                # include of the target was — then this is the canonical
                # include, not a duplicate. The latter pardon is spent here,
                # so a further unconditional include is a real duplicate.
                guarded || delete!(guarded_seen, target)
            else
                push!(get!(result, uri, Diagnostic[]), _include_diagnostic_v2(offset, span, StaticLint.DuplicateInclude))
            end
            continue
        end

        push!(seen, target)
        guarded && push!(guarded_seen, target)
        _collect_include_diagnostics_v2!(rt, target, stack, seen, guarded_seen, result)
    end

    pop!(stack)

    return result
end

"""
    derived_all_include_diagnostics_v2(rt)

Compute include-graph diagnostics (`DuplicateInclude`, `IncludeLoop`,
`MissingFile`) for the whole workspace, keyed by the URI of the file that
contains the offending `include(...)` statement.

This is a purely structural analysis over the include graph and does not depend
on a project/environment, so it is reported even for files that are not part of
a package.
"""
Salsa.@derived function derived_all_include_diagnostics_v2(rt)
    @debug "derived_all_include_diagnostics_v2"

    result = Dict{URI,Vector{Diagnostic}}()

    for root in derived_roots(rt)
        stack = URI[]
        visited = Set{URI}([root])
        guarded_visited = Set{URI}()
        _collect_include_diagnostics_v2!(rt, root, stack, visited, guarded_visited, result)
    end

    # The same statement can be reached from multiple roots; deduplicate.
    for ds in values(result)
        unique!(ds)
    end

    return result
end

Salsa.@derived function derived_include_diagnostics_v2(rt, uri)
    all_diags = derived_all_include_diagnostics_v2(rt)

    return get(all_diags, uri, Diagnostic[])
end
