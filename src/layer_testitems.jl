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

# Test item discovery is scoped by `JuliaTestItems.toml`, whose v1 schema is
# just the shared `include`/`exclude` globs. Execution settings (workers, env,
# tag filters) are deliberately not part of it yet.
const _TESTITEMS_CONFIG_TOP_LEVEL_KEYS = ["config-version", "include", "exclude"]

Salsa.@derived function derived_testitemsconfig_files(rt)
    files = derived_text_files(rt)

    return [file for file in files if file.scheme=="file" && is_path_testitemsconfig_file(uri2filepath(file))]
end

Salsa.@derived function derived_testitemsconfig_diagnostics(rt, uri)
    toml_content = derived_toml_syntax_tree(rt, uri)

    res = Diagnostic[]

    validate_key_set!(res, toml_content, _TESTITEMS_CONFIG_TOP_LEVEL_KEYS, Dict{String,String}(), "test items configuration key")
    validate_config_version!(res, toml_content)
    shadowing_diagnostic!(res, derived_testitemsconfig_files(rt), uri, "JuliaTestItems.toml")
    parse_glob_list!(res, toml_content, "include")
    parse_glob_list!(res, toml_content, "exclude")

    return res
end

"""
    derived_testitems_selected(rt, uri) -> Bool

Whether test items are discovered in `uri` at all, per the governing
`JuliaTestItems.toml`.
"""
Salsa.@derived function derived_testitems_selected(rt, uri)
    uri.scheme == "file" || return true

    config_uri = nearest_config(derived_testitemsconfig_files(rt), uri)
    config_uri === nothing && return true

    relpath = config_relative_path(config_dir_of(config_uri), uri2filepath(uri))
    relpath === nothing && return true

    toml_content = derived_toml_syntax_tree(rt, config_uri)
    discard = Diagnostic[]

    return path_selected(parse_path_filter!(discard, toml_content), relpath)
end

Salsa.@derived function derived_testitems(rt, uri)
    @debug "derived_testitems" uri=uri

    # Gating the per-file query covers every consumer at once — the whole
    # workspace sweep, the LS publish path and the test runner all read
    # through here.
    if !derived_testitems_selected(rt, uri)
        return TestDetails(TestItemDetail[], TestSetupDetail[], TestErrorDetail[])
    end

    testitems = []
    testsetups = []
    testerrors = []

    text_file = derived_text_file_content(rt, uri)
    syntax_tree, _ = parse_julia_syntax_tree(text_file.content.content)

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

    res = Dict{URI,TestDetails}()
    for uri in files
        res[uri] = derived_testitems(rt, uri)
        # Yield between files so cooperatively scheduled tasks aren't starved
        # while testitems for a whole workspace are computed (see
        # derived_all_diagnostics).
        yield()
    end

    return res
end

Salsa.@derived function derived_testenv(rt, uri)
    project_uri = derived_project_for_file(rt, uri)
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
    elseif project_uri in derived_project_folders(rt)
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
