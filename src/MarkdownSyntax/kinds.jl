# Kind registration. Module ids 0/1/2 are JuliaSyntax, JuliaLowering and
# JuliaSyntaxFormatter, 3 is TomlSyntax. Kind NAMES are one global namespace
# across modules, hence the `Md`/`md_` prefixes.
#
# Registered at include time: as a nested module there is no `__init__`, and
# the registration is baked into the package image exactly like TomlSyntax's.
# The standalone package re-registers from `__init__` (a repeated identical
# registration is a no-op).
const MARKDOWN_KIND_MODULE_ID = 4

function _register_markdown_kinds()
    JuliaSyntax.register_kinds!(@__MODULE__, MARKDOWN_KIND_MODULE_ID, [
        "BEGIN_MD_TOKENS",
            "MdFenceDelim",         # one whole fence delimiter line, EOL included
            "MdCode",               # the content lines of a fenced block (may be zero-width)
            "MdFrontMatterDelim",   # a `---`/`...` front matter delimiter line
            "MdFrontMatterContent", # the lines between the delimiters (may be zero-width)
            "MdHeading",            # one ATX heading line
            "MdIndentedCode",       # a maximal run of indented-code lines
            "MdText",               # a maximal run of anything else (prose, blanks); trivia
        "END_MD_TOKENS",
        "BEGIN_MD_NONTERMINALS",
            "md_document",
            "md_code_fence",
            "md_front_matter",
        "END_MD_NONTERMINALS",
    ])
end
_register_markdown_kinds()

"True for the kinds the parser treats as trivia (prose and blank lines)."
is_md_trivia(k::Kind) = k == K"MdText"
"True for the nonterminal kinds."
is_md_nonterminal(k::Kind) = K"BEGIN_MD_NONTERMINALS" <= k <= K"END_MD_NONTERMINALS"

for f in (:is_md_trivia, :is_md_nonterminal)
    @eval $f(x) = $f(kind(x))
end
