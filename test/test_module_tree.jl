@testitem "module tree types: structural equality across separately built instances" begin
    using JuliaWorkspaces: ModuleTree, ModuleNode, ResolvedImport, ImportTarget, ItemRef, module_node
    using JuliaWorkspaces.URIs2: URI

    f = URI("file:///t/src/T.jl")
    make() = ModuleTree(f,
        [ModuleNode(String[], false, nothing, [f],
            Dict("g" => (file=f, id=2)), ["g"], String[],
            [ResolvedImport(:using, ImportTarget(:external, ["Base64"]),
                            JuliaWorkspaces.ImportSymbol[], nothing, (file=f, id=1))]),
         ModuleNode(["M"], false, (file=f, id=3), [f], Dict{String,ItemRef}(), String[], String[], ResolvedImport[])],
        Dict(f => String[]))

    a = make(); b = make()
    @test a == b && isequal(a, b) && hash(a) == hash(b)
    @test module_node(a, ["M"]) !== nothing
    @test module_node(a, ["Nope"]) === nothing
end

@testitem "workspace package roots: name to entry file" begin
    using JuliaWorkspaces
    using JuliaWorkspaces.URIs2: URI

    function project_toml(name, uuid)
        """
        name = "$name"
        uuid = "$uuid"
        version = "0.1.0"
        """
    end

    jw = JuliaWorkspace()

    # Package A: valid Project.toml + src/A.jl entry file
    add_file!(jw, TextFile(URI("file:///ws/A/Project.toml"), SourceText(project_toml("A", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0001"), "toml")))
    add_file!(jw, TextFile(URI("file:///ws/A/src/A.jl"), SourceText("module A\nend\n", "julia")))

    # Package B: valid Project.toml + src/B.jl entry file
    add_file!(jw, TextFile(URI("file:///ws/B/Project.toml"), SourceText(project_toml("B", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0002"), "toml")))
    add_file!(jw, TextFile(URI("file:///ws/B/src/B.jl"), SourceText("module B\nend\n", "julia")))

    # Package C: valid Project.toml, but NO src/C.jl entry file
    add_file!(jw, TextFile(URI("file:///ws/C/Project.toml"), SourceText(project_toml("C", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0003"), "toml")))

    roots = JuliaWorkspaces.derived_workspace_package_roots(jw.runtime)

    @test length(roots) == 2
    @test roots["A"] == URI("file:///ws/A/src/A.jl")
    @test roots["B"] == URI("file:///ws/B/src/B.jl")
    @test !haskey(roots, "C")
end

@testitem "workspace package roots: duplicate names tie-break by entry-file validity" begin
    using JuliaWorkspaces
    using JuliaWorkspaces.URIs2: URI

    function project_toml(name, uuid)
        """
        name = "$name"
        uuid = "$uuid"
        version = "0.1.0"
        """
    end

    jw = JuliaWorkspace()

    # Dup1: smaller-URI folder ("dup1/a") has NO entry file; larger-URI folder
    # ("dup1/b") has a valid entry file. The valid one must win even though it
    # is not the lexicographically smallest folder.
    add_file!(jw, TextFile(URI("file:///ws/dup1/a/Project.toml"), SourceText(project_toml("Dup1", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0011"), "toml")))
    add_file!(jw, TextFile(URI("file:///ws/dup1/b/Project.toml"), SourceText(project_toml("Dup1", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0012"), "toml")))
    add_file!(jw, TextFile(URI("file:///ws/dup1/b/src/Dup1.jl"), SourceText("module Dup1\nend\n", "julia")))

    # Dup2: both folders have valid entry files; the lexicographically smaller
    # folder URI ("dup2/a") must win.
    add_file!(jw, TextFile(URI("file:///ws/dup2/a/Project.toml"), SourceText(project_toml("Dup2", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0021"), "toml")))
    add_file!(jw, TextFile(URI("file:///ws/dup2/a/src/Dup2.jl"), SourceText("module Dup2\nend\n", "julia")))
    add_file!(jw, TextFile(URI("file:///ws/dup2/b/Project.toml"), SourceText(project_toml("Dup2", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0022"), "toml")))
    add_file!(jw, TextFile(URI("file:///ws/dup2/b/src/Dup2.jl"), SourceText("module Dup2\nend\n", "julia")))

    roots = JuliaWorkspaces.derived_workspace_package_roots(jw.runtime)

    @test roots["Dup1"] == URI("file:///ws/dup1/b/src/Dup1.jl")
    @test roots["Dup2"] == URI("file:///ws/dup2/a/src/Dup2.jl")
end

@testsnippet ModuleTreeWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: module_node, ImportTarget, ResolvedImport, ItemRef
    using JuliaWorkspaces.URIs2: URI

    function tree_of(root_src::String; root_uri=URI("file:///t/src/F.jl"), extra_files=Dict{URI,String}())
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(root_uri, SourceText(root_src, "julia")))
        for (u, s) in extra_files
            add_file!(jw, TextFile(u, SourceText(s, "julia")))
        end
        return JuliaWorkspaces.derived_module_tree(jw.runtime, root_uri), root_uri, jw
    end
end

@testitem "module tree: package shape splices includes into the declaring module" setup=[ModuleTreeWS] begin
    a_uri = URI("file:///t/src/a.jl")
    b_uri = URI("file:///t/src/b.jl")
    tree, root_uri, _ = tree_of("""
    module Pkg
    include("a.jl")
    include("b.jl")
    end
    """; extra_files=Dict(
        a_uri => """
        afunc() = 1
        module Common
        x() = 1
        end
        """,
        b_uri => """
        module Common
        y() = 2
        end
        """,
    ))

    pkg = module_node(tree, ["Pkg"])
    @test pkg !== nothing
    @test haskey(pkg.declared, "afunc")
    @test haskey(pkg.declared, "Common")
    @test tree.file_modules[a_uri] == ["Pkg"]
    @test tree.file_modules[b_uri] == ["Pkg"]
end

@testitem "module tree: module split across files splices at the nested path" setup=[ModuleTreeWS] begin
    inner_uri = URI("file:///t/src/inner.jl")
    tree, root_uri, _ = tree_of("""
    module Pkg
    module Sub
    include("inner.jl")
    end
    end
    """; extra_files=Dict(inner_uri => "z() = 1\n"))

    @test tree.file_modules[inner_uri] == ["Pkg", "Sub"]
    sub = module_node(tree, ["Pkg", "Sub"])
    @test sub !== nothing
    @test haskey(sub.declared, "z")
end

@testitem "module tree: later declaration wins in include order" setup=[ModuleTreeWS] begin
    a_uri = URI("file:///t/src/a.jl")
    b_uri = URI("file:///t/src/b.jl")
    tree, root_uri, _ = tree_of("""
    include("a.jl")
    include("b.jl")
    """; extra_files=Dict(
        a_uri => "shared() = 1\n",
        b_uri => "shared() = 2\n",
    ))

    root_node = module_node(tree, String[])
    @test root_node.declared["shared"].file == b_uri
end

@testitem "module tree: duplicate include of the same file is spliced only once" setup=[ModuleTreeWS] begin
    a_uri = URI("file:///t/src/a.jl")
    tree, root_uri, _ = tree_of("""
    include("a.jl")
    include("a.jl")
    """; extra_files=Dict(a_uri => "q() = 1\n"))

    root_node = module_node(tree, String[])
    @test count(==(a_uri), root_node.files) == 1
    @test root_node.files == [root_uri, a_uri]
end

@testitem "module tree: include cycles terminate" setup=[ModuleTreeWS] begin
    a_uri = URI("file:///t/src/a.jl")
    b_uri = URI("file:///t/src/b.jl")
    tree, root_uri, _ = tree_of("""
    include("a.jl")
    """; extra_files=Dict(
        a_uri => "include(\"b.jl\")\n",
        b_uri => "include(\"a.jl\")\n",
    ))

    @test tree.file_modules[root_uri] == String[]
    @test tree.file_modules[a_uri] == String[]
    @test tree.file_modules[b_uri] == String[]
    root_node = module_node(tree, String[])
    @test count(==(a_uri), root_node.files) == 1
end

@testitem "module tree: missing include target is ignored" setup=[ModuleTreeWS] begin
    tree, root_uri, _ = tree_of("""
    include("missing.jl")
    f() = 1
    """)

    @test length(tree.modules) == 1
    root_node = module_node(tree, String[])
    @test root_node.files == [root_uri]
    @test haskey(root_node.declared, "f")
end

@testitem "module tree: script shape declares at the synthetic root" setup=[ModuleTreeWS] begin
    tree, root_uri, _ = tree_of("""
    f() = 1
    g() = 2
    """)

    root_node = module_node(tree, String[])
    @test haskey(root_node.declared, "f")
    @test haskey(root_node.declared, "g")
    @test tree.file_modules[root_uri] == String[]
end

@testitem "module tree: includes splice depth-first, not breadth-first" setup=[ModuleTreeWS] begin
    # Julia's `include` is an in-place, depth-first splice: root includes
    # a.jl then b.jl; a.jl itself includes deep.jl before returning to root.
    # True source order is root, a, deep, b — deep.jl is fully spliced (and
    # so is anything IT declares) before root's `include("b.jl")` runs.
    a_uri = URI("file:///t/src/a.jl")
    b_uri = URI("file:///t/src/b.jl")
    deep_uri = URI("file:///t/src/deep.jl")
    tree, root_uri, _ = tree_of("""
    include("a.jl")
    include("b.jl")
    """; extra_files=Dict(
        a_uri => "include(\"deep.jl\")\n",
        b_uri => "shared() = 2\n",
        deep_uri => "shared() = 1\n",
    ))

    root_node = module_node(tree, String[])
    # DFS pre-order: root, then a's whole subtree (a, deep), then b.
    @test root_node.files == [root_uri, a_uri, deep_uri, b_uri]
    # b.jl runs strictly after deep.jl in true source order, so its
    # declaration of `shared` must win — a BFS traversal gets this backwards
    # (it would finish both root-level includes, a and b, before ever
    # descending into a's own include of deep.jl).
    @test root_node.declared["shared"].file == b_uri
end

@testitem "module tree: a file's own later declaration wins over an earlier include" setup=[ModuleTreeWS] begin
    # root includes a.jl BEFORE declaring its own `foo` — the root's `foo`
    # is textually later, so it must win, even though the whole included
    # file logically finishes "instantly" at the include site.
    a_uri = URI("file:///t/src/a.jl")
    tree, root_uri, _ = tree_of("""
    include("a.jl")
    foo() = 2
    """; extra_files=Dict(a_uri => "foo() = 1\n"))

    root_node = module_node(tree, String[])
    @test root_node.declared["foo"].file == root_uri
end

@testitem "module tree: relative imports resolve against enclosing tree modules" setup=[ModuleTreeWS] begin
    tree, root_uri, _ = tree_of("""
    module Pkg
        module Sibling
        end
        module Child
        end
        using .Child
        module Sub
            using ..Sibling
        end
    end
    """)

    pkg = module_node(tree, ["Pkg"])
    @test pkg !== nothing
    child_import = only(pkg.imports)
    @test child_import.target == ImportTarget(:tree, ["Pkg", "Child"])

    sub = module_node(tree, ["Pkg", "Sub"])
    @test sub !== nothing
    sibling_import = only(sub.imports)
    @test sibling_import.target == ImportTarget(:tree, ["Pkg", "Sibling"])
end

@testitem "module tree: relative import popping beyond the root is unresolved" setup=[ModuleTreeWS] begin
    tree, root_uri, _ = tree_of("""
    using ..TooFar
    """)

    root_node = module_node(tree, String[])
    imp = only(root_node.imports)
    @test imp.target == ImportTarget(:unresolved, [".", ".", "TooFar"])
end

@testitem "module tree: absolute import anchors at the innermost enclosing module walking outward" setup=[ModuleTreeWS] begin
    tree, root_uri, _ = tree_of("""
    module Pkg
        module Sub
        end
    end
    module Other
        using Pkg.Sub
    end
    """)

    other = module_node(tree, ["Other"])
    @test other !== nothing
    imp = only(other.imports)
    @test imp.target == ImportTarget(:tree, ["Pkg", "Sub"])
end

@testitem "module tree: absolute import with a mid-path miss stays committed to unresolved" setup=[ModuleTreeWS] begin
    tree, root_uri, _ = tree_of("""
    module Pkg
        module Sub
        end
    end
    using Pkg.NotAModule.Deeper
    """)

    root_node = module_node(tree, String[])
    imp = only(root_node.imports)
    @test imp.target == ImportTarget(:unresolved, ["Pkg", "NotAModule", "Deeper"])
end

@testitem "module tree: import naming a declared non-module item is unresolved" setup=[ModuleTreeWS] begin
    tree, root_uri, _ = tree_of("""
    module Pkg
        f() = 1
    end
    using Pkg.f
    """)

    root_node = module_node(tree, String[])
    imp = only(root_node.imports)
    @test imp.target == ImportTarget(:unresolved, ["Pkg", "f"])
end

@testitem "module tree: colon-form import of Base symbols classifies as external" setup=[ModuleTreeWS] begin
    tree, root_uri, _ = tree_of("""
    import Base: +, map
    """)

    root_node = module_node(tree, String[])
    imp = only(root_node.imports)
    @test imp.kind == :import
    @test imp.target == ImportTarget(:external, ["Base"])
    @test [s.name for s in imp.symbols] == ["+", "map"]
end

@testitem "module tree: import of an unknown package classifies as external" setup=[ModuleTreeWS] begin
    tree, root_uri, _ = tree_of("""
    using SomeRegistryPkg
    """)

    root_node = module_node(tree, String[])
    imp = only(root_node.imports)
    @test imp.target == ImportTarget(:external, ["SomeRegistryPkg"])
end

@testitem "module tree: statement-level alias is carried through classification" setup=[ModuleTreeWS] begin
    tree, root_uri, _ = tree_of("""
    import Foo.Bar as FB
    """)

    root_node = module_node(tree, String[])
    imp = only(root_node.imports)
    @test imp.alias == "FB"
    @test imp.target == ImportTarget(:external, ["Foo", "Bar"])
end

@testitem "module tree: per-symbol alias is carried through classification" setup=[ModuleTreeWS] begin
    tree, root_uri, _ = tree_of("""
    using SomeRegistryPkg: a as b
    """)

    root_node = module_node(tree, String[])
    imp = only(root_node.imports)
    @test imp.symbols == [(name="a", alias="b")]
    @test imp.target == ImportTarget(:external, ["SomeRegistryPkg"])
end

@testitem "module tree: absolute import of a workspace package classifies as workspace_package" begin
    using JuliaWorkspaces
    using JuliaWorkspaces: ImportTarget, module_node
    using JuliaWorkspaces.URIs2: URI

    function project_toml(name, uuid)
        """
        name = "$name"
        uuid = "$uuid"
        version = "0.1.0"
        """
    end

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///ws/Main/Project.toml"), SourceText(project_toml("Main", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0001"), "toml")))
    root_uri = URI("file:///ws/Main/src/Main.jl")
    add_file!(jw, TextFile(root_uri, SourceText("using DevedPkg\n", "julia")))

    add_file!(jw, TextFile(URI("file:///ws/DevedPkg/Project.toml"), SourceText(project_toml("DevedPkg", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0002"), "toml")))
    add_file!(jw, TextFile(URI("file:///ws/DevedPkg/src/DevedPkg.jl"), SourceText("module DevedPkg\nend\n", "julia")))

    tree = JuliaWorkspaces.derived_module_tree(jw.runtime, root_uri)
    root_node = module_node(tree, String[])
    imp = only(root_node.imports)
    @test imp.target == ImportTarget(:workspace_package, ["DevedPkg"])
end
