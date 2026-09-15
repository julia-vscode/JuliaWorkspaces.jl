# The semantic pass: the TOML stdlib's test/invalids.jl, one case per code
# with its range, and the table rules Base's parser gets wrong.

@testitem "tomlsyntax table: stdlib invalids" setup=[TomlTS] begin
    err = TS.tryparse("""
    [foo]
    bar = 3

    [foo]
    quiz = 3
    """)
    @test err isa TomlParseError
    @test TS.error_kind(err) == TS.ErrDuplicatedKey

    err = TS.tryparse("""
    [[foo.bar]]

    [foo]
    bar = 2
    """)
    @test err isa TomlParseError
    @test TS.error_kind(err) == TS.ErrKeyAlreadyHasValue

    err = TS.tryparse("""
    [[foo.bar]]

    [foo.bar]
    q = 3
    """)
    @test err isa TomlParseError
    @test TS.error_kind(err) == TS.ErrDuplicatedKey
end

@testitem "tomlsyntax table: one case per code, at the key's range" setup=[TomlTS] begin
    function sem(src)
        e = TS.tryparse(src)
        e isa TomlParseError || return []
        return [(d.code, slice(src, d.first_byte, d.last_byte)) for d in e.diagnostics]
    end
    @test sem("a = 1\na = 2\n") == [(TS.ErrKeyAlreadyHasValue, "a")]
    @test sem("[a]\nx = 1\n[a]\ny = 2\n") == [(TS.ErrDuplicatedKey, "a")]
    @test sem("[a]\n[a]\n") == [(TS.ErrDuplicatedKey, "a")]
    @test sem("[[a]]\n[a]\n") == [(TS.ErrDuplicatedKey, "a")]
    @test sem("a.b = 1\na.b.c = 2\n") == [(TS.ErrKeyAlreadyHasValue, "a.b.c")]
    @test sem("a = {x = 1}\na.y = 2\n") == [(TS.ErrAddKeyToInlineTable, "a.y")]
    @test sem("a = {x = 1}\n[a]\n") == [(TS.ErrAddKeyToInlineTable, "a")]
    @test sem("a = {x = 1}\n[a.b]\n") == [(TS.ErrAddKeyToInlineTable, "a.b")]
    @test sem("a = [1]\n[[a]]\n") == [(TS.ErrAddArrayToStaticArray, "a")]
    @test sem("a = []\n[[a]]\n") == [(TS.ErrAddArrayToStaticArray, "a")]
    @test sem("[a]\n[[a]]\n") == [(TS.ErrArrayTreatedAsDictionary, "a")]
    @test sem("a = 1\n[[a]]\n") == [(TS.ErrArrayTreatedAsDictionary, "a")]
    @test sem("a = 1\n[a.b]\n") == [(TS.ErrKeyAlreadyHasValue, "a.b")]
    @test sem("a = 1\n[a]\n") == [(TS.ErrKeyAlreadyHasValue, "a")]
    @test sem("a.b = 1\na = {c = 2}\n") == [(TS.ErrInlineTableRedefine, "a")]
    @test sem("a = {b = 1, b = 2}\n") == [(TS.ErrKeyAlreadyHasValue, "b")]
    @test sem("a = {b.c = 1, b = {}}\n") == [(TS.ErrInlineTableRedefine, "b")]
    @test sem("a = [1]\na.b = 2\n") == [(TS.ErrKeyAlreadyHasValue, "a.b")]
    @test sem("[[a]]\n[[a]]\n[a.b]\n[a.b]\n") == [(TS.ErrDuplicatedKey, "a.b")]
    # Several errors, all reported, in order.
    @test sem("a = 1\na = 2\nb = 1\nb = 2\n") == [(TS.ErrKeyAlreadyHasValue, "a"), (TS.ErrKeyAlreadyHasValue, "b")]
    # Whole dotted key, including whitespace around the dots.
    @test sem("a = 1\n[ a . b ]\n") == [(TS.ErrKeyAlreadyHasValue, "a . b")]
    # Quoted key parts compare by value.
    @test sem("a = 1\n\"a\" = 2\n") == [(TS.ErrKeyAlreadyHasValue, "\"a\"")]
end

