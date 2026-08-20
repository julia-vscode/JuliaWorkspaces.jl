@testitem "Glob: segment wildcards do not cross separators" begin
    m(p, s) = JuliaWorkspaces.matches(JuliaWorkspaces.GlobPattern(p), s)

    @test m("*.jl", "foo.jl")
    @test !m("*.jl", "foo.txt")
    # A pattern with no separator matches at any depth (gitignore semantics).
    @test m("*.jl", "a/b/foo.jl")
    # An anchored one does not.
    @test !m("/*.jl", "a/foo.jl")
    @test m("/*.jl", "foo.jl")
end

@testitem "Glob: ** spans path segments" begin
    m(p, s) = JuliaWorkspaces.matches(JuliaWorkspaces.GlobPattern(p), s)

    @test m("**/*.jl", "foo.jl")
    @test m("**/*.jl", "a/b/c/foo.jl")
    @test m("test/**", "test/foo.jl")
    @test m("test/**", "test/a/b/foo.jl")
    @test !m("test/**", "src/foo.jl")
    @test !m("test/**", "test")
end

@testitem "Glob: directory suffix matches everything below" begin
    m(p, s) = JuliaWorkspaces.matches(JuliaWorkspaces.GlobPattern(p), s)

    @test m("gen/", "gen/foo.jl")
    @test m("gen/", "gen/a/foo.jl")
    @test !m("gen/", "generated.jl")
end

@testitem "Glob: ? and character classes" begin
    m(p, s) = JuliaWorkspaces.matches(JuliaWorkspaces.GlobPattern(p), s)

    @test m("/foo?.jl", "fooa.jl")
    @test !m("/foo?.jl", "foo.jl")
    @test !m("/foo?.jl", "foo/.jl")
    @test m("/foo[12].jl", "foo1.jl")
    @test !m("/foo[12].jl", "foo3.jl")
    @test m("/foo[!12].jl", "foo3.jl")
end

@testitem "Glob: separators are normalized" begin
    m(p, s) = JuliaWorkspaces.matches(JuliaWorkspaces.GlobPattern(p), s)

    # Windows-style separators in the pattern behave like `/`.
    @test m("test\\**", "test/foo.jl")
end

@testitem "Glob: patterns compare and hash by their written form" begin
    a = JuliaWorkspaces.GlobPattern("test/**")
    b = JuliaWorkspaces.GlobPattern("test/**")
    c = JuliaWorkspaces.GlobPattern("src/**")

    @test a == b
    @test isequal(a, b)
    @test hash(a) == hash(b)
    @test a != c
end

@testitem "PathFilter: exclude beats include, empty include means all" begin
    G = JuliaWorkspaces.GlobPattern
    sel = JuliaWorkspaces.path_selected

    @test sel(JuliaWorkspaces.PathFilter(), "anything.jl")
    @test sel(JuliaWorkspaces.PathFilter([G("**/*.jl")], JuliaWorkspaces.GlobPattern[]), "a/b.jl")
    @test !sel(JuliaWorkspaces.PathFilter([G("**/*.jl")], JuliaWorkspaces.GlobPattern[]), "a/b.txt")
    @test !sel(JuliaWorkspaces.PathFilter([G("**/*.jl")], [G("gen/**")]), "gen/b.jl")
end

@testitem "config_relative_path: only paths below the config dir" begin
    rel = JuliaWorkspaces.config_relative_path

    @test rel("/proj", "/proj/src/a.jl") == "src/a.jl"
    @test rel("/proj/", "/proj/a.jl") == "a.jl"
    @test rel("/proj", "/other/a.jl") === nothing
end

@testitem "Lint rules: every preset classifies every rule" begin
    # A rule no preset mentions would be reported at whatever severity the
    # lookup fell back to, in every project naming a preset, from the moment the
    # tool is upgraded. `lint_rules.jl` enforces this at load; this test states
    # the invariant so a refactor there cannot quietly drop it.
    for (name, preset) in JuliaWorkspaces.LINT_PRESETS
        for rule in JuliaWorkspaces.LINT_RULES
            @test haskey(preset, rule.id)
        end
        # ...and no preset invents a rule that does not exist.
        for id in keys(preset)
            @test haskey(JuliaWorkspaces.LINT_RULES_BY_ID, id)
        end
    end
end

