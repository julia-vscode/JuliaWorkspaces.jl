# The validate pass: token content that the lexer accepts by shape but the
# spec rejects. Each rule gives a code at an exact range and turns the token
# into an error node.

@testitem "tomlsyntax validate: escapes" setup=[TomlTS] begin
    @test diag_slices("a = \"\\q\"\n") == [(TS.ErrInvalidEscapeCharacter, "\\q")]
    @test diag_slices("a = \"\\é\"\n") == [(TS.ErrInvalidEscapeCharacter, "\\é")]
    @test diag_slices("a = \"\\x41\"\n") == [(TS.ErrInvalidEscapeCharacter, "\\x")]   # TOML 1.1 only
    @test diag_slices("a = \"\\e\"\n") == [(TS.ErrInvalidEscapeCharacter, "\\e")]     # TOML 1.1 only
    @test diag_slices("a = \"\\u12\"\n") == [(TS.ErrInvalidUnicodeScalar, "\\u12")]
    @test diag_slices("a = \"\\uD800\"\n") == [(TS.ErrInvalidUnicodeScalar, "\\uD800")]
    @test diag_slices("a = \"\\U00110000\"\n") == [(TS.ErrInvalidUnicodeScalar, "\\U00110000")]
    @test diag_slices("a = \"\\U1F600\"\n") == [(TS.ErrInvalidUnicodeScalar, "\\U1F600")]
    @test diag_slices("a = \"\\uZZZZ\"\n") == [(TS.ErrInvalidUnicodeScalar, "\\uZZZZ")]
    @test all_codes("a = \"\\u0041\\U0001F600\\b\\t\\n\\f\\r\\\"\\\\\"\n") == []
    @test TS.parse("a = \"\\u0041\\U0001F600\"")["a"] == "A😀"
    # Several bad escapes in one string are all reported.
    @test diag_slices("a = \"\\q\\w\"\n") == [(TS.ErrInvalidEscapeCharacter, "\\q"), (TS.ErrInvalidEscapeCharacter, "\\w")]
    # Multi-line: a line-ending backslash may be followed by whitespace only.
    @test all_codes("a = \"\"\"x \\\n   y\"\"\"\n") == []
    @test all_codes("a = \"\"\"x \\   \r\n   y\"\"\"\n") == []
    @test diag_slices("a = \"\"\"x \\  y\"\"\"\n") == [(TS.ErrInvalidEscapeCharacter, "\\ ")]
    @test diag_slices("a = \"\"\"x \\\"\"\"\n") == [(TS.ErrUnexpectedEndString, "\"\"\"x \\\"\"\"\n")]
    # Literal strings have no escapes at all.
    @test all_codes("a = 'C:\\q\\u12'\n") == []
    # A rejected token is an error node in the tree.
    @test sexpr("a = \"\\q\"") == "(toml_document (toml_keyval (toml_key a) (error)))"
end

@testitem "tomlsyntax validate: control characters and UTF-8" setup=[TomlTS] begin
    @test diag_slices("a = \"x\u0001y\"\n") == [(TS.ErrControlCharacterInString, "\u0001")]
    @test diag_slices("a = \"x\u007fy\"\n") == [(TS.ErrControlCharacterInString, "\u007f")]
    @test diag_slices("a = 'x\u0000y'\n") == [(TS.ErrControlCharacterInString, "\u0000")]
    @test diag_slices("a = \"\"\"x\u001fy\"\"\"\n") == [(TS.ErrControlCharacterInString, "\u001f")]
    @test diag_slices("a = '''x\u001fy'''\n") == [(TS.ErrControlCharacterInString, "\u001f")]
    @test all_codes("a = \"x\ty\"\n") == []
    @test all_codes("a = 'x\ty'\n") == []
    @test all_codes("a = \"\"\"x\ny\r\nz\"\"\"\n") == []
    @test all_codes("a = '''x\ny\r\nz'''\n") == []
    # A bare carriage return is a control character, not a newline.
    @test diag_slices("a = \"\"\"x\ry\"\"\"\n") == [(TS.ErrControlCharacterInString, "\r")]
    @test diag_slices("a = '''x\ry'''\n") == [(TS.ErrControlCharacterInString, "\r")]
    @test diag_slices("a = \"x\ry\"\n") == [(TS.ErrControlCharacterInString, "\r")]
    # Comments too.
    @test diag_slices("# a\u0001b\n") == [(TS.ErrControlCharacterInComment, "\u0001")]
    @test diag_slices("# a\u007f\n") == [(TS.ErrControlCharacterInComment, "\u007f")]
    @test diag_slices("# a\rb\n") == [(TS.ErrControlCharacterInComment, "\r")]
    @test all_codes("# tab\tis fine\n") == []
    @test all_codes("# unicode ✓ is fine\n") == []
    # Invalid UTF-8, in strings and comments.
    @test diag_slices("a = \"\xff\"\n") == [(TS.ErrInvalidUTF8, "\xff")]
    @test diag_slices("a = '\xc3(x'\n") == [(TS.ErrInvalidUTF8, "\xc3")]
    @test diag_slices("# \xed\xa0\x80\n") == [(TS.ErrInvalidUTF8, "\xed\xa0\x80")]
    @test diag_slices("a = \"\xf4\x90\x80\x80\"\n") == [(TS.ErrInvalidUTF8, "\xf4\x90\x80\x80")]
    @test diag_slices("a = \"\xff\xfe\"\n") == [(TS.ErrInvalidUTF8, "\xff"), (TS.ErrInvalidUTF8, "\xfe")]
    @test all_codes("a = \"é😀\"\n# ✓\n") == []
    @test all_codes("a = \"\xf4\x8f\xbf\xbf\"\n") == []
end

@testitem "tomlsyntax validate: date and time ranges" setup=[TomlTS] begin
    @test diag_slices("a = 2016-13-09\n") == [(TS.ErrParsingDateTime, "2016-13-09")]
    @test diag_slices("a = 2016-02-30T00:00:00\n") == [(TS.ErrParsingDateTime, "2016-02-30T00:00:00")]
    @test diag_slices("a = 25:00:00\n") == [(TS.ErrParsingDateTime, "25:00:00")]
    @test diag_slices("a = 2016-09-09T09:09:09+25:00\n") == [(TS.ErrParsingDateTime, "2016-09-09T09:09:09+25:00")]
    @test all_codes("a = 2016-12-31T23:59:60Z\n") == []
    @test all_codes("a = 0000-01-01\n") == []
    @test sexpr("a = 2016-13-09") == "(toml_document (toml_keyval (toml_key a) (error)))"
end
