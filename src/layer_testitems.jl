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

# Sorted: this vector is now a dependency of every file's scope, and
# `derived_text_files` is a `Set`, so an unsorted result would change on
# unrelated file adds and defeat Salsa's backdating.
Salsa.@derived function derived_testitemsconfig_files(rt)
    files = derived_text_files(rt)

    return sort!([file for file in files if file.scheme=="file" && is_path_testitemsconfig_file(uri2filepath(file))], by=string)
end

Salsa.@derived function derived_testitemsconfig_diagnostics(rt, uri)
    toml_content = derived_toml_syntax_tree(rt, uri)

    res = Diagnostic[]

    validate_key_set!(res, toml_content, _TESTITEMS_CONFIG_TOP_LEVEL_KEYS, Dict{String,String}(), "test items configuration key")
    validate_config_version!(res, toml_content)
    # No `shadowing_diagnostic!` here: v1 of this file has nothing but scope keys,
    # and scope composes over the whole ancestor chain rather than being replaced
    # by the nearest file, so a nested `JuliaTestItems.toml` supersedes nothing.
    # Reinstate the call if execution settings are ever added to the schema.
    parse_glob_list!(res, toml_content, "include")
    parse_glob_list!(res, toml_content, "exclude")

    return res
end

"""
    derived_testitems_path_filter(rt, config_uri) -> PathFilter

The `include`/`exclude` globs of one `JuliaTestItems.toml`. Split out from
`derived_testitems_selected` so a config is parsed once rather than once per
file it governs, and so editing a config only invalidates the files whose scope
actually depends on it.
"""
Salsa.@derived function derived_testitems_path_filter(rt, config_uri)
    discard = Diagnostic[]   # diagnostics are reported by derived_testitemsconfig_diagnostics

    return parse_path_filter!(discard, derived_toml_syntax_tree(rt, config_uri))
end

"""
    derived_testitems_selected(rt, uri) -> Bool

Whether test items are discovered in `uri` at all. Every `JuliaTestItems.toml`
enclosing `uri` must admit it: a nested config can narrow discovery further, but
it cannot resurrect a subtree an enclosing config excluded.
"""
Salsa.@derived function derived_testitems_selected(rt, uri)
    uri.scheme == "file" || return true

    chain = ancestor_configs(derived_testitemsconfig_files(rt), uri)
    isempty(chain) && return true

    return scope_selected(chain, uri2filepath(uri), c -> derived_testitems_path_filter(rt, c))
end

"""
    testitem_relative_path(package_uri, uri) -> String

The path of `uri` relative to its package root, with `/` separators. This is the
first half of a test item id, so it must be stable across machines: relative so a
dev checkout and a CI runner agree, `/`-separated so Windows and Linux do. Falls
back to the full URI when there is no filesystem path to work with.
"""
function testitem_relative_path(package_uri::Union{URI,Nothing}, uri::URI)
    if package_uri !== nothing
        package_path = uri2filepath(package_uri)
        file_path = uri2filepath(uri)

        if package_path !== nothing && file_path !== nothing
            relpath = config_relative_path(package_path, file_path)
            relpath === nothing || return relpath
        end
    end

    return string(uri)
end

"""
    testitem_id_scope(package, package_uri, uri) -> String

The location half of a test item id: the file's path within its package, qualified by
the package it belongs to.

The package qualifier is `<name>@<first 8 hex of the uuid>`. The name is what a human
recognises in a JUnit classname or an MCP call; the uuid fragment separates two
*different* packages that happen to share a name, such as a vendored copy sitting
beside a dev checkout. Both are always available — a folder is only a package when its
Project.toml carries a name, a uuid and a version.

Deliberately scoped to the package rather than the workspace. The *same* package cloned
into two folders produces the same id from both clones, because the only thing that
tells those apart is their location, and location differs between a dev checkout and a
CI runner. An id cannot be both workspace-unique and portable; this one keeps
portability, and callers that need uniqueness key on `(package_uri, id)` — which is why
`TestEnvironment` carries the package uri.

Falls back to the bare URI when there is no filesystem path, since a URI is already
unique on its own and `MyPkg@abcd1234/file:///…` would help nobody.
"""
function testitem_id_scope(package, package_uri::Union{URI,Nothing}, uri::URI)
    relpath = testitem_relative_path(package_uri, uri)

    # The fallback fired: `relpath` is the whole URI, so there is nothing to qualify.
    package === nothing && return relpath
    relpath == string(uri) && return relpath

    return string(package.name, '@', first(string(package.uuid), 8), '/', relpath)