@testitem "Lint rules: preset severities match the pre-registry values" begin
    # The presets used to be three hand-written dicts; they are now derived from
    # per-rule severity fields. This pins every value to what the hand-written
    # dicts contained, so the registry refactor is provably behavior-neutral and
    # any future change to a preset severity is a conscious test update.
    expected_default = Dict{Symbol,Symbol}(
        :incorrect_call_args => :information,
        :incorrect_iter_spec => :information,
        :index_from_length => :information,
        :nothing_comparison => :information,
        :const_if_condition => :information,
        :pointless_boolean => :information,
        :invalid_type_declaration => :information,
        :unused_type_parameter => :hint,
        :module_name => :information,
        :type_piracy => :information,
        :unused_function_argument => :hint,
        :duplicate_function_argument => :information,
        :kw_default_mismatch => :information,
        :literal_use => :information,
        :break_continue => :information,
        :global_const_decl => :information,
        :unused_binding => :hint,
        :const_decl => :information,
        :relative_import => :information,
        :include_errors => :warning,
        :missing_reference => :warning,
        :unresolved_import => :warning,
        :syntax_errors => :error,
        :syntax_warnings => :off,
        :testitem_errors => :error,
        :toml_syntax_errors => :error,
        :config_errors => :error,
        :shadowed_config => :information,
        :environment_errors => :information,
        # Syntactic rules added with the rule registry; off outside `strict`.
        :nan_comparison => :off,
        :duplicate_branch_condition => :off,
        :string_concat_style => :off,
        :bare_using => :off,
        :debug_statement => :off,
        :async_task => :off,
    )
    @test JuliaWorkspaces.LINT_PRESETS["default"] == expected_default

    # minimal: everything off except the checks that catch outright breakage.
    expected_minimal = Dict{Symbol,Symbol}(
        r.id => get(
            Dict{Symbol,Symbol}(
                :syntax_errors => :error,
                :testitem_errors => :error,
                :toml_syntax_errors => :error,
                :config_errors => :error,
                :include_errors => :warning,
                :const_decl => :warning,
                :shadowed_config => :information,
            ),
            r.id,
            :off,
        )
        for r in JuliaWorkspaces.LINT_RULES
    )
    @test JuliaWorkspaces.LINT_PRESETS["minimal"] == expected_minimal

    # strict: everything on, hints/infos/offs promoted to warnings.
    expected_strict = Dict{Symbol,Symbol}(
        r.id => begin
            d = expected_default[r.id]
            r.id === :syntax_warnings ? :warning :
            d in (:off, :hint, :information) ? :warning : d
        end
        for r in JuliaWorkspaces.LINT_RULES
    )
    @test JuliaWorkspaces.LINT_PRESETS["strict"] == expected_strict

    # The env-dependent set, formerly a side table, now derived from rule fields.
    @test JuliaWorkspaces.ENV_DEPENDENT_LINT_RULES == Set([
        :incorrect_call_args, :incorrect_iter_spec, :nothing_comparison,
        :invalid_type_declaration, :type_piracy, :kw_default_mismatch,
        :missing_reference, :unresolved_import,
    ])

    # Tags and doc links, formerly side tables.
    @test JuliaWorkspaces.rule_tags(:unused_binding) == [:unnecessary]
    @test JuliaWorkspaces.rule_tags(:unused_function_argument) == [:unnecessary]
    @test JuliaWorkspaces.rule_tags(:unused_type_parameter) == [:unnecessary]
    @test JuliaWorkspaces.rule_tags(:nothing_comparison) == Symbol[]
    @test JuliaWorkspaces.rule_code_description(:index_from_length) !== nothing
    @test JuliaWorkspaces.rule_code_description(:nothing_comparison) === nothing
end

@testitem "Lint config: a nested config reports that it supersedes the outer one" begin
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sh/JuliaLint.toml"), SourceText("[rules]\nunused_binding = \"off\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///sh/src/JuliaLint.toml"), SourceText("[rules]\nunused_binding = \"error\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///sh/src/deep/JuliaLint.toml"), SourceText("preset = \"minimal\"\n", "toml")))

    # The outermost config supersedes nothing.
    @test !any(d -> d.code === :shadowed_config, get_diagnostic(jw, URI("file:///sh/JuliaLint.toml")))

    nested = get_diagnostic(jw, URI("file:///sh/src/JuliaLint.toml"))
    idx = findfirst(d -> d.code === :shadowed_config, nested)
    @test idx !== nothing
    @test nested[idx].severity === :information
    @test occursin("JuliaLint.toml", nested[idx].message)

    # It names the NEAREST enclosing config, not the outermost one.
    deep = get_diagnostic(jw, URI("file:///sh/src/deep/JuliaLint.toml"))
    jdx = findfirst(d -> d.code === :shadowed_config, deep)
    @test jdx !== nothing
    @test occursin("src", deep[jdx].message)
