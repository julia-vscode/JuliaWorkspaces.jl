using Documenter, JuliaWorkspaces


makedocs(
    modules=[JuliaWorkspaces],
    sitename="JuliaWorkspaces.jl",
    pages=[
        "Home" => "index.md"
    ])

deploydocs(repo="github.com/julia-vscode/JuliaWorkspaces.jl.git")
