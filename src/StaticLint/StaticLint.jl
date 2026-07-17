module StaticLint

import ..derived_has_file
import ..derived_julia_legacy_syntax_tree
import ..derived_include_dict
import ..ItemRef

using AutoHashEquals: @auto_hash_equals

function hasfile end

include("exception_types.jl")

using ..SymbolServer, CSTParser, ..URIs2
using ..URIs2: URI

using CSTParser: EXPR, isidentifier, setparent!, valof, headof, hastrivia, parentof, isoperator, ispunctuation, to_codeobject
# CST utils
using CSTParser: is_getfield, isassignment, isdeclaration, isbracketed, iskwarg, iscall, iscurly, isunarycall, isunarysyntax, isbinarycall, isbinarysyntax, issplat, defines_function, is_getfield_w_quotenode, iswhere, iskeyword, isstringliteral, isparameters, isnonstdid, istuple
using ..SymbolServer: VarRef

const noname = EXPR(:noname, nothing, nothing, 0, 0, nothing, nothing, nothing)

"""
    AbstractModuleContext

Marker supertype for the per-file traversal's module-resolution handles.
StaticLint itself only ever routes values of this type around (seeded root
scope `.modules`, `resolve_ref_from_module`, `_get_field`); the concrete
`TreeModuleContext` — and every method that actually consults the module
tree — lives outside StaticLint, in `layer_file_analysis.jl`.
"""
abstract type AbstractModuleContext end

"""
    child_module_context(ctx::AbstractModuleContext, name::String)

The context for a module named `name` declared inside `ctx`'s module. Used
when the per-file traversal enters a `module` declared in the analyzed file
(see `seed_module_scope_context!`). Implemented by the concrete context type.
"""
function child_module_context end

"""
    TreeRef

Plain-data reference target for a name resolved through the module tree in
the per-file traversal mode: what `Meta.ref` points at instead of a `Binding`
or `SymbolServer.SymStore` when the resolution came from
`derived_module_visible_names`. Deliberately carries no `Binding`/`EXPR`
(they would alias other files' syntax trees) and no runtime handle — only
the resolved name, its item kind (or `:module`/`:external_symbol`), the
declaring `ItemRef` (when the name traces back to a tree declaration), and
the origin module path.
"""
@auto_hash_equals struct TreeRef
    name::String
    kind::Symbol
    item::Union{Nothing,ItemRef}
    origin_module::Vector{String}
end

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
    ref::Union{Nothing,Binding,SymbolServer.SymStore,TreeRef}
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

"""
    TestSetupInfo

Holds pre-computed semantic information for a `@testmodule` or `@testsnippet`
declaration. Used by `handle_macro` to resolve `setup=[...]` references in
`@testitem` macros.

- `kind`: `:module` for `@testmodule`, `:snippet` for `@testsnippet`
- `binding`: For modules, the `Binding` of the module definition (injected into scope.modules).
             For snippets, `nothing` (snippet body is inlined directly).
- `body_exprs`: The CSTParser EXPR nodes of the setup's body block. For snippets,
                these are `process_EXPR`'d directly in the `@testitem`'s scope. For modules,
                this is `nothing` (the module binding handles it).
- `scope`: For modules, the `Scope` of the module. For snippets, `nothing`.
"""
struct TestSetupInfo
    kind::Symbol  # :module or :snippet
    binding::Union{Nothing,Binding}
    body_exprs::Union{Nothing,Vector{EXPR}}
    scope::Union{Nothing,Scope}
end

getsymbols(env::ExternalEnv) = env.symbols
getsymbolextendeds(env::ExternalEnv) = env.extended_methods

getsymbols(state::TraverseState) = getsymbols(state.env)
getsymbolextendeds(state::TraverseState) = getsymbolextendeds(state.env)

mutable struct Toplevel{RT} <: TraverseState
    uri::URI
    included_files::Vector{URI}
    all_included_files::Set{URI}
    scope::Scope
    in_modified_expr::Bool
    modified_exprs::Union{Nothing,Vector{EXPR}}
    delayed::Vector{EXPR}
    resolveonly::Vector{EXPR}
    env::ExternalEnv
    workspace_packages::Dict{String,Any}
    test_setups::Dict{Symbol,TestSetupInfo}
    self_package_name::Union{Nothing,String}
    # Whether `followinclude` traverses into included files (the whole-closure
    # pass) or returns immediately (the per-file traversal mode, where included
    # files' names come from the module tree instead).
    follow_includes::Bool
    flags::Int
    meta_dict::Dict{UInt64,Meta}
    runtime::RT
end

getpath(state::Toplevel) = URIs2.uri2filepath(state.uri)

Toplevel(uri, included_files, all_included_files, scope, in_modified_expr, modified_exprs, delayed, resolveonly, env, workspace_packages, meta_dict, runtime) =
    Toplevel(uri, included_files, all_included_files, scope, in_modified_expr, modified_exprs, delayed, resolveonly, env, workspace_packages, Dict{Symbol,TestSetupInfo}(), nothing, true, 0, meta_dict, runtime)

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
    if CSTParser.defines_function(x) || CSTParser.defines_anon_function(x) || CSTParser.defines_macro(x) || headof(x) === :export || headof(x) === :public
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
    workspace_packages::Dict{String,Any}
    flags::Int
    meta_dict::Dict{UInt64,Meta}
    urefs::Vector{EXPR} # refs that failed to resolve
    deferred_unused::Vector{Tuple{Binding,Scope}} # unused checks pending parent-scope completion
