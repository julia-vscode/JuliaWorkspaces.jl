module JuliaWorkspaces

import UUIDs, JuliaSyntax
using UUIDs: UUID
using JuliaSyntax: SyntaxNode

include("compat.jl")

import Pkg

include("URIs2/URIs2.jl")
import .URIs2
using .URIs2: filepath2uri, uri2filepath

using .URIs2: URI, @uri_str

include("textdocument.jl")

function our_isvalid(s)
    return isvalid(s) && !occursin('\0', s)
end

struct TestItemDetail
    uri::URI
    name::String    
    project_uri::Union{URI,Nothing}
    package_uri::Union{URI,Nothing}
    package_name::String
    range::UnitRange{Int}
    code_range::UnitRange{Int}
    option_default_imports::Bool
    option_tags::Vector{Symbol}
    option_setup::Vector{Symbol}
end

struct TestSetupDetail
    uri::URI
    name::Symbol    
    package_uri::Union{URI,Nothing}
    package_name::String
    range::UnitRange{Int}
    code_range::UnitRange{Int}
end

struct TestErrorDetail
    uri::URI
    message::String
    range::UnitRange{Int}
end

struct JuliaPackage
    project_file_uri::URI
    name::String
    uuid::UUID
end

struct JuliaDevedPackage
    name::String
    uuid::UUID
end

struct JuliaProject
    project_file_uri::URI
    deved_packages::Dict{URI,JuliaDevedPackage}
end

struct JuliaWorkspace
    _workspace_folders::Set{URI}

    # Text content
    _text_documents::Dict{URI,TextDocument}

    # Parsed syntax trees
    _julia_syntax_trees::Dict{URI,SyntaxNode}
    # TODO Replace this with a concrete syntax tree for TOML
    _toml_syntax_trees::Dict{URI,Dict}

    # diagnostics
    _diagnostics::Dict{URI,Vector{JuliaSyntax.Diagnostic}}

    # Semantic information
    _packages::Dict{URI,JuliaPackage} # For now we just record all the packages, later we would want to extract the semantic content
    _projects::Dict{URI,JuliaProject} # For now we just record all the projects, later we would want to extract the semantic content
    _testitems::Dict{URI,Vector{TestItemDetail}}
    _testsetups::Dict{URI,Vector{TestSetupDetail}}
    _testerrors::Dict{URI,Vector{TestErrorDetail}}
end

include("semantic_pass_tests.jl")
include("semantic_pass_toml_files.jl")


JuliaWorkspace() = JuliaWorkspace(
    Set{URI}(),
    Dict{URI,TextDocument}(),
    Dict{URI,SyntaxNode}(),
    Dict{URI,Dict}(),
    Dict{URI,Vector{JuliaSyntax.Diagnostic}}(),
    Dict{URI,JuliaPackage}(),
    Dict{URI,JuliaProject}(),
    Dict{URI,Vector{TestItemDetail}}(),
    Dict{URI,Vector{TestSetupDetail}}(),
    Dict{URI,Vector{TestErrorDetail}}()
)

function JuliaWorkspace(workspace_folders::AbstractVector{URI})
    return JuliaWorkspace(Set(workspace_folders))
end

function JuliaWorkspace(workspace_folders::Set{URI})
    new_text_documents = isempty(workspace_folders) ? Dict{URI,TextDocument}() : merge((read_path_into_textdocuments(path) for path in workspace_folders)...)

    new_julia_syntax_trees = Dict{URI,SyntaxNode}()
    new_toml_syntax_trees = Dict{URI,Dict}()
    new_diagnostics = Dict{URI,Vector{JuliaSyntax.Diagnostic}}()
    for (k,v) in pairs(new_text_documents)
        if endswith(lowercase(string(k)), ".jl")
            node, diag = parse_julia_file(get_text(v))
            new_julia_syntax_trees[k] = node
            new_diagnostics[k] = diag
        elseif endswith(lowercase(string(k)), ".toml")
            # try
                new_toml_syntax_trees[k] = parse_toml_file(get_text(v))
            # catch err
                # TODO Add some diagnostics
            # end
        end
    end

    new_packages, new_projects = SemanticPassTomlFiles.semantic_pass_toml_files(new_toml_syntax_trees)

    new_jw = JuliaWorkspace(
        workspace_folders,
        new_text_documents,
        new_julia_syntax_trees,
        new_toml_syntax_trees,
        new_diagnostics,        
        new_packages,
        new_projects,
        SemanticPassTests.semantic_pass_tests(workspace_folders, new_julia_syntax_trees, new_packages, new_projects, uri"something")...
    )

    return new_jw
end

function parse_julia_file(content)
    JuliaSyntax.parse!(SyntaxNode, IOBuffer(content))
