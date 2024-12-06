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

@auto_hash_equals struct TestSetupDetail
    uri::URI
    name::Symbol
    kind::Symbol
    range::UnitRange{Int}
    code_range::UnitRange{Int}
end

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

    symbol_cache_path::Union{Nothing,String}
    symbol_cache_channel_requests::Union{Nothing,Channel{Any}}
    symbol_cache_channel_responses::Union{Nothing,Channel{Any}}
    symbol_cache_async::Bool

    function JuliaWorkspace(; symbol_cache_path=nothing, async_symbol_loading=true)
        rt = Salsa.Runtime()

        set_input_files!(rt, Set{URI}())
        set_input_package_symbols!(rt, Set{JuliaProjectEntryRegularPackage}())
        set_input_fallback_test_project!(rt, nothing)

        symbol_cache_channel_requests = symbol_cache_path===nothing ? nothing : Channel(Inf)
        symbol_cache_channel_responses = symbol_cache_path===nothing ? nothing : Channel(Inf)

        if symbol_cache_path!==nothing
            Threads.@spawn try
                while true
                    still_need_to_be_loaded = take!(symbol_cache_channel_requests)
       
                    new_symbols = map(still_need_to_be_loaded) do i
                        # Construct cache path
                        file_to_load_path = joinpath(
                            symbol_cache_path,
                            string(uppercase(string(i.name)[1])), # Capitalized first letter of the package name
                            string(i.name, "_", i.uuid),
                            string("v", i.version, "_", i.git_tree_sha1, ".jstore")
                        )

                        if isfile(file_to_load_path)
                            # println("We found cache file $file_to_load_path")
                            package_data = open(file_to_load_path) do io
                                SymbolServer.CacheStore.read(io)
                            end

                            pkg_path = nothing

                            git_tree_sha1 = Base.SHA1(i.git_tree_sha1)
                            # Keep the 4 since it used to be the default
                            slugs = (Base.version_slug(i.uuid, git_tree_sha1, 4), Base.version_slug(i.uuid, git_tree_sha1))
                            for depot in Base.DEPOT_PATH, slug in slugs
                                path = abspath(depot, "packages", i.name, slug)
                                if ispath(path)
                                    pkg_path = path
                                    break
                                end
                            end

                            if pkg_path !== nothing
                                SymbolServer.modify_dirs(package_data.val, f -> SymbolServer.modify_dir(f, r"^PLACEHOLDER", joinpath(pkg_path, "src")))
                            end

                            return @NamedTuple{package,data}((i, package_data))
                        end
                        
                        return @NamedTuple{package,data}((i, nothing))
                    end

                    put!(symbol_cache_channel_responses, new_symbols)
                end
            catch err
                Base.display_error(err, catch_backtrace())
            end
        end

        new(rt, symbol_cache_path, symbol_cache_channel_requests, symbol_cache_channel_responses, async_symbol_loading)
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
