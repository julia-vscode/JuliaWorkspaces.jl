struct TestItemDetail
    uri::URI
    name::String
    range::UnitRange{Int}
    code_range::UnitRange{Int}
    option_default_imports::Bool
    option_tags::Vector{Symbol}
    option_setup::Vector{Symbol}
end

struct TestSetupDetail
    uri::URI
    name::Symbol
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
    content_hash::UInt
end

struct JuliaDevedPackage
    name::String
    uuid::UUID
end

struct JuliaProject
    project_file_uri::URI
    manifest_file_uri::URI
    content_hash::UInt
    deved_packages::Dict{URI,JuliaDevedPackage}
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

struct TextChange
    span::Union{UnitRange{Int},Nothing}
    new_text::String
end

@auto_hash_equals struct TextFile
    uri::URI
    content::SourceText
end

struct NotebookFile
    uri::URI
    cells::Vector{SourceText}
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

function get_test_items(jw::JuliaWorkspace, uri::URI)
    derived_testitems(jw.runtime, uri)
end

function get_test_env(jw::JuliaWorkspace, uri::URI)
    derived_testenv(jw.runtime, uri)
end
