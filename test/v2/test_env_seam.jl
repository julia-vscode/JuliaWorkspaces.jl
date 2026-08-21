# The v2 environment seam (src/layer_v2_env_seam.jl): plain-data store
# queries. Workspaces here have no project, so every root resolves to the
# stdlib-only env — which, despite the name, is `load_core()`'s bake: `Core`,
# `Base` (with nested submodule stores) and an empty `Main`, no actual
# stdlibs. `Base`/`Base.Threads` are the store-present fixtures; `Printf` is a
# genuinely-missing store here.

@testsnippet EnvSeamWS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: URI

    const SEAM_ROOT = URI("file:///seam/src/Root.jl")

    function seam_workspace(src::String="f() = 1\n")
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(SEAM_ROOT, SourceText(src, "julia")))
        return jw
    end
end

@testitem "env seam: exports of an external module" setup=[EnvSeamWS] begin
    jw = seam_workspace()
    ex = JW.derived_v2_external_module_exports(jw.runtime, SEAM_ROOT, ["Base"])
    @test ex isa Vector{String}
    @test "println" in ex
    # A nested submodule store resolves through the walk.
    thr = JW.derived_v2_external_module_exports(jw.runtime, SEAM_ROOT, ["Base", "Threads"])
    @test thr isa Vector{String}
    @test "@threads" in thr
    # A missing package: nothing, distinguishable from empty. (`Printf` is a
    # real stdlib but the projectless env has no store for it.)
    @test JW.derived_v2_external_module_exports(jw.runtime, SEAM_ROOT, ["NotAPkgXYZ"]) === nothing
    @test JW.derived_v2_external_module_exports(jw.runtime, SEAM_ROOT, ["Printf"]) === nothing
    # A nested path through a non-module member fails the walk.
    @test JW.derived_v2_external_module_exports(jw.runtime, SEAM_ROOT, ["Base", "println"]) === nothing
end

@testitem "env seam: member kinds" setup=[EnvSeamWS] begin
    jw = seam_workspace()
    mk(path, name) = JW.derived_v2_external_module_member_kind(jw.runtime, SEAM_ROOT, path, name)
    # The member gate is `haskey`, not export-gated: Base.Filesystem is an
    # unexported submodule and still answers :module.
    @test mk(["Base"], "Filesystem") === :module
    @test mk(["Base"], "println") === :value
    @test mk(["Base"], "no_such_name_xyz") === :absent
    @test mk(["NotAPkgXYZ"], "anything") === :missing_store
    # Exported module-valued names, for wildcard ledger targets.
    mods = JW.derived_v2_external_exported_module_names(jw.runtime, SEAM_ROOT, ["Base"])
    @test "Threads" in mods
    @test !("println" in mods)
    @test JW.derived_v2_external_exported_module_names(jw.runtime, SEAM_ROOT, ["NotAPkgXYZ"]) == String[]
end

@testitem "env seam: first missing segment" setup=[EnvSeamWS] begin
    jw = seam_workspace()
    fms(path) = JW.derived_v2_external_first_missing_segment(jw.runtime, SEAM_ROOT, path)
    @test fms(["Base"]) === nothing
    @test fms(["Base", "Filesystem"]) === nothing
    @test fms(["NotAPkgXYZ"]) == "NotAPkgXYZ"
    @test fms(["Printf"]) == "Printf"   # real stdlib, but no store in this env
    @test fms(["Base", "NoSuchSub"]) == "NoSuchSub"
    @test fms(["Base", "NoSuchSub", "Deeper"]) == "NoSuchSub"
end

@testitem "env seam: implicit scope names" setup=[EnvSeamWS] begin
    jw = seam_workspace()
    names = JW.derived_v2_implicit_scope_names(jw.runtime, SEAM_ROOT, false)
    for n in ("println", "Base", "Core", "include", "eval", "Main", "Int", "nothing")
        @test n in names
    end
    @test issorted(names)
    # baremodule: no implicit `using Base`, Core side only.
    bare = JW.derived_v2_implicit_scope_names(jw.runtime, SEAM_ROOT, true)
    @test !("println" in bare)
    @test !("Base" in bare)
    @test "Core" in bare
    @test "include" in bare
    # Core exports still present (e.g. `throw`, `nothing`).
    @test "nothing" in bare
end

@testitem "env seam: project deps of a projectless root" setup=[EnvSeamWS] begin
    jw = seam_workspace()
    deps = JW.derived_v2_env_project_deps(jw.runtime, SEAM_ROOT)
    @test deps isa Vector{String}
    @test issorted(deps)
end
