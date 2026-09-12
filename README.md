# JuliaWorkspaces.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://julia-vscode.github.io/JuliaWorkspaces.jl/dev)
[![Build Status](https://github.com/julia-vscode/JuliaWorkspaces.jl/actions/workflows/juliaci.yml/badge.svg?branch=main)](https://github.com/julia-vscode/JuliaWorkspaces.jl/actions/workflows/juliaci.yml)

The analysis engine that powers [LanguageServer.jl](https://github.com/julia-vscode/LanguageServer.jl).
See also [LintApp.jl](https://github.com/julia-vscode/LintApp.jl) a standalone command-line application that using JuliaWorkspaces to do linting.

JuliaWorkspaces.jl takes a set of files — Julia sources, `Project.toml` /
`Manifest.toml`, configuration files — and answers questions about them:
diagnostics, hover text, completions, go-to-definition, references, document and
workspace symbols, signature help, formatting, code actions, test items, and
more. The same engine can back an interactive language server, a CI linter, or a
command-line tool.

Internally it is an **incremental, memoized query system** built on
[Salsa.jl](https://github.com/julia-vscode/Salsa.jl): mutable *inputs* (files,
the active project, background-indexing results) feed a graph of pure, cached
*derived queries*, so changing one file only recomputes what depends on it.

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

# Query diagnostics for the whole workspace.
for (uri, file_diags) in get_diagnostics(jw)
    for d in file_diags
        println("$(uri): [$(d.severity)] $(d.message)")
    end
end
```

## Documentation

Full documentation is hosted at <https://julia-vscode.github.io/JuliaWorkspaces.jl/dev>. Start with
the architecture page if you intend to work on the package.

## Repository scripts

| Script | Purpose |
|:-------|:--------|
| `scripts/update_vendored_packages.jl` | Reconcile the vendored `packages/` trees with `scripts/vendored_packages.jl`. |
| `scripts/install_julia_versions.jl` | Install every supported Julia via juliaup. |
| `scripts/update_app_environments.jl` | Regenerate the per-version dynamic analysis process environments. |

`scripts/vendored_packages.jl` is the list the first of those works from: add a package
there and run it with `--apply` to vendor it. Nothing records which version is vendored —
that is read back from each tree's own `Project.toml`, and `--verify` audits it against the
commit `git subtree` recorded.
