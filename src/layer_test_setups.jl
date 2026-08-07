# Plain-data index of @testmodule/@testsnippet declarations, per package,
# flattened from a normal-passes analysis run over each body. The per-file
# analysis injects setups into @testitem scopes from this index (via
# StaticLint.test_setup_info) — never from another file's EXPRs, which must
# not survive into a frozen FileAnalysis.

"""
    TestSetupData

One `@testmodule` or `@testsnippet` declaration, as plain data flattened
from a normal-passes analysis of the body: `kind` is `:module`/`:snippet`,
`file` the declaring file, `bound_names` the sorted names the body scope
binds, `exported_names` the sorted names a top-level `export a, b` makes
public (relevant for `:module` setups: TestItemRunner injects a testmodule
via `using ..Setups.TM`, which brings TM's EXPORTS — not its full member
set — into the referencing testitem). `wildcard_packages` are the packages
a wildcard `using X` resolved against (env store or module tree); a
referencing `@testitem` re-attaches them into its own scope.
`has_unresolved_wildcard` is `true` when a wildcard `using` resolved
against nothing — the item must then suppress bare missing-ref checks
rather than trust the name sets.
"""
@auto_hash_equals struct TestSetupData
    name::Symbol
    kind::Symbol
    file::URI
    bound_names::Vector{String}
    exported_names::Vector{String}
    wildcard_packages::Vector{String}
    has_unresolved_wildcard::Bool
end

# A top-level statement wrapped in a docstring macrocall (`"""doc""" x`)
# binds nothing itself; unwrap to the wrapped statement `x` so callers collect
# names/enumerability from what actually executes. Mirrors
# `_doc_wrapped_item` (layer_inventory.jl) one level deep.
function _setup_unwrap_doc(a)
    a isa CSTParser.EXPR || return a
    CSTParser.ismacrocall(a) || return a
    (a.args !== nothing && length(a.args) == 4 && StaticLint.is_doc_macro_name(a.args[1])) || return a
    return a.args[4]
end

# The name(s) a top-level `export a, b` statement makes public.
function _setup_export_names!(names, a)
    a isa CSTParser.EXPR || return
    CSTParser.headof(a) === :export || return
    a.args === nothing && return
    for e in a.args
        CSTParser.isidentifier(e) || continue
        nm = StaticLint.valofid(e)
        nm !== nothing && push!(names, nm)
    end
    return
end

function _setup_toplevel_export_names(body::CSTParser.EXPR)
    names = String[]
    body.args === nothing && return names
    for raw in body.args
        _setup_export_names!(names, _setup_unwrap_doc(raw))
    end
    return sort!(unique!(names))
end

