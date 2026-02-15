module StaticLint

import ..derived_has_file
import ..derived_julia_legacy_syntax_tree
import ..input_canonical_uri

function hasfile end

include("exception_types.jl")

using ..SymbolServer, CSTParser, ..URIs2
using ..URIs2: URI

using CSTParser: EXPR, isidentifier, setparent!, valof, headof, hastrivia, parentof, isoperator, ispunctuation, to_codeobject
# CST utils
using CSTParser: is_getfield, isassignment, isdeclaration, isbracketed, iskwarg, iscall, iscurly, isunarycall, isunarysyntax, isbinarycall, isbinarysyntax, issplat, defines_function, is_getfield_w_quotenode, iswhere, iskeyword, isstringliteral, isparameters, isnonstdid, istuple
using ..SymbolServer: VarRef

const noname = EXPR(:noname, nothing, nothing, 0, 0, nothing, nothing, nothing)

include("coretypes.jl")
include("bindings.jl")
include("scope.jl")
include("subtypes.jl")
include("methodmatching.jl")
include("traverse.jl")

const LARGE_FILE_LIMIT = 2_000_000 # bytes

mutable struct Meta
    binding::Union{Nothing,Binding}
    scope::Union{Nothing,Scope}
    ref::Union{Nothing,Binding,SymbolServer.SymStore}
    error
end
Meta() = Meta(nothing, nothing, nothing, nothing)

function Base.show(io::IO, m::Meta)
    m.binding !== nothing && show(io, m.binding)
    m.ref !== nothing && printstyled(io, " * ", color = :red)
    m.scope !== nothing && printstyled(io, " new scope", color = :green)
    m.error !== nothing && printstyled(io, " lint ", color = :red)
end
hasmeta(x::EXPR, meta_dict::Dict{UInt64,StaticLint.Meta}) = haskey(meta_dict, objectid(x))
getmeta(x::EXPR, meta_dict) = meta_dict[objectid(x)]
ensuremeta(x::EXPR, meta_dict) = hasmeta(x, meta_dict) || (meta_dict[objectid(x)] = Meta())
hasbinding(m::Meta) = m.binding isa Binding
hasref(m::Meta) = m.ref !== nothing
hasscope(m::Meta) = m.scope isa Scope
scopeof(m::Meta) = m.scope
bindingof(m::Meta) = m.binding


"""
    ExternalEnv

Holds a representation of an environment cached by SymbolServer.
"""
mutable struct ExternalEnv
    symbols::SymbolServer.EnvStore
    extended_methods::Dict{SymbolServer.VarRef,Vector{SymbolServer.VarRef}}
    project_deps::Vector{Symbol}
end

getsymbols(env::ExternalEnv) = env.symbols
getsymbolextendeds(env::ExternalEnv) = env.extended_methods

getsymbols(state::TraverseState) = getsymbols(state.env)
getsymbolextendeds(state::TraverseState) = getsymbolextendeds(state.env)

mutable struct Toplevel{RT} <: TraverseState
    uri::URI
    included_files::Vector{URI}
    scope::Scope
    in_modified_expr::Bool
    modified_exprs::Union{Nothing,Vector{EXPR}}
    delayed::Vector{EXPR}
    resolveonly::Vector{EXPR}
    env::ExternalEnv
    flags::Int
    meta_dict::Dict{UInt64,Meta}
    include_dict::Dict{UInt64,URI}
    runtime::RT
end

getpath(state::Toplevel) = URIs2.uri2filepath(state.uri)

Toplevel(uri, included_files, scope, in_modified_expr, modified_exprs, delayed, resolveonly, env, meta_dict, include_dict, runtime) =
    Toplevel(uri, included_files, scope, in_modified_expr, modified_exprs, delayed, resolveonly, env, 0, meta_dict, include_dict, runtime)

