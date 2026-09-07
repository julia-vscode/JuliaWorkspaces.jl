# The dynamic analysis process must never write into the folder it is analysing.
# `scratch_env.jl` is what keeps that promise: it lives in the child project
# rather than in `JuliaWorkspaces` itself, so these items load it directly.
#
# The end-to-end path (a real resolve through TestEnv) is covered by the
# `:integration` item at the bottom, which is opt-in because it needs a registry.
#
# Shared helpers live in `test_scratch_env_helpers.jl`.

@testitem "scratch env: a manifest-less package is mirrored, never written to" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    uuid = "aaaaaaaa-1111-2222-3333-444444444444"
    dir = _write_package(mktempdir(), "Bare", uuid)
    before = _snapshot(dir)

    env_dir = materialize_scratch_env(dir, "Bare")

    @test env_dir != dir
    # Nothing to preserve, so no manifest is fabricated here either — TestEnv's
    # own `Pkg.instantiate` resolves one into the scratch dir later.
    @test !isfile(joinpath(env_dir, "Manifest.toml"))

    project = Pkg.Types.read_project(joinpath(env_dir, "Project.toml"))

    # Nameless is the whole point: it stops Pkg deriving the package's source
    # location from `dirname(env.project_file)`, which would be the scratch dir.
    @test project.name === nothing
    @test project.uuid === nothing
    @test project.version === nothing

    @test project.deps["Bare"] == Base.UUID(uuid)
    @test haskey(project.deps, "Dates")
    @test isempty(project.extras)
    @test isempty(project.targets)

    @static if VERSION >= v"1.11"
        # `EnvCache` realpaths the project file, so the recorded path is the
        # resolved form — `/private/var/...` on macOS, the long profile name on
        # Windows — never the raw `mktempdir()` string.
        @test isabspath(project.sources["Bare"]["path"])
        @test realpath(project.sources["Bare"]["path"]) == realpath(dir)
    end

    @test _snapshot(dir) == before
end

