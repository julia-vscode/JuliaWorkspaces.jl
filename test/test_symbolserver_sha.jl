# `sha2_256_dir`/`sha_pkg` fingerprint a deved package's `src` so the indexer
# can tell whether its symbol cache is stale. Entries it skips must leave the
# running hash intact.

@testmodule ShaDirHelpers begin
    # A `src` entry that `stat` cannot read (`uperm == 0`). Windows without
    # Developer Mode can't create symlinks, but junctions need no privilege.
    function make_dangling!(dir, name)
        link = joinpath(dir, name)
        try
            symlink(joinpath(dir, "does-not-exist.jl"), link)
        catch err
            Sys.iswindows() || rethrow()
            target = mktempdir()
            run(pipeline(`cmd /c mklink /J $link $target`, devnull))
            rm(target; recursive=true)
        end
        return link
    end

    function make_src(files::Pair...)
        src = joinpath(mktempdir(), "src")
        mkpath(src)
        for (name, content) in files
            mkpath(dirname(joinpath(src, name)))
            write(joinpath(src, name), content)
        end
        return src
    end
end

@testitem "sha2_256_dir: an unreadable entry does not break the hash" setup=[ShaDirHelpers] begin
    using JuliaWorkspaces.SymbolServer: sha2_256_dir
    using .ShaDirHelpers: make_dangling!, make_src

    expected = sha2_256_dir(make_src("a.jl" => "a = 1", "c.jl" => "c = 2"))

    # Sorted between two `.jl` files, so a lost accumulator hits the next one.
    src = make_src("a.jl" => "a = 1", "c.jl" => "c = 2")
    link = make_dangling!(src, "b_broken.jl")
    @test uperm(link) & 0x04 == 0
    @test sha2_256_dir(src) == expected

    # Last entry: nothing follows it to throw, but the hash must survive.
    src = make_src("a.jl" => "a = 1", "c.jl" => "c = 2")
    make_dangling!(src, "z_broken.jl")
    @test sha2_256_dir(src) == expected

    # Same inside a subdirectory.
    src = make_src("a.jl" => "a = 1", "c.jl" => "c = 2")
    mkdir(joinpath(src, "sub"))
    make_dangling!(joinpath(src, "sub"), "broken.jl")
    @test sha2_256_dir(src) == expected
end

@testitem "sha2_256_dir: hidden entries are skipped" setup=[ShaDirHelpers] begin
    using JuliaWorkspaces.SymbolServer: sha2_256_dir
    using .ShaDirHelpers: make_src

    expected = sha2_256_dir(make_src("a.jl" => "a = 1"))
    src = make_src(
        "a.jl" => "a = 1",
        ".hidden.jl" => "h = 1",
        ".ipynb_checkpoints/a-checkpoint.jl" => "a = 0",
    )
    @test sha2_256_dir(src) == expected

    # Content still counts.
    @test sha2_256_dir(make_src("a.jl" => "a = 2")) != expected
end

@testitem "sha_pkg: a deved package with an unreadable src entry" setup=[ShaDirHelpers] begin
    using JuliaWorkspaces.SymbolServer: sha_pkg, sha2_256_dir
    using .ShaDirHelpers: make_dangling!, make_src
    using Pkg

    src = make_src("Foo.jl" => "module Foo end", "z.jl" => "z = 1")
    make_dangling!(src, "b_broken.jl")
    pkg_dir = dirname(src)
    manifest_dir = mktempdir()
    pe = Pkg.Types.PackageEntry(name="Foo", path=relpath(pkg_dir, manifest_dir))

    sha = sha_pkg(manifest_dir, pe)
    @test sha isa Vector{UInt8}
    @test sha == sha2_256_dir(make_src("Foo.jl" => "module Foo end", "z.jl" => "z = 1"))
end
