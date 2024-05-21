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

struct SourceText
    content::String
    line_indices::Vector{Int}
    language_id::String

    function SourceText(content, language_id)
        line_indices = _compute_line_indices(content)

        return new(content, line_indices, language_id)
    end
end

struct TextChange
    span::UnitRange{Int}
    new_text::String
end

struct Documents
    _sourcetexts::Dict{URI,SourceText}
    _text_files::Set{URI}
    _notebook_files::Set{URI}
end

abstract type AbstractDocumentChange end

struct DocumentChangeAddTextFile <: AbstractDocumentChange
    uri::URI
    content::SourceText
end

struct DocumentChangeAddNotebookFile <: AbstractDocumentChange
    uri::URI
    content::Vector{Pair{URI,SourceText}}
end

struct DocumentChangeModifyTextFile <: AbstractDocumentChange
    uri::URI
    changes::Vector{TextChange}
end

struct DocumentChangeDeleteTextFile <: AbstractDocumentChange
    uri::URI
end

struct JuliaSyntaxTrees
    _julia_syntax_trees::Dict{URI,SyntaxNode}
    # TODO Replace this with a concrete syntax tree for TOML
    _toml_syntax_trees::Dict{URI,Dict}

    # diagnostics
    _diagnostics::Dict{URI,Vector{JuliaSyntax.Diagnostic}}
end

struct JuliaSemantics
    _packages::Dict{URI,JuliaPackage} # For now we just record all the packages, later we would want to extract the semantic content
    _projects::Dict{URI,JuliaProject} # For now we just record all the projects, later we would want to extract the semantic content
    _testitems::Dict{URI,Vector{TestItemDetail}}
    _testsetups::Dict{URI,Vector{TestSetupDetail}}
    _testerrors::Dict{URI,Vector{TestErrorDetail}}
end

struct JuliaWorkspace
    # Text content
    _documents::Documents

    # Parsed syntax trees
    _julia_syntax_trees::Dict{URI,JuliaSyntaxTrees}

    # Semantic information
    _julia_semantics::JuliaSemantics
end
