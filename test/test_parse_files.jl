@testitem "parse_files_blocking parses all Julia files and reports progress" begin
    using JuliaWorkspaces.URIs2: URI

    jw = JuliaWorkspace()
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:/a.jl"), SourceText("f() = 1", "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:/b.jl"), SourceText("g( = 2", "julia")))
    JuliaWorkspaces.add_file!(jw, TextFile(URI("file:/c.toml"), SourceText("x = 1", "toml")))

    reports = Tuple{Int,Int}[]
    parse_files_blocking(jw; progress_callback=(k, n) -> push!(reports, (k, n)))

    # Only the Julia files are parsed; the counter runs to completion.
    @test reports == [(1, 2), (2, 2)]

    # No callback and repeat calls (memoized) are fine.
    parse_files_blocking(jw)

    # The workspace still produces diagnostics afterwards (syntax error in b.jl).
    @test !isempty(get_diagnostic(jw, URI("file:/b.jl")))
end
