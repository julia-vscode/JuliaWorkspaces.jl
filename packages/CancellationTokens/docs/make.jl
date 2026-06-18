using Documenter, CancellationTokens
import Sockets

makedocs(
    sitename = "CancellationTokens.jl",
    modules  = [CancellationTokens],
    pages = [
        "Home" => "index.md",
        "Guide" => "guide.md",
        "Base Function Extensions" => "base.md",
        "API Reference" => "api.md",
    ],
)

deploydocs(
    repo = "github.com/davidanthoff/CancellationTokens.jl.git"
)