function process_EXPR(x::EXPR, state::Toplevel)
    resolve_import(x, state)
    mark_bindings!(x, state)
    add_binding(x, state)
    mark_globals(x, state)
    handle_macro(x, state)
    s0 = scopes(x, state)
    resolve_ref(x, state)
    followinclude(x, state)

    old_in_modified_expr = state.in_modified_expr
    if state.modified_exprs !== nothing && x in state.modified_exprs
        state.in_modified_expr = true
    end
    if CSTParser.defines_function(x) || CSTParser.defines_macro(x) || headof(x) === :export || headof(x) === :public
        if state.in_modified_expr
            push!(state.delayed, x)
        else
            push!(state.resolveonly, x)
        end
    else
        old = flag!(state, x)
        traverse(x, state)
        state.flags = old
    end

    state.in_modified_expr = old_in_modified_expr
    state.scope != s0 && (state.scope = s0)
    return state.scope
end

mutable struct Delayed <: TraverseState
    scope::Scope
    env::ExternalEnv
    flags::Int
    meta_dict::Dict{UInt64,Meta}
end

Delayed(scope, env, meta_dict) = Delayed(scope, env, 0, meta_dict)

function process_EXPR(x::EXPR, state::Delayed)
    meta_dict = state.meta_dict

    mark_bindings!(x, state)
    add_binding(x, state)
    mark_globals(x, state)
    handle_macro(x, state)
    s0 = scopes(x, state)

    resolve_ref(x, state)

    old = flag!(state, x)
    traverse(x, state)
    state.flags = old
    if state.scope != s0
        for b in values(state.scope.names)
            infer_type_by_use(b, state.env, meta_dict)
            check_unused_binding(b, state.scope, meta_dict)
        end
        state.scope = s0
    end
    return state.scope
end

mutable struct ResolveOnly <: TraverseState
    scope::Scope
    env::ExternalEnv
    meta_dict::Dict{UInt64,Meta}
end

function process_EXPR(x::EXPR, state::ResolveOnly)
    meta_dict = state.meta_dict

    if hasscope(x, meta_dict)
        s0 = state.scope
        state.scope = scopeof(x, meta_dict)
    else
        s0 = state.scope
    end

    # NEW: late import resolution (idempotent for already-resolved imports)
    resolve_import(x, state)

    resolve_ref(x, state)

    traverse(x, state)
    if state.scope != s0
        state.scope = s0
    end
    return state.scope
end

# feature flags that can disable or enable functionality further down in the CST
const NO_NEW_BINDINGS = 0x1

function flag!(state, x::EXPR)
    old = state.flags
    if CSTParser.ismacrocall(x) && (valof(x.args[1]) == "@." || valof(x.args[1]) == "@__dot__")
        state.flags |= NO_NEW_BINDINGS
    end
    return old
end

"""
    semantic_pass(file, modified_expr=nothing)

Performs a semantic pass across a project from the entry point `file`. A first pass traverses the top-level scope after which secondary passes handle delayed scopes (e.g. functions). These secondary passes can be, optionally, very light and only seek to resovle references (e.g. link symbols to bindings). This can be done by supplying a list of expressions on which the full secondary pass should be made (`modified_expr`), all others will receive the light-touch version.
"""
function semantic_pass(uri, cst, env, meta_dict, include_dict, rt, modified_expr = nothing)
    setscope!(cst, Scope(nothing, cst, Dict(), Dict{Symbol,Any}(:Base => env.symbols[:Base], :Core => env.symbols[:Core]), nothing), meta_dict)
    state = Toplevel(uri, [uri], scopeof(cst, meta_dict), modified_expr === nothing, modified_expr, EXPR[], EXPR[], env, meta_dict, include_dict, rt)
    process_EXPR(cst, state)
    for x in state.delayed
        if hasscope(x, meta_dict)
            traverse(x, Delayed(scopeof(x, meta_dict), env, meta_dict))
            for (k, b) in scopeof(x, meta_dict).names
                infer_type_by_use(b, env, meta_dict)
                check_unused_binding(b, scopeof(x, meta_dict), meta_dict)
            end
        else
            traverse(x, Delayed(retrieve_delayed_scope(x, meta_dict), env, meta_dict))
        end
    end
    if state.resolveonly !== nothing
        for x in state.resolveonly
            if hasscope(x, meta_dict)
                traverse(x, ResolveOnly(scopeof(x, meta_dict), env, meta_dict))
            else
                traverse(x, ResolveOnly(retrieve_delayed_scope(x, meta_dict), env, meta_dict))
            end
        end
    end
end