end

@testitem "Lint config: the shadowing warning is an ordinary rule" begin
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sh2/JuliaLint.toml"), SourceText("preset = \"default\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///sh2/src/JuliaLint.toml"),
        SourceText("[rules]\nshadowed_config = \"off\"\n", "toml")))

    @test !any(d -> d.code === :shadowed_config, get_diagnostic(jw, URI("file:///sh2/src/JuliaLint.toml")))
end

@testitem "Config: a nested formatter config reports it too" begin
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sh3/JuliaFormat.toml"), SourceText("style = \"blue\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///sh3/src/JuliaFormat.toml"), SourceText("style = \"yas\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///sh3/JuliaTestItems.toml"), SourceText("include = [\"src/**\"]\n", "toml")))
    add_file!(jw, TextFile(URI("file:///sh3/src/JuliaTestItems.toml"), SourceText("include = [\"*.jl\"]\n", "toml")))

    fmt = get_diagnostic(jw, URI("file:///sh3/src/JuliaFormat.toml"))
    idx = findfirst(d -> d.code === :shadowed_config, fmt)
    @test idx !== nothing
    # The message says what still survives the takeover.
    @test occursin("include", fmt[idx].message) && occursin("narrow", fmt[idx].message)

    # A nested `JuliaTestItems.toml` shadows nothing: v1 of that file has only
    # scope keys, and scope composes over the chain instead of being replaced.
    @test !any(d -> d.code === :shadowed_config, get_diagnostic(jw, URI("file:///sh3/src/JuliaTestItems.toml")))

    # Different kinds don't shadow each other.
    @test !any(d -> d.code === :shadowed_config, get_diagnostic(jw, URI("file:///sh3/JuliaFormat.toml")))
end

@testitem "Config: config-version is reserved" begin
    using JuliaWorkspaces.URIs2: URI

    function diags(name, content)
        jw = JuliaWorkspace()
        uri = URI("file:///cv/" * name)
        add_file!(jw, TextFile(uri, SourceText(content, "toml")))
        return get_diagnostic(jw, uri)
    end

    # Absent and current are both fine.
    @test isempty(diags("JuliaLint.toml", "preset = \"default\"\n"))
    @test isempty(diags("JuliaLint.toml", "config-version = 1\npreset = \"default\"\n"))

    # A file from the future says so, rather than complaining about an unknown key.
    for name in ("JuliaLint.toml", "JuliaFormat.toml", "JuliaTestItems.toml")
        d = diags(name, "config-version = 2\n")
        @test any(x -> occursin("only understands version 1", x.message), d)
    end

    @test any(x -> occursin("expected a positive integer", x.message),
              diags("JuliaLint.toml", "config-version = \"one\"\n"))
end

# Settings only — scope composes over the chain instead, see the veto tests below.
@testitem "Lint config: nearest file governs, no merging" begin
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///nc/JuliaLint.toml"),
        SourceText("[rules]\nunused_binding = \"off\"\ntype_piracy = \"off\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///nc/src/JuliaLint.toml"),
        SourceText("[rules]\nunused_binding = \"error\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///nc/src/a.jl"), SourceText("x = 1\n", "julia")))
    add_file!(jw, TextFile(URI("file:///nc/b.jl"), SourceText("x = 1\n", "julia")))

    inner = JuliaWorkspaces.derived_effective_lint_config(jw.runtime, URI("file:///nc/src/a.jl"))
    @test JuliaWorkspaces.rule_severity(inner, :unused_binding) === :error
    # `type_piracy` is off only in the OUTER file, which does not apply here.
    @test JuliaWorkspaces.rule_enabled(inner, :type_piracy)

    outer = JuliaWorkspaces.derived_effective_lint_config(jw.runtime, URI("file:///nc/b.jl"))
    @test JuliaWorkspaces.rule_severity(outer, :unused_binding) === :off
    @test !JuliaWorkspaces.rule_enabled(outer, :type_piracy)
end