@testitem "tomlsyntax table: rules Base's parser misses" setup=[TomlTS] begin
    # A table created by dotted keys cannot be reopened by a header...
    @test all_codes("[a]\nb.c = 1\n[a.b]\nx = 1\n") == [TS.ErrDuplicatedKey]
    @test all_codes("[fruit]\napple.color = \"red\"\n[fruit.apple.taste]\nsweet = true\n[fruit.apple]\n") == [TS.ErrDuplicatedKey]
    # ...but its sub-tables can be defined.
    @test TS.parse("[a]\nb.c = 1\n[a.b.d]\nx = 1\n") == Dict("a" => Dict("b" => Dict("c" => 1, "d" => Dict("x" => 1))))
    # Dotted keys may not extend a header-defined table from an outer section.
    @test all_codes("[a.b.c]\nz = 9\n[a]\nb.c.t = 1\n") == [TS.ErrDuplicatedKey]
    @test all_codes("[a.b]\nz = 9\n[a]\nb.t = 1\n") == [TS.ErrDuplicatedKey]
    # Overwriting an implicit table with a value is an error, not an overwrite.
    @test all_codes("[a.b]\nx = 1\n[c]\n") == []
    @test all_codes("a.b.c = 1\na.b = 2\n") == [TS.ErrDuplicatedKey]
    # Within one section, dotted keys extend their own tables freely.
    @test TS.parse("[t]\na.b = 1\na.c = 2\na.d.e = 3\n") == Dict("t" => Dict("a" => Dict("b" => 1, "c" => 2, "d" => Dict("e" => 3))))
    # Array-of-table elements get their sub-tables.
    @test TS.parse("[[a]]\nx = 1\n[a.b]\ny = 2\n[[a]]\nx = 3\n[a.b]\ny = 4\n") ==
        Dict("a" => [Dict("x" => 1, "b" => Dict("y" => 2)), Dict("x" => 3, "b" => Dict("y" => 4))])
    # Super-tables may be defined after their sub-tables.
    @test TS.parse("[x.y.z.w]\na = 3\n[x]\nb = 2\n") == Dict("x" => Dict("b" => 2, "y" => Dict("z" => Dict("w" => Dict("a" => 3)))))
end

@testitem "tomlsyntax table: values" setup=[TomlTS] begin
    d = TS.parse("""
    ints = [1, 2]
    mixed = [1.0, 2]
    empty = []
    nested = [[1], [2]]
    strs = ["a", 'b']
    bools = [true]
    floats = [1.5, 2.5]
    hex = [0x1]
    dates = [1979-05-27]
    tables = [{a = 1}, {a = 2}]
    """)
    @test d["ints"] isa Vector{Int64}
    @test d["mixed"] isa Vector{Any}
    @test d["empty"] isa Vector{Any} && isempty(d["empty"])
    @test d["nested"] isa Vector{Any}
    @test d["strs"] isa Vector{String}
    @test d["bools"] isa Vector{Bool}
    @test d["floats"] isa Vector{Float64}
    @test d["hex"] isa Vector{UInt64}
    @test d["dates"] isa Vector{Any}
    @test d["tables"] == [Dict("a" => 1), Dict("a" => 2)]
    @test d["tables"] isa Vector{Any}

    # Inline tables nest and are frozen.
    d = TS.parse("a = {b = {c = 1}, d.e = 2}\n")
    @test d == Dict("a" => Dict("b" => Dict("c" => 1), "d" => Dict("e" => 2)))
    @test all_codes("a = {b = {c = 1}}\na.b.x = 2\n") == [TS.ErrAddKeyToInlineTable]

    # The partial table on error holds every intact item.
    err = TS.tryparse("a = 1\nb = \nc = 3\n[t]\nx = 1\ny = ]\nz = 2\n")
    @test err isa TomlParseError
    @test err.table == Dict("a" => 1, "c" => 3, "t" => Dict("x" => 1, "z" => 2))
    # A broken header detaches its entries rather than misfiling them.
    err = TS.tryparse("[t\nx = 1\n[u]\ny = 2\n")
    @test err.table == Dict("u" => Dict("y" => 2))
    # A broken value skips the item; a duplicate of it is not reported twice.
    err = TS.tryparse("a = \na = 1\n")
    @test [d.code for d in err.diagnostics] == [TS.ErrUnexpectedStartOfValue]
    @test err.table == Dict("a" => 1)
end
