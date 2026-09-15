# TomlSyntax

```@meta
CurrentModule = JuliaWorkspaces.TomlSyntax
```

`JuliaWorkspaces.TomlSyntax` is a TOML 1.0 parser built on the language-agnostic
core of the vendored JuliaSyntax 2.0 (kinds, green tree, cursors, source files,
diagnostics). It produces a lossless green tree and a trivia-free syntax tree
with byte ranges, recovers from errors line by line, and turns trees into the
same `Dict{String,Any}` the TOML stdlib produces. The workspace uses it for
`Project.toml`, `Manifest.toml` and the tool configuration files (see
[`layer_toml_tree.jl`](architecture.md#layers)); the module itself depends only
on JuliaSyntax and `Dates`, so it can become a standalone package once
JuliaSyntax 2.0 is released.

```@docs
TomlSyntax
```

## Parsing to a table

```@docs
parse
tryparse
parsefile
tryparsefile
TomlParseError
error_kind
build_table
```

## Syntax trees

```@docs
parsetoml
parsetoml_with_diagnostics
TomlNode
TomlData
build_tree
TomlParseStream
parse_toml!
tokenize
parse_toml_literal
OffsetDateTime
```

## Diagnostics

```@docs
TomlDiagnostic
TomlErrorKind
```

## Kind predicates

```@docs
is_toml_string
is_toml_datetime
is_toml_value_token
is_toml_trivia
is_toml_nonterminal
```
