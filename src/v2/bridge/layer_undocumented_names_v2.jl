# The undocumented_public_name rule (Aqua.jl's `test_undocumented_names`,
# statically): every `export`ed / `public` name a workspace package declares
# needs a docstring, and so does every submodule (its name is a public name of
# itself, per `Docs.undocumented_names`); the root module is exempt (Julia
# falls back to the README). Names a module merely re-exports (bound by
# `using`, not declared) are skipped — their docstrings live upstream.
#
# Three pieces, mirroring the position-free/position-class split used
# everywhere else: a per-file query of the names that RECEIVE a docstring, a
# per-root query of the public names that lack one (both position-free, both
# backdate), and a per-file emission walk that reattaches byte ranges through
# a fresh parse at the last mile.
#
# In src/v2/bridge/ because the rule is v2-only (its emission lives only in
# `derived_diagnostics_v2`) while the queries read the v1 pipeline's module
# tree (`derived_workspace_package_roots`, `derived_roots_for_uri`,
# `derived_file_module_path`), names the v2 boundary guard forbids in src/v2/
# itself.

# ── Documented names of one file ────────────────────────────────────────────

# The name a doc-attached expression documents, or `nothing` (a qualified
# target documents a foreign binding; unknown shapes stay silent). Macros
# document `@name`, matching how export statements spell them.
function _documented_target_name(node::SyntaxNode)
    k = kind(node)
    if k === K"Identifier"
        return node.val isa Symbol ? string(node.val) : nothing
    end
    if k === K"MacroName"
        return node.val isa Symbol ? string(node.val) : nothing
    end
    JuliaSyntax.is_leaf(node) && return nothing
    cs = children(node)
    isempty(cs) && return nothing

    if k === K"function" || k === K"macro"
        name = _documented_target_name(cs[1])
        name === nothing && return nothing
        return k === K"macro" ? "@" * name : name
    elseif k === K"call" || k === K"where" || k === K"curly"
        return _documented_target_name(cs[1])
    elseif k === K"::"
        # A return-type annotation on a signature (2 children) unwraps to the
        # signature; a bare `(o::T)` callable head documents no name.
        return length(cs) == 2 ? _documented_target_name(cs[1]) : nothing
    elseif k === K"=" || k === K"const" || k === K"global" || k === K"local"
        return _documented_target_name(cs[1])
    elseif k === K"struct" || k === K"abstract" || k === K"primitive"
        head = cs[1]
        while !JuliaSyntax.is_leaf(head) && (kind(head) === K"<:" || kind(head) === K"curly")
            isempty(children(head)) && return nothing
            head = children(head)[1]
        end
        return _documented_target_name(head)
    elseif k === K"module"
        return _documented_target_name(cs[1])
    elseif k === K"macrocall"
        # `"..." @kwdef struct S` documents what the macro wraps.
        return _documented_target_name(cs[end])
    elseif k === K"doc"
        return length(cs) == 2 ? _documented_target_name(cs[2]) : nothing
    end
    return nothing
end

function _collect_documented_names!(names::Set{String}, node::SyntaxNode)
    JuliaSyntax.is_leaf(node) && return nothing
    k = kind(node)
    cs = children(node)
    if k === K"doc" && length(cs) == 2
        name = _documented_target_name(cs[2])
        name === nothing || push!(names, name)
    elseif k === K"macrocall" && length(cs) >= 3 && _macro_name(node) === Symbol("@doc")
        # `@doc "..." name` (and `Base.@doc`): the target is the last argument.
        name = _documented_target_name(cs[end])
        name === nothing || push!(names, name)
    end
    for c in cs
        _collect_documented_names!(names, c)
    end
    return nothing
end

"""
    derived_documented_names(rt, uri) -> Vector{String}

The names that receive a docstring anywhere in `uri` (doc-wrapped
definitions, bare `"...\n" name`, `@doc` forms), sorted. Position-free by
construction, so docstring-content and position edits backdate.
"""
Salsa.@derived function derived_documented_names(rt, uri)
    @debug "derived_documented_names" uri=uri

    content = derived_julia_source_view(rt, uri)
    content === nothing && return String[]

    tree, _ = parse_julia_syntax_tree(content)
    names = Set{String}()
    _collect_documented_names!(names, tree)
    return sort!(collect(names))
end

# ── Undocumented public names of one package root ───────────────────────────

"""
    struct UndocumentedPublicNames

The position-free finding set of one package root: `exports` maps a module's
absolute path to the exported/public names it declares without a docstring;
`modules` is the set of absolute paths of submodules without a module
docstring.
"""
@auto_hash_equals struct UndocumentedPublicNames
    exports::Dict{Vector{String},Vector{String}}
    modules::Set{Vector{String}}
end

const EMPTY_UNDOCUMENTED_PUBLIC_NAMES =
    UndocumentedPublicNames(Dict{Vector{String},Vector{String}}(), Set{Vector{String}}())

