using Documenter, DocumenterMermaid, JuliaWorkspaces


makedocs(
    modules=[JuliaWorkspaces],
    authors="Uwe Fechner <uwe.fechner.msc@gmail.com> and contributors",
    sitename="JuliaWorkspaces.jl",
    checkdocs=:exports,
    pages=[
        "Home" => "index.md",
        "Architecture" => "architecture.md",
        "Functions" => "functions.md",
        "Types" => "types.md"
    ])

deploydocs(repo="github.com/julia-vscode/JuliaWorkspaces.jl.git")