end

function _label_counts(labels)
    counts = Dict{String,Int}()
    for label in labels
        counts[label] = get(counts, label, 0) + 1
    end
    return counts
end

Salsa.@derived function derived_testitems(rt, uri)
    @debug "derived_testitems" uri=uri

    # Gating the per-file query covers every consumer at once — the whole
    # workspace sweep, the LS publish path and the test runner all read
    # through here.
    if !derived_testitems_selected(rt, uri)
        return TestDetails(TestItemDetail[], TestSetupDetail[], TestErrorDetail[])
    end

    # Under the v2 flag, detection comes off the v2 skeleton: position-only and
    # body edits backdate at `derived_v2_file_testitems` instead of re-detecting.
    input_lowering_lint(rt) && return derived_v2_testitem_details(rt, uri)

    text_file = derived_text_file_content(rt, uri)

    # Detection comes out of the fused parse (layer_parse_products.jl); the
    # parse is shared with syntax diagnostics and the syntax lint tier.
    raw = derived_raw_test_details(rt, uri)

    return _assemble_test_details(rt, uri, text_file.content.content,
                                  raw.testitems, raw.testsetups, raw.testerrors)
end

"""
    _assemble_test_details(rt, uri, text, testitems, testsetups, testerrors) -> TestDetails

Everything below the detection step, shared by the legacy and the v2 paths: the
outside-package check, id minting, duplicate-label errors, and the `code`/skip
slicing. Inputs are `RawTest*Detail`-shaped records whose ranges are
string-index ranges with an inclusive end.
"""
function _assemble_test_details(rt, uri, text, testitems, testsetups, testerrors)
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

    all_testerrors = TestErrorDetail[
        TestErrorDetail(
            uri,
            "$uri:error$i",
            string(te.name),
            te.message,
            te.range
        ) for (i,te) in enumerate(testerrors)
    ]

    # Ids are `<package>/<path relative to the package>::<label>`, so inserting a test
    # item above another one no longer renumbers it, and two packages that both contain
    # `test/runtests.jl` no longer mint the same id. A label used more than once in one
    # file is a definition error, but the run must still degrade rather than break, so
    # *every* occurrence gets a `#N` suffix — that keeps ids unique within the file,
    # keeps each item individually addressable, and makes the error state visible in
    # the id.
    relpath = testitem_id_scope(
        package_uri === nothing ? nothing : derived_package(rt, package_uri),
        package_uri,
        uri,
    )

    item_labels = String[ti.name for ti in testitems]
    item_counts = _label_counts(item_labels)
    seen_items = Dict{String,Int}()
    item_ids = Vector{String}(undef, length(testitems))

    for (i, label) in enumerate(item_labels)
        if item_counts[label] > 1
            occurrence = seen_items[label] = get(seen_items, label, 0) + 1
            item_ids[i] = "$relpath::$label#$occurrence"

            push!(all_testerrors, TestErrorDetail(
                uri,
                "$uri:error$(length(all_testerrors) + 1)",
                label,
                "The test item name \"$label\" is used more than once in this file. Test item names must be unique within a file.",
                testitems[i].range
            ))
        else
            item_ids[i] = "$relpath::$label"
        end
    end

    setup_counts = _label_counts(String[string(ts.name) for ts in testsetups])

    for ts in testsetups
        if setup_counts[string(ts.name)] > 1
            push!(all_testerrors, TestErrorDetail(
                uri,
                "$uri:error$(length(all_testerrors) + 1)",
                string(ts.name),
                "The test setup name `$(ts.name)` is used more than once in this file. Test setup names must be unique within a file.",
                ts.range
            ))
        end
    end

    return TestDetails(
        [TestItemDetail(
            uri,
            item_ids[i],
            ti.name,
            text[ti.code_range],
            ti.range,
            ti.code_range,
            ti.option_default_imports,
            ti.option_tags,
            ti.option_setup,
            ti.option_skip isa Bool ? ti.option_skip : text[ti.option_skip]
            ) for (i,ti) in enumerate(testitems)],
        [TestSetupDetail(
            uri,
            i.name,
            i.kind,
            text[i.code_range],
            i.range,
            i.code_range
            ) for i in testsetups],
        all_testerrors
    )
end

