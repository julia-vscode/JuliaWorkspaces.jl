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

function find_project_for_file(projects::Vector{URI}, file::URI)
    file.scheme != "file" && return nothing

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
    @debug "derived_testitems" uri=uri

    testitems = []
    testsetups = []
    testerrors = []

    text_file = derived_text_file_content(rt, uri)
    syntax_tree = derived_julia_syntax_tree(rt, uri)

    TestItemDetection.find_test_detail!(syntax_tree, testitems, testsetups, testerrors)

    package_uri = derived_package_for_file(rt, uri)

    if isnothing(package_uri) && (!isempty(testitems) || !isempty(testsetups))
        all_testerrors = [
            TestErrorDetail(
                uri,
                "$uri:error$i",
                string(te.name),
                te.message,
                te.range
            ) for (i,te) in enumerate(testerrors)
        ]

        error_offset = length(testerrors)

        for (i, ti) in enumerate(testitems)
            push!(all_testerrors, TestErrorDetail(
                uri,
                "$uri:error$(error_offset + i)",
                ti.name,
                "Test items must be defined inside a Julia package.",
                ti.range
            ))
        end

        for (i, ts) in enumerate(testsetups)
            push!(all_testerrors, TestErrorDetail(
                uri,
                "$uri:error$(error_offset + length(testitems) + i)",
                string(ts.name),
                "Test setups must be defined inside a Julia package.",
                ts.range
            ))
        end

        return TestDetails(
            TestItemDetail[],
            TestSetupDetail[],
            all_testerrors
        )
    end

    return TestDetails(
        [TestItemDetail(
            uri,
            "$uri:$i",
            ti.name,
            text_file.content.content[ti.code_range],
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
            text_file.content.content[i.code_range],
            i.range,
            i.code_range
            ) for i in testsetups],
        [TestErrorDetail(
            uri,
            "$uri:error$i",
            string(te.name),
            te.message,
            te.range
            ) for (i,te) in enumerate(testerrors)]
    )
end

Salsa.@derived function derived_all_testitems(rt)
    @debug "derived_all_testitems"

    files = derived_julia_files(rt)

    res = Dict{URI,TestDetails}(
        uri => derived_testitems(rt, uri)
        for uri in files
    )

    return res
end

Salsa.@derived function derived_testenv(rt, uri)
    projects = derived_project_folders(rt)

    project_uri = find_project_for_file(projects, uri)
    package_uri = derived_package_for_file(rt, uri)

    if project_uri === nothing
        project_uri = input_active_project(rt)

        # Sometimes the active project is actually not a valid project
        # because there is no manifest, here we check for that
        if project_uri === nothing || derived_project(rt, project_uri) === nothing
            project_uri = nothing
        end
    end

    package_name = package_uri === nothing ? nothing : derived_package(rt, package_uri).name

    if project_uri == package_uri
    elseif project_uri in projects
        relevant_project = derived_project(rt, project_uri)

        if relevant_project === nothing || findfirst(i->i.uri == package_uri, collect(values(relevant_project.deved_packages))) === nothing
            project_uri = nothing
        end
    else
        project_uri = nothing
    end

    env_content_hash = isnothing(project_uri) ? hash(nothing) : derived_project(rt, project_uri).content_hash
    if package_uri===nothing
        env_content_hash = hash(nothing, env_content_hash)
    else
        env_content_hash = hash(derived_package(rt, package_uri).content_hash)
    end

    # We construct a string for the env content hash here so that later when we
    # deserialize it with JSON.jl we don't end up with Int conversion issues
    return JuliaTestEnv(package_name, package_uri, project_uri, "x$env_content_hash")
end