"""
    derived_undocumented_public_names(rt, root) -> UndocumentedPublicNames

The undocumented public surface of the package rooted at `root` (its
`src/<Name>.jl` entry file). A name counts as documented when any file whose
top level splices into its module documents it — which also covers module
docstrings, written in the file that DECLARES the submodule.
"""
Salsa.@derived function derived_undocumented_public_names(rt, root)
    @debug "derived_undocumented_public_names" root=root

    tree = derived_module_tree(rt, root)

    # The package's own module — the one named after the entry file — is
    # exempt like Aqua's root exemption: Julia documents it with the README.
    root_path = uri2filepath(root)
    entry_name = root_path === nothing ? nothing :
        replace(basename(root_path), r"\.jl$" => "")

    files_of = Dict{Vector{String},Vector{URI}}(n.path => n.files for n in tree.modules)

    # The files that physically contain code of module `path`: its own spliced
    # files plus every ancestor's — a `module` block's definitions live in the
    # file DECLARING the module, which splices at the parent's path (the
    # package's docstrings live in src/<Name>.jl, whose top level is the
    # synthetic root `[]`).
    function containing_files(path)
        files = URI[]
        for k in 0:length(path)
            append!(files, get(files_of, path[1:k], URI[]))
        end
        return files
    end

    documented_in(name, files) =
        any(name in derived_documented_names(rt, f) for f in files)

    exports = Dict{Vector{String},Vector{String}}()
    modules = Set{Vector{String}}()

    for node in tree.modules
        node.kind === :testitem && continue

        # A submodule needs a module docstring; its `module` statement lives at
        # the parent's context (the package's own module is exempt, like Aqua's
        # root exemption — the README is its fallback docstring).
        if node.kind === :module && !isempty(node.path) && node.path != [entry_name]
            if !documented_in(last(node.path), containing_files(node.path[1:end-1]))
                push!(modules, node.path)
            end
        end

        public_names = union(Set(node.exports), Set(node.publics))
        isempty(public_names) && continue

        undoc = String[]
        node_files = containing_files(node.path)
        for name in sort!(collect(public_names))
            # Not declared here: a re-export (documented upstream) or an
            # undefined name (missing_reference's finding).
            haskey(node.declared, name) || continue
            documented_in(name, node_files) && continue
            # A declared submodule's doc check lives above, against the right
            # file set; don't double-report it here.
            haskey(files_of, vcat(node.path, name)) && continue
            push!(undoc, name)
        end
        isempty(undoc) || (exports[node.path] = undoc)
    end

    isempty(exports) && isempty(modules) && return EMPTY_UNDOCUMENTED_PUBLIC_NAMES
    return UndocumentedPublicNames(exports, modules)
end

# ── Emission-time position reattachment ─────────────────────────────────────

_undoc_statement_name(node) =
    (kind(node) === K"Identifier" || kind(node) === K"MacroName") && node.val isa Symbol ?
        string(node.val) : nothing

function _walk_undocumented!(findings, node::SyntaxNode, path::Vector{String}, undoc::UndocumentedPublicNames)
    JuliaSyntax.is_leaf(node) && return nothing
    k = kind(node)
    cs = children(node)

    if k === K"module" && length(cs) >= 2
        name = _undoc_statement_name(cs[1])
        name === nothing && return nothing
        newpath = vcat(path, name)
        if newpath in undoc.modules
            push!(findings, (_node_range(cs[1]),
                "The module `$name` has no docstring."))
        end
        for c in cs[2:end]
            _walk_undocumented!(findings, c, newpath, undoc)
        end
        return nothing
    elseif k === K"export" || k === K"public"
        names = get(undoc.exports, path, nothing)
        names === nothing && return nothing
        verb = k === K"export" ? "exported" : "declared `public`"
        for c in cs
            n = _undoc_statement_name(c)
            n !== nothing && n in names && push!(findings, (_node_range(c),
                "`$n` is $verb but has no docstring."))
        end
        return nothing
    end

    for c in cs
        _walk_undocumented!(findings, c, path, undoc)
    end
    return nothing
end

"""
    collect_undocumented_public_findings(rt, uri) -> Vector{Tuple{UnitRange{Int64},String}}

The `undocumented_public_name` findings whose statements live in `uri`:
`(byte range, message)` pairs, located at the offending name inside the
`export`/`public` statement (or at the undocumented submodule's name). Reads
a fresh parse of the file — a volatile last-mile join, called only from
`derived_diagnostics` when the rule is enabled.
"""
function collect_undocumented_public_findings(rt, uri)
    findings = Tuple{UnitRange{Int64},String}[]

    package_roots = derived_workspace_package_roots(rt)
    isempty(package_roots) && return findings
    root_set = Set{URI}(values(package_roots))
    relevant = sort!([r for r in derived_roots_for_uri(rt, uri) if r in root_set]; by=string)
    isempty(relevant) && return findings

    content = derived_julia_source_view(rt, uri)
    content === nothing && return findings
    tree = nothing

    for root in relevant
        undoc = derived_undocumented_public_names(rt, root)
        isempty(undoc.exports) && isempty(undoc.modules) && continue
        splice = derived_file_module_path(rt, root, uri)
        splice === nothing && continue
        tree === nothing && (tree = parse_julia_syntax_tree(content)[1])
        _walk_undocumented!(findings, tree, splice, undoc)
    end

    unique!(findings)
    return findings
end
