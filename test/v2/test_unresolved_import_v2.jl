# v2 `unresolved_import` (lint_lowering_rules.jl): the first env-dependent
# takeover rule. Workspaces without a project are env-ready by construction
# (nothing to index) and resolve against the core-only env, so `Base` is a
# present store and `NotAPackage`/`Printf` are missing ones.

@testsnippet UnresolvedImpWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_lowering_lint!
    using JuliaWorkspaces.URIs2: URI

    const UI_URI = URI("file:///ui/src/F.jl")

    function ui_workspace(src::String; flag=true)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(UI_URI, SourceText(src, "julia")))
        flag && set_lowering_lint!(jw, true)
        return jw
    end

    ui_diags(jw; uri=UI_URI) =
        filter(d -> d.code === :unresolved_import, get_diagnostic(jw, uri))
end

@testitem "v2 unresolved_import: messages and forms" setup=[UnresolvedImpWS] begin
    # Wildcard `using` of a missing package: cause + the scope consequence.
    jw = ui_workspace("using NotAPackage\n")
    d = only(ui_diags(jw))
    @test d.source == "JuliaWorkspaces.jl"
    @test d.message == "Failed to resolve `NotAPackage`. " *
        "Missing-reference checks are disabled in this scope and all nested scopes."

    # Non-wildcard forms get the assumed-to-exist consequence.
    jw = ui_workspace("import NotAPackage\n")
    @test only(ui_diags(jw)).message == "Failed to resolve `NotAPackage`. " *
        "Anything imported through this statement is assumed to exist and will not be checked."
    jw = ui_workspace("using NotAPackage: something\n")
    @test occursin("will not be checked", only(ui_diags(jw)).message)

    # The message names the FIRST unresolved component of a dotted path.
    jw = ui_workspace("using Base.NoSuchSub\n")
    @test occursin("`NoSuchSub`", only(ui_diags(jw)).message)

    # Present stores and tree targets are silent.
    jw = ui_workspace("using Base\nusing Base.Threads\nimport Base: println\nmodule M\nend\nusing .M\n")
    @test isempty(ui_diags(jw))
end

@testitem "v2 unresolved_import: unresolved relative imports" setup=[UnresolvedImpWS] begin
    # A relative import that lands nowhere.
    jw = ui_workspace("module P\nusing ..Nowhere\nend\n")
    @test occursin("`Nowhere`", only(ui_diags(jw)).message)

    # Dots exceeding the nesting are relative_import's finding, not this
    # rule's (v1's no-double-diagnosis).
    jw = ui_workspace("module P\nusing ....Foo\nend\n")
    @test isempty(ui_diags(jw))
    @test any(d -> d.code === :relative_import, get_diagnostic(jw, UI_URI))

    # A relative import the pass-2 ledger re-attempt resolves is silent — this
    # rule can never contradict what visibility bound.
    jw = ui_workspace("""
    module Parent
    import Base
    module Child
    using ..Base
    end
    end
    """)
    @test isempty(ui_diags(jw))

    # The same shape through a MISSING store still fails, at the ledger name.
    jw = ui_workspace("""
    module Parent
    using Printf
    module Child
    using ..Printf
    end
    end
    """)
    ds = ui_diags(jw)
    @test length(ds) == 2   # Parent's `using Printf` and Child's re-attempt
    @test all(d -> occursin("`Printf`", d.message), ds)
end

@testitem "v2 unresolved_import: takeover and flag-off" setup=[UnresolvedImpWS] begin
    # Flag on: v2 reports, StaticLint's finding for the same statement is
    # suppressed.
    jw = ui_workspace("using NotAPackage\n")
    @test all(d -> d.source == "JuliaWorkspaces.jl", ui_diags(jw))

    # Flag off: nothing from the v2 producer.
    jw = ui_workspace("using NotAPackage\n"; flag=false)
    @test !any(d -> d.source == "JuliaWorkspaces.jl", ui_diags(jw))
end

@testitem "v2 unresolved_import: env-ready gating" setup=[UnresolvedImpWS] begin
    # A workspace WITH a project that requires indexing is not env-ready, so
    # the env-dependent v2 finding is suppressed at materialization…
    project = "name = \"UiPkg\"\nuuid = \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee31\"\nversion = \"0.1.0\"\n"
    manifest = "julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc\"\n\n[deps]\n"
    src_uri = URI("file:///uip/src/UiPkg.jl")
    function pkg_workspace(; ready)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///uip/Project.toml"), SourceText(project, "toml")))
        add_file!(jw, TextFile(URI("file:///uip/Manifest.toml"), SourceText(manifest, "toml")))
        add_file!(jw, TextFile(src_uri, SourceText("module UiPkg\nusing NotAPackage\nend\n", "julia")))
        set_lowering_lint!(jw, true)
        ready && JW.set_input_env_ready!(jw.runtime, true)
        return jw
    end
    jw = pkg_workspace(ready=false)
    @test isempty(ui_diags(jw; uri=src_uri))
    # …and appears once the env is ready. A non-env-dependent v2 rule
    # (unused_binding) emits either way.
    jw = pkg_workspace(ready=true)
    @test !isempty(ui_diags(jw; uri=src_uri))
end