end

function parse_toml_file(content)
    return Pkg.TOML.parse(content)
end

function is_path_project_file(path)
    basename_lower_case = basename(lowercase(path))

    return basename_lower_case=="project.toml" || basename_lower_case=="juliaproject.toml"
end

function is_path_manifest_file(path)
    basename_lower_case = basename(lowercase(path))

    return basename_lower_case=="manifest.toml" || basename_lower_case=="juliamanifest.toml"
end

function is_path_julia_file(path)
    _, ext = splitext(lowercase(path))

    return ext == ".jl"
end

function read_textdocument_from_uri(uri::URI)
    path = uri2filepath(uri)

    content = try
        s = read(path, String)
        our_isvalid(s) || return nothing
        s
    catch err
        # TODO Reenable this
        # is_walkdir_error(err) || rethrow()
        # return nothing
        rethrow()
    end
    return TextDocument(uri, content, 0)
end

function read_path_into_textdocuments(uri::URI)
    path = uri2filepath(uri)
    result = Dict{URI,TextDocument}()

    if true
        #T TODO Move this check into the LS logic
    # if load_rootpath(path)    
    # TODO Think about this try catch block
        # try
            for (root, _, files) in walkdir(path, onerror=x -> x)
                for file in files
                    
                    filepath = joinpath(root, file)
                    if is_path_julia_file(filepath) || is_path_project_file(filepath) || is_path_manifest_file(filepath)
                        uri = filepath2uri(filepath)
                        doc = read_textdocument_from_uri(uri)
                        doc === nothing && continue
                        result[uri] = doc
                    end
                end
            end
        # catch err
        #     is_walkdir_error(err) || rethrow()
        # end
    end

    return result
end

function add_workspace_folder(jw::JuliaWorkspace, folder::URI)
    new_roots = push!(copy(jw._workspace_folders), folder)
    new_toml_syntax_trees = copy(jw._toml_syntax_trees)
    new_julia_syntax_trees = copy(jw._julia_syntax_trees)
    new_diagnostics = copy(jw._diagnostics)

    additional_documents = read_path_into_textdocuments(folder)
    for (k,v) in pairs(additional_documents)
        if is_path_julia_file(string(k))
            node, diags = parse_julia_file(get_text(v))
            new_julia_syntax_trees[k] = node
            new_diagnostics[k] = diags
        elseif is_path_project_file(string(k)) || is_path_manifest_file(string(K))
            try
                new_toml_syntax_trees[k] = parse_toml_file(get_text(v))
            catch err
                # TODO Add some diagnostics
            end
        end
    end

    new_text_documents = merge(jw._text_documents, additional_documents)

    new_packages, new_projects = SemanticPassTomlFiles.semantic_pass_toml_files(new_toml_syntax_trees)

    new_jw = JuliaWorkspace(
        new_roots,
        new_text_documents,
        new_julia_syntax_trees,
        new_toml_syntax_trees,
        new_diagnostics,        
        new_packages,
        new_projects,
        SemanticPassTests.semantic_pass_tests(new_roots, new_julia_syntax_trees, new_packages, new_projects, uri"something")...
    )
    return new_jw
end

function remove_workspace_folder(jw::JuliaWorkspace, folder::URI)
    new_roots = delete!(copy(jw._workspace_folders), folder)

    new_text_documents = filter(jw._text_documents) do i
        # TODO Eventually use FilePathsBase functionality to properly test this
        return any(startswith(string(i.first), string(j)) for j in new_roots )
    end

    new_julia_syntax_trees = filter(jw._julia_syntax_trees) do i
        return haskey(new_text_documents, i.first)
    end

    new_toml_syntax_trees = filter(jw._toml_syntax_trees) do i
        return haskey(new_text_documents, i.first)
    end

    new_diagnostics = filter(jw._diagnostics) do i
        return haskey(new_text_documents, i.first)
    end

    new_packages, new_projects = SemanticPassTomlFiles.semantic_pass_toml_files(new_toml_syntax_trees)

    new_jw = JuliaWorkspace(
        new_roots,
        new_text_documents,
        new_julia_syntax_trees,
        new_toml_syntax_trees,
        new_diagnostics,        
        new_packages,
        new_projects,        
        SemanticPassTests.semantic_pass_tests(new_roots, new_julia_syntax_trees, new_packages, new_projects, uri"something")...
    )
    return new_jw
end

