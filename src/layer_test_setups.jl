# Plain-data index of @testmodule/@testsnippet declarations, per package.
# The per-file analysis injects setups into @testitem scopes from this index
# (via StaticLint.test_setup_info) — never from another file's EXPRs, which
# must not survive into a frozen FileAnalysis.

"""
    TestSetupData

One `@testmodule` or `@testsnippet` declaration, as plain data: `kind` is
`:module`/`:snippet`, `file` the declaring file, `bound_names` the sorted,
unique names the setup's top level binds — declarations, assignments, and the
explicit leaves of a top-level `using X: a, b`/`import X: a as c` (the alias
for `as` forms, the leaf name otherwise). `exported_names` are the sorted,
unique names a top-level `export a, b` makes public (relevant for `:module`
setups: TestItemRunner injects a testmodule via `using ..Setups.TM`, which
brings TM's EXPORTS — not its full member set — into the referencing
testitem). `fully_enumerable` is `false` when the setup body contains a
top-level wildcard `using X`/`import X` (no explicit `: name` list) or an
unrecognized top-level macrocall — anything that can bind names this scan
cannot enumerate — so a consumer must fall back to suppressing bare
missing-ref checks entirely rather than trust `bound_names`/`exported_names`
as exhaustive.
"""
@auto_hash_equals struct TestSetupData
    name::Symbol
    kind::Symbol
    file::URI
    bound_names::Vector{String}
    exported_names::Vector{String}
    fully_enumerable::Bool
end

# The name an EXPR binds at a setup's top level, or `nothing`.
function _setup_bound_name(a)
    a isa CSTParser.EXPR || return nothing
    if CSTParser.defines_function(a) || CSTParser.defines_struct(a) ||
       CSTParser.defines_abstract(a) || CSTParser.defines_primitive(a) ||
       CSTParser.defines_macro(a) || CSTParser.defines_module(a)
        nm = CSTParser.get_name(a)
        return nm isa CSTParser.EXPR && CSTParser.isidentifier(nm) ? StaticLint.valofid(nm) : nothing
    elseif CSTParser.isassignment(a)
        return nothing # handled by _setup_collect_names! (tuple lhs binds several)
    elseif (CSTParser.headof(a) === :const || CSTParser.headof(a) === :global) &&
           a.args !== nothing && length(a.args) >= 1
        return _setup_bound_name(a.args[1])
    end
    return nothing
end

# Collect the names an assignment lhs binds (identifier, x::T, tuple, call for short-form functions).
function _setup_lhs_names!(names, l)
    l isa CSTParser.EXPR || return
    if CSTParser.isidentifier(l)
        n = StaticLint.valofid(l)
        n !== nothing && push!(names, n)
    elseif CSTParser.isdeclaration(l) && l.args !== nothing && length(l.args) >= 1
        _setup_lhs_names!(names, l.args[1])
    elseif (CSTParser.istuple(l) || CSTParser.isbracketed(l)) && l.args !== nothing
        for el in l.args
            _setup_lhs_names!(names, el)
        end
    elseif CSTParser.headof(l) === :call && l.args !== nothing && length(l.args) >= 1
        # Short-form function definition: tmf() = ...
        _setup_lhs_names!(names, l.args[1])
    end
    return
end

function _setup_collect_names!(names, a)
    a isa CSTParser.EXPR || return
    if CSTParser.isassignment(a) && a.args !== nothing && length(a.args) >= 1
        _setup_lhs_names!(names, a.args[1])
    elseif (CSTParser.headof(a) === :const || CSTParser.headof(a) === :global) &&
           a.args !== nothing && length(a.args) >= 1
        _setup_collect_names!(names, a.args[1])
    else
        n = _setup_bound_name(a)
        n !== nothing && push!(names, n)
    end
    return
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

# The explicit colon-form node of a top-level `using X: ...`/`import X: ...`
# (`a.args[1]` when headed by the `:` operator), or `nothing` for a wildcard
# `using X`/`import X` with no explicit name list.
function _setup_import_colon_form(a)
    a isa CSTParser.EXPR || return nothing
    (CSTParser.headof(a) === :using || CSTParser.headof(a) === :import) || return nothing
    (a.args !== nothing && length(a.args) >= 1) || return nothing
    first = a.args[1]
    first isa CSTParser.EXPR || return nothing
    (CSTParser.isoperator(CSTParser.headof(first)) && CSTParser.valof(CSTParser.headof(first)) == ":") || return nothing
    return first
