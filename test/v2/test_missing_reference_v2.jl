# v2 `missing_reference` (lint_lowering_rules.jl): the post-pass join over
# lowering's anchor-module globals. Projectless workspaces are env-ready by
# construction and see the core-only env (Base/Core stores present).

@testsnippet MissRefV2WS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_lowering_lint!
    using JuliaWorkspaces.URIs2: URI

    const MR_URI = URI("file:///mr/src/F.jl")

    function mr_workspace(src::String; flag=true, config::Union{Nothing,String}=nothing)
        jw = JuliaWorkspace()
        config !== nothing &&
            add_file!(jw, TextFile(URI("file:///mr/JuliaLint.toml"), SourceText(config, "toml")))
        add_file!(jw, TextFile(MR_URI, SourceText(src, "julia")))
        flag && set_lowering_lint!(jw, true)
        return jw
    end

    mr_diags(jw; uri=MR_URI) =
        filter(d -> d.code === :missing_reference, get_diagnostic(jw, uri))
end

@testitem "v2 missing_reference: basics" setup=[MissRefV2WS] begin
    # An undefined bare name flags at the use site, once per use.
    jw = mr_workspace("f() = undefined_name_xyz\n")
    d = only(mr_diags(jw))
    @test d.source == "JuliaWorkspaces.jl"
    @test d.message == "Missing reference: undefined_name_xyz"

    jw = mr_workspace("f() = undefined_a + undefined_a\n")
    ds = mr_diags(jw)
    @test length(ds) == 2
    @test length(unique(d.range for d in ds)) == 2

    # Locals, arguments, and declared siblings are not missing.
    jw = mr_workspace("g() = 1\nf(x) = begin y = x + 1; g() + y end\n")
    @test isempty(mr_diags(jw))

    # Names declared in a sibling file of the same module resolve.
    add = URI("file:///mr/src/other.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(MR_URI, SourceText("include(\"other.jl\")\nf() = from_other()\n", "julia")))
    add_file!(jw, TextFile(add, SourceText("from_other() = 1\n", "julia")))
    set_lowering_lint!(jw, true)
    @test isempty(mr_diags(jw))
    @test isempty(mr_diags(jw; uri=add))
end

@testitem "v2 missing_reference: implicit scope and imports" setup=[MissRefV2WS] begin
    # Base/Core exports and the builtins never flag.
    jw = mr_workspace("f() = println(length([1]))\ng() = Base.show\nh() = Core.Int\ni() = Main\n")
    @test isempty(mr_diags(jw))

    # A store-backed wildcard using brings in its exports.
    jw = mr_workspace("module M\nusing Base.Threads\nf() = nthreads()\nend\n")
    @test isempty(mr_diags(jw))

    # A colon import binds its name lexically even when the store is missing —
    # the import statement carries the diagnosis, never the use site.
    jw = mr_workspace("module M\nusing Printf: @sprintf, psetup\nf() = psetup()\nend\n")
    @test isempty(mr_diags(jw))

    # Qualified reads check only the root name.
    jw = mr_workspace("module M\nimport Base\nf() = Base.no_such_member_xyz()\nend\n")
    @test isempty(mr_diags(jw))
    jw = mr_workspace("f() = NoSuchModule.member\n")
    @test only(mr_diags(jw)).message == "Missing reference: NoSuchModule"
end

@testitem "v2 missing_reference: module blindness gates" setup=[MissRefV2WS] begin
    # An unresolved wildcard using silences the module…
    jw = mr_workspace("module M\nusing NotAPackage\nf() = undefined_xyz\nend\n")
    @test isempty(mr_diags(jw))
    # …but not a sibling module.
    jw = mr_workspace("module M\nusing NotAPackage\nend\nmodule N\nf() = undefined_xyz\nend\n")
    @test !isempty(mr_diags(jw))

    # A computed include may define anything.
    jw = mr_workspace("module M\ninclude(pathof_something())\nf() = undefined_xyz\nend\n")
    @test isempty(mr_diags(jw))

    # A top-level opaque macrocall may define anything.
    jw = mr_workspace("module M\n@some_dsl begin end\nf() = undefined_xyz\nend\n")
    @test isempty(mr_diags(jw))
