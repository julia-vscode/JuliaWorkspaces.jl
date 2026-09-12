using Documenter, DocumenterMermaid, JuliaWorkspaces


makedocs(
    modules=[JuliaWorkspaces],
    authors="Uwe Fechner <uwe.fechner.msc@gmail.com> and contributors",
    sitename="JuliaWorkspaces.jl",
    checkdocs=:exports,
    # The vendored JuliaSyntax/JuliaLowering copy exports upstream's documented
    # API; those docstrings are not part of this manual. Ignoring the wrapper
    # module skips its submodules too.
    checkdocs_ignored_modules=[JuliaWorkspaces.VendoredLowering],
    pages=[
        "Home" => "index.md",
        "Architecture" => "architecture.md",
        "Configuration" => "configuration.md",
        "TomlSyntax" => "tomlsyntax.md",
        "MarkdownSyntax" => "markdownsyntax.md",
        "Functions" => "functions.md",
        "Types" => "types.md"
    ])

deploydocs(repo="github.com/julia-vscode/JuliaWorkspaces.jl.git")
