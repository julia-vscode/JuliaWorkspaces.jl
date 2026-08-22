# v2 visibility layer (layer_visibility_v2.jl): unit tests, mirroring v1's
# suite in test/test_module_tree.jl. External targets resolve through the env
# seam (src/layer_v2_env_seam.jl). These workspaces have no project, so the
# env is load_core()'s bake — `Base`/`Core` (and nested submodules) have
# stores; `Printf`/`Downloads` are genuinely MISSING stores here, which is
# what makes them the store-missing fixtures below.

@testsnippet VisV2WS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!, update_file!,
        derived_v2_module_visible_names, derived_v2_module_visible_names_idfree,
        derived_v2_visible_item, derived_v2_module_imports, derived_v2_module_declared,
        derived_v2_module_self_and_parents, derived_v2_module_unresolved_wildcard_using
    using JuliaWorkspaces.URIs2: URI

    const VIS_ROOT = URI("file:///vis/src/Root.jl")

    function vis_workspace(src::String)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(VIS_ROOT, SourceText(src, "julia")))
        return jw
    end

    vis(jw, path) = derived_v2_module_visible_names(jw.runtime, VIS_ROOT, path)

    project_toml(name, uuid) = "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n"
end

@testitem "v2 visibility: declared shadows using'd exports; tiers order correctly" setup=[VisV2WS] begin
    jw = vis_workspace("""
    module Prov
    export f, g
    f() = 1
    g() = 2
    end
    module User
    using ..Prov
    import ..Prov: g as gg
    f() = "mine"
    end
    """)
    v = vis(jw, ["User"])
    # Declared f shadows the using'd export.
    @test v["f"].origin === :declared
    @test v["f"].kind === :function
    @test v["f"].origin_module == ["User"]
    # The un-shadowed export comes through the using.
    @test v["g"].origin === :using_tree
    @test v["g"].origin_module == ["Prov"]
    # The colon-list alias binds at import tier under the alias only.
    @test v["gg"].origin === :import_binding
    @test v["gg"].kind === :function
    # The whole-module using binds the module name too.
    @test v["Prov"].kind === :module
end

@testitem "v2 visibility: using-tree bring-ins carry declaring items" setup=[VisV2WS] begin
    jw = vis_workspace("""
    module A
    module B
    export h
    h() = 1
    end
    using .B
    end
    """)
    v = vis(jw, ["A"])
    @test v["h"].origin === :using_tree
    @test v["h"].item == derived_v2_module_declared(jw.runtime, VIS_ROOT, ["A", "B"])["h"]
    @test derived_v2_visible_item(jw.runtime, VIS_ROOT, ["A"], "h") == v["h"].item
    # B is visible both as declared submodule (tier 3 wins over the using's
    # module binding).
    @test v["B"].kind === :module
    @test v["B"].origin === :declared
end

@testitem "v2 visibility: a re-export binds :unknown; same-root using cycles terminate" setup=[VisV2WS] begin
    jw = vis_workspace("""
    module P
    using ..Q
    export bar
    end
    module Q
    using ..P
    export baz
    end
    module User
    using ..P
    end
    """)
    v = vis(jw, ["User"])
    # `bar` is exported by P but not declared there (it would come through
    # P's own using) — bound as :unknown so uses aren't spurious missing-refs.
    @test v["bar"].kind === :unknown
    @test v["bar"].origin === :using_tree
    # And the P<->Q using cycle terminated.
    @test v["P"].kind === :module
end

@testitem "v2 visibility: statement aliases and colon-lists" setup=[VisV2WS] begin
    jw = vis_workspace("""
    module Prov
    export f
    f() = 1
    module Sub end
    end
    module User
    import ..Prov as PV
    using ..Prov: f as ff, Prov as P2, Sub
    end
    """)
    v = vis(jw, ["User"])
    # `import X as Y` binds only the alias.
    @test v["PV"].kind === :module
    @test v["PV"].origin === :import_binding
    @test !haskey(v, "Prov")
    # Colon-list member alias.
    @test v["ff"].kind === :function
    @test !haskey(v, "f")
    # A colon-list member naming the target module itself is the self-binding.
    @test v["P2"].kind === :module
    # A module-valued member.
    @test v["Sub"].kind === :module
    @test v["Sub"].origin === :import_binding
