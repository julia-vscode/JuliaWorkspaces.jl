# Plain-data index of @testmodule/@testsnippet declarations, per package.
# The per-file analysis injects setups into @testitem scopes from this index
# (via StaticLint.test_setup_info) — never from another file's EXPRs, which
# must not survive into a frozen FileAnalysis.

"""
    TestSetupData

One `@testmodule` or `@testsnippet` declaration, as plain data: `kind` is
`:module`/`:snippet`, `file` the declaring file, `bound_names` the sorted,
unique names the setup's top level binds (declarations and assignments; names
introduced by macros or `using` inside the setup are not enumerable here, so
member misses must stay un-flagged downstream).
"""
@auto_hash_equals struct TestSetupData
    name::Symbol
    kind::Symbol
    file::URI
    bound_names::Vector{String}
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

function _setup_toplevel_bound_names(body::CSTParser.EXPR)
    names = String[]
    body.args === nothing && return names
    for a in body.args
        _setup_collect_names!(names, a)
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
        push!(result, TestSetupData(Symbol(setup_name), kind, uri, _setup_toplevel_bound_names(body)))
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
    package_folder_path = lowercase(uri2filepath(package_folder_uri))
    files = sort(collect(derived_all_julia_files(rt)); by=string)
    for uri in files
        uri.scheme == "file" || continue
        startswith(lowercase(uri2filepath(uri)), package_folder_path) || continue
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
