@testsnippet ModTreeV2WS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: V2ItemRef, V2ModuleTree, V2ImportTarget, v2_module_node,
        derived_v2_module_tree, derived_v2_include_target, derived_v2_file_module_path,
        derived_v2_module_exists, derived_v2_module_is_bare, derived_v2_module_declared,
        derived_v2_module_exports, derived_v2_module_imports, derived_v2_module_names,
        derived_v2_module_has_computed_include, derived_v2_module_has_opaque_macrocall,
        update_file!
    using JuliaWorkspaces.URIs2: URI, filepath2uri

    # Drive-lettered so `uri2filepath` round-trips on every platform — include
    # resolution is genuine path arithmetic, not URI string munging.
    mt_uri(name) = filepath2uri(joinpath(Sys.iswindows() ? "C:\\mt\\src" : "/mt/src", name))
    const MT_ROOT = mt_uri("Root.jl")

    "Build a workspace from `name => source` pairs; the first is the root."
    function mt_workspace(files::Pair{String,String}...)
        jw = JuliaWorkspace()
        for (name, src) in files
            add_file!(jw, TextFile(mt_uri(name), SourceText(src, "julia")))
        end
        return jw
    end

    mt_tree(jw) = derived_v2_module_tree(jw.runtime, MT_ROOT)
    mt_paths(jw) = sort([n.path for n in mt_tree(jw).modules])
end

@testitem "v2 module tree: the synthetic root always exists" setup=[ModTreeV2WS] begin
    jw = mt_workspace("Root.jl" => "")
    tree = mt_tree(jw)
    @test tree.root == MT_ROOT
    @test v2_module_node(tree, String[]) !== nothing
    @test derived_v2_file_module_path(jw.runtime, MT_ROOT, MT_ROOT) == String[]
end

@testitem "v2 module tree: nested modules become nodes" setup=[ModTreeV2WS] begin
    jw = mt_workspace("Root.jl" => """
    module A
        f() = 1
        module B
            g() = 2
        end
    end
    h() = 3
    """)
    @test mt_paths(jw) == [String[], ["A"], ["A", "B"]]

    @test derived_v2_module_exists(jw.runtime, MT_ROOT, ["A", "B"])
    @test !derived_v2_module_exists(jw.runtime, MT_ROOT, ["A", "C"])

    @test haskey(derived_v2_module_declared(jw.runtime, MT_ROOT, ["A"]), "f")
    @test haskey(derived_v2_module_declared(jw.runtime, MT_ROOT, ["A", "B"]), "g")
    @test haskey(derived_v2_module_declared(jw.runtime, MT_ROOT, String[]), "h")
    # A module's own name binds in its PARENT.
    @test haskey(derived_v2_module_declared(jw.runtime, MT_ROOT, String[]), "A")
    @test haskey(derived_v2_module_declared(jw.runtime, MT_ROOT, ["A"]), "B")

    @test derived_v2_module_names(jw.runtime, MT_ROOT, ["A"])["f"] == :function
end

@testitem "v2 module tree: baremodule is recorded" setup=[ModTreeV2WS] begin
    jw = mt_workspace("Root.jl" => "module M end\nbaremodule B end\n")
    @test derived_v2_module_is_bare(jw.runtime, MT_ROOT, ["B"])
    @test !derived_v2_module_is_bare(jw.runtime, MT_ROOT, ["M"])
end

@testitem "v2 module tree: exports and publics land on their module" setup=[ModTreeV2WS] begin
    jw = mt_workspace("Root.jl" => """
    module A
        export f, g
        public h
        f() = 1
    end
    """)
    @test derived_v2_module_exports(jw.runtime, MT_ROOT, ["A"]) == ["f", "g"]
    @test v2_module_node(mt_tree(jw), ["A"]).publics == ["h"]
end

@testitem "v2 module tree: include edges splice files at the including module" setup=[ModTreeV2WS] begin
    jw = mt_workspace(
        "Root.jl" => "module A\ninclude(\"inner.jl\")\nend\n",
        "inner.jl" => "f() = 1\n",
    )
    @test derived_v2_file_module_path(jw.runtime, MT_ROOT, mt_uri("inner.jl")) == ["A"]
    @test haskey(derived_v2_module_declared(jw.runtime, MT_ROOT, ["A"]), "f")
    @test mt_uri("inner.jl") in v2_module_node(mt_tree(jw), ["A"]).files
