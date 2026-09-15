# toml-test (vendored)

The TOML conformance corpus from https://github.com/toml-lang/toml-test,
release **v2.2.0**, directory `tests/` copied verbatim (MIT license, see
`LICENSE`). Byte-exact fidelity matters (CRLF, bare CR, invalid UTF-8 cases),
so `.gitattributes` at the repo root disables line-ending normalisation here.

`tests/files-toml-1.0.0` lists the cases that apply to TOML 1.0; the runner in
`test/tomlsyntax/test_tomlsyntax_toml_test.jl` selects by that list.