function add_file(jw::JuliaWorkspace, uri::URI, text_document::TextDocument)
    new_jw = jw

    if text_document !== nothing
        new_text_documents = copy(jw._text_documents)
        new_text_documents[uri] = text_document

        new_toml_syntax_trees = jw._toml_syntax_trees
        new_julia_syntax_trees = jw._julia_syntax_trees
        new_diagnostics = jw._diagnostics

        if is_path_julia_file(string(uri))
            node, diag = parse_julia_file(get_text(text_document))

            new_julia_syntax_trees = copy(jw._julia_syntax_trees)
            new_diagnostics = copy(jw._diagnostics)

            new_julia_syntax_trees[uri] = node
            new_diagnostics[uri] = diag
        elseif is_path_project_file(string(uri)) || is_path_manifest_file(string(uri))
            try
                new_toml_syntax_tree = parse_toml_file(get_text(text_document))

                new_toml_syntax_trees = copy(jw._toml_syntax_trees)

                new_toml_syntax_trees[uri] = new_toml_syntax_tree
            catch err
                nothing
            end
        end

        new_packages, new_projects = SemanticPassTomlFiles.semantic_pass_toml_files(new_toml_syntax_trees)

        new_jw =  JuliaWorkspace(
            jw._workspace_folders,
            new_text_documents,
            new_julia_syntax_trees,
            new_toml_syntax_trees,
            new_diagnostics,            
            new_packages,
            new_projects,
            SemanticPassTests.semantic_pass_tests(jw._workspace_folders, new_julia_syntax_trees, new_packages, new_projects, uri"something")...
        )
    end

    return new_jw
end

function add_file(jw::JuliaWorkspace, uri::URI, content::AbstractString)
    new_doc = TextDocument(uri, content, 0)

    return add_file(jw, uri, new_doc)
end

function add_file(jw::JuliaWorkspace, uri::URI)
    new_doc = read_textdocument_from_uri(uri)

    return add_file(jw, uri, new_doc)
end

function update_file(jw::JuliaWorkspace, uri::URI)
    new_doc = read_textdocument_from_uri(uri)

    new_jw = jw

    if new_doc!==nothing
        new_text_documents = copy(jw._text_documents)
        new_text_documents[uri] = new_doc

        new_toml_syntax_trees = jw._toml_syntax_trees
        new_julia_syntax_trees = jw._julia_syntax_trees
        new_diagnostics = jw._diagnostics

        if is_path_julia_file(string(uri))
            node, diag = parse_julia_file(get_text(new_doc))

            new_julia_syntax_trees = copy(jw._julia_syntax_trees)
            new_diagnostics = copy(jw._diagnostics)

            new_julia_syntax_trees[uri] = node
            new_diagnostics[uri] = diag
        elseif is_path_project_file(string(uri)) || is_path_manifest_file(string(uri))
            try
                new_toml_syntax_tree = parse_toml_file(get_text(new_doc))

                new_toml_syntax_trees = copy(jw._toml_syntax_trees)

                new_toml_syntax_trees[uri] = new_toml_syntax_tree
            catch err
                delete!(new_toml_syntax_trees, uri)
            end
        end

        new_packages, new_projects = SemanticPassTomlFiles.semantic_pass_toml_files(new_toml_syntax_trees)

        new_jw = JuliaWorkspace(
            jw._workspace_folders,
            new_text_documents,
            new_julia_syntax_trees,
            new_toml_syntax_trees,
            new_diagnostics,            
            new_packages,
            new_projects,
            SemanticPassTests.semantic_pass_tests(jw._workspace_folders, new_julia_syntax_trees, new_packages, new_projects, uri"something")...
        )
    end

    return new_jw
end

function delete_file(jw::JuliaWorkspace, uri::URI)
    new_text_documents = copy(jw._text_documents)
    delete!(new_text_documents, uri)

    new_toml_syntax_trees = jw._toml_syntax_trees
    new_julia_syntax_trees = jw._julia_syntax_trees
    new_diagnostics = jw._diagnostics
    
    if haskey(jw._toml_syntax_trees, uri)
        new_toml_syntax_trees = copy(jw._toml_syntax_trees)
        delete!(new_toml_syntax_trees, uri)
    end

    if haskey(jw._julia_syntax_trees, uri)
        new_julia_syntax_trees = copy(jw._julia_syntax_trees)
        delete!(new_julia_syntax_trees, uri)
    end

    if haskey(jw._diagnostics, uri)
        new_diagnostics = copy(jw._diagnostics)
        delete!(new_diagnostics, uri)
    end

    new_packages, new_projects = SemanticPassTomlFiles.semantic_pass_toml_files(new_toml_syntax_trees)

    new_jw = JuliaWorkspace(
        jw._workspace_folders,
        new_text_documents,
        new_julia_syntax_trees,
        new_toml_syntax_trees,
        new_diagnostics,        
        new_packages,
        new_projects,
        SemanticPassTests.semantic_pass_tests(jw._workspace_folders, new_julia_syntax_trees, new_packages, new_projects, uri"something")...
    )

    return new_jw
end


end