@testitem "Lint config: presets set the severity baseline" begin
    using JuliaWorkspaces.URIs2: URI

    function cfg_for(content)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///pre/JuliaLint.toml"), SourceText(content, "toml")))
        add_file!(jw, TextFile(URI("file:///pre/a.jl"), SourceText("x = 1\n", "julia")))
        return JuliaWorkspaces.derived_effective_lint_config(jw.runtime, URI("file:///pre/a.jl"))
    end

    default = cfg_for("preset = \"default\"")
    @test JuliaWorkspaces.rule_severity(default, :unused_binding) === :hint
    @test JuliaWorkspaces.rule_severity(default, :syntax_errors) === :error

    minimal = cfg_for("preset = \"minimal\"")
    @test JuliaWorkspaces.rule_severity(minimal, :unused_binding) === :off
    @test JuliaWorkspaces.rule_severity(minimal, :type_piracy) === :off
    # Outright breakage stays reported even in the minimal preset.
    @test JuliaWorkspaces.rule_severity(minimal, :syntax_errors) === :error

    strict = cfg_for("preset = \"strict\"")
    @test JuliaWorkspaces.rule_severity(strict, :unused_binding) === :warning
    @test JuliaWorkspaces.rule_severity(strict, :syntax_warnings) === :warning

    # A `[rules]` entry is a delta on the preset.
    mixed = cfg_for("preset = \"minimal\"\n[rules]\nunused_binding = \"error\"")
    @test JuliaWorkspaces.rule_severity(mixed, :unused_binding) === :error
    @test JuliaWorkspaces.rule_severity(mixed, :type_piracy) === :off
end

@testitem "Lint config: override blocks re-scope rules by path" begin
    using JuliaWorkspaces.URIs2: URI

    config = """
    [rules]
    unused_binding = "error"

    [[override]]
    paths = ["test/**"]

    [override.rules]
    unused_binding = "off"
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///ovr/JuliaLint.toml"), SourceText(config, "toml")))
    add_file!(jw, TextFile(URI("file:///ovr/src/a.jl"), SourceText("x = 1\n", "julia")))
    add_file!(jw, TextFile(URI("file:///ovr/test/a.jl"), SourceText("x = 1\n", "julia")))

    src = JuliaWorkspaces.derived_effective_lint_config(jw.runtime, URI("file:///ovr/src/a.jl"))
    tst = JuliaWorkspaces.derived_effective_lint_config(jw.runtime, URI("file:///ovr/test/a.jl"))

    @test JuliaWorkspaces.rule_severity(src, :unused_binding) === :error
    @test JuliaWorkspaces.rule_severity(tst, :unused_binding) === :off
end

@testitem "Lint config: later override blocks win" begin
    using JuliaWorkspaces.URIs2: URI

    config = """
    [[override]]
    paths = ["src/**"]

    [override.rules]
    unused_binding = "error"

    [[override]]
    paths = ["src/gen/**"]

    [override.rules]
    unused_binding = "off"
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///ovr2/JuliaLint.toml"), SourceText(config, "toml")))
    add_file!(jw, TextFile(URI("file:///ovr2/src/a.jl"), SourceText("x = 1\n", "julia")))
    add_file!(jw, TextFile(URI("file:///ovr2/src/gen/a.jl"), SourceText("x = 1\n", "julia")))

    plain = JuliaWorkspaces.derived_effective_lint_config(jw.runtime, URI("file:///ovr2/src/a.jl"))
    gen = JuliaWorkspaces.derived_effective_lint_config(jw.runtime, URI("file:///ovr2/src/gen/a.jl"))

    @test JuliaWorkspaces.rule_severity(plain, :unused_binding) === :error
    @test JuliaWorkspaces.rule_severity(gen, :unused_binding) === :off
end

@testitem "Lint config: exclude suppresses a file's diagnostics" begin
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///lex/JuliaLint.toml"),
        SourceText("exclude = [\"gen/**\"]\n", "toml")))
    add_file!(jw, TextFile(URI("file:///lex/gen/a.jl"), SourceText("function foo() end begin", "julia")))
    add_file!(jw, TextFile(URI("file:///lex/b.jl"), SourceText("function foo() end begin", "julia")))

    @test isempty(get_diagnostic(jw, URI("file:///lex/gen/a.jl")))
    @test !isempty(get_diagnostic(jw, URI("file:///lex/b.jl")))
end

