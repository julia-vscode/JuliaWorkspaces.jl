"""
    struct TestItemDetail

Details of a test item.

- uri::URI
- id::String
- name::String
- code::String
- range::UnitRange{Int}
- code_range::UnitRange{Int}
- `option_default_imports`::Bool
- option_tags::Vector{Symbol}
- option_setup::Vector{Symbol}
"""
@auto_hash_equals struct TestItemDetail
    uri::URI
    id::String
    name::String
    code::String
    range::UnitRange{Int}
    code_range::UnitRange{Int}
    option_default_imports::Bool
    option_tags::Vector{Symbol}
    option_setup::Vector{Symbol}
end

"""
    struct TestSetupDetail

Details of a test setup.

- uri::URI
- name::Symbol
- kind::Symbol
- code::String
- range::UnitRange{Int}
- code_range::UnitRange{Int}
"""
@auto_hash_equals struct TestSetupDetail
    uri::URI
    name::Symbol
    kind::Symbol
    code::String
    range::UnitRange{Int}
    code_range::UnitRange{Int}
end

"""
    struct TestErrorDetail

Details of a test error.

- uri::URI
- id::String
- name::Union{Nothing,String}
- message::String
- range::UnitRange{Int}
"""
@auto_hash_equals struct TestErrorDetail
    uri::URI
    id::String
    name::Union{Nothing,String}
    message::String
    range::UnitRange{Int}
end

"""
    struct TestDetails

Details of a test.

- testitems::Vector{TestItemDetail}
- testsetups::Vector{TestSetupDetail}
- testerrors::Vector{TestErrorDetail}
"""
@auto_hash_equals struct TestDetails
    testitems::Vector{TestItemDetail}
    testsetups::Vector{TestSetupDetail}
    testerrors::Vector{TestErrorDetail}
end

"""
    struct JuliaPackage

Details of a Julia package.

- `project_file_uri`::URI
- name::String
- uuid::UUID
- content_hash::UInt
"""
@auto_hash_equals struct JuliaPackage
    project_file_uri::URI
    name::String
    uuid::UUID
    content_hash::UInt
end

"""
    struct JuliaProjectEntryDevedPackage

Details of a Julia project entry for a developed package.

- name::String
- uuid::UUID
- uri::URI
- version::String
"""
@auto_hash_equals struct JuliaProjectEntryDevedPackage
    name::String
    uuid::UUID
    uri::URI
    version::String
end

"""
    struct JuliaProjectEntryRegularPackage

Details of a Julia project entry for a regular package.

- name::String
- uuid::UUID
- version::String
- `git_tree_sha1`::String
"""
@auto_hash_equals struct JuliaProjectEntryRegularPackage
    name::String
    uuid::UUID
    version::String
    git_tree_sha1::String
end

"""
    struct JuliaProjectEntryStdlibPackage

Details of a Julia project entry for a standard library package.

- name::String
- uuid::UUID
- version::Union{Nothing,String}
"""
@auto_hash_equals struct JuliaProjectEntryStdlibPackage
    name::String
    uuid::UUID
    version::Union{Nothing,String}
end

"""
    struct JuliaProject

Details of a Julia project.

- `project_file_uri`::URI
- `manifest_file_uri`::URI
- `julia_version`::Union{Nothing,VersionNumber}
- content_hash::UInt
- deved_packages::Dict{String,JuliaProjectEntryDevedPackage}
- regular_packages::Dict{String,JuliaProjectEntryRegularPackage}
- stdlib_packages::Dict{String,JuliaProjectEntryStdlibPackage}
"""
@auto_hash_equals struct JuliaProject
    project_file_uri::URI
    manifest_file_uri::URI
    julia_version::Union{Nothing,VersionNumber}
    content_hash::UInt
    deved_packages::Dict{String,JuliaProjectEntryDevedPackage}
    regular_packages::Dict{String,JuliaProjectEntryRegularPackage}
    stdlib_packages::Dict{String,JuliaProjectEntryStdlibPackage}
end

"""
    struct JuliaTestEnv

Details of a Julia test environment.

- package_name::String
- package_uri::Union{URI,Nothing}
- project_uri::Union{URI,Nothing}
- `env_content_hash`::Union{UInt,Nothing}
"""
@auto_hash_equals struct JuliaTestEnv
    package_name::Union{String,Nothing}
    package_uri::Union{URI,Nothing}
    project_uri::Union{URI,Nothing}
    env_content_hash::Union{String,Nothing}
end

"""
    struct SourceText

A source text, consisting of its content, line indices, and language ID.

- content::String
- line_indices::Vector{Int}
- language_id::String
"""
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

- `uri::URI`: The [`URI`](@ref) of the file.
- `content::SourceText`: The content of the file as [`SourceText`](@ref).
"""
@auto_hash_equals struct TextFile
    uri::URI
    content::SourceText
end

"""
    struct NotebookFile

A notebook file, consisting of its URI and cells.

- `uri::URI`: The [`URI`](@ref) of the file.
- `cells::Vector{SourceText}`: The cells of the notebook as a vector of [`SourceText`](@ref).
"""
@auto_hash_equals struct NotebookFile
    uri::URI
    cells::Vector{SourceText}
end

"""
    struct Diagnostic

A diagnostic struct, consisting of range, severity, message, and source.

- range::UnitRange{Int64}
- severity::Symbol
- message::String
- uri::Union{Nothing,URI}
- tags::Vector{Symbol}
- source::String
"""
@auto_hash_equals struct Diagnostic
    range::UnitRange{Int64}
    severity::Symbol
    message::String
    uri::Union{Nothing,URI}
    tags::Vector{Symbol}
    source::String
end

"""
    struct JuliaWorkspace

A Julia workspace, consisting of a [`Salsa`](https://github.com/julia-vscode/Salsa.jl) runtime.

- runtime::Salsa.Runtime
"""
struct JuliaWorkspace
    runtime::Salsa.Runtime
    dynamic_feature::Union{Nothing,DynamicFeature}

    function JuliaWorkspace(;dynamic=false)
        rt = Salsa.Runtime()

        set_input_files!(rt, Set{URI}())
        set_input_project_environments!(rt, Set{URI}())
        set_input_fallback_test_project!(rt, nothing)

        dynamic_feature = dynamic ? DynamicFeature() : nothing
        dynamic_feature === nothing || start(dynamic_feature)

        new(rt, dynamic_feature)
    end
end

function update_dynamic(jw::JuliaWorkspace)
    project_uris = derived_project_folders(jw.runtime)

    if jw.dynamic_feature !== nothing
        put!(jw.dynamic_feature.in_channel, (command = :set_environments, environments = Dict{String,JuliaProject}(uri2filepath(i) => derived_project(jw.runtime, i) for i in project_uris)))
    end
end

function process_from_dynamic(jw::JuliaWorkspace)
    if jw.dynamic_feature !== nothing
        while isready(jw.dynamic_feature.out_channel)
            msg = take!(jw.dynamic_feature.out_channel)

            if msg.command == :environment_ready
                @info "Processeing new env" msg.path msg.environment
                env = msg.environment

                old_environments = input_project_environments(jw.runtime)
                new_environments = Set{URI}([old_environments...; filepath2uri(msg.path)])
                set_input_project_environments!(jw.runtime, new_environments)

                ext_env = StaticLint.ExternalEnv(
                    env,
                    SymbolServer.collect_extended_methods(env),
                    collect(keys(env))
                )

                set_input_project_environment!(jw.runtime, filepath2uri(msg.path), ext_env)
            else
                error("Unknown message: $msg")
            end
        end
    end
end
