# JuliaWorkspaces.jl

*The analysis engine that powers [LanguageServer.jl](https://github.com/julia-vscode/LanguageServer.jl).*

JuliaWorkspaces.jl takes a set of files — Julia sources, `Project.toml` /
`Manifest.toml`, configuration files — and answers questions about them:
diagnostics, hover text, completions, go-to-definition, references, document and
workspace symbols, signature help, formatting, code actions, test items, and
more. It is designed to be reusable: the same engine can back an interactive
language server, a CI linter, or a command-line tool.

Internally it is an **incremental, memoized query system** built on
[Salsa.jl](https://github.com/julia-vscode/Salsa.jl). Mutable *inputs* (files,
the active project, results from background indexing) feed a graph of pure,
cached *derived queries*. Change one file and only the queries that depend on it
recompute. For the full picture, read the [Architecture](architecture.md) page.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/julia-vscode/JuliaWorkspaces.jl")
```

## Quick start

```julia
using JuliaWorkspaces

# Build a workspace from one or more folders on disc.
jw = workspace_from_folders(["/path/to/my/project"])

# Inspect the files that were picked up.
for uri in get_julia_files(jw)
    println(uri)
end

# Query diagnostics for the whole workspace.
diags = get_diagnostics(jw)
for (uri, file_diags) in diags
    for d in file_diags
        println("$(uri): [$(d.severity)] $(d.message)")
    end
end
```

You can also build a workspace incrementally and feed it in-memory content
(this is what a language server does as the user edits):

```julia
using JuliaWorkspaces
using JuliaWorkspaces.URIs2

jw = JuliaWorkspace()

uri = filepath2uri("/path/to/file.jl")
add_file!(jw, TextFile(uri, SourceText("x = 1\n", "julia")))

tree = get_julia_syntax_tree(jw, uri)
```

To resolve symbols from a package's dependencies, enable the
[dynamic feature](architecture.md#the-dynamic-feature) by passing a
[`DynamicMode`](@ref):

```julia
jw = workspace_from_folders(["/path/to/my/project"]; dynamic=DynamicIndexingOnly)
wait_until_ready(jw)            # block until background indexing finishes
diags = get_diagnostics(jw)    # now environment-aware
```

## Documentation map

- [Architecture](architecture.md) — the Salsa query model, the layer structure,
  the public API design, and the dynamic feature. **Start here if you are
  working on the package.**
- [Functions](functions.md) — reference for the exported functions.
- [Types](types.md) — reference for the exported and internal types.

## Design and roadmap

JuliaWorkspaces.jl is the home of two deliberate transitions of the Julia
tooling stack.

### Transition 1: CSTParser → JuliaSyntax

The first transition is adopting [JuliaSyntax.jl](https://github.com/JuliaLang/JuliaSyntax.jl)
for parsing and, eventually, for representing code. Most of the language server
is currently powered by CSTParser, which has its own parser and node type. At
the same time JuliaSyntax is already used for some features (such as test-item
detection), so today every file is parsed twice. The roadmap is to drop the
CSTParser parser entirely, settle on a single parse pass, and then decide on the
right node types for the engine.

### Transition 2: mutable state → incremental Salsa model

The second transition is towards a functional, immutable, incremental
computational model. The older design used mutable data structures throughout,
which made it very hard to reason about when and where state changed (and
effectively ruled out multithreading). The strategy is to use
[Salsa.jl](https://github.com/julia-vscode/Salsa.jl) as the core design — an
approach inspired by the Rust language server — yielding a data model that is far
easier to reason about. This is the model the rest of the package is built on;
see [Architecture](architecture.md).

### Goal

Roughly, StaticLint / CSTParser / SymbolServer hold the code from before these
transitions, while JuliaWorkspaces holds the code written in the new world — the
split is by *generation*, not by functionality. The expectation is that once the
transition is complete, StaticLint and SymbolServer cease to exist as separate
packages and their code is incorporated into JuliaWorkspaces. The end state:
[LanguageServer.jl](https://github.com/julia-vscode/LanguageServer.jl) contains
only the LSP wire protocol, and all functionality lives in JuliaWorkspaces — so
that CI tools (such as julia-actions/julia-lint), command-line apps, and other
hosts can use it directly.