"""
    derived_test_setups_in_file(rt, uri) -> Vector{TestSetupData}

The `@testmodule`/`@testsnippet` declarations at `uri`'s top level. Per-file
so a keystroke in one file backdates every other file's contribution.
"""
Salsa.@derived function derived_test_setups_in_file(rt, uri)
    @debug "derived_test_setups_in_file" uri=uri

    result = TestSetupData[]
    cst = derived_julia_legacy_syntax_tree(rt, uri)
    cst.args === nothing && return result

    # One env/tree frame for all setups in the file, built lazily so files
    # without setups (the common case) never pay for the env lookup.
    frame = nothing
    for arg in cst.args
        (CSTParser.ismacrocall(arg) && arg.args !== nothing && length(arg.args) >= 4) || continue
        # _macro_name_string unwraps the qualified `X.@testmodule` form, so the
        # scan recognizes exactly what StaticLint's matchers isolate.
        n = _macro_name_string(arg.args[1])
        kind = n == "@testmodule" ? :module : n == "@testsnippet" ? :snippet : nothing
        kind === nothing && continue
        # args[2] is CSTParser's NOTHING line-info placeholder; the name is args[3]
        name_expr = arg.args[3]
        CSTParser.isidentifier(name_expr) || continue
        setup_name = CSTParser.str_value(name_expr)
        setup_name isa AbstractString || continue
        body = nothing
        for i in 4:length(arg.args)
            if arg.args[i] isa CSTParser.EXPR && CSTParser.headof(arg.args[i]) === :block
                body = arg.args[i]
                break
            end
        end
        body === nothing && continue

        if frame === nothing
            root = derived_best_root_for_uri(rt, uri)
            project_uri = root === nothing ? nothing : derived_project_uri_for_root(rt, root)
            env = project_uri === nothing ? derived_stdlib_only_env(rt) : derived_environment(rt, project_uri)
            path = root === nothing ? nothing : derived_file_module_path(rt, root, uri)
            frame = (env, root, path)
        end
        env, root, path = frame

        # Run the normal passes over the WHOLE macrocall (not just its body
        # block): handle_macro's own @testmodule/@testsnippet dispatch then
        # builds the module-like scope exactly as it would during a real
        # file-level analysis, which is what keeps Base/Core (and the tree
        # context) reachable — a bare :block root has no such protection and
        # gets its seeded scope.modules cleared by the generic scope-reset
        # path before any statement runs. `simulate_testitem_runtime=false`:
        # this pass has no enclosing testitem, so the `using Test`/`using
        # <package>` simulation must not run — it would leak Test's exports
        # into this setup's own bound-names/wildcards data — and a
        # `@testitem setup=[...]` nested in the body must not resolve its
        # setups either, or it re-enters this same query and cycles. The
        # meta is local and discarded, so the pass may keep its context
        # handles (strip_contexts=false), which the wildcard flattening
        # below needs to see in scope.modules.
        ctx = path === nothing ? nothing : TreeModuleContext(rt, root, path)
        meta_dict = Dict{UInt64,StaticLint.Meta}()
        StaticLint.semantic_pass(uri, arg, env, meta_dict, rt; module_context=ctx, strip_contexts=false, simulate_testitem_runtime=false)
        StaticLint.mark_unresolved_imports!(arg, env, meta_dict)

        scope = StaticLint.scopeof(arg, meta_dict)
        bound = String[]
        wildcards = String[]
        unresolved = false
        if scope isa StaticLint.Scope
            append!(bound, keys(scope.names))
            if scope.modules isa Dict
                # Base/Core are pass-seeded, :__tree__ is the context handle;
                # everything else got there through a wildcard `using`.
                for k in keys(scope.modules)
                    k in (:Base, :Core, :__tree__) && continue
                    push!(wildcards, String(k))
                end
            end
            unresolved = scope.unresolved_wildcard_import
        end
        push!(result, TestSetupData(Symbol(setup_name), kind, uri,
            sort!(unique!(bound)), _setup_toplevel_export_names(body),
            sort!(unique!(wildcards)), unresolved))
    end
    return result
end

"""
    derived_test_setups(rt, package_folder_uri) -> Dict{Symbol,TestSetupData}

All test setups declared in files belonging to `package_folder_uri` — the
same file→package mapping (`derived_package_for_file`) the consumer keys
its lookups with. On duplicate names the lexicographically smallest file
URI wins (deterministic; the runner rejects duplicates anyway).
"""
Salsa.@derived function derived_test_setups(rt, package_folder_uri)
    @debug "derived_test_setups" package_folder_uri=package_folder_uri

    result = Dict{Symbol,TestSetupData}()
    files = sort(collect(derived_all_julia_files(rt)); by=string)
    for uri in files
        derived_package_for_file(rt, uri) == package_folder_uri || continue
        for s in derived_test_setups_in_file(rt, uri)
            haskey(result, s.name) || (result[s.name] = s)
        end
    end
    return result
end

"""
    derived_test_setup(rt, package_folder_uri, name) -> Union{Nothing,TestSetupData}

Per-name face over `derived_test_setups`: consumers depend on ONE setup's
value, so an edit that changes a different setup backdates them.
"""
Salsa.@derived function derived_test_setup(rt, package_folder_uri, name::Symbol)
    return get(derived_test_setups(rt, package_folder_uri), name, nothing)
end
