# Tree shapes, byte ranges, trivia and error recovery.

@testitem "tomlsyntax parser: tree shapes" setup=[TomlTS] begin
    @test sexpr("a = 1") == "(toml_document (toml_keyval (toml_key a) 1))"
    @test sexpr("a.b.c = 'x'") == "(toml_document (toml_keyval (toml_key a b c) \"x\"))"
    @test sexpr("\"q k\".'l' = 1.5") == "(toml_document (toml_keyval (toml_key \"q k\" \"l\") 1.5))"
    @test sexpr("a = [1, [2], []]") == "(toml_document (toml_keyval (toml_key a) (toml_array 1 (toml_array 2) (toml_array))))"
    @test sexpr("a = {b = true, c.d = 'x'}") ==
        "(toml_document (toml_keyval (toml_key a) (toml_inline_table (toml_keyval (toml_key b) true) (toml_keyval (toml_key c d) \"x\"))))"
    @test sexpr("a = {}") == "(toml_document (toml_keyval (toml_key a) (toml_inline_table)))"
    @test sexpr("[t]\na = 1\n[[u]]\n[[u]]\nb = 2\n") ==
        "(toml_document (toml_table (toml_key t) (toml_keyval (toml_key a) 1)) (toml_array_table (toml_key u)) (toml_array_table (toml_key u) (toml_keyval (toml_key b) 2)))"
    @test sexpr("[ a . \"b\" ]") == "(toml_document (toml_table (toml_key a \"b\")))"
    @test sexpr("d = 1979-05-27T07:32:00Z") == "(toml_document (toml_keyval (toml_key d) OffsetDateTime(1979-05-27T07:32:00, Z)))"
    @test sexpr("d = 1979-05-27") == "(toml_document (toml_keyval (toml_key d) 1979-05-27))"
    @test sexpr("") == "(toml_document)"
    @test sexpr("# only a comment\n\n") == "(toml_document)"
    # Trivia is invisible to the shape.
    @test sexpr("  a  =  1  # c\n\n") == sexpr("a = 1")
    @test sexpr("a = [ # c\n 1, # d\n 2,\n]") == sexpr("a = [1, 2]")
    @test sexpr("a = 1\r\nb = 2\r\n") == sexpr("a = 1\nb = 2\n")
    @test sexpr("x = 1\n[t]\n\n# c\ny = 2\n\n") == sexpr("x = 1\n[t]\ny = 2")
end

@testitem "tomlsyntax parser: byte ranges" setup=[TomlTS] begin
    JS = TS.JuliaSyntax
    src = "a = 1\n[ t ]\nx.y = [1, 2] # c\n\n[[arr]]\nz = {p = 'q'}\n"
    tree = TS.parsetoml(TomlNode, src)
    text(node) = String(codeunits(src)[JS.byte_range(node)])
    kv, tbl, arr = tree[1], tree[2], tree[3]
    @test text(kv) == "a = 1"
    @test text(kv[1]) == "a"
    @test text(kv[2]) == "1"
    # A section runs from its bracket to its last value: trailing comments
    # and blank lines belong to the document.
    @test text(tbl) == "[ t ]\nx.y = [1, 2]"
    @test text(tbl[1]) == "t"
    @test text(tbl[2]) == "x.y = [1, 2]"
    @test text(tbl[2][1]) == "x.y"
    @test text(tbl[2][1][2]) == "y"
    @test text(tbl[2][2]) == "[1, 2]"
    @test text(tbl[2][2][2]) == "2"
    @test text(arr) == "[[arr]]\nz = {p = 'q'}"
    @test text(arr[1]) == "arr"
    @test text(arr[2][2]) == "{p = 'q'}"
    @test text(arr[2][2][1]) == "p = 'q'"
    @test text(tree) == src
    @test JS.source_location(tbl[2]) == (3, 1)
    @test JS.source_location(arr[2][2][1][2]) == (6, 10)
    @test JS.sourcetext(tbl[2][2]) == "[1, 2]"

    # The lossless green tree keeps every byte, trivia included.
    green = TS.parsetoml(JS.GreenNode, src)
    @test JS.span(green) == ncodeunits(src)
    s = sprint(show, green)
    @test occursin("Comment", s)
    @test occursin("NewlineWs", s)
    @test occursin("Whitespace", s)
    @test occursin("(toml_array", s)
end