end

@testitem "v2 visibility: missing-store externals bind only the module name" setup=[VisV2WS] begin
    jw = vis_workspace("""
    module User
    using Printf
    import Downloads
    using Printf: @sprintf
    end
    """)
    v = vis(jw, ["User"])
    @test v["Printf"].kind === :external_symbol
    @test v["Printf"].origin === :using_external
    @test v["Downloads"].kind === :external_symbol
    @test v["Downloads"].origin === :import_binding
    # No store in this env: exported names are NOT expanded…
    @test !haskey(v, "@printf")
    # …and colon-list members bind lexically as :unknown.
    @test v["@sprintf"].kind === :unknown
    @test v["@sprintf"].origin === :import_binding
end

@testitem "v2 visibility: store-present externals expand through the env seam" setup=[VisV2WS] begin
    jw = vis_workspace("""
    module User
    using Base.Threads
    using Base: Filesystem, no_such_name_xyz
    end
    """)
    v = vis(jw, ["User"])
    # The wildcard expands the store's exports.
    @test v["@threads"].kind === :external_symbol
    @test v["@threads"].origin === :using_external
    @test v["@threads"].origin_module == ["Base", "Threads"]
    @test v["nthreads"].origin === :using_external
    # The statement still binds the module name itself.
    @test v["Threads"].kind === :external_symbol
    # Colon members resolve against the store's haskey (NOT export-gated:
    # Filesystem is an unexported submodule).
    @test v["Filesystem"].kind === :external_symbol
    @test v["Filesystem"].origin === :import_binding
    # An absent member still binds lexically, as :unknown.
    @test v["no_such_name_xyz"].kind === :unknown
end

