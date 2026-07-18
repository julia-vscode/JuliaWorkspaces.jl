# AGENTS.md for JuliaWorkspaces.jl

This is a static analysis engine for Julia projects and mainly backs LanguageServer.jl.

- Use `julia-mcp` in a new synthetic Julia environment.
    - Make sure Revise is loaded before this package
    - Use an environment that `Pkg.develop`s this package and adds TestItemRunner
    - Restart the session when unexpected failures occur (due to accumulation of state) or when making changes to structs/`@derived` functions
- Always run tests first via `TestItemRunner`
- For checkpointing/final validation, run tests in a new process with `Pkg.test()`
- Fix any test or type errors until the whole suite is green.
- Add or update tests for the code you change, even if nobody asked.

## Internals
- Base/Core/stdlibs are baked into the precompile file via `const stdlibs = load_core()`. Verify changes by running `load_core()`, not by checking `stdlibs`.
- Store the minimal plain-data fingerprint a derived value actually depends on, not the big `ModuleStore`/`ExternalEnv`/`Binding`. It's both cheaper to compare and gives precise invalidation
- SymbolServer and StaticLint were separate packages, but are deprecated and not updated since getting folded into JuliaWorkspaces