end

@testitem "v2 missing_reference: synthetic-read suppression intervals" setup=[MissRefV2WS] begin
    # Reads fabricated from an opaque macrocall's arguments are suppressed;
    # real reads in the same item still flag.
    jw = mr_workspace("function f()\n    @assert undefined_inside\n    return undefined_outside\nend\n")
    d = only(mr_diags(jw))
    @test d.message == "Missing reference: undefined_outside"

    # Identifiers inside a quote never flag — including interpolations.
    jw = mr_workspace("f() = :(undefined_in_quote + 1)\ng(x) = :(\$x + undefined_q)\n")
    @test isempty(mr_diags(jw))

    # var-strings and operators are exempt.
    jw = mr_workspace("f() = var\"weird name\"\ng(a, b) = a ⊕ b\n")
    @test isempty(mr_diags(jw))
end

@testitem "v2 missing_reference: item gates" setup=[MissRefV2WS] begin
    # Existence-guarded items are skipped whole.
    jw = mr_workspace("f() = @isdefined(maybe_undef) ? maybe_undef : 0\n")
    @test isempty(mr_diags(jw))
    jw = mr_workspace("f() = VERSION >= v\"1.9\" ? new_thing_xyz() : 0\n")
    @test isempty(mr_diags(jw))
    jw = mr_workspace("f() = isdefined(Main, :x) && undefined_maybe\n")
    @test isempty(mr_diags(jw))

    # Test blocks and testitems run with runtime imports this analysis cannot
    # see.
    jw = mr_workspace("@testset \"t\" begin\n    something_from_test()\nend\n")
    @test isempty(mr_diags(jw))
    jw = mr_workspace("@testitem \"t\" begin\n    @test undefined_in_testitem()\nend\n")
    @test isempty(mr_diags(jw))
end

@testitem "v2 missing_reference: file-level suppression" setup=[MissRefV2WS] begin
    # An own-root helper under a package's test/ folder is silenced whole (a
    # @testitem includes it at runtime with invisible imports).
    project = "name = \"MrPkg\"\nuuid = \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee41\"\nversion = \"0.1.0\"\n"
    helper = URI("file:///mrp/test/helpers.jl")
    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///mrp/Project.toml"), SourceText(project, "toml")))
    add_file!(jw, TextFile(URI("file:///mrp/src/MrPkg.jl"), SourceText("module MrPkg\nend\n", "julia")))
    add_file!(jw, TextFile(helper, SourceText("helper_f() = undefined_from_helper\n", "julia")))
    set_lowering_lint!(jw, true)
    JW.set_input_env_ready!(jw.runtime, true)
    @test isempty(mr_diags(jw; uri=helper))
end

@testitem "v2 missing_reference: options, flag, and takeover" setup=[MissRefV2WS] begin
    # scope = "none" and the rule off are both silent.
    jw = mr_workspace("f() = undefined_name_xyz\n";
        config="[rules]\nmissing_reference = { severity = \"warning\", scope = \"none\" }\n")
    @test isempty(mr_diags(jw))
    jw = mr_workspace("f() = undefined_name_xyz\n";
        config="[rules]\nmissing_reference = \"off\"\n")
    @test isempty(mr_diags(jw))

    # Flag on: only the v2 producer reports (StaticLint suppressed).
    jw = mr_workspace("f() = undefined_name_xyz\n")
    @test all(d -> d.source == "JuliaWorkspaces.jl", mr_diags(jw))

    # Flag off: nothing from the v2 producer.
    jw = mr_workspace("f() = undefined_name_xyz\n"; flag=false)
    @test !any(d -> d.source == "JuliaWorkspaces.jl", mr_diags(jw))
end