@testitem "Lint config: an excluded config file still validates itself" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:///selfex/JuliaLint.toml")

    jw = JuliaWorkspace()
    # The config excludes everything, including the directory it lives in.
    add_file!(jw, TextFile(config_uri, SourceText("exclude = [\"**\"]\nbogus_key = 1\n", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "bogus_key"), diags)
end

@testitem "Lint config: severity overrides the built-in severity" begin
    using JuliaWorkspaces.URIs2: URI

    source = """
    module SevTest
    function foo()
        unused_local = 1
        return 0
    end
    end
    """

    project_toml = """
    name = "SevTest"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee11"
    version = "0.1.0"
    """

    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    function diags_with(config)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///sev/Project.toml"), SourceText(project_toml, "toml")))
        add_file!(jw, TextFile(URI("file:///sev/Manifest.toml"), SourceText(manifest_toml, "toml")))
        add_file!(jw, TextFile(URI("file:///sev/src/SevTest.jl"), SourceText(source, "julia")))
        config === nothing ||
            add_file!(jw, TextFile(URI("file:///sev/JuliaLint.toml"), SourceText(config, "toml")))
        return get_diagnostic(jw, URI("file:///sev/src/SevTest.jl"))
    end

    baseline = diags_with(nothing)
    hint = findfirst(d -> d.code === :unused_binding, baseline)
    @test hint !== nothing
    @test baseline[hint].severity === :hint
    @test :unnecessary in baseline[hint].tags

    promoted = diags_with("[rules]\nunused_binding = \"error\"")
    idx = findfirst(d -> d.code === :unused_binding, promoted)
    @test idx !== nothing
    @test promoted[idx].severity === :error
    # The tag is a property of the rule, not of the configured severity.
    @test :unnecessary in promoted[idx].tags

    silenced = diags_with("[rules]\nunused_binding = \"off\"")
    @test !any(d -> d.code === :unused_binding, silenced)
end

@testitem "Lint config: diagnostics carry their rule id" begin
    using JuliaWorkspaces.URIs2: URI

    uri = URI("file:///codes/a.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText("function foo() end begin", "julia")))

    diags = get_diagnostic(jw, uri)
    @test !isempty(diags)
    @test all(d -> d.code === :syntax_errors, diags)
end

@testitem "Test items config: exclude removes discovery" begin
    using JuliaWorkspaces.URIs2: URI

    content = """
    module TIC
    @testitem "t" begin
        @test true
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///tic/Project.toml"),
        SourceText("name = \"TIC\"\nuuid = \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee12\"\nversion = \"0.1.0\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///tic/src/TIC.jl"), SourceText(content, "julia")))
    add_file!(jw, TextFile(URI("file:///tic/other/TIC2.jl"), SourceText(content, "julia")))
    add_file!(jw, TextFile(URI("file:///tic/JuliaTestItems.toml"),
        SourceText("exclude = [\"other/**\"]\n", "toml")))

    @test !isempty(JuliaWorkspaces.derived_testitems(jw.runtime, URI("file:///tic/src/TIC.jl")).testitems)
    @test isempty(JuliaWorkspaces.derived_testitems(jw.runtime, URI("file:///tic/other/TIC2.jl")).testitems)
end

@testitem "Test items config: include restricts discovery" begin
    using JuliaWorkspaces.URIs2: URI

    content = """
    module TIC3
    @testitem "t" begin
        @test true
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///tic3/Project.toml"),
        SourceText("name = \"TIC3\"\nuuid = \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee13\"\nversion = \"0.1.0\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///tic3/src/TIC3.jl"), SourceText(content, "julia")))
    add_file!(jw, TextFile(URI("file:///tic3/extra/More.jl"), SourceText(content, "julia")))
    add_file!(jw, TextFile(URI("file:///tic3/JuliaTestItems.toml"),
        SourceText("include = [\"src/**\"]\n", "toml")))

    @test !isempty(JuliaWorkspaces.derived_testitems(jw.runtime, URI("file:///tic3/src/TIC3.jl")).testitems)
    @test isempty(JuliaWorkspaces.derived_testitems(jw.runtime, URI("file:///tic3/extra/More.jl")).testitems)
end

@testitem "Test items config: unknown key produces a diagnostic" begin
    using JuliaWorkspaces.URIs2: URI

    config_uri = URI("file:///tic4/JuliaTestItems.toml")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(config_uri, SourceText("workers = 4\n", "toml")))

    diags = get_diagnostic(jw, config_uri)
    @test any(d -> contains(d.message, "Invalid test items configuration key `workers`"), diags)
    @test all(d -> d.code === :config_errors, diags)
end

