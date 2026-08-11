# Unknown-effect macros: a macro expansion replaces its call site and may
# define arbitrary names in the scope it is spliced into. Unless a macro is on
# the curated known list (StaticLint.EFFECT_FREE_MACROS / HANDLED_MACROS),
# bare missing-reference reporting is suppressed in that scope — module scope
# for top-level calls, the enclosing function for local ones — and the
# value-semantics checks skip its argument code (DSLs).

@testitem "opaque macros: unknown top-level macro suppresses module missing refs, cross-file" begin
    using JuliaWorkspaces: set_input_env_ready!
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///opqmac/src/OpqMac.jl")
    sibling = URI("file:///opqmac/src/other.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///opqmac/Project.toml"), SourceText("""
    name = "OpqMac"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeef10"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///opqmac/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    # `@define_rule` is unknown: it might define `generated_name`.
    add_file!(jw, TextFile(root_uri, SourceText("""
    module OpqMac
    @define_rule sin exp
    include("other.jl")
    end
    """, "julia")))
    add_file!(jw, TextFile(sibling, SourceText("use() = generated_name()\n", "julia")))
    set_input_env_ready!(jw.runtime, true)

    @test !any(d -> contains(d.message, "generated_name"), get_diagnostic(jw, sibling))
    # The module flag suppresses bare missing refs uniformly — including the
    # unresolved macro name itself, matching unresolved-wildcard semantics.
    @test !any(d -> contains(d.message, "@define_rule"), get_diagnostic(jw, root_uri))
end

@testitem "opaque macros: known macros do not suppress" begin
    using JuliaWorkspaces: set_input_env_ready!
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///knownmac/src/KnownMac.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///knownmac/Project.toml"), SourceText("""
    name = "KnownMac"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeef11"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///knownmac/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    add_file!(jw, TextFile(root_uri, SourceText("""
    module KnownMac
    @enum Fruit apple banana
    @inline f(x) = x + 1
    g() = undefined_in_known
    pick() = apple
    end
    """, "julia")))
    set_input_env_ready!(jw.runtime, true)

    msgs = [d.message for d in get_diagnostic(jw, root_uri)]
    # Known macros (@enum handled, @inline effect-free) leave checking on...
    @test any(contains("undefined_in_known"), msgs)
    # ...and @enum's members resolve.
    @test !any(contains("apple"), msgs)
end

@testitem "opaque macros: local unknown macro does not suppress the enclosing function" begin
    using JuliaWorkspaces: set_input_env_ready!
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///localmac/src/LocalMac.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///localmac/Project.toml"), SourceText("""
    name = "LocalMac"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeef12"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///localmac/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    add_file!(jw, TextFile(root_uri, SourceText("""
    module LocalMac
    function f(c)
        @unpack_things c
        used_after_unpack
    end
    g() = undefined_in_g
    end
    """, "julia")))
    set_input_env_ready!(jw.runtime, true)

    msgs = [d.message for d in get_diagnostic(jw, root_uri)]
    # Deliberately narrower in local scopes: only the macrocall's ARGUMENTS
    # are opaque (`in_macrocall_arg`); names used after the call in the same
    # function keep full checking, matching the established policy pinned in
    # "macro-name imports are bound, uses silent" (test_diagnostics.jl).
    # Cost: `@unpack`-style locally-introduced names still flag — rare (4
    # sites in the top-100 sweep vs 422 top-level ones).
    @test any(contains("used_after_unpack"), msgs)
    @test any(contains("undefined_in_g"), msgs)
end

@testitem "opaque macros: value-semantics checks skip unknown-macro DSL arguments" begin
    using JuliaWorkspaces: set_input_env_ready!
    using JuliaWorkspaces.URIs2: URI

    root_uri = URI("file:///dslmac/src/DslMac.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///dslmac/Project.toml"), SourceText("""
    name = "DslMac"
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeef13"
    version = "0.1.0"
    """, "toml")))
    add_file!(jw, TextFile(URI("file:///dslmac/Manifest.toml"), SourceText("""
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """, "toml")))
    # Same code twice: bare (checked) and inside an unknown macro (skipped).
    add_file!(jw, TextFile(root_uri, SourceText("""
    module DslMac
    function bare(xs)
        for i in 5
        end
    end
    @rewrite_dsl function wrapped(xs)
        for i in 5
        end
    end
    end
    """, "julia")))
    set_input_env_ready!(jw.runtime, true)

    diags = get_diagnostic(jw, root_uri)
    iter_msgs = [d for d in diags if contains(d.message, "loop iterator")]
    @test length(iter_msgs) == 1
end