end

Delayed(scope, env, workspace_packages, meta_dict, flags=0) = Delayed(scope, env, workspace_packages, flags, meta_dict, EXPR[], Tuple{Binding,Scope}[])

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
        retry_urefs!(state)
        for b in values(state.scope.names)
            infer_type_by_use(b, state.env, meta_dict)
            # Defer the unused-binding check until the enclosing scope has been
            # fully traversed: a binding may be captured by a closure that is
            # defined textually later (see retry_urefs!).
            push!(state.deferred_unused, (b, state.scope))
        end
        state.scope = s0
    end
    return state.scope
end

mutable struct ResolveOnly <: TraverseState
    scope::Scope
    env::ExternalEnv
    workspace_packages::Dict{String,Any}
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

With `module_context` given, the pass runs in per-file traversal mode: the
seeded root scope's `.modules` contains `:__tree__ => module_context` in
addition to the Base/Core stores — so `resolve_ref`'s existing scope.modules
loop resolves non-local names through the module tree, after file-local
scopes and the Base/Core stores — and includes are NOT followed
(`follow_includes = false`; included files' names come from the tree).
"""
function semantic_pass(uri, cst, env, meta_dict, rt, modified_expr = nothing; workspace_packages = Dict{String,Any}(), test_setups = Dict{Symbol,TestSetupInfo}(), self_package_name::Union{Nothing,String} = nothing, module_context::Union{Nothing,AbstractModuleContext} = nothing)
    root_modules = Dict{Symbol,Any}(:Base => env.symbols[:Base], :Core => env.symbols[:Core])
    module_context !== nothing && (root_modules[:__tree__] = module_context)
    setscope!(cst, Scope(nothing, cst, Dict(), root_modules, nothing), meta_dict)
    state = Toplevel(uri, [uri], Set([uri]), scopeof(cst, meta_dict), modified_expr === nothing, modified_expr, EXPR[], EXPR[], env, workspace_packages, test_setups, self_package_name, module_context === nothing, 0, meta_dict, rt)
    process_EXPR(cst, state)
    unique!(state.delayed)
    for x in state.delayed
        if hasscope(x, meta_dict)
            ds = Delayed(scopeof(x, meta_dict), env, workspace_packages, meta_dict)
            traverse(x, ds)
            retry_urefs!(ds)
            for (k, b) in scopeof(x, meta_dict).names
                infer_type_by_use(b, env, meta_dict)
                check_unused_binding(b, scopeof(x, meta_dict), meta_dict)
            end
        else
            ds = Delayed(retrieve_delayed_scope(x, meta_dict), env, workspace_packages, meta_dict)
            traverse(x, ds)
            retry_urefs!(ds)
        end
        for (b, sc) in ds.deferred_unused
            check_unused_binding(b, sc, meta_dict)
        end
    end
    if state.resolveonly !== nothing
        unique!(state.resolveonly)
        for x in state.resolveonly
            # process_EXPR (not traverse) so that resolve_import re-runs on the
            # scheduled expression itself: for a file-toplevel import statement
            # there is no enclosing module in resolveonly to revisit it, and
            # traverse would only descend into its children.
            if hasscope(x, meta_dict)
                process_EXPR(x, ResolveOnly(scopeof(x, meta_dict), env, workspace_packages, meta_dict))
            else
                process_EXPR(x, ResolveOnly(retrieve_delayed_scope(x, meta_dict), env, workspace_packages, meta_dict))
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
    # per-file traversal mode: included files are analyzed separately, their
    # names resolve through the module tree context
    state.follow_includes || return

    meta_dict = state.meta_dict
    rt = state.runtime
    include_dict = derived_include_dict(state.runtime, state.uri)

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
        # Circular- and duplicate-include detection (and the corresponding
        # diagnostics) is handled structurally in `derived_all_include_diagnostics`,
        # independently of the semantic pass. Here we only use the same checks as
        # recursion guards so the traversal terminates and does not re-process a
        # file that was already included.
        if target_uri in state.included_files
            return
        end

        if target_uri in state.all_included_files
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
        push!(state.all_included_files, state.uri)
    #     root_dict[state.file] = root_dict[oldfile]
        cst_new_file = derived_julia_legacy_syntax_tree(rt, target_uri)
        setscope!(cst_new_file, nothing, meta_dict)
        process_EXPR(cst_new_file, state)
        state.uri = old_uri
        pop!(state.included_files)
    # TODO Understand this original code better
    # elseif !is_in_fexpr(x, CSTParser.defines_function) && !isempty(init_path)
    elseif !is_in_fexpr(x, CSTParser.defines_function)
        # MissingFile is likewise reported structurally; nothing to do here.
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