@testitem "Code actions: a fix for a disabled rule is not offered" begin
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "QF"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee14"
    version = "0.1.0"
    """

    manifest_toml = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module QF
    function f(x)
        unused_local = 1
        return x
    end
    end
    """

    # Inside the unused binding's name.
    offset = first(findfirst("unused_local", source)) + 1

    function actions_with(config)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///qf/Project.toml"), SourceText(project_toml, "toml")))
        add_file!(jw, TextFile(URI("file:///qf/Manifest.toml"), SourceText(manifest_toml, "toml")))
        add_file!(jw, TextFile(URI("file:///qf/src/QF.jl"), SourceText(source, "julia")))
        config === nothing ||
            add_file!(jw, TextFile(URI("file:///qf/JuliaLint.toml"), SourceText(config, "toml")))
        return get_code_actions(jw, URI("file:///qf/src/QF.jl"), offset, String[])
    end

    @test any(a -> a.id == "ReplaceUnusedAssignmentName", actions_with(nothing))

    # Turning the rule off withdraws its fix along with its diagnostic.
    @test !any(a -> a.id == "ReplaceUnusedAssignmentName",
               actions_with("[rules]\nunused_binding = \"off\""))

    # Lowering the severity is not the same as disabling it; the fix stays.
    @test any(a -> a.id == "ReplaceUnusedAssignmentName",
              actions_with("[rules]\nunused_binding = \"error\""))
end

@testitem "Code actions: refactorings ignore lint config" begin
    using JuliaWorkspaces.URIs2: URI

    source = """
    module RF
    f(x) = x + 1
    end
    """

    # On the `x` in the single-line function body.
    offset = first(findlast("x + 1", source))

    function actions_with(config)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///rf/Project.toml"),
            SourceText("name = \"RF\"\nuuid = \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee15\"\nversion = \"0.1.0\"\n", "toml")))
        add_file!(jw, TextFile(URI("file:///rf/src/RF.jl"), SourceText(source, "julia")))
        config === nothing ||
            add_file!(jw, TextFile(URI("file:///rf/JuliaLint.toml"), SourceText(config, "toml")))
        return [a.id for a in get_code_actions(jw, URI("file:///rf/src/RF.jl"), offset, String[])]
    end

    # `ExpandFunction` fixes no rule, so even the most restrictive config keeps it.
    @test "ExpandFunction" in actions_with(nothing)
    @test "ExpandFunction" in actions_with("preset = \"minimal\"")
end

@testitem "Config chain: ancestor_configs walks outermost to innermost" begin
    using JuliaWorkspaces.URIs2: URI

    ancestors(uris, u) = JuliaWorkspaces.ancestor_configs(uris, URI(u))

    root = URI("file:///p/JuliaTestItems.toml")
    mid = URI("file:///p/packages/JuliaTestItems.toml")
    deep = URI("file:///p/packages/Foo/JuliaTestItems.toml")
    other = URI("file:///q/JuliaTestItems.toml")

    # Outermost first, and the ordering does not depend on the input order.
    for input in ([root, mid, deep, other], [deep, other, root, mid])
        @test ancestors(input, "file:///p/packages/Foo/src/a.jl") == [root, mid, deep]
    end

    @test ancestors([root, mid, deep], "file:///p/a.jl") == [root]
    @test isempty(ancestors([root, mid, deep], "file:///elsewhere/a.jl"))
    @test isempty(ancestors([root], "untitled:Untitled-1"))

    # `nearest_config` is the innermost entry of the same chain.
    @test JuliaWorkspaces.nearest_config([root, mid, deep], URI("file:///p/packages/Foo/src/a.jl")) == deep
    @test JuliaWorkspaces.nearest_config([root, mid, deep], URI("file:///elsewhere/a.jl")) === nothing

    # A config never counts as its own strict ancestor.
    @test JuliaWorkspaces.strict_ancestor_configs([root, mid, deep], deep) == [root, mid]
    @test isempty(JuliaWorkspaces.strict_ancestor_configs([root, mid, deep], root))
end

