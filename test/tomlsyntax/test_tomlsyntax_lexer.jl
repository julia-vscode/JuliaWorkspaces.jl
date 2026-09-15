# The lexer on its own, one mode at a time, via `TomlSyntax.tokenize`.

@testsnippet TomlLexerTS begin
    # (kind name, covered text) per token, dropping the end marker.
    function toks(text; mode=:key)
        out = Tuple{String,String}[]
        for (k, _, r) in TS.tokenize(text; mode)
            k == TS.K"EndMarker" && break
            push!(out, (string(k), String(codeunits(text)[r])))
        end
        return out
    end
    # (kind name, error code) per token.
    function tokerrs(text; mode=:key)
        return [(string(k), e) for (k, e, _) in TS.tokenize(text; mode) if k != TS.K"EndMarker"]
    end
    # The single classified value token of a value-mode word.
    function word(text)
        ts = TS.tokenize(text; mode=:value)
        @assert length(ts) == 2 "$text lexed as $(length(ts) - 1) tokens"
        k, e, _ = ts[1]
        return e === nothing ? string(k) : e
    end
end

@testitem "tomlsyntax lexer: keys, punctuation and trivia" setup=[TomlTS, TomlLexerTS] begin
    @test toks("a.b = c") == [("TomlBareKey", "a"), (".", "."), ("TomlBareKey", "b"), ("Whitespace", " "),
                              ("=", "="), ("Whitespace", " "), ("TomlBareKey", "c")]
    @test toks("1979-05-27 = 1") == [("TomlBareKey", "1979-05-27"), ("Whitespace", " "), ("=", "="),
                                     ("Whitespace", " "), ("TomlBareKey", "1")]
    @test toks("[[a]] {b}, ]") == [("[", "["), ("[", "["), ("TomlBareKey", "a"), ("]", "]"), ("]", "]"),
                                    ("Whitespace", " "), ("{", "{"), ("TomlBareKey", "b"), ("}", "}"),
                                    (",", ","), ("Whitespace", " "), ("]", "]")]
    @test toks("a\tb  c") == [("TomlBareKey", "a"), ("Whitespace", "\t"), ("TomlBareKey", "b"),
                              ("Whitespace", "  "), ("TomlBareKey", "c")]
    @test toks("a\nb\r\nc") == [("TomlBareKey", "a"), ("NewlineWs", "\n"), ("TomlBareKey", "b"),
                                ("NewlineWs", "\r\n"), ("TomlBareKey", "c")]
    @test tokerrs("a\rb") == [("TomlBareKey", nothing), ("error", TS.ErrUnexpectedCharacter), ("TomlBareKey", nothing)]
    @test toks("# c\n#") == [("Comment", "# c"), ("NewlineWs", "\n"), ("Comment", "#")]
    @test toks("# a\r\nb") == [("Comment", "# a"), ("NewlineWs", "\r\n"), ("TomlBareKey", "b")]
    @test toks("") == []

    # Anything else in key position is one error token per character.
    @test tokerrs("aα") == [("TomlBareKey", nothing), ("error", TS.ErrInvalidBareKeyCharacter)]
    @test toks("aαb") == [("TomlBareKey", "a"), ("error", "α"), ("TomlBareKey", "b")]
    @test tokerrs("+") == [("error", TS.ErrInvalidBareKeyCharacter)]
    @test tokerrs("\$") == [("error", TS.ErrInvalidBareKeyCharacter)]
end

@testitem "tomlsyntax lexer: strings" setup=[TomlTS, TomlLexerTS] begin
    @test toks("\"a\\\"b\" 'c\\d'") == [("TomlBasicString", "\"a\\\"b\""), ("Whitespace", " "), ("TomlLiteralString", "'c\\d'")]
    @test toks("\"\"") == [("TomlBasicString", "\"\"")]
    @test toks("\"\"\"a\nb\"\"\"") == [("TomlMultilineBasicString", "\"\"\"a\nb\"\"\"")]
    @test toks("'''a\nb'''x") == [("TomlMultilineLiteralString", "'''a\nb'''"), ("TomlBareKey", "x")]
    @test toks("\"\"\"\"\"\"") == [("TomlMultilineBasicString", "\"\"\"\"\"\"")]
    # Up to two extra quotes belong to the content; a sixth is left over.
    @test toks("\"\"\"\"str\"\"\"\"") == [("TomlMultilineBasicString", "\"\"\"\"str\"\"\"\"")]
    @test toks("\"\"\" \"\"\"\"\"") == [("TomlMultilineBasicString", "\"\"\" \"\"\"\"\"")]
    @test tokerrs("\"\"\" \"\"\"\"\"\"") == [("TomlMultilineBasicString", nothing), ("error", TS.ErrUnexpectedEndString)]
    @test toks("\"\"\"a\\\"\"\"\"\"\"") == [("TomlMultilineBasicString", "\"\"\"a\\\"\"\"\"\"\"")]
    # Escapes only matter in basic strings.
    @test toks("'a\\'b'") == [("TomlLiteralString", "'a\\'"), ("TomlBareKey", "b"), ("error", "'")]
    # Unterminated.
    @test tokerrs("\"abc") == [("error", TS.ErrUnexpectedEndString)]
    @test tokerrs("\"abc\\\"") == [("error", TS.ErrUnexpectedEndString)]
    @test tokerrs("'''abc") == [("error", TS.ErrUnexpectedEndString)]
    @test toks("\"a\nb\"") == [("error", "\"a"), ("NewlineWs", "\n"), ("TomlBareKey", "b"), ("error", "\"")]
    @test tokerrs("\"a\r\nb") == [("error", TS.ErrNewLineInString), ("NewlineWs", nothing), ("TomlBareKey", nothing)]
    # Strings lex the same in value mode.
    @test toks("\"x\" 'y'"; mode=:value) == [("TomlBasicString", "\"x\""), ("Whitespace", " "), ("TomlLiteralString", "'y'")]