"""
    derived_v2_testitem_details(rt, uri) -> TestDetails

The v2 emission join (design doc §13): `derived_v2_file_testitems` carries the
position-free facts, and this query — mirroring `derived_semantic_lint_findings`
— reattaches what only positions can provide: `range`, `code_range`, the `code`
slice, and a non-literal skip expression's source text. Volatile by design; it
is one of the two legitimate readers of `derived_v2_file_maps`.

Lives here rather than in `src/v2/` because ids and the outside-package check
need `derived_package_for_file` and `testitem_id_scope`, which the v2 layer must
not touch.
"""
Salsa.@derived function derived_v2_testitem_details(rt, uri)
    @debug "derived_v2_testitem_details" uri=uri

    if !derived_testitems_selected(rt, uri)
        return TestDetails(TestItemDetail[], TestSetupDetail[], TestErrorDetail[])
    end

    recs = derived_v2_file_testitems(rt, uri)
    if isempty(recs.testitems) && isempty(recs.testerrors)
        return TestDetails(TestItemDetail[], TestSetupDetail[], TestErrorDetail[])
    end

    text_file = derived_text_file_content(rt, uri)
    text = text_file.content.content
    maps = derived_v2_file_maps(rt, uri)
    bodies = derived_v2_file_bodies(rt, uri)

    # Map ranges are byte ranges with an exclusive end; the raw detail shape
    # wants string-index ranges with an inclusive end (`our_range`).
    incl(r) = first(r):prevind(text, last(r))

    testitems = RawTestItemDetail[]
    testsetups = RawTestSetupDetail[]
    for t in recs.testitems
        rngs = get(maps, t.id, nothing)
        body = get(bodies, t.id, nothing)
        (rngs === nothing || body === nothing) && continue
        addrs = _v2_test_macro_addresses(body)
        addrs === nothing && continue

        range = incl(rngs[1])
        code_range = if addrs.block_first === nothing
            # The legacy shape for `begin end`: skip past the keywords.
            block = incl(rngs[addrs.block])
            (first(block) + 5):(last(block) - 3)
        else
            first(rngs[addrs.block_first]):last(incl(rngs[addrs.block_last]))
        end

        if t.kind === :testitem
            skip = if t.option_skip === nothing
                addrs.skip_value === nothing ? false : incl(rngs[addrs.skip_value])
            else
                t.option_skip
            end
            push!(testitems, RawTestItemDetail(
                t.label, range, code_range, t.option_default_imports,
                t.option_tags, t.option_setup, skip))
        else
            push!(testsetups, RawTestSetupDetail(
                Symbol(t.label), t.kind === :testsetup_module ? :module : :snippet,
                range, code_range))
        end
    end

    testerrors = RawTestErrorDetail[
        RawTestErrorDetail(e.name, e.message, incl(maps[e.id][1]))
        for e in recs.testerrors if haskey(maps, e.id)]

    return _assemble_test_details(rt, uri, text, testitems, testsetups, testerrors)
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

    # The test process is only restarted when this hash changes, so it must
    # cover every input the test environment is built from: the chosen
    # project (Project + Manifest), the package's own Project.toml and
    # Manifest, and the package's test/Project.toml and test/Manifest.toml
    # (see julia-vscode/julia-vscode#3022).
    # We fold everything with `hash(x, h)`, whose seed argument must be a
    # `UInt` (32 bit on 32 bit platforms), while `content_hash` fields are
    # `UInt64`. Keep the accumulator at native `UInt` width by hashing the
    # stored hash instead of seeding with it directly.
    env_content_hash = isnothing(project_uri) ? hash(nothing) : hash(derived_project(rt, project_uri).content_hash)
    if package_uri===nothing
        env_content_hash = hash(nothing, env_content_hash)
    else
        env_content_hash = hash(derived_package(rt, package_uri).content_hash, env_content_hash)

        package_project = derived_project(rt, package_uri)
        env_content_hash = hash(package_project === nothing ? nothing : package_project.content_hash, env_content_hash)

        test_folder_uri = filepath2uri(joinpath(uri2filepath(package_uri), "test"))
        test_toml_files = derived_project_toml_files(rt, test_folder_uri)
        for file in (test_toml_files.project_file, test_toml_files.manifest_file)
            text_file = file === nothing ? nothing : derived_text_file_content(rt, file)
            env_content_hash = hash(text_file === nothing ? nothing : text_file.content.content, env_content_hash)
        end
    end

    # We construct a string for the env content hash here so that later when we
    # deserialize it with JSON.jl we don't end up with Int conversion issues
    return JuliaTestEnv(package_name, package_uri, project_uri, "x$env_content_hash")
end
