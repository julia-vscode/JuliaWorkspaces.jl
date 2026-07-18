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
- Keep code comments brief and to-the-point. Don't reference random non-representative examples
- Build a fresh `JuliaWorkspace` per check; Revise picks up non-`@derived` edits but memoized results are stale.
- Test cross-file behaviour via `derived_file_analysis(rt, root, uri).meta` — `derived_static_lint_meta_for_root(rt, uri)` analyses a non-root file standalone (no module context), so cross-file names don't resolve.
- In a bare module (no project), `get_diagnostic` won't surface check_call/missing-ref hints; read `StaticLint.errorof(node, meta_dict)` directly.

## Internals
- Base/Core/stdlibs are baked into the precompile file via `const stdlibs = load_core()`. Verify changes by running `load_core()`, not by checking `stdlibs`. `load_core`/crawler edits only reach the `derived_*` pipeline after a session restart (the baked const is stale until recompile); a fresh `load_core()` verifies crawler output only.
- Store the minimal plain-data fingerprint a derived value actually depends on, not the big `ModuleStore`/`ExternalEnv`/`Binding`. It's both cheaper to compare and gives precise invalidation
- SymbolServer and StaticLint were separate packages, but are deprecated and not updated since getting folded into JuliaWorkspaces