@testitem "scratch env: the extension env wrapper carries weakdeps and their compat" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    uuid = "aaaaaaaa-9999-aaaa-bbbb-cccccccccccc"
    dir = mktempdir()
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Project.toml"), """
    name = "HasExt"
    uuid = "$uuid"
    version = "0.1.0"

    [deps]
    Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"

    [weakdeps]
    Printf = "de0858da-6303-5e67-8744-51eddeeeb8d7"

    [extensions]
    HasExtPrintfExt = "Printf"

    [compat]
    julia = "1.6"
    Printf = "1"
    Dates = "1"
    """)
    write(joinpath(dir, "src", "HasExt.jl"), "module HasExt end\n")
    before = _snapshot(dir)

    project_dir = mktempdir()
    write_extension_env_project(dir, project_dir)

    project = Pkg.Types.read_project(joinpath(project_dir, "Project.toml"))

    if hasfield(Pkg.Types.Project, :weakdeps)
        # The wrapper's deps are the WEAKDEPS (the triggers to resolve); the
        # package itself and its regular deps arrive later via `Pkg.develop`.
        @test project.deps == Dict("Printf" => Base.UUID("de0858da-6303-5e67-8744-51eddeeeb8d7"))
        # Trigger and julia compat carry over; the regular dep's does not (it
        # is not part of this wrapper's dep set).
        @test haskey(project.compat, "Printf")
        @test haskey(project.compat, "julia")
        @test !haskey(project.compat, "Dates")
        # Nameless, like every scratch wrapper.
        @test project.name === nothing
        @test project.uuid === nothing
    else
        @test isempty(project.deps)
    end

    # The package folder is only ever read.
    @test _snapshot(dir) == before
end

@testitem "scratch env: an existing manifest is carried over with absolute paths" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    uuid = "aaaaaaaa-5555-6666-7777-888888888888"
    # Manifest format 2.0 records the root package as `path = "."`, which has to
    # end up pointing back at the real package folder.
    manifest = """
    manifest_format = "2.0"

    [[deps.Dates]]
    uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"

    [[deps.Pinned]]
    deps = ["Dates"]
    path = "."
    uuid = "$uuid"
    version = "0.1.0"
    """
    dir = _write_package(mktempdir(), "Pinned", uuid; manifest)
    before = _snapshot(dir)

    env_dir = materialize_scratch_env(dir, "Pinned")

    written = Pkg.Types.read_manifest(joinpath(env_dir, "Manifest.toml"))
    entry = written[Base.UUID(uuid)]
    @test isabspath(entry.path)
    @test realpath(entry.path) == realpath(dir)
    @test entry.version == v"0.1.0"
    # The rest of the pinned graph survives, so the test env resolves against
    # exactly the versions the user has.
    @test haskey(written, Base.UUID("ade2ca70-3891-5945-98fb-dc099432e06a"))

    @test _snapshot(dir) == before
end

@testitem "scratch env: a deved package resolves to its real source" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    # `_test_environment_key` routes a deved package's test env to the project
    # that devs it, so the package under test is a dependency, not the project.
    root = mktempdir()
    child_uuid = "aaaaaaaa-9999-0000-1111-222222222222"
    child = _write_package(joinpath(root, "Child"), "Child", child_uuid)

    parent = mkpath(joinpath(root, "Parent"))
    write(
        joinpath(parent, "Project.toml"), """
        [deps]
        Child = "$child_uuid"
        """
    )
    write(
        joinpath(parent, "Manifest.toml"), """
        manifest_format = "2.0"

        [[deps.Child]]
        path = "../Child"
        uuid = "$child_uuid"
        version = "0.1.0"
        """
    )
    before_parent, before_child = _snapshot(parent), _snapshot(child)

    env_dir = materialize_scratch_env(parent, "Child")

    entry = Pkg.Types.read_manifest(joinpath(env_dir, "Manifest.toml"))[Base.UUID(child_uuid)]
    @test isabspath(entry.path)
    @test realpath(entry.path) == realpath(child)

    @static if VERSION >= v"1.11"
        sources = Pkg.Types.read_project(joinpath(env_dir, "Project.toml")).sources
        @test realpath(sources["Child"]["path"]) == realpath(child)
    end

    @test _snapshot(parent) == before_parent
    @test _snapshot(child) == before_child
end

@testitem "child: the scratch fallback sees the real module's unexported macros" begin
    mod = Module(:ExpansionTextUnderTest2)
    Base.include(mod, normpath(joinpath(@__DIR__, "..", "juliadynamicanalysisprocess",
        "JuliaDynamicAnalysisProcess", "src", "expansion_text.jl")))
    # A package whose unexported macro refuses to run where its type exists
    # (IrrationalConstants' `@irrational`): the real module fails, the scratch
    # module — given the macro — succeeds.
    real = Module(:RealPkg)
    Core.eval(real, :(macro defconst(name)
        isdefined(__module__, name) && error("already defined")
        :(const $(esc(name)) = 1)
    end))
    Core.eval(real, :(const twoπ = 1))
    scratch = Module(:Scratch)
    @test !isdefined(scratch, Symbol("@defconst"))
    Base.invokelatest(mod._bind_real_macros!, scratch, real)
    @test isdefined(scratch, Symbol("@defconst"))
    @test_throws Exception Base.invokelatest(mod._expand_fully, real, Meta.parse("@defconst twoπ"))
    ex = Base.invokelatest(mod._expand_fully, scratch, Meta.parse("@defconst twoπ"))
    @test occursin("const twoπ = 1", string(ex))
end

@testitem "child: an expansion prints without line nodes so the host can parse it" begin
    # Base's logging macros leave a LineNumberNode first in an `if` condition;
    # `string` prints it as `if #= … =#, try`, which does not parse back.
    mod = Module(:ExpansionTextUnderTest)
    Base.include(mod, normpath(joinpath(@__DIR__, "..", "juliadynamicanalysisprocess",
        "JuliaDynamicAnalysisProcess", "src", "expansion_text.jl")))
    ex = Meta.parse("function f(x)\n    @warn \"careful\" x\n    x\nend")
    expanded = Base.invokelatest(mod._expand_fully, mod, ex)
    text = string(expanded)
    @test !occursin("#=", text)
    # The logging expansion's `Expr(:isdefined, …)` prints as a `$(Expr(…))`
    # splice unless rewritten to `@isdefined`.
    @test !occursin("\$(Expr", text)
    @test occursin("@isdefined", text)
    parsed = Meta.parse(text)
    @test parsed isa Expr && !(parsed.head in (:error, :incomplete))
    # Inert lowered markers vanish: `@inbounds` leaves no `Expr(:inbounds, …)`.
    inb = string(Base.invokelatest(mod._expand_fully, mod, Meta.parse("g(a) = @inbounds a[1]")))
    @test !occursin("\$(Expr", inb)
    @test Meta.parse(inb) isa Expr
    # `@test`'s expansion carries `QuoteNode`s of the original expression:
    # printed as quotes, so the whole expansion parses (and lowers).
    Core.eval(mod, :(using Test))
    t = string(Base.invokelatest(mod._expand_fully, mod, Meta.parse("h(T) = @test T == 1")))
    @test !occursin("QuoteNode", t)
    @test Meta.parse(t) isa Expr
    # A `toplevel` result is flattened into a block of expanded statements.
    Core.eval(mod, :(macro two() Expr(:toplevel, :(a() = 1), :(b() = 2)) end))
    flat = Base.invokelatest(mod._expand_fully, mod, Meta.parse("@two"))
    @test flat isa Expr && flat.head === :block && length(flat.args) == 2
end

@testitem "child: a workspace member loads by identity from the root project" begin
    # `using Member` from a `[workspace]` root fails (`[deps]` does not name
    # the member) although the manifest locates it — the expansion context
    # binds it by PkgId instead, so the real module (and its macros) is found.
    mod = Module(:WorkspaceMembersUnderTest)
    Base.include(mod, normpath(joinpath(@__DIR__, "..", "juliadynamicanalysisprocess",
        "JuliaDynamicAnalysisProcess", "src", "workspace_members.jl")))

    @test Base.invokelatest(mod._bare_import_name, "using Mem") == "Mem"
    @test Base.invokelatest(mod._bare_import_name, "import Mem") == "Mem"
    @test Base.invokelatest(mod._bare_import_name, "using Mem: f") === nothing
    @test Base.invokelatest(mod._bare_import_name, "using ..Mem") === nothing

    root = mktempdir()
    uuid = "aaaaaaaa-9999-0000-1111-444444444444"
    write(joinpath(root, "Project.toml"), "[workspace]\nprojects = [\"Mem\"]\n")
    write(joinpath(root, "Manifest.toml"), """
    julia_version = "$(VERSION)"
    manifest_format = "2.0"
    project_hash = "x"

    [[deps.MemWsMember]]
    path = "Mem"
    uuid = "$uuid"
    version = "0.1.0"
    """)
    mkpath(joinpath(root, "Mem", "src"))
    write(joinpath(root, "Mem", "Project.toml"), "name = \"MemWsMember\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n")
    write(joinpath(root, "Mem", "src", "MemWsMember.jl"),
        "module MemWsMember\nmacro twice(x)\n    :(\$(esc(x)) * 2)\nend\nend\n")

    prev = Base.ACTIVE_PROJECT[]
    Base.ACTIVE_PROJECT[] = joinpath(root, "Project.toml")
    try
        @test Base.identify_package("MemWsMember") === nothing
        id = Base.invokelatest(mod._manifest_pkgid, "MemWsMember")
        @test id == Base.PkgId(Base.UUID(uuid), "MemWsMember")
        @test Base.invokelatest(mod._manifest_pkgid, "NoSuchMember") === nothing
        member = Base.invokelatest(mod._require_from_manifest, "MemWsMember")
        @test member isa Module && nameof(member) === :MemWsMember
        @test Base.invokelatest(Core.eval, member, :(@twice 3)) == 6
    finally
        Base.ACTIVE_PROJECT[] = prev
    end
end

@testitem "scratch env: a package only the manifest devs resolves by name" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    # A workspace root devs a member's dependency without naming it in its
    # own `[deps]` (Plots' root manifest devs `StatsPlots` for `docs`): the
    # wrapper finds it by name and declares it.
    root = mktempdir()
    child_uuid = "aaaaaaaa-9999-0000-1111-333333333333"
    child = _write_package(joinpath(root, "Child"), "Child", child_uuid)

    parent = mkpath(joinpath(root, "Parent"))
    write(joinpath(parent, "Project.toml"), "[deps]\n")
    write(
        joinpath(parent, "Manifest.toml"), """
        manifest_format = "2.0"

        [[deps.Child]]
        path = "../Child"
        uuid = "$child_uuid"
        version = "0.1.0"
        """
    )

    env_dir = materialize_scratch_env(parent, "Child")

    entry = Pkg.Types.read_manifest(joinpath(env_dir, "Manifest.toml"))[Base.UUID(child_uuid)]
    @test realpath(entry.path) == realpath(child)
    wrapper = Pkg.Types.read_project(joinpath(env_dir, "Project.toml"))
    @test wrapper.deps["Child"] == Base.UUID(child_uuid)
    @static if VERSION >= v"1.11"
        @test realpath(wrapper.sources["Child"]["path"]) == realpath(child)
    end
end

@testitem "scratch env: a test-only extra pinned by [sources] resolves" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    # The OrdinaryDiffEq monorepo: `DiffEqDevTools = {path = "lib/…"}` under
    # `[sources]`, named only in `[extras]`/`[targets]` — in no manifest.
    root = mktempdir()
    child_uuid = "aaaaaaaa-9999-0000-1111-555555555555"
    child = _write_package(joinpath(root, "Child"), "Child", child_uuid)

    parent = mkpath(joinpath(root, "Parent"))
    write(joinpath(parent, "Project.toml"), """
        name = "Parent"
        uuid = "aaaaaaaa-9999-0000-1111-666666666666"
        version = "0.1.0"

        [sources]
        Child = {path = "../Child"}

        [extras]
        Child = "$child_uuid"

        [targets]
        test = ["Child"]
        """)
    write(joinpath(parent, "Manifest.toml"), "manifest_format = \"2.0\"\n")

    @static if VERSION >= v"1.11"
        env_dir = materialize_scratch_env(parent, "Child")
        # The pin lives in the wrapper's `[sources]` (the manifest is written
        # by `instantiate` later); the wrapper declares the extra as a dep.
        wrapper = Pkg.Types.read_project(joinpath(env_dir, "Project.toml"))
        @test realpath(wrapper.sources["Child"]["path"]) == realpath(child)
        @test wrapper.deps["Child"] == Base.UUID(child_uuid)
    end
end

@testitem "scratch env: dangling compat for a test-only extra is pruned" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    # A compat entry for a test-only extra is legal in the source project, but
    # the wrapper empties `[extras]` — carrying the entry over used to make Pkg
    # reject the whole wrapper ("Compat `Test` not listed in `deps`, `weakdeps`
    # or `extras` section"), failing the test env of any package shaped like
    # this (JuliaSyntax, Pkg itself).
    uuid = "aaaaaaaa-2222-3333-4444-555555555555"
    dir = mktempdir()
    mkpath(joinpath(dir, "src"))
    mkpath(joinpath(dir, "test"))
    write(
        joinpath(dir, "Project.toml"), """
        name = "CompatPrune"
        uuid = "$uuid"
        version = "0.1.0"

        [deps]
        Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"

        [compat]
        Dates = "1"
        Test = "1"
        julia = "1"

        [extras]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

        [targets]
        test = ["Test"]
        """
    )
    write(joinpath(dir, "src", "CompatPrune.jl"), "module CompatPrune\nend\n")
    write(joinpath(dir, "test", "runtests.jl"), "using Test\n@test true\n")

    env_dir = materialize_scratch_env(dir, "CompatPrune")
    project = Pkg.Types.read_project(joinpath(env_dir, "Project.toml"))

    @test haskey(project.compat, "Dates")
    @test haskey(project.compat, "julia")
    @test !haskey(project.compat, "Test")

    # The wrapper must be acceptable to Pkg — `EnvCache` runs the same project
    # validation `Pkg.activate` does.
    @test Pkg.Types.EnvCache(joinpath(env_dir, "Project.toml")) isa Pkg.Types.EnvCache
end

@testitem "scratch env: dangling [sources] for a test-only extra is pruned" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    # A `[sources]` entry for a test-only extra is legal in the source project
    # (monorepo subpackages pin their test deps to sibling folders this way),
    # but the wrapper empties `[extras]` — carrying the entry over used to make
    # Pkg reject the whole wrapper ("Sources for `LocalTestDep` not listed in
    # `deps` or `extras` section"), failing the test env of every SciML-style
    # subpackage.
    @static if VERSION >= v"1.11"
        parent = mktempdir()
        dir = joinpath(parent, "SourcesPrune")
        dep = _write_package(joinpath(parent, "LocalTestDep"), "LocalTestDep", "aaaaaaaa-7777-8888-9999-aaaaaaaaaaaa")
        mkpath(joinpath(dir, "src"))
        mkpath(joinpath(dir, "test"))
        write(
            joinpath(dir, "Project.toml"), """
            name = "SourcesPrune"
            uuid = "aaaaaaaa-8888-9999-aaaa-bbbbbbbbbbbb"
            version = "0.1.0"

            [deps]
            Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"

            [extras]
            LocalTestDep = "aaaaaaaa-7777-8888-9999-aaaaaaaaaaaa"

            [sources]
            LocalTestDep = {path = "../LocalTestDep"}

            [targets]
            test = ["LocalTestDep"]
            """
        )
        write(joinpath(dir, "src", "SourcesPrune.jl"), "module SourcesPrune\nend\n")
        write(joinpath(dir, "test", "runtests.jl"), "using LocalTestDep\n")
        before_dir, before_dep = _snapshot(dir), _snapshot(dep)

        env_dir = materialize_scratch_env(dir, "SourcesPrune")
        project = Pkg.Types.read_project(joinpath(env_dir, "Project.toml"))

        # The test-only source is gone; the package-under-test pin survives.
        @test !haskey(project.sources, "LocalTestDep")
        @test realpath(project.sources["SourcesPrune"]["path"]) == realpath(dir)

        # The wrapper must be acceptable to Pkg — `EnvCache` runs the same
        # project validation `Pkg.activate` does, which is what used to throw.
        @test Pkg.Types.EnvCache(joinpath(env_dir, "Project.toml")) isa Pkg.Types.EnvCache

        @test _snapshot(dir) == before_dir
        @test _snapshot(dep) == before_dep
    end
end

@testitem "scratch env: stdlib test env extras fallback carries [sources]" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    # When a stdlib-shaped checkout declares its test deps via [extras]/[targets]
    # (no test/Project.toml) and path-pins one of them through [sources], the
    # promoted dep must carry its (rebased) source entry — otherwise Pkg would
    # go looking for it in a registry.
    @static if VERSION >= v"1.11"
        parent = mktempdir()
        dep = _write_package(joinpath(parent, "LocalTestDep"), "LocalTestDep", "aaaaaaaa-7777-8888-9999-aaaaaaaaaaaa")
        dir = joinpath(parent, "Dates")
        mkpath(joinpath(dir, "src"))
        mkpath(joinpath(dir, "test"))
        dates_uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
        write(
            joinpath(dir, "Project.toml"), """
            name = "Dates"
            uuid = "$dates_uuid"
            version = "1.0.0"

            [extras]
            LocalTestDep = "aaaaaaaa-7777-8888-9999-aaaaaaaaaaaa"
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

            [sources]
            LocalTestDep = {path = "../LocalTestDep"}

            [targets]
            test = ["LocalTestDep", "Test"]
            """
        )
        write(joinpath(dir, "src", "Dates.jl"), "module Dates\nend\n")
        write(joinpath(dir, "test", "runtests.jl"), "using LocalTestDep, Test\n")
        before = _snapshot(dir)

        env_dir = materialize_stdlib_test_env(dir, "Dates")
        project = Pkg.Types.read_project(joinpath(env_dir, "Project.toml"))

        @test haskey(project.deps, "LocalTestDep")
        @test isabspath(project.sources["LocalTestDep"]["path"])
        @test realpath(project.sources["LocalTestDep"]["path"]) == realpath(dep)
        # The package's own pin points at the checkout, exactly once.
        @test realpath(project.sources["Dates"]["path"]) == realpath(dir)
        @test _snapshot(dir) == before
    end
end

@testitem "scratch env: write_resolved_env_project copies a manifest-less env project" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    # A docs/-style env: no name/uuid, deps plus a relative [sources] entry and
    # a [workspace] section. The copy must rebase sources to absolute, drop the
    # env-location-relative sections, and never write into the source folder.
    # `[sources]` exists from 1.11, `[workspace]` (as a Project field) only from
    # 1.12 — build the fixture from exactly the sections this Julia's Pkg knows.
    has_sources = VERSION >= v"1.11"
    has_workspace = hasfield(Pkg.Types.Project, :workspace)

    parent = mktempdir()
    dep = _write_package(joinpath(parent, "LocalDep"), "LocalDep", "aaaaaaaa-7777-8888-9999-aaaaaaaaaaaa")
    env_dir = joinpath(parent, "docs")
    mkpath(env_dir)
    project_toml = """
    [deps]
    LocalDep = "aaaaaaaa-7777-8888-9999-aaaaaaaaaaaa"
    """
    has_sources && (project_toml *= """

    [sources]
    LocalDep = {path = "../LocalDep"}
    """)
    has_workspace && (project_toml *= """

    [workspace]
    projects = ["sub"]
    """)
    write(joinpath(env_dir, "Project.toml"), project_toml)
    before = _snapshot(env_dir)

    project_dir = mktempdir()
    write_resolved_env_project(env_dir, project_dir)

    project = Pkg.Types.read_project(joinpath(project_dir, "Project.toml"))
    @test project.name === nothing
    @test haskey(project.deps, "LocalDep")
    if has_sources
        @test isabspath(project.sources["LocalDep"]["path"])
        @test realpath(project.sources["LocalDep"]["path"]) == realpath(dep)
    end
    if has_workspace
        @test isempty(project.workspace)
    end
    # The copy is valid for Pkg and the source env untouched.
    @test Pkg.Types.EnvCache(joinpath(project_dir, "Project.toml")) isa Pkg.Types.EnvCache
    @test _snapshot(env_dir) == before
    @test !isfile(joinpath(env_dir, "Manifest.toml"))
end

@testitem "scratch env: a stdlib checkout gets a hand-built test environment" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    # A dev checkout of a stdlib (the julia repo's stdlib/ folder) cannot go
    # through TestEnv: its `get_test_dir` bails out on stdlib UUIDs without
    # setting `pkgspec.path` and crashes downstream. The fixture reuses Dates'
    # real UUID to look like such a checkout.
    dates_uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
    dir = _write_package(mktempdir(), "Dates", dates_uuid)

    @test needs_stdlib_test_env(dir, "Dates") == (VERSION >= v"1.11")

    # An ordinary package is not routed through the stdlib path.
    other = _write_package(mktempdir(), "Ordinary", "aaaaaaaa-6666-7777-8888-999999999999")
    @test !needs_stdlib_test_env(other, "Ordinary")

    @static if VERSION >= v"1.11"
        before = _snapshot(dir)
        env_dir = materialize_stdlib_test_env(dir, "Dates")
        project = Pkg.Types.read_project(joinpath(env_dir, "Project.toml"))

        # Nameless wrapper, package path-pinned, test target deps promoted.
        @test project.name === nothing
        @test project.deps["Dates"] == Base.UUID(dates_uuid)
        @test haskey(project.deps, "Test")
        @test realpath(project.sources["Dates"]["path"]) == realpath(dir)
        @test _snapshot(dir) == before

        # With a test/Project.toml, the test deps come from there instead.
        write(
            joinpath(dir, "test", "Project.toml"), """
            [deps]
            Logging = "56ddb016-857b-54e1-b83d-db4d58db5568"
            """
        )
        env_dir2 = materialize_stdlib_test_env(dir, "Dates")
        project2 = Pkg.Types.read_project(joinpath(env_dir2, "Project.toml"))
        @test haskey(project2.deps, "Logging")
        @test project2.deps["Dates"] == Base.UUID(dates_uuid)
    end
end

@testitem "scratch env: TestEnv activates against the scratch env" begin
    include(joinpath(@__DIR__, "test_scratch_env_helpers.jl"))
    import Pkg

    # The failure this guards against only appears once TestEnv runs: if the
    # scratch env were a plain copy of the package's Project.toml, `get_test_dir`
    # would look for `<scratch>/test` and find nothing.
    dir = _write_package(mktempdir(), "Activated", "aaaaaaaa-3333-4444-5555-666666666666")
    before = _snapshot(dir)

    original_project = Base.active_project()
    try
        Pkg.activate(materialize_scratch_env(dir, "Activated"))
        activate_test_env("Activated")

        # A test-only dep resolving proves the merged env is real, not empty.
        @test Base.identify_package("Test") !== nothing
        @test Base.identify_package("Activated") !== nothing
    finally
        Pkg.activate(original_project)
    end

    @test _snapshot(dir) == before
end