end

@testitem "tomlsyntax lexer: value words" setup=[TomlTS, TomlLexerTS] begin
    @test word("1") == "TomlInteger"
    @test word("+1_000") == "TomlInteger"
    @test word("-17") == "TomlInteger"
    @test word("0") == "TomlInteger"
    @test word("0x1F_ab") == "TomlInteger"
    @test word("0o755") == "TomlInteger"
    @test word("0b1010") == "TomlInteger"
    @test word("1.5") == "TomlFloat"
    @test word("1e5") == "TomlFloat"
    @test word("-2E-2") == "TomlFloat"
    @test word("6.626e-34") == "TomlFloat"
    @test word("0e0") == "TomlFloat"
    @test word("inf") == "TomlFloat"
    @test word("+inf") == "TomlFloat"
    @test word("-nan") == "TomlFloat"
    @test word("true") == "TomlBool"
    @test word("false") == "TomlBool"
    @test word("07:32:00") == "TomlLocalTime"
    @test word("07:32:00.999") == "TomlLocalTime"
    @test word("1979-05-27") == "TomlLocalDate"
    @test word("1979-05-27T07:32:00") == "TomlLocalDateTime"
    @test word("1979-05-27t07:32:00.5") == "TomlLocalDateTime"
    @test word("1979-05-27 07:32:00") == "TomlLocalDateTime"
    @test word("1979-05-27T07:32:00Z") == "TomlOffsetDateTime"
    @test word("1979-05-27T07:32:00z") == "TomlOffsetDateTime"
    @test word("1979-05-27 07:32:00.5-07:00") == "TomlOffsetDateTime"
    @test word("1979-05-27T07:32:00+00:00") == "TomlOffsetDateTime"

    @test word("1_") == TS.ErrTrailingUnderscoreNumber
    @test word("0_") == TS.ErrUnderscoreNotSurroundedByDigits
    @test word("1__2") == TS.ErrUnderscoreNotSurroundedByDigits
    @test word("_1") == TS.ErrUnexpectedStartOfValue
    @test word(".5") == TS.ErrLeadingDot
    @test word("5.") == TS.ErrNoTrailingDigitAfterDot
    @test word("5.e3") == TS.ErrNoTrailingDigitAfterDot
    @test word("5e") == TS.ErrGenericValueError
    @test word("5e+") == TS.ErrGenericValueError
    @test word("01") == TS.ErrLeadingZeroNotAllowedInteger
    @test word("0x") == TS.ErrGenericValueError
    @test word("0xZ") == TS.ErrGenericValueError
    @test word("-0x1") == TS.ErrSignInNonBase10Number
    @test word("1979-05-27T") == TS.ErrParsingDateTime
    @test word("1979-05-27T07") == TS.ErrParsingDateTime
    @test word("1979-05-27T07:32") == TS.ErrParsingDateTime
    @test word("1979-05-27T07:32:00+07") == TS.ErrParsingDateTime
    @test word("1979-05-27T07:32:00Zx") == TS.ErrParsingDateTime
    @test word("1979-5-27") == TS.ErrParsingDateTime
    @test word("-1979-05-27") == TS.ErrParsingDateTime
    @test word("07:32") == TS.ErrParsingDateTime
    @test word("07:32:00.") == TS.ErrParsingDateTime
    @test word("abc") == TS.ErrGenericValueError
    @test word("tru") == TS.ErrGenericValueError
    @test word("+") == TS.ErrGenericValueError

    # Word boundaries.
    @test toks("true2"; mode=:value) == [("TomlBool", "true"), ("TomlInteger", "2")]
    @test toks("1,2]"; mode=:value) == [("TomlInteger", "1"), (",", ","), ("TomlInteger", "2"), ("]", "]")]
    @test toks("1979-05-27 x"; mode=:value) == [("TomlLocalDate", "1979-05-27"), ("Whitespace", " "), ("error", "x")]
    @test toks("1979-05-27 1"; mode=:value) == [("error", "1979-05-27 1")]
    @test toks("1 # c"; mode=:value) == [("TomlInteger", "1"), ("Whitespace", " "), ("Comment", "# c")]
    @test tokerrs("= ."; mode=:value) == [("=", nothing), ("Whitespace", nothing), ("error", TS.ErrLeadingDot)]
    @test tokerrs("@"; mode=:value) == [("error", TS.ErrUnexpectedStartOfValue)]
    @test toks("αβ"; mode=:value) == [("error", "α"), ("error", "β")]
end
