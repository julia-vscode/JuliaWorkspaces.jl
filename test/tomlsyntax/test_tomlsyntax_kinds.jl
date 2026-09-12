@testitem "tomlsyntax kinds: registration and predicates" setup=[TomlTS] begin
    JS = TS.JuliaSyntax
    @test parentmodule(TS.K"toml_document") === TS
    @test parentmodule(TS.K"TomlBareKey") === TS
    # Structural kinds and punctuation are JuliaSyntax's own.
    @test parentmodule(TS.K"error") === JS
    @test parentmodule(TS.K"[") === JS
    @test string(TS.K"toml_keyval") == "toml_keyval"

    @test TS.is_toml_string(TS.K"TomlBasicString")
    @test TS.is_toml_string(TS.K"TomlMultilineLiteralString")
    @test !TS.is_toml_string(TS.K"TomlBareKey")
    @test TS.is_toml_datetime(TS.K"TomlLocalTime")
    @test !TS.is_toml_datetime(TS.K"TomlFloat")
    for k in (TS.K"TomlBasicString", TS.K"TomlInteger", TS.K"TomlFloat", TS.K"TomlBool", TS.K"TomlOffsetDateTime")
        @test TS.is_toml_value_token(k)
    end
    @test !TS.is_toml_value_token(TS.K"TomlBareKey")
    @test !TS.is_toml_value_token(TS.K"toml_array")
    @test TS.is_toml_trivia(TS.K"NewlineWs")
    @test !TS.is_toml_trivia(TS.K"=")
    @test TS.is_toml_nonterminal(TS.K"toml_inline_table")
    @test !TS.is_toml_nonterminal(TS.K"TomlInteger")

    # Re-registering the same list is a no-op, as the standalone package's
    # `__init__` relies on.
    @test TS._register_toml_kinds() === nothing
    @test JS.is_error(TS.K"error")
end