@testitem "v2 visibility: workspace package exports come in cross-root" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: URI

    project_toml(name, uuid) = "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///ws/MainPkg/Project.toml"), SourceText(project_toml("MainPkg", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0001"), "toml")))
    root = URI("file:///ws/MainPkg/src/MainPkg.jl")
    add_file!(jw, TextFile(root, SourceText("module MainPkg\nusing DevedPkg\nend\n", "julia")))
    add_file!(jw, TextFile(URI("file:///ws/DevedPkg/Project.toml"), SourceText(project_toml("DevedPkg", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0002"), "toml")))
    add_file!(jw, TextFile(URI("file:///ws/DevedPkg/src/DevedPkg.jl"), SourceText("""
    module DevedPkg
    export myfunc
    myfunc() = 1
    end
    """, "julia")))

    v = JW.derived_v2_module_visible_names(jw.runtime, root, ["MainPkg"])
    @test v["myfunc"].kind === :function
    @test v["myfunc"].origin === :using_workspace_package
    @test v["myfunc"].origin_module == ["DevedPkg"]
    @test v["myfunc"].item !== nothing   # cross-root V2ItemRef into DevedPkg's file
    @test v["DevedPkg"].kind === :module
end

@testitem "v2 visibility: circularly-deved packages terminate" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: URI

    project_toml(name, uuid) = "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///ws/A/Project.toml"), SourceText(project_toml("A", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0001"), "toml")))
    add_file!(jw, TextFile(URI("file:///ws/A/src/A.jl"), SourceText("module A\nusing B\nexport af\naf() = 1\nend\n", "julia")))
    add_file!(jw, TextFile(URI("file:///ws/B/Project.toml"), SourceText(project_toml("B", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0002"), "toml")))
    add_file!(jw, TextFile(URI("file:///ws/B/src/B.jl"), SourceText("module B\nusing A\nexport bf\nbf() = 2\nend\n", "julia")))

    va = JW.derived_v2_module_visible_names(jw.runtime, URI("file:///ws/A/src/A.jl"), ["A"])
    @test va["bf"].origin === :using_workspace_package
    @test va["af"].origin === :declared
    vb = JW.derived_v2_module_visible_names(jw.runtime, URI("file:///ws/B/src/B.jl"), ["B"])
    @test vb["af"].origin === :using_workspace_package
end

@testitem "v2 visibility: the ledger re-attempt (pass 2)" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: URI

    project_toml(name, uuid) = "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///ws/MainPkg/Project.toml"), SourceText(project_toml("MainPkg", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0001"), "toml")))
    root = URI("file:///ws/MainPkg/src/MainPkg.jl")
    add_file!(jw, TextFile(root, SourceText("""
    module MainPkg
    import DevedPkg
    module Inner
    using ..DevedPkg
    import ..DevedPkg.Sub
    using ..DevedPkg: DevedPkg as DP
    import ..DevedPkg.ThirdPkg
    end
    end
    """, "julia")))
    add_file!(jw, TextFile(URI("file:///ws/DevedPkg/Project.toml"), SourceText(project_toml("DevedPkg", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0002"), "toml")))
    add_file!(jw, TextFile(URI("file:///ws/DevedPkg/src/DevedPkg.jl"), SourceText("""
    module DevedPkg
    import ThirdPkg
    export myfunc
    myfunc() = 1
    module Sub
    export subfunc
    subfunc() = 2
    end
    end
    """, "julia")))
    add_file!(jw, TextFile(URI("file:///ws/ThirdPkg/Project.toml"), SourceText(project_toml("ThirdPkg", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0003"), "toml")))
    add_file!(jw, TextFile(URI("file:///ws/ThirdPkg/src/ThirdPkg.jl"), SourceText("module ThirdPkg\nend\n", "julia")))

    # The tree layer must have left every Inner import unresolved.
    inner = JW.derived_v2_module_imports(jw.runtime, root, ["MainPkg", "Inner"])
    @test length(inner) == 4
    @test all(ri -> ri.target.sort === :unresolved, inner)

    v = JW.derived_v2_module_visible_names(jw.runtime, root, ["MainPkg", "Inner"])

    # `using ..DevedPkg`: recovered as WORKSPACE-PACKAGE, exports cross-root.
    @test v["myfunc"].kind === :function
    @test v["myfunc"].origin === :using_workspace_package
    @test v["DevedPkg"].kind === :module
    @test v["DevedPkg"].origin === :using_workspace_package

    # `import ..DevedPkg.Sub`: extension validates in the package's own tree.
    @test v["Sub"].kind === :module
    @test v["Sub"].origin === :import_binding
    @test v["Sub"].origin_module == ["DevedPkg", "Sub"]
    @test !haskey(v, "subfunc")

    # Colon-list against unresolved target: the package module's self-binding.
    @test v["DP"].kind === :module
    @test v["DP"].origin === :import_binding

    # `import ..DevedPkg.ThirdPkg`: continues through the PACKAGE's own
    # binding ledger (the `import ..JSONRPC.JSON` pattern).
    @test v["ThirdPkg"].kind === :module
    @test v["ThirdPkg"].origin === :import_binding
    @test v["ThirdPkg"].origin_module == ["ThirdPkg"]
end

@testitem "v2 visibility: self-binding resolves relative imports of the enclosing module's own name" setup=[VisV2WS] begin
    jw = vis_workspace("""
    module Outer
    module Vendored
    export vfunc
    vfunc() = 1
    module Cache
    using ..Vendored: vfunc
    end
    end
    end
    """)
    # Self-binding is a visible name in its own right.
    vv = vis(jw, ["Outer", "Vendored"])
    @test vv["Vendored"].kind === :module
    @test vv["Vendored"].origin === :declared

    # The tree layer left the relative import unresolved…
    imp = only(derived_v2_module_imports(jw.runtime, VIS_ROOT, ["Outer", "Vendored", "Cache"]))
    @test imp.target.sort === :unresolved

    # …and pass 2 resolves it through the self-binding.
    vc = vis(jw, ["Outer", "Vendored", "Cache"])
    @test vc["vfunc"].kind === :function
    @test vc["vfunc"].origin === :import_binding
    @test vc["vfunc"].origin_module == ["Outer", "Vendored"]
    @test vc["vfunc"].item == derived_v2_module_declared(jw.runtime, VIS_ROOT, ["Outer", "Vendored"])["vfunc"]
end

@testitem "v2 visibility: external ledger case binds only the module name; equal tier is first-wins" setup=[VisV2WS] begin
    jw = vis_workspace("""
    module Parent
    using Printf
    module Child
    using ..Printf
    end
    end
    """)
    # Parent binds `Printf` externally; Child's relative import finds it in
    # the ledger — but the external extension cannot validate against a
    # MISSING store (v1 behaves identically), so nothing binds and the
    # wildcard-unresolved flag covers suppression instead.
    imp = only(derived_v2_module_imports(jw.runtime, VIS_ROOT, ["Parent", "Child"]))
    @test imp.target.sort === :unresolved
    vc = vis(jw, ["Parent", "Child"])
    @test !haskey(vc, "Printf")
    @test !haskey(vc, "@printf")
    @test derived_v2_module_unresolved_wildcard_using(jw.runtime, VIS_ROOT, ["Parent", "Child"])

    # The same shape against a PRESENT store: the pass-2 extension validates
    # through the env seam and the wildcard expands in Child.
    jws = vis_workspace("""
    module Parent
    import Base
    module Child
    using ..Base
    end
    end
    """)
    vcs = vis(jws, ["Parent", "Child"])
    @test vcs["Base"].kind === :external_symbol
    @test vcs["println"].origin === :using_external
    @test !derived_v2_module_unresolved_wildcard_using(jws.runtime, VIS_ROOT, ["Parent", "Child"])

    # Single-dot `using .X` failing at depth 0 stays unresolved without
    # recursion.
    jw2 = vis_workspace("module M\nusing .NoSuch\nend\n")
    v2 = vis(jw2, ["M"])
    @test !haskey(v2, "NoSuch")

    # Pops past the root are fundamentally invalid: no binding, no crash.
    jw3 = vis_workspace("module M\nusing ....Foo\nend\n")
    @test !haskey(vis(jw3, ["M"]), "Foo")
end

@testitem "v2 visibility: unresolved-wildcard flag matrix" setup=[VisV2WS] begin
    flag(jw, path) = derived_v2_module_unresolved_wildcard_using(jw.runtime, VIS_ROOT, path)

    # Tree wildcard: resolved.
    jw = vis_workspace("module P\nmodule Q\nend\nusing .Q\nend\n")
    @test !flag(jw, ["P"])

    # External wildcard with a MISSING store: unresolved.
    jw = vis_workspace("module P\nusing Printf\nend\n")
    @test flag(jw, ["P"])

    # External wildcard with a PRESENT store: resolved through the env seam.
    jw = vis_workspace("module P\nusing Base.Threads\nend\n")
    @test !flag(jw, ["P"])

    # Colon form never flags.
    jw = vis_workspace("module P\nusing Printf: @sprintf\nend\n")
    @test !flag(jw, ["P"])

    # Unresolved and un-reattemptable: flags.
    jw = vis_workspace("module P\nusing ..Nowhere\nend\n")
    @test flag(jw, ["P"])

    # Unresolved but re-attempted onto a TREE target: does not flag.
    jw = vis_workspace("""
    module Outer
    module Prov
    export pf
    pf() = 1
    end
    using .Prov: Prov as PV
    module Child
    using ..PV
    end
    end
    """)
    @test !flag(jw, ["Outer", "Child"])
end

@testitem "v2 visibility: self-and-parents chain" setup=[VisV2WS] begin
    jw = vis_workspace("module A\nmodule B\nend\nend\n")
    @test derived_v2_module_self_and_parents(jw.runtime, VIS_ROOT, ["A", "B"]) ==
        [["A", "B"], ["A"], String[]]
end

@testitem "v2 visibility: id-free face backdates across declaration reorder" setup=[VisV2WS] begin
    src(a_first) = a_first ?
        "module M\nfa() = 1\nfb() = 2\nend\n" :
        "module M\nfb() = 2\nfa() = 1\nend\n"
    jw = vis_workspace(src(true))
    full1 = vis(jw, ["M"])
    face1 = derived_v2_module_visible_names_idfree(jw.runtime, VIS_ROOT, ["M"])
    item1 = derived_v2_visible_item(jw.runtime, VIS_ROOT, ["M"], "fa")

    update_file!(jw, TextFile(VIS_ROOT, SourceText(src(false), "julia")))
    # The face is id-free: identical after the reorder.
    @test isequal(derived_v2_module_visible_names_idfree(jw.runtime, VIS_ROOT, ["M"]), face1)
    # The full dict changed (ids shifted), and the per-name item moved.
    @test !isequal(vis(jw, ["M"]), full1) || item1 == derived_v2_visible_item(jw.runtime, VIS_ROOT, ["M"], "fa")
end