@testitem "Config chain: scope_selected is the intersection over the chain" begin
    using JuliaWorkspaces.URIs2: URI

    root = URI("file:///p/JuliaTestItems.toml")
    nested = URI("file:///p/packages/Foo/JuliaTestItems.toml")

    filters = Dict{URI,JuliaWorkspaces.PathFilter}()
    pf(inc, exc) = JuliaWorkspaces.PathFilter(
        JuliaWorkspaces.GlobPattern[JuliaWorkspaces.GlobPattern(x) for x in inc],
        JuliaWorkspaces.GlobPattern[JuliaWorkspaces.GlobPattern(x) for x in exc],
    )
    sel(path) = JuliaWorkspaces.scope_selected([root, nested], path, c -> filters[c])

    # The parent excludes the subtree; the nested file cannot take it back.
    filters[root] = pf(String[], ["packages/**"])
    filters[nested] = pf(String[], String[])
    @test !sel("/p/packages/Foo/src/a.jl")

    # Not even with an explicit `include`.
    filters[nested] = pf(["**/*.jl"], String[])
    @test !sel("/p/packages/Foo/src/a.jl")

    # A nested file may narrow further.
    filters[root] = pf(String[], String[])
    filters[nested] = pf(String[], ["gen/**"])
    @test sel("/p/packages/Foo/src/a.jl")
    @test !sel("/p/packages/Foo/gen/a.jl")

    # A nested `include` cannot widen the parent's.
    filters[root] = pf(["packages/Foo/src/**"], String[])
    filters[nested] = pf(["**"], String[])
    @test sel("/p/packages/Foo/src/a.jl")
    @test !sel("/p/packages/Foo/docs/a.jl")
end

@testitem "Test items config: a vendored config cannot undo an enclosing exclude" begin
    using JuliaWorkspaces.URIs2: URI

    content = """
    module Foo
    @testitem "t" begin
        @test true
    end
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///veto/Project.toml"),
        SourceText("name = \"Veto\"\nuuid = \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee21\"\nversion = \"0.1.0\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///veto/JuliaTestItems.toml"),
        SourceText("exclude = [\"packages/**\"]\n", "toml")))
    add_file!(jw, TextFile(URI("file:///veto/src/Veto.jl"), SourceText(content, "julia")))

    # A vendored package carrying its own config, which under nearest-wins would
    # have resurrected the whole subtree.
    add_file!(jw, TextFile(URI("file:///veto/packages/Foo/Project.toml"),
        SourceText("name = \"Foo\"\nuuid = \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee22\"\nversion = \"0.1.0\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///veto/packages/Foo/JuliaTestItems.toml"),
        SourceText("include = [\"**/*.jl\"]\n", "toml")))
    add_file!(jw, TextFile(URI("file:///veto/packages/Foo/src/Foo.jl"), SourceText(content, "julia")))

    @test !isempty(JuliaWorkspaces.derived_testitems(jw.runtime, URI("file:///veto/src/Veto.jl")).testitems)
    @test isempty(JuliaWorkspaces.derived_testitems(jw.runtime, URI("file:///veto/packages/Foo/src/Foo.jl")).testitems)

    # And the whole-workspace sweep agrees: it is keyed by file, and the
    # vendored file contributes no test items to it.
    sweep = JuliaWorkspaces.derived_all_testitems(jw.runtime)
    @test !isempty(sweep[URI("file:///veto/src/Veto.jl")].testitems)
    @test isempty(sweep[URI("file:///veto/packages/Foo/src/Foo.jl")].testitems)
end

@testitem "Test items config: a nested config may still narrow discovery" begin
    using JuliaWorkspaces.URIs2: URI

    content = """
    @testitem "t" begin
        @test true
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///narrow/Project.toml"),
        SourceText("name = \"Narrow\"\nuuid = \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee23\"\nversion = \"0.1.0\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///narrow/JuliaTestItems.toml"), SourceText("\n", "toml")))
    add_file!(jw, TextFile(URI("file:///narrow/sub/JuliaTestItems.toml"),
        SourceText("exclude = [\"gen/**\"]\n", "toml")))
    add_file!(jw, TextFile(URI("file:///narrow/sub/src/a.jl"), SourceText(content, "julia")))
    add_file!(jw, TextFile(URI("file:///narrow/sub/gen/b.jl"), SourceText(content, "julia")))

    @test !isempty(JuliaWorkspaces.derived_testitems(jw.runtime, URI("file:///narrow/sub/src/a.jl")).testitems)
    @test isempty(JuliaWorkspaces.derived_testitems(jw.runtime, URI("file:///narrow/sub/gen/b.jl")).testitems)
end

