using Documenter, JuliaWorkspaces


makedocs(
    modules=[JuliaWorkspaces],
    authors="Uwe Fechner <uwe.fechner.msc@gmail.com> and contributors",
    sitename="JuliaWorkspaces.jl",
    pages=[
        "Home" => "index.md",
        "Exported Functions" => "functions.md"
    ])

    using Documenter

# DocMeta.setdocmeta!(KiteUtils, :DocTestSetup, :(using KiteUtils); recursive=true)
#
# makedocs(;
#     modules=[KiteUtils],
#     authors="Uwe Fechner <uwe.fechner.msc@gmail.com> and contributors",
#     repo="https://github.com/ufechner7/KiteUtils.jl/blob/{commit}{path}#{line}",
#     sitename="KiteUtils.jl",
#     checkdocs=:none,
#     format=Documenter.HTML(;
#         prettyurls=get(ENV, "CI", "false") == "true",
#         canonical="https://ufechner7.github.io/KiteUtils.jl",
#         assets=String[],
#     ),
#     pages=[
#         "Home" => "index.md",
#         "Reference frames" => "reference_frames.md",
#         "Exported Functions" => "functions.md",
#         "Exported Types" => "types.md",
#         "Examples" => "examples.md",
#     ],
# )

deploydocs(repo="github.com/julia-vscode/JuliaWorkspaces.jl.git")
