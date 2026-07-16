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
