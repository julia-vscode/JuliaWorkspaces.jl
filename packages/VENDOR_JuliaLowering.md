# Vendored JuliaSyntax v2 + JuliaLowering

`packages/JuliaSyntax/` and `packages/JuliaLowering/` are verbatim copies of the
`JuliaSyntax/` and `JuliaLowering/` subdirectories of the JuliaLang/julia repository at

    commit b657e6a0d95c9a5fc2497347f8123ef6e5932475 (master, 2026-08)

They are NOT git subtrees (they are subdirectories of a monorepo) and are NOT Pkg
dependencies — the registered JuliaSyntax 1.0.2 remains JW's Pkg dep and coexists as a
separate module. The vendored files are never patched; all import rewiring lives in the
JW-owned wrapper `src/v2/vendor_lowering.jl`, which mirrors
`packages/JuliaLowering/src/JuliaLowering.jl` (see the deviation list at the top of the
wrapper). Both are loaded only on Julia >= 1.12 (`isdefinedglobal` and friends fail to
load on 1.11) and are used exclusively by `src/v2/layer_lowering.jl`.

Only `src/`, `Project.toml`, `LICENSE*` are required at runtime; the rest of the trees
(test/, docs/, tools/, ...) is kept for reference and excluded from linting via the
`packages/**` rule in `JuliaLint.toml`.

## Refresh procedure

1. Sparse-clone julia master (`git clone --filter=blob:none --sparse --depth 1
   https://github.com/JuliaLang/julia`, `git sparse-checkout set JuliaSyntax
   JuliaLowering`) and replace the two directories; update the SHA above.
2. Re-sync `src/v2/vendor_lowering.jl` against the new
   `packages/JuliaLowering/src/JuliaLowering.jl` (the wrapper mirrors its ~60 lines;
   diff them and re-apply the documented deviations).
3. Run the smoke gate on the oldest supported Julia (1.12): the standalone matrix in
   this repo's history (parse / macroexpand / expand_forms_1+2+resolve_scopes / lower
   must pass; thunk *execution* is expected to fail on stable Julia — it targets
   master-only Core builtins) and the `lowering layer` testitems in
   `test/v2/test_lowering_layer.jl`.

Upstream CI tests nightly only, so a refresh without step 3 is not safe.
