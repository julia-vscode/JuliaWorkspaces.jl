"""
    struct TestItemDetail

Details of a test item.

$(TYPEDFIELDS)
"""
@auto_hash_equals struct TestItemDetail
    uri::URI
    id::String
    name::String
    range::UnitRange{Int}
    code_range::UnitRange{Int}
    option_default_imports::Bool
    option_tags::Vector{Symbol}
    option_setup::Vector{Symbol}
end

"""
    struct TestSetupDetail

Details of a test setup.

$(TYPEDFIELDS)
"""
@auto_hash_equals struct TestSetupDetail
    uri::URI
    name::Symbol
    kind::Symbol
    range::UnitRange{Int}
    code_range::UnitRange{Int}
end

"""
    struct TestErrorDetail

Details of a test error.

$(TYPEDFIELDS)
"""
@auto_hash_equals struct TestErrorDetail
    uri::URI
    id::String
    name::Union{Nothing,String}
    message::String
    range::UnitRange{Int}
end

@auto_hash_equals struct TestDetails
    testitems::Vector{TestItemDetail}
    testsetups::Vector{TestSetupDetail}
    testerrors::Vector{TestErrorDetail}
end

@auto_hash_equals struct JuliaPackage
    project_file_uri::URI
    name::String
    uuid::UUID
    content_hash::UInt
end

@auto_hash_equals struct JuliaProjectEntryDevedPackage
    name::String
    uuid::UUID
    uri::URI
    version::String
end

@auto_hash_equals struct JuliaProjectEntryRegularPackage
    name::String
    uuid::UUID
    version::String
    git_tree_sha1::String
end

@auto_hash_equals struct JuliaProjectEntryStdlibPackage
    name::String
    uuid::UUID
    version::Union{Nothing,String}
end

@auto_hash_equals struct JuliaProject
    project_file_uri::URI
    manifest_file_uri::URI
    content_hash::UInt
    deved_packages::Dict{String,JuliaProjectEntryDevedPackage}
    regular_packages::Dict{String,JuliaProjectEntryRegularPackage}
    stdlib_packages::Dict{String,JuliaProjectEntryStdlibPackage}
end

@auto_hash_equals struct JuliaTestEnv
    package_name::String
    package_uri::Union{URI,Nothing}
    project_uri::Union{URI,Nothing}
    env_content_hash::Union{UInt,Nothing}
end

@auto_hash_equals struct SourceText
    content::String
    line_indices::Vector{Int}
    language_id::String

    function SourceText(content, language_id)
        line_indices = _compute_line_indices(content)

        return new(content, line_indices, language_id)
    end
end

function position_at(source_text::SourceText, x)
    line_indices = source_text.line_indices

    # TODO Implement a more efficient algorithm
    for line in length(line_indices):-1:1
        if x >= line_indices[line]
            return line, x - line_indices[line] + 1
        end
    end

    error("This should never happen")
end

"""
    struct TextFile

A text file, consisting of its URI and content.

$(TYPEDFIELDS)
"""
@auto_hash_equals struct TextFile
    uri::URI
    content::SourceText
end

@auto_hash_equals struct NotebookFile
    uri::URI
    cells::Vector{SourceText}
end

@auto_hash_equals struct Diagnostic
    range::UnitRange{Int64}
    severity::Symbol
    message::String
    source::String
end

struct JuliaWorkspace
    runtime::Salsa.Runtime

    function JuliaWorkspace()
        rt = Salsa.Runtime()

        set_input_files!(rt, Set{URI}())
        set_input_fallback_test_project!(rt, nothing)

        new(rt)
    end
end

@auto_hash_equals struct DiagnosticsMark
    id::UUID
    data::Dict{URI,Vector{Diagnostic}}
end

@auto_hash_equals struct TestitemsMark
    id::UUID
    data::Dict{URI,TestDetails}
end
