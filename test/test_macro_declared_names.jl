@testsnippet MacroDeclWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: _macro_owner_confirmed
    using JuliaWorkspaces.URIs2: URI

    # A workspace with `root_src` as the root file, plus any extra files, plus
    # (optionally) a sibling workspace package that declares `@declare_input`.
    function macro_ws(root_src::String; root_uri=URI("file:///t/src/T.jl"),
                      extra=Dict{URI,String}(), with_salsa_package::Bool=false)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(root_uri, SourceText(root_src, "julia")))
        for (u, s) in extra
            add_file!(jw, TextFile(u, SourceText(s, "julia")))
        end
        if with_salsa_package
            add_file!(jw, TextFile(URI("file:///ws/Salsa/Project.toml"), SourceText("""
            name = "Salsa"
            uuid = "1fbf2c77-44e2-4d5d-8131-0fa618a5c278"
            version = "2.5.1"
            """, "toml")))
            add_file!(jw, TextFile(URI("file:///ws/Salsa/src/Salsa.jl"), SourceText("""
            module Salsa
            macro declare_input(ex) end
            export @declare_input
            end
            """, "julia")))
        end
        return jw, root_uri
    end
end

@testitem "macro-declared: owner confirmation via a workspace package" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=String[], name="@declare_input"))
end

@testitem "macro-declared: owner confirmation fails without the import" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    @test !_macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
end

@testitem "macro-declared: a same-named submodule does not confirm" setup=[MacroDeclWS] begin
    # `Salsa` here is a submodule of this very root, so the import target is
    # `:tree`, not the owner package.
    jw, root = macro_ws("""
    module T
    module Salsa
    macro declare_input(ex) end
    end
    using .Salsa
    Salsa.@declare_input foo(rt, x::Int)::V
    end
    """)

    @test !_macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
end

@testitem "macro-declared: a local macro shadows the bare spelling only" setup=[MacroDeclWS] begin
    jw, root = macro_ws("""
    module T
    using Salsa
    macro declare_input(ex) end
    @declare_input foo(rt, x::Int)::V
    end
    """; with_salsa_package=true)

    # Bare: the local macro wins, so this is confirmed FOREIGN.
    @test !_macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=String[], name="@declare_input"))
    # Qualified: a local macro cannot shadow `Salsa.@declare_input`.
    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Salsa"], name="@declare_input"))
end

@testitem "macro-declared: owner confirmation via the environment store" setup=[MacroDeclWS] begin
    # Base is always in the baked stdlib stores, so this exercises the store
    # branch with no workspace package involved.
    jw, root = macro_ws("""
    module T
    @deprecate oldf newf
    end
    """)

    # `Base` needs no import to be in scope, so the spelling check accepts a
    # bare or `Base.`-qualified use without an import record.
    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=String[], name="@deprecate"))
    @test _macro_owner_confirmed(jw.runtime, root, ["T"],
        (qualifier=["Base"], name="@deprecate"))
end