@testitem "tomlsyntax parser: headers" setup=[TomlTS] begin
    @test sexpr("[[a]]") == "(toml_document (toml_array_table (toml_key a)))"
    # `[ [a]]` is a table header whose key is missing; `[[a] ]` is not an array header.
    @test all_codes("[ [a]]\n") == [TS.ErrExpectedKey, TS.ErrExpectedEqualAfterKey] || first(all_codes("[ [a]]\n")) == TS.ErrExpectedKey
    @test first(all_codes("[[a] ]\n")) == TS.ErrExpectedEndArrayOfTable
    @test first(all_codes("[a\n")) == TS.ErrExpectedEndOfTable
    @test first(all_codes("[a]]\n")) == TS.ErrExpectedNewLineKeyValue
    @test first(all_codes("[]\n")) == TS.ErrExpectedKey
    @test first(all_codes("[a.]\n")) == TS.ErrExpectedKey
    @test first(all_codes("[.a]\n")) == TS.ErrExpectedKey
    @test first(all_codes("[a] x = 1\n")) == TS.ErrExpectedNewLineKeyValue
    @test all_codes("[a] # c\n") == []
    @test all_codes("[a]\n[b.c]\n[[d]]\n[d.e]\n") == []
    # A malformed header wraps its key in an error node.
    @test sexpr("[t\nx = 1\n") == "(toml_document (toml_table (error (toml_key t)) (toml_keyval (toml_key x) 1)))"
end

@testitem "tomlsyntax parser: key/value errors" setup=[TomlTS] begin
    @test diag_slices("= 1\n") == [(TS.ErrEmptyBareKey, "")]
    @test sexpr("= 1") == "(toml_document (toml_keyval (toml_key (error)) 1))"
    @test diag_slices("a\n") == [(TS.ErrExpectedEqualAfterKey, "")]
    @test diag_slices("a b = 1\n") == [(TS.ErrExpectedEqualAfterKey, "b")]
    @test diag_slices("a = \n") == [(TS.ErrUnexpectedStartOfValue, "")]
    @test diag_slices("a = # c\n") == [(TS.ErrUnexpectedStartOfValue, "")]
    @test diag_slices("a =") == [(TS.ErrUnexpectedEofExpectedValue, "")]
    @test diag_slices("a = ]\n") == [(TS.ErrUnexpectedStartOfValue, "]")]
    @test diag_slices("a = 1 2\n") == [(TS.ErrExpectedNewLineKeyValue, "2")]
    @test diag_slices("a = 1 b = 2\n") == [(TS.ErrExpectedNewLineKeyValue, "b")]
    @test diag_slices("a.\"\"\"m\"\"\" = 1\n") == [(TS.ErrMultilineStringAsKey, "\"\"\"m\"\"\"")]
    @test diag_slices("a. = 1\n") == [(TS.ErrExpectedKey, "")]
    @test diag_slices(".a = 1\n") == [(TS.ErrExpectedKey, ".")]
    @test sexpr(".a = 1") == "(toml_document (toml_keyval (toml_key (error .) a) 1))"
    @test diag_slices("a..b = 1\n") == [(TS.ErrExpectedKey, ""), (TS.ErrExpectedEqualAfterKey, ".")]
    @test diag_slices("aé = 1\n") == [(TS.ErrInvalidBareKeyCharacter, "é")]
    @test sexpr("aé = 1") == "(toml_document (toml_keyval (toml_key a (error)) 1))"
    @test diag_slices("a.bé.c = 1\n") == [(TS.ErrInvalidBareKeyCharacter, "é")]
    @test diag_slices("é = 1\n") == [(TS.ErrInvalidBareKeyCharacter, "é")]
    @test TS.tryparse("aé = 1\n").table == Dict()
    @test diag_slices("]\n") == [(TS.ErrExpectedKey, ""), (TS.ErrExpectedNewLineKeyValue, "]")]
    d = TS.parsetoml_with_diagnostics("aé = 1\n")[2][1]
    @test d.message == "invalid bare key character: 'é'"
    @test diag_slices("a = 1\r\nb = 2\n") == []
    @test diag_slices("a = 1\rb = 2\n") == [(TS.ErrExpectedNewLineKeyValue, "\r")]
end