@testitem "Test items config: a nested include cannot widen an enclosing one" begin
    using JuliaWorkspaces.URIs2: URI

    content = """
    @testitem "t" begin
        @test true
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///widen/Project.toml"),
        SourceText("name = \"Widen\"\nuuid = \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee24\"\nversion = \"0.1.0\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///widen/JuliaTestItems.toml"),
        SourceText("include = [\"src/**\"]\n", "toml")))
    add_file!(jw, TextFile(URI("file:///widen/docs/JuliaTestItems.toml"),
        SourceText("include = [\"**\"]\n", "toml")))
    add_file!(jw, TextFile(URI("file:///widen/src/a.jl"), SourceText(content, "julia")))
    add_file!(jw, TextFile(URI("file:///widen/docs/b.jl"), SourceText(content, "julia")))

    @test !isempty(JuliaWorkspaces.derived_testitems(jw.runtime, URI("file:///widen/src/a.jl")).testitems)
    @test isempty(JuliaWorkspaces.derived_testitems(jw.runtime, URI("file:///widen/docs/b.jl")).testitems)
end

@testitem "Lint config: a vendored config cannot undo an enclosing exclude" begin
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///lveto/JuliaLint.toml"),
        SourceText("exclude = [\"vendor/**\"]\n", "toml")))
    add_file!(jw, TextFile(URI("file:///lveto/vendor/JuliaLint.toml"),
        SourceText("preset = \"strict\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///lveto/a.jl"), SourceText("function foo() end begin", "julia")))
    add_file!(jw, TextFile(URI("file:///lveto/vendor/b.jl"), SourceText("function foo() end begin", "julia")))
    add_file!(jw, TextFile(URI("file:///lveto/nested/JuliaLint.toml"),
        SourceText("preset = \"strict\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///lveto/nested/c.jl"), SourceText("x = 1\n", "julia")))

    @test !isempty(get_diagnostic(jw, URI("file:///lveto/a.jl")))
    @test isempty(get_diagnostic(jw, URI("file:///lveto/vendor/b.jl")))

    # Settings are unaffected: they still come from the nearest file alone.
    nested = JuliaWorkspaces.derived_effective_lint_config(jw.runtime, URI("file:///lveto/nested/c.jl"))
    @test nested.selected
    @test JuliaWorkspaces.rule_severity(nested, :unused_binding) === :warning
end

@testitem "Format config: a vendored config cannot undo an enclosing exclude" begin
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///fveto/JuliaFormat.toml"),
        SourceText("exclude = [\"vendor/**\"]\n", "toml")))
    add_file!(jw, TextFile(URI("file:///fveto/vendor/JuliaFormat.toml"),
        SourceText("style = \"blue\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///fveto/a.jl"), SourceText("x = 1\n", "julia")))
    add_file!(jw, TextFile(URI("file:///fveto/vendor/b.jl"), SourceText("x = 1\n", "julia")))
    add_file!(jw, TextFile(URI("file:///fveto/nested/JuliaFormat.toml"),
        SourceText("style = \"blue\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///fveto/nested/c.jl"), SourceText("x = 1\n", "julia")))

    @test !is_format_excluded(jw, URI("file:///fveto/a.jl"))
    @test is_format_excluded(jw, URI("file:///fveto/vendor/b.jl"))

    # Style still comes from the nearest file for a file that is in scope.
    @test JuliaWorkspaces.derived_format_configuration(jw.runtime, URI("file:///fveto/nested/c.jl")).style == "blue"
end

@testitem "Config: a config file inside an excluded subtree is silent" begin
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///quiet/JuliaLint.toml"),
        SourceText("exclude = [\"vendor/**\"]\n", "toml")))
    # Deliberately broken configs inside the subtree the project set aside.
    add_file!(jw, TextFile(URI("file:///quiet/vendor/JuliaTestItems.toml"),
        SourceText("workers = 4\n", "toml")))
    add_file!(jw, TextFile(URI("file:///quiet/vendor/JuliaLint.toml"),
        SourceText("bogus_key = 1\n", "toml")))

    @test isempty(get_diagnostic(jw, URI("file:///quiet/vendor/JuliaTestItems.toml")))
    @test isempty(get_diagnostic(jw, URI("file:///quiet/vendor/JuliaLint.toml")))

    # But a config excluding its own directory still reports its own mistakes,
    # or a bad `exclude` could hide the diagnostic that explains it.
    jw2 = JuliaWorkspace()
    add_file!(jw2, TextFile(URI("file:///quiet2/JuliaLint.toml"),
        SourceText("exclude = [\"**\"]\nbogus_key = 1\n", "toml")))
    @test any(d -> d.code === :config_errors, get_diagnostic(jw2, URI("file:///quiet2/JuliaLint.toml")))
end
