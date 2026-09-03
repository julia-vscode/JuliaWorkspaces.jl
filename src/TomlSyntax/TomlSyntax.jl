# TomlSyntax: a TOML 1.0 parser built on the language-agnostic core of
# JuliaSyntax 2.0 (kinds, green tree, cursors, source files, diagnostics).
#
# Layering (mirrors JuliaSyntax):
#   lexer.jl        byte-level tokenizer; delimits tokens only, two modes
#   parse_stream.jl the mark/emit output stream (JuliaSyntax's `ParseStream`
#                   is hard-wired to the Julia lexer, so this is an adapted
#                   copy of its lookahead/bump/emit machinery)
#   literals.jl     leaf value conversion
#   validate.jl     token CONTENT checks (escapes, control chars, UTF-8, dates)
#   parser.jl       recursive-descent productions with line-level recovery
#   tree.jl         `TomlNode`, the trivia-free AST (a `TreeNode{TomlData}`)
#   table.jl        the semantic pass: tree -> Dict, with the table rules
#   api.jl          parse/tryparse/parsefile and `TomlParseError`
#
# Self-contained by design: only JuliaSyntax and Dates. Nothing from
# JuliaWorkspaces (Salsa, URIs, Diagnostic) is referenced, so the module can be
# lifted into a standalone package once JuliaSyntax 2.0 is released; the one
# line to change is the `using` below.
"""
    TomlSyntax

A TOML 1.0 parser on the JuliaSyntax 2.0 core: `parse`/`tryparse` give the
document as a `Dict` like the TOML stdlib, `parsetoml` gives the syntax tree
(`TomlNode`) with byte ranges and recovers from errors, and `build_table`
turns a tree into the `Dict` while checking the table rules.
"""
module TomlSyntax

using ..VendoredLowering: JuliaSyntax   # standalone package: `using JuliaSyntax`
using .JuliaSyntax: Kind, @K_str, @KSet_str, SyntaxHead, RawFlags, EMPTY_FLAGS, TRIVIA_FLAG,
    NON_TERMINAL_FLAG, RawGreenNode, ParseStreamPosition, GreenTreeCursor, RedTreeCursor,
    GreenNode, TreeNode, AbstractSyntaxData, SourceFile, Diagnostic, ErrorVal,
    kind, flags, head, is_trivia, is_error, is_terminal, is_non_terminal, is_leaf, children,
    numchildren, byte_range, first_byte, last_byte, span, sourcefile, source_location,
    filename, untokenize, show_diagnostic, show_diagnostics, any_error
using Dates

include("kinds.jl")
include("diagnostics.jl")
include("lexer.jl")
include("parse_stream.jl")
include("literals.jl")
include("validate.jl")
include("parser.jl")
include("tree.jl")
include("table.jl")
include("api.jl")

public parse, tryparse, parsefile, tryparsefile, parsetoml, parsetoml_with_diagnostics,
    build_table, build_tree, error_kind, tokenize, parse_toml_literal,
    TomlNode, TomlData, TomlParseError, TomlDiagnostic, TomlErrorKind, OffsetDateTime,
    TomlParseStream, is_toml_string, is_toml_datetime, is_toml_value_token, is_toml_trivia,
    is_toml_nonterminal

end # module TomlSyntax