end

@testitem "v2 module tree: include resolution is relative to the including file" setup=[ModTreeV2WS] begin
    jw = mt_workspace("Root.jl" => "")
    @test derived_v2_include_target(jw.runtime, MT_ROOT, "other.jl") == mt_uri("other.jl")
    @test derived_v2_include_target(jw.runtime, MT_ROOT, nothing) === nothing
    @test derived_v2_include_target(jw.runtime, MT_ROOT, "") === nothing
end

@testitem "v2 module tree: include cycles terminate" setup=[ModTreeV2WS] begin
    jw = mt_workspace(
        "Root.jl" => "include(\"a.jl\")\n",
        "a.jl" => "include(\"b.jl\")\nx = 1\n",
        "b.jl" => "include(\"a.jl\")\ny = 2\n",
    )
    tree = mt_tree(jw)
    @test haskey(derived_v2_module_declared(jw.runtime, MT_ROOT, String[]), "x")
    @test haskey(derived_v2_module_declared(jw.runtime, MT_ROOT, String[]), "y")
    # Each file is spliced exactly once.
    @test length(v2_module_node(tree, String[]).files) == 3
end

@testitem "v2 module tree: imports are classified against the tree" setup=[ModTreeV2WS] begin
    jw = mt_workspace("Root.jl" => """
    module A
        module B
            g() = 1
        end
        module C
            using ..B
            using A.B
            using Printf
        end
    end
    """)
    targets = [i.target for i in derived_v2_module_imports(jw.runtime, MT_ROOT, ["A", "C"])]
    # `using ..B` anchors one level up from A.C, i.e. at A, then resolves B.
    @test V2ImportTarget(:tree, ["A", "B"]) in targets
    # An absolute path anchors at the first enclosing module that has `A`.
    @test V2ImportTarget(:tree, ["A", "B"]) ==
          targets[findfirst(t -> t.sort == :tree && t.path == ["A", "B"], targets)]
    @test any(t -> t.sort == :external && t.path == ["Printf"], targets)
end

@testitem "v2 module tree: blindness flags" setup=[ModTreeV2WS] begin
    # A variable in the path keeps it genuinely computed (the resolvable
    # `joinpath(@__DIR__, …)` idiom no longer counts as computed).
    jw = mt_workspace("Root.jl" => "include(joinpath(dir, \"x.jl\"))\n")
    @test derived_v2_module_has_computed_include(jw.runtime, MT_ROOT, String[])

    jw2 = mt_workspace("Root.jl" => "@some_unknown_macro foo\n")
    @test derived_v2_module_has_opaque_macrocall(jw2.runtime, MT_ROOT, String[])

    jw3 = mt_workspace("Root.jl" => "f() = 1\n")
    @test !derived_v2_module_has_computed_include(jw3.runtime, MT_ROOT, String[])
    @test !derived_v2_module_has_opaque_macrocall(jw3.runtime, MT_ROOT, String[])
end

@testitem "v2 module tree: blindness flags see inside nested modules" setup=[ModTreeV2WS] begin
    # The record's absolute path is its file's splice path PLUS its own in-file
    # module path — filtering on the file's path alone would miss these.
    jw = mt_workspace("Root.jl" => """
    module A
        @some_unknown_macro foo
        include(joinpath(dir, "x.jl"))
    end
    """)
    @test derived_v2_module_has_opaque_macrocall(jw.runtime, MT_ROOT, ["A"])
    @test derived_v2_module_has_computed_include(jw.runtime, MT_ROOT, ["A"])
    # ...and they do NOT leak to the enclosing module.
    @test !derived_v2_module_has_opaque_macrocall(jw.runtime, MT_ROOT, String[])
    @test !derived_v2_module_has_computed_include(jw.runtime, MT_ROOT, String[])
end

@testitem "v2 module tree: body edits do not change the tree" setup=[ModTreeV2WS] begin
    jw = mt_workspace("Root.jl" => "module A\nf(x) = x + 1\nend\n")
    before = mt_tree(jw)

    update_file!(jw, TextFile(MT_ROOT, SourceText("module A\nf(x) = x * 42\nend\n", "julia")))
    @test isequal(before, mt_tree(jw))

    # An API edit does change it.
    update_file!(jw, TextFile(MT_ROOT, SourceText("module A\ng(x) = x\nend\n", "julia")))
    @test !isequal(before, mt_tree(jw))
end