function check_filesize(x, path, meta_dict)
    nb = try
        filesize(path)
    catch
        seterror!(x, FileNotAvailable, meta_dict)
        return false
    end

    toobig = nb > LARGE_FILE_LIMIT
    if toobig
        seterror!(x, FileTooBig, meta_dict)
    end
    return !toobig
end

"""
    followinclude(x, state)

Checks whether the arguments of a call to `include` can be resolved to a path.
If successful it checks whether a file with that path is loaded on the server
or a file exists on the disc that can be loaded.
If this is successful it traverses the code associated with the loaded file.
"""
function followinclude(x, state::Toplevel)
    meta_dict = state.meta_dict
    rt = state.runtime
    include_dict = state.include_dict

    if !haskey(include_dict, objectid(x))
        return
    end

    target_uri = include_dict[objectid(x)]

    # # this runs on the `include` symbol instead of a function call so that we
    # # can be sure the ref has already been resolved
    # isinclude = isincludet = false
    # p = x
    # if isidentifier(x) && hasref(x, meta_dict)
    #     r = getmeta(x, meta_dict).ref

    #     if is_in_fexpr(x, iscall)
    #         p = get_parent_fexpr(x, iscall)
    #         if r == refof_call_func(p, meta_dict)
    #             isinclude = r.name == SymbolServer.VarRef(SymbolServer.VarRef(nothing, :Base), :include)
    #             isincludet = r.name == SymbolServer.VarRef(SymbolServer.VarRef(nothing, :Revise), :includet)
    #         end
    #     end
    # end

    # if !(isinclude || isincludet)
    #     return
    # end

    # x = p

    # init_path = path = get_path(x, dirname(getpath(state)), meta_dict)
    # if path===nothing || isempty(path)
    # elseif isabspath(path)
    #     if hasfile(rt, path)
    #     # elseif canloadfile(state.server, path)
    #     #     if check_filesize(x, path)
    #     #         loadfile(state.server, path)
    #     #     else
    #     #         return
    #     #     end
    #     else
    #         path = ""
    #     end
    # elseif !isempty(getpath(state)) && isabspath(joinpath(dirname(getpath(state)), path))
    #     # Relative path from current
    #     if hasfile(rt, joinpath(dirname(getpath(state)), path))
    #         path = joinpath(dirname(getpath(state)), path)
    #     # elseif canloadfile(state.server, joinpath(dirname(getpath(state.file)), path))
    #     #     path = joinpath(dirname(getpath(state.file)), path)
    #     #     if check_filesize(x, path)
    #     #         loadfile(state.server, path)
    #     #     else
    #     #         return
    #     #     end
    #     else
    #         path = ""
    #     end
    # elseif !isempty((basepath = _is_in_basedir(getpath(state)); basepath))
    #     # Special handling for include method used within Base
    #     path = joinpath(basepath, path)
    #     if hasfile(rt, path)
    #         # skip
    #     # elseif canloadfile(state.server, path)
    #     #     loadfile(state.server, path)
    #     else
    #         path = ""
    #     end
    # else
    #     path = ""
    # end
  
    # TODO DA FIX
    if derived_has_file(rt, target_uri)
        if target_uri in state.included_files
            seterror!(x, IncludeLoop)
            return
        end

    #     f = getfile(state.server, path)

    #     if f.cst.fullspan > LARGE_FILE_LIMIT
    #         seterror!(x, FileTooBig)
    #         return
    #     end
        old_uri = state.uri
        state.uri = target_uri
        push!(state.included_files, state.uri)
    #     root_dict[state.file] = root_dict[oldfile]
        cst_new_file = derived_julia_legacy_syntax_tree(rt, target_uri)
        setscope!(cst_new_file, nothing, meta_dict)
        process_EXPR(cst_new_file, state)
        state.uri = old_uri
        pop!(state.included_files)
    # TODO Understand this original code better
    # elseif !is_in_fexpr(x, CSTParser.defines_function) && !isempty(init_path)    
    elseif !is_in_fexpr(x, CSTParser.defines_function)
        seterror!(x, MissingFile)
    end
end

include("imports.jl")
include("references.jl")
include("macros.jl")
include("linting/checks.jl")
include("type_inf.jl")
include("utils.jl")
include("includes.jl")
end