@testitem "tomlsyntax parser: arrays and inline tables" setup=[TomlTS] begin
    @test diag_slices("a = [1 2]\n") == [(TS.ErrExpectedCommaBetweenItemsArray, "")]
    @test diag_slices("a = [1,, 2]\n") == [(TS.ErrUnexpectedStartOfValue, ",")]
    @test diag_slices("a = [1\n") == [(TS.ErrExpectedCommaBetweenItemsArray, "")]
    @test diag_slices("a = [1,\n") == [(TS.ErrUnexpectedEofExpectedValue, "")]
    @test all_codes("a = [1, 2,]\n") == []
    @test all_codes("a = [\n]\n") == []
    @test all_codes("a = [1\n, 2\n]\n") == []
    # An unclosed array stops at the next `key =` line instead of eating the file.
    src = "a = [1,\nb = 2\n"
    @test diag_slices(src) == [(TS.ErrExpectedEndOfArray, "")]
    @test sexpr(src) == "(toml_document (toml_keyval (toml_key a) (toml_array 1 (error))) (toml_keyval (toml_key b) 2))"
    @test TS.tryparse(src).table == Dict("b" => 2)
    src = "a = [1\n\"b\" = 2\n"
    @test diag_slices(src) == [(TS.ErrExpectedEndOfArray, "")]
    @test TS.tryparse(src).table == Dict("b" => 2)

    @test diag_slices("a = {b = 1 c = 2}\n") == [(TS.ErrExpectedCommaBetweenItemsInlineTable, ""), (TS.ErrExpectedNewLineKeyValue, "c")]
    @test diag_slices("a = {b = 1,}\n") == [(TS.ErrTrailingCommaInlineTable, "")]
    @test diag_slices("a = {b = 1,\nc = 2}\n") == [(TS.ErrExpectedKey, ""), (TS.ErrExpectedNewLineKeyValue, "}")]
    @test diag_slices("a = {b = 1\n}\n") == [(TS.ErrExpectedCommaBetweenItemsInlineTable, ""), (TS.ErrExpectedKey, ""), (TS.ErrExpectedNewLineKeyValue, "}")]
    @test diag_slices("a = {,}\n") == [(TS.ErrExpectedKey, ""), (TS.ErrTrailingCommaInlineTable, "")]
    @test diag_slices("a = {b c = 1}\n") == [(TS.ErrExpectedEqualAfterKey, "c"), (TS.ErrExpectedCommaBetweenItemsInlineTable, "")] ||
        first(diag_slices("a = {b c = 1}\n")) == (TS.ErrExpectedEqualAfterKey, "c")
    @test all_codes("a = {b, c = 1}\n")[1] == TS.ErrExpectedEqualAfterKey
    @test TS.tryparse("a = {b, c = 1}\n").table == Dict()
    @test diag_slices("a = [1, ]]\n") == [(TS.ErrExpectedNewLineKeyValue, "]")]
    @test all_codes("a = { b = 1 , c = { d = [1, {e = 2}] } }\n") == []
    @test all_codes("a = {b = 1}\n") == []
    @test all_codes("a = { }\n") == []
end

@testitem "tomlsyntax parser: recovery keeps later items" setup=[TomlTS] begin
    JS = TS.JuliaSyntax
    src = "a = 1 junk\nb = \n[t\nc = 3\n= 4\nd = {x = 1\ne = [1,\nf = 6\n[u]\ng = 7\n"
    tree, diags = TS.parsetoml_with_diagnostics(src)
    @test !isempty(diags)
    @test sexpr(src) == "(toml_document (toml_keyval (toml_key a) 1) (error junk) (toml_keyval (toml_key b) (error)) " *
        "(toml_table (error (toml_key t)) (toml_keyval (toml_key c) 3) (toml_keyval (toml_key (error)) 4) " *
        "(toml_keyval (toml_key d) (toml_inline_table (toml_keyval (toml_key x) 1) (error))) " *
        "(toml_keyval (toml_key e) (toml_array 1 (error))) (toml_keyval (toml_key f) 6)) " *
        "(toml_table (toml_key u) (toml_keyval (toml_key g) 7)))"
    err = TS.tryparse(src)
    @test err.table == Dict("a" => 1, "u" => Dict("g" => 7))
    # One diagnostic per broken line, at the line.
    lines = unique(JS.source_location(err.source, d.first_byte)[1] for d in err.diagnostics)
    @test lines == [1, 2, 3, 5, 6, 7]

    # Recovery on every prefix of a document never throws and never loops.
    full = "# c\ntitle = \"x\"\n[a.b]\nc = [1, {d = 2}, '''m\n''']\n[[e]]\nf = 1979-05-27T07:32:00-07:00\n"
    for i in 0:ncodeunits(full)
        t = TS.parsetoml(TomlNode, String(codeunits(full)[1:i]); ignore_errors=true)
        @test t isa TomlNode
    end
end
