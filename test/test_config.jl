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

@testitem "Config: a nested formatter or test items config reports it too" begin
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///sh3/JuliaFormat.toml"), SourceText("style = \"blue\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///sh3/src/JuliaFormat.toml"), SourceText("style = \"yas\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///sh3/JuliaTestItems.toml"), SourceText("include = [\"src/**\"]\n", "toml")))
    add_file!(jw, TextFile(URI("file:///sh3/src/JuliaTestItems.toml"), SourceText("include = [\"*.jl\"]\n", "toml")))

    @test any(d -> d.code === :shadowed_config, get_diagnostic(jw, URI("file:///sh3/src/JuliaFormat.toml")))
    @test any(d -> d.code === :shadowed_config, get_diagnostic(jw, URI("file:///sh3/src/JuliaTestItems.toml")))

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
