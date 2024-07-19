import JuliaSyntax
using JuliaSyntax: @K_str, kind, children, haschildren, first_byte, last_byte, SyntaxNode

import ..URIs2
using ..URIs2: URI, uri2filepath

import ...JuliaWorkspaces
using ...JuliaWorkspaces: TestItemDetail, TestSetupDetail, TestErrorDetail, JuliaPackage, JuliaProject, splitpath

function vec_startswith(a, b)
    if length(a) < length(b)
        return false
    end

    for (i,v) in enumerate(b)
        if a[i] != v
            return false
        end
    end
    return true
end

function find_package_for_file(packages::Vector{URI}, file::URI)
    file_path = uri2filepath(file)
    package = packages |>
        x -> map(x) do i
            package_folder_path = uri2filepath(i)
            parts = splitpath(package_folder_path)
            return (uri = i, parts = parts)
        end |>
        x -> filter(x) do i
            return vec_startswith(splitpath(file_path), i.parts)
        end |>
        x -> sort(x, by=i->length(i.parts), rev=true) |>
        x -> length(x) == 0 ? nothing : first(x).uri

    return package
end

function find_project_for_file(projects::Vector{URI}, file::URI)
    file_path = uri2filepath(file)
    project = projects |>
        x -> map(x) do i
            project_folder_path = uri2filepath(i)
            parts = splitpath(project_folder_path)
            return (uri = i, parts = parts)
        end |>
        x -> filter(x) do i
            return vec_startswith(splitpath(file_path), i.parts)
        end |>
        x -> sort(x, by=i->length(i.parts), rev=true) |>
        x -> length(x) == 0 ? nothing : first(x).uri

    return project
end

Salsa.@derived function derived_testitems(rt, uri)
    testitems = []
    testsetups = []
    testerrors = []

    syntax_tree = derived_julia_syntax_tree(rt, uri)

    TestItemDetection.find_test_detail!(syntax_tree, testitems, testsetups, testerrors)

    return TestDetails(
        [TestItemDetail(
            uri,
            "$uri:$i",
            ti.name,
            ti.range,
            ti.code_range,
            ti.option_default_imports,
            ti.option_tags,
            ti.option_setup
            ) for (i,ti) in enumerate(testitems)],
        [TestSetupDetail(
            uri,
            i.name,
            i.kind,
            i.range,
            i.code_range
            ) for i in testsetups],
        [TestErrorDetail(
            uri,
            "$uri:error$i",
            te.name,
            te.message,
            te.range
            ) for (i,te) in enumerate(testerrors)]
    )
end

Salsa.@derived function derived_all_testitems(rt)
    files = derived_julia_files(rt)

    res = Dict{URI,@NamedTuple{testitems::Vector{TestItemDetail},testsetups::Vector{TestSetupDetail},testerrors::Vector{TestErrorDetail}}}(
        uri => derived_testitems(rt, uri)
        for uri in files
    )

    return res
end

Salsa.@derived function derived_testenv(rt, uri)
    projects = derived_project_folders(rt)
    packages = derived_package_folders(rt)

    project_uri = find_project_for_file(projects, uri)
    package_uri = find_package_for_file(packages, uri)

    if project_uri === nothing
        project_uri = input_fallback_test_project(rt)
    end

    if package_uri === nothing
        package_name = ""
    else
        package_name = derived_package(rt, package_uri).name
    end

    if project_uri == package_uri
    elseif project_uri in projects
        relevant_project = derived_project(rt, project_uri)

        if !haskey(relevant_project.deved_packages, package_uri)
            project_uri = nothing
        end
    else
        project_uri = nothing
    end

    env_content_hash = isnothing(project_uri) ? nothing : derived_project(rt, project_uri).content_hash
    if package_uri===nothing
        env_content_hash = hash(nothing, env_content_hash)
    else
        env_content_hash = hash(derived_package(rt, package_uri).content_hash)
    end

    return JuliaTestEnv(package_name, package_uri, project_uri, env_content_hash)
end

Salsa.@derived function derived_testitems_updated_since_mark(rt)
    current_text_files = derived_julia_files(rt)
    marked_versions = input_marked_testitems(rt)

    old_text_files = collect(keys(marked_versions))

    deleted_files = setdiff(old_text_files, current_text_files)
    updated_files = Set{URI}()

    for uri in current_text_files
        if !(uri in old_text_files)
            push!(updated_files, uri)
        else
            new_diag = derived_testitems(rt, uri)

            if hash(marked_versions[uri]) != hash(new_diag)
                push!(updated_files, uri)
            end
        end
    end

    return updated_files, deleted_files
end

function mark_current_testitems(jw::JuliaWorkspace)
    files = derived_julia_files(jw.runtime)

    results = Dict{URI,TestDetails}()

    for f in files
        results[f] = derived_testitems(jw.runtime, f)
    end

    set_input_marked_testitems!(jw.runtime, results)
end

function get_files_with_updated_testitems(jw::JuliaWorkspace)
    # @info "get_files_with_updated_testitems" string.(input_files(jw.runtime))
    # graph = Salsa.Inspect.build_graph(jw.runtime)
    # println(stderr, graph)
    return derived_testitems_updated_since_mark(jw.runtime)
end
