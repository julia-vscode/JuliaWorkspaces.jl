using Documenter, JuliaWorkspaces


makedocs(
    modules=[JuliaWorkspaces],
    authors="Uwe Fechner <uwe.fechner.msc@gmail.com> and contributors",
    sitename="JuliaWorkspaces.jl",
    pages=[
        "Home" => "index.md",
        "Functions" => "functions.md",
        "Types" => "types.md",
        "Development" => "development.md"
    ])

deploydocs(repo="github.com/julia-vscode/JuliaWorkspaces.jl.git")
