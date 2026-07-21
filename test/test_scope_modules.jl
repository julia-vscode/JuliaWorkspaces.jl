@testitem "in-scope syms: external using contributes its top module" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, URIs2,
        _in_scope_module_syms, derived_best_root_for_uri, derived_file_module_path
    uri = URIs2.uri"file:///t/Foo.jl"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText("module Foo\nusing Base.Iterators\nlength([])\nend\n", "julia")))
    rt = jw.runtime
    root = derived_best_root_for_uri(rt, uri)

    # `using Base.Iterators` is an external (env) module → its top segment `:Base`
    # appears in the in-scope set at the module's path.
    base = derived_file_module_path(rt, root, uri)
    syms = _in_scope_module_syms(rt, root, vcat(base, ["Foo"]))
    @test :Base in syms

    # A module with no `using` yields no external in-scope modules.
    uri2 = URIs2.uri"file:///t/Bar.jl"
    add_file!(jw, TextFile(uri2, SourceText("module Bar\nlength([])\nend\n", "julia")))
    root2 = derived_best_root_for_uri(rt, uri2)
    base2 = derived_file_module_path(rt, root2, uri2)
    @test isempty(_in_scope_module_syms(rt, root2, vcat(base2, ["Bar"])))
end

@testitem "in-scope syms: selective and module-name imports contribute the module" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, URIs2,
        _in_scope_module_syms, derived_best_root_for_uri, derived_file_module_path

    function inscope(src)
        uri = URIs2.uri"file:///imp/Foo.jl"
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        rt = jw.runtime
        root = derived_best_root_for_uri(rt, uri)
        _in_scope_module_syms(rt, root, vcat(derived_file_module_path(rt, root, uri), ["Foo"]))
    end

    # Every import form that names a module LOADS it, so its overloads are in
    # scope — not only the whole-module `using Foo`.
    @test :Base in inscope("module Foo\nusing Base.Iterators\nend\n")            # whole-module using
    @test :Base in inscope("module Foo\nusing Base.Iterators: partition\nend\n") # selective `using M: name`
    @test :Base in inscope("module Foo\nusing Base: Base\nend\n")                # module-name `using M: M`
    @test :Base in inscope("module Foo\nimport Base.Iterators\nend\n")           # bare `import M`
end