end

# The name one colon-form leaf binds: for `... as y` the alias, otherwise the
# trailing identifier of the (possibly dotted) import path. Mirrors
# `ensure_synthetic_import_binding!`'s leaf handling (imports.jl) — same CST
# shape, name extraction instead of a synthetic binding.
function _import_colon_leaf_name(leaf)
    leaf isa CSTParser.EXPR || return nothing
    if CSTParser.headof(leaf) === :as
        (leaf.args !== nothing && length(leaf.args) == 2) || return nothing
        alias = leaf.args[2]
        return CSTParser.isidentifier(alias) ? StaticLint.valofid(alias) : nothing
    end
    (leaf.args === nothing || isempty(leaf.args)) && return nothing
    last_component = last(leaf.args)
    return CSTParser.isidentifier(last_component) ? StaticLint.valofid(last_component) : nothing
end

# The names an explicit top-level `using X: a, b`/`import X: a as c` binds.
# A wildcard form (no colon list) binds none here — it instead makes the
# setup `!fully_enumerable` (see `_setup_unenumerable_toplevel_stmt`).
function _setup_import_bound_names!(names, a)
    colon = _setup_import_colon_form(a)
    colon === nothing && return
    for i in 2:length(colon.args)
        nm = _import_colon_leaf_name(colon.args[i])
        nm !== nothing && push!(names, nm)
    end
    return
end

# Can `a` bind names this plain-CST scan cannot enumerate: a wildcard
# `using X`/`import X` (no explicit `: name` list), or any macrocall (which
# may bind arbitrary names, e.g. `@enum`)? Doc-wrapped statements are
# unwrapped by the caller before this is checked, so a docstring above a
# recognized definition never trips it.
function _setup_unenumerable_toplevel_stmt(a)
    a isa CSTParser.EXPR || return false
    if CSTParser.headof(a) === :using || CSTParser.headof(a) === :import
        return _setup_import_colon_form(a) === nothing
    elseif CSTParser.ismacrocall(a)
        return true
    end
    return false
end

function _setup_toplevel_bound_names(body::CSTParser.EXPR)
    names = String[]
    body.args === nothing && return names
    for raw in body.args
        a = _setup_unwrap_doc(raw)
        _setup_collect_names!(names, a)
        _setup_import_bound_names!(names, a)
    end
    return sort!(unique!(names))
end

function _setup_toplevel_export_names(body::CSTParser.EXPR)
    names = String[]
    body.args === nothing && return names
    for raw in body.args
        _setup_export_names!(names, _setup_unwrap_doc(raw))
    end
    return sort!(unique!(names))
end

function _setup_toplevel_fully_enumerable(body::CSTParser.EXPR)
    body.args === nothing && return true
    for raw in body.args
        _setup_unenumerable_toplevel_stmt(_setup_unwrap_doc(raw)) && return false
    end
    return true
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
    for arg in cst.args
        (CSTParser.ismacrocall(arg) && arg.args !== nothing && length(arg.args) >= 4) || continue
        mname = arg.args[1]
        CSTParser.isidentifier(mname) || continue
        n = CSTParser.valof(mname)
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
        push!(result, TestSetupData(Symbol(setup_name), kind, uri,
            _setup_toplevel_bound_names(body), _setup_toplevel_export_names(body),
            _setup_toplevel_fully_enumerable(body)))
    end
    return result
end

"""
    derived_test_setups(rt, package_folder_uri) -> Dict{Symbol,TestSetupData}

All test setups declared in files under `package_folder_uri`. On duplicate
names the lexicographically smallest file URI wins (deterministic; the
runner rejects duplicates anyway).
"""
Salsa.@derived function derived_test_setups(rt, package_folder_uri)
    @debug "derived_test_setups" package_folder_uri=package_folder_uri

    result = Dict{Symbol,TestSetupData}()
    package_folder_uri.scheme == "file" || return result
    package_folder_path = lowercase(uri2filepath(package_folder_uri))
    # A path-separator-terminated prefix, so `/pkg` doesn't match `/pkgfoo`.
    prefix = endswith(package_folder_path, "/") ? package_folder_path : package_folder_path * "/"
    files = sort(collect(derived_all_julia_files(rt)); by=string)
    for uri in files
        uri.scheme == "file" || continue
        startswith(lowercase(uri2filepath(uri)), prefix) || continue
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
