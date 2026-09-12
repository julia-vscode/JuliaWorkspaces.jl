# Kind registration. Module ids 0/1/2 are JuliaSyntax, JuliaLowering and
# JuliaSyntaxFormatter. Kind NAMES are one global namespace across modules,
# hence the `Toml`/`toml_` prefixes; structural kinds the shared machinery
# hard-codes (`TOMBSTONE None EndMarker error Whitespace NewlineWs Comment`)
# and the punctuation `= [ ] { } , .` are reused from JuliaSyntax itself.
#
# Registered at include time: as a nested module there is no `__init__`, and
# the registration is baked into the package image exactly like the vendored
# JuliaLowering's. The standalone package re-registers from `__init__`
# (a repeated identical registration is a no-op).
const TOML_KIND_MODULE_ID = 3

function _register_toml_kinds()
    JuliaSyntax.register_kinds!(@__MODULE__, TOML_KIND_MODULE_ID, [
        "BEGIN_TOML_TOKENS",
            "TomlBareKey",
            "BEGIN_TOML_STRINGS",
                "TomlBasicString",
                "TomlLiteralString",
                "TomlMultilineBasicString",
                "TomlMultilineLiteralString",
            "END_TOML_STRINGS",
            "TomlInteger",
            "TomlFloat",
            "TomlBool",
            "BEGIN_TOML_DATETIMES",
                "TomlOffsetDateTime",
                "TomlLocalDateTime",
                "TomlLocalDate",
                "TomlLocalTime",
            "END_TOML_DATETIMES",
        "END_TOML_TOKENS",
        "BEGIN_TOML_NONTERMINALS",
            "toml_document",
            "toml_table",
            "toml_array_table",
            "toml_keyval",
            "toml_key",
            "toml_array",
            "toml_inline_table",
        "END_TOML_NONTERMINALS",
    ])
end
_register_toml_kinds()

"True for the four string token kinds."
is_toml_string(k::Kind) = K"BEGIN_TOML_STRINGS" <= k <= K"END_TOML_STRINGS"
"True for the four date/time token kinds."
is_toml_datetime(k::Kind) = K"BEGIN_TOML_DATETIMES" <= k <= K"END_TOML_DATETIMES"
"True for every token kind that is a complete TOML value on its own."
is_toml_value_token(k::Kind) = K"BEGIN_TOML_STRINGS" <= k <= K"END_TOML_DATETIMES"
"True for the kinds the parser treats as trivia (newlines are significant, but trivia)."
is_toml_trivia(k::Kind) = k == K"Whitespace" || k == K"NewlineWs" || k == K"Comment"
"True for the nonterminal kinds."
is_toml_nonterminal(k::Kind) = K"BEGIN_TOML_NONTERMINALS" <= k <= K"END_TOML_NONTERMINALS"

for f in (:is_toml_string, :is_toml_datetime, :is_toml_value_token, :is_toml_trivia, :is_toml_nonterminal)
    @eval $f(x) = $f(kind(x))
end
