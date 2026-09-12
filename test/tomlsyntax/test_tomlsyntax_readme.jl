# Port of the TOML stdlib's test/readme.jl (Julia 1.12): the examples of the
# TOML README, one test item per section. `roundtrip` prints with the stdlib
# `TOML.print` and reparses with TomlSyntax; offset date-times are printed
# as their wall-clock `DateTime` since the stdlib has no such type.
# Deviations from Base are marked.

@testsnippet TomlReadmeTS begin
    import TOML

    _local(x::OffsetDateTime) = x.datetime
    _local(x::AbstractDict) = Dict{String,Any}(k => _local(v) for (k, v) in x)
    _local(x::AbstractVector) = Any[_local(v) for v in x]
    _local(x) = x

    # The stdlib prints every date-time with a trailing `Z`, so the reparsed
    # side is normalised too.
    function roundtrip(data)
        parsed = TS.parse(data)
        printed = sprint(io -> TOML.print(_local, io, parsed))
        reparsed = TS.parse(printed)
        return isequal(_local(parsed), _local(reparsed))
    end

    err_kind(str) = (e = TS.tryparse(str); e isa TomlParseError ? TS.error_kind(e) : nothing)
end

@testitem "tomlsyntax readme: Example" setup=[TomlTS, TomlReadmeTS] begin
    str = """
    # This is a TOML document.

    title = "TOML Example"

    [owner]
    name = "Tom Preston-Werner"

    [database]
    server = "192.168.1.1"
    ports = [ 8001, 8001, 8002 ]
    connection_max = 5000
    enabled = true

    [servers]

      # Indentation (tabs and/or spaces) is allowed but not required
      [servers.alpha]
      ip = "10.0.0.1"
      dc = "eqdc10"

      [servers.beta]
      ip = "10.0.0.2"
      dc = "eqdc10"

    [clients]
    data = [ ["gamma", "delta"], [1, 2] ]

    # Line breaks are OK when inside arrays
    hosts = [
      "alpha",
      "omega"
    ]
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["title"] == "TOML Example"
    @test d["owner"]["name"] == "Tom Preston-Werner"
    @test d["database"] == Dict(
        "server" => "192.168.1.1",
        "ports" => [8001, 8001, 8002],
        "connection_max" => 5000,
        "enabled" => true,
    )
    @test d["servers"] == Dict(
        "alpha" => Dict("ip" => "10.0.0.1", "dc" => "eqdc10"),
        "beta" => Dict("ip" => "10.0.0.2", "dc" => "eqdc10"),
    )
    @test d["clients"]["data"] == [["gamma", "delta"], [1, 2]]
    @test d["clients"]["hosts"] == ["alpha", "omega"]
end

@testitem "tomlsyntax readme: Comment" setup=[TomlTS, TomlReadmeTS] begin
    str = """
    # This is a full-line comment
    key = "value"  # This is a comment at the end of a line
    another = "# This is not a comment"
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict("key" => "value", "another" => "# This is not a comment")
end

@testitem "tomlsyntax readme: Key/Value Pair" setup=[TomlTS, TomlReadmeTS] begin
    @test err_kind("key = # INVALID\n") == TS.ErrUnexpectedStartOfValue
    @test err_kind("first = \"Tom\" last = \"Preston-Werner\" # INVALID\n") == TS.ErrExpectedNewLineKeyValue
end

@testitem "tomlsyntax readme: Keys" setup=[TomlTS, TomlReadmeTS] begin
    str = """
    key = "value"
    bare_key = "value"
    bare-key = "value"
    1234 = "value"
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict("key" => "value", "bare_key" => "value", "bare-key" => "value", "1234" => "value")

    str = """
    "127.0.0.1" = "value"
    "character encoding" = "value"
    "ʎǝʞ" = "value"
    'key2' = "value"
    'quoted "value"' = "value"
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict(
        "127.0.0.1" => "value",
        "character encoding" => "value",
        "ʎǝʞ" => "value",
        "key2" => "value",
        "quoted \"value\"" => "value",
    )

    @test err_kind("= \"no key name\"  # INVALID\n") == TS.ErrEmptyBareKey
    @test TS.parse("\"\" = \"blank\"     # VALID but discouraged\n") == Dict("" => "blank")
    str = "'' = 'blank'     # VALID but discouraged\n"
    @test roundtrip(str)
    @test TS.parse(str) == Dict("" => "blank")

    str = """
    name = "Orange"
    physical.color = "orange"
    physical.shape = "round"
    site."google.com" = true
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict(
        "name" => "Orange",
        "physical" => Dict("color" => "orange", "shape" => "round"),
        "site" => Dict("google.com" => true),
    )

    @test err_kind("# DO NOT DO THIS\nname = \"Tom\"\nname = \"Pradyun\"\n") == TS.ErrKeyAlreadyHasValue
    @test err_kind("# THIS WILL NOT WORK\nspelling = \"favorite\"\n\"spelling\" = \"favourite\"\n") == TS.ErrKeyAlreadyHasValue

    str = "3.14159 = \"pi\"\n"
    @test roundtrip(str)
    @test TS.parse(str) == Dict("3" => Dict("14159" => "pi"))

    str = """
    # This makes the key "fruit" into a table.
    fruit.apple.smooth = true

    # So then you can add to the table "fruit" like so:
    fruit.orange = 2
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict("fruit" => Dict("orange" => 2, "apple" => Dict("smooth" => true)))

    str = """
    # THE FOLLOWING IS INVALID

    # This defines the value of fruit.apple to be an integer.
    fruit.apple = 1

    # But then this treats fruit.apple like it's a table.
    # You can't turn an integer into a table.
    fruit.apple.smooth = true
    """
    @test err_kind(str) == TS.ErrKeyAlreadyHasValue

    str = """
    # VALID BUT DISCOURAGED

    apple.type = "fruit"
    orange.type = "fruit"

    apple.skin = "thin"
    orange.skin = "thick"

    apple.color = "red"
    orange.color = "orange"
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict(
        "apple" => Dict("type" => "fruit", "skin" => "thin", "color" => "red"),
        "orange" => Dict("type" => "fruit", "skin" => "thick", "color" => "orange"),
    )

    str = """
    # RECOMMENDED

    apple.type = "fruit"
    apple.skin = "thin"
    apple.color = "red"

    orange.type = "fruit"
    orange.skin = "thick"
    orange.color = "orange"
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict(
        "apple" => Dict("type" => "fruit", "skin" => "thin", "color" => "red"),
        "orange" => Dict("type" => "fruit", "skin" => "thick", "color" => "orange"),
    )
end

@testitem "tomlsyntax readme: String" setup=[TomlTS, TomlReadmeTS] begin
    str = """str = "I'm a string. \\"You can quote me\\". Name\\tJos\\u00E9\\nLocation\\tSF." """
    @test roundtrip(str)
    @test TS.parse(str) == Dict("str" => "I'm a string. \"You can quote me\". Name\tJos\u00E9\nLocation\tSF.")

    str = """str1 = \"\"\"
    Roses are red
    Violets are blue
    \"\"\"
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict("str1" => "Roses are red\nViolets are blue\n")

    str = """
    # The following strings are byte-for-byte equivalent:
    str1 = "The quick brown fox jumps over the lazy dog."

    str2 = \"\"\"
    The quick brown \\


      fox jumps over \\
        the lazy dog.\"\"\"

    str3 = \"\"\"\\
           The quick brown \\
           fox jumps over \\
           the lazy dog.\\
           \"\"\"
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["str1"] == d["str2"] == d["str3"]

    str = """
    str4 = \"\"\"Here are two quotation marks: \"\". Simple enough.\"\"\"
    str5 = \"\"\"Here are three quotation marks: \"\"\\\".\"\"\"
    str6 = \"\"\"Here are fifteen quotation marks: \"\"\\\"\"\"\\\"\"\"\\\"\"\"\\\"\"\"\\\".\"\"\"
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["str4"] == "Here are two quotation marks: \"\". Simple enough."
    @test d["str5"] == "Here are three quotation marks: \"\"\"."
    @test d["str6"] == "Here are fifteen quotation marks: \"\"\"\"\"\"\"\"\"\"\"\"\"\"\"."

    # Base: @test_broken (quotes just inside the delimiters).
    str = """
    # "This," she said, "is just a pointless statement."
    str7 = \"\"\"\"This,\" she said, \"is just a pointless statement.\"\"\"\"
    """
    @test roundtrip(str)
    @test TS.parse(str)["str7"] == "\"This,\" she said, \"is just a pointless statement.\""

    @test err_kind("str5 = \"\"\"Here are three quotation marks: \"\"\".\"\"\"  # INVALID\n") !== nothing

    str = raw"""
    # What you see is what you get.
    winpath  = 'C:\Users\nodejs\templates'
    winpath2 = '\\ServerX\admin$\system32\'
    quoted   = 'Tom "Dubs" Preston-Werner'
    regex    = '<\i\c*\s*>'
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["winpath"] == raw"C:\Users\nodejs\templates"
    @test d["winpath2"] == raw"\\ServerX\admin$\system32\\"
    @test d["quoted"] == raw"""Tom "Dubs" Preston-Werner"""
    @test d["regex"] == raw"<\i\c*\s*>"

    str = raw"""
    regex2 = '''I [dw]on't need \d{2} apples'''
    lines  = '''
    The first newline is
    trimmed in raw strings.
       All other whitespace
       is preserved.
    '''
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["regex2"] == raw"I [dw]on't need \d{2} apples"
    @test d["lines"] == "The first newline is\ntrimmed in raw strings.\n   All other whitespace\n   is preserved.\n"

    # Base: @test_broken.
    str = """
    quot15 = '''Here are fifteen quotation marks: \"\"\"\"\"\"\"\"\"\"\"\"\"\"\"'''

    apos15 = "Here are fifteen apostrophes: '''''''''''''''"

    # 'That,' she said, 'is still pointless.'
    str = ''''That,' she said, 'is still pointless.''''
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["quot15"] == "Here are fifteen quotation marks: \"\"\"\"\"\"\"\"\"\"\"\"\"\"\""
    @test d["apos15"] == "Here are fifteen apostrophes: '''''''''''''''"
    @test d["str"] == "'That,' she said, 'is still pointless.'"

    @test TS.tryparse("apos15 = '''Here are fifteen apostrophes: ''''''''''''''''''  # INVALID\n") isa TomlParseError
end

@testitem "tomlsyntax readme: Integer" setup=[TomlTS, TomlReadmeTS] begin
    str = """
    int1 = +99
    int2 = 42
    int3 = 0
    int4 = -17
    int5 = -0
    int6 = +0
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["int1"] === Int64(99)
    @test d["int2"] === Int64(42)
    @test d["int3"] === Int64(0)
    @test d["int4"] === Int64(-17)
    @test d["int5"] === Int64(0)
    @test d["int6"] === Int64(0)

    str = """
    int5 = 1_000
    int6 = 5_349_221
    int7 = 53_49_221  # Indian number system grouping
    int8 = 1_2_3_4_5  # VALID but discouraged
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["int5"] == 1_000
    @test d["int6"] == 5_349_221
    @test d["int7"] == 53_49_221
    @test d["int8"] == 1_2_3_4_5

    str = """
    # hexadecimal with prefix `0x`
    hex1 = 0xDEADBEEF
    hex2 = 0xdeadbeef
    hex3 = 0xdead_beef

    # octal with prefix `0o`
    oct1 = 0o01234567
    oct2 = 0o755 # useful for Unix file permissions

    # binary with prefix `0b`
    bin1 = 0b11010110
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["hex1"] == 0xDEADBEEF
    @test d["hex2"] == 0xdeadbeef
    @test d["hex3"] == 0xdead_beef
    @test d["oct1"] == 0o01234567
    @test d["oct2"] == 0o755
    @test d["bin1"] == 0b11010110

    str = """
    hex1 = 0x6E # UInt8
    hex2 = 0x8f1e # UInt16
    hex3 = 0x765f3173 # UInt32
    hex4 = 0xc13b830a807cc7f4 # UInt64
    hex5 = 0x937efe0a4241edb24a04b97bd90ef363 # UInt128
    hex6 = 0x937efe0a4241edb24a04b97bd90ef3632 # BigInt
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["hex1"] isa UInt64
    @test d["hex2"] isa UInt64
    @test d["hex3"] isa UInt64
    @test d["hex4"] isa UInt64
    @test d["hex5"] isa UInt128
    @test d["hex6"] isa BigInt

    str = """
    oct1 = 0o140 # UInt8
    oct2 = 0o46244 # UInt16
    oct3 = 0o32542120656 # UInt32
    oct4 = 0o1526535761042630654411 # UInt64
    oct5 = 0o3467204325743773607311464533371572447656531 # UInt128
    oct6 = 0o34672043257437736073114645333715724476565312 # BigInt
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["oct1"] isa UInt64
    @test d["oct2"] isa UInt64
    @test d["oct3"] isa UInt64
    @test d["oct4"] isa UInt64
    @test d["oct5"] isa UInt128
    @test d["oct6"] isa BigInt

    str = """
    bin1 = 0b10001010 # UInt8
    bin2 = 0b11111010001100 # UInt16
    bin3 = 0b11100011110000010101000010101 # UInt32
    bin4 = 0b10000110100111011010001000000111110110000011111101101110011011 # UInt64
    bin5 = 0b1101101101101100110001010110111011101000111010101110011000011100110100101111110001010001011001000001000001010010011101100100111 # UInt128
    bin6 = 0b110110110110110011000101011011101110100011101010111001100001110011010010111111000101000101100100000100000101001001110110010011111 # BigInt
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["bin1"] isa UInt64
    @test d["bin2"] isa UInt64
    @test d["bin3"] isa UInt64
    @test d["bin4"] isa UInt64
    @test d["bin5"] isa UInt128
    @test d["bin6"] isa BigInt

    str = """
    low = -170_141_183_460_469_231_731_687_303_715_884_105_728
    high = 170_141_183_460_469_231_731_687_303_715_884_105_727
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["low"] == typemin(Int128)
    @test d["high"] == typemax(Int128)

    str = """
    low = -170_141_183_460_469_231_731_687_303_715_884_105_728_123
    high = 170_141_183_460_469_231_731_687_303_715_884_105_727_123
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["low"] == big"-170_141_183_460_469_231_731_687_303_715_884_105_728_123"
    @test d["high"] == big"170_141_183_460_469_231_731_687_303_715_884_105_727_123"

    @test TS.parse("toolow = -9_223_372_036_854_775_809\n")["toolow"] == -9223372036854775809
    @test TS.parse("toohigh = 9_223_372_036_854_775_808\n")["toohigh"] == 9_223_372_036_854_775_808
end

@testitem "tomlsyntax readme: Float" setup=[TomlTS, TomlReadmeTS] begin
    str = """
    # fractional
    flt1 = +1.0
    flt2 = 3.1415
    flt3 = -0.01

    # exponent
    flt4 = 5e+22
    flt5 = 1e06
    flt6 = -2E-2

    # both
    flt7 = 6.626e-34
    flt8 = 224_617.445_991_228
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["flt1"] == +1.0
    @test d["flt2"] == 3.1415
    @test d["flt3"] == -0.01
    @test d["flt4"] == 5e+22
    @test d["flt5"] == 1e+6
    @test d["flt6"] == -2E-2
    @test d["flt7"] == 6.626e-34
    @test d["flt8"] == 224_617.445_991_228

    @test err_kind("# INVALID FLOATS\ninvalid_float_1 = .7\n") == TS.ErrLeadingDot
    @test err_kind("# INVALID FLOATS\ninvalid_float_2 = 7.\n") == TS.ErrNoTrailingDigitAfterDot
    @test err_kind("# INVALID FLOATS\ninvalid_float_3 = 3.e+20\n") == TS.ErrNoTrailingDigitAfterDot

    str = """
    # infinity
    sf1 = inf  # positive infinity
    sf2 = +inf # positive infinity
    sf3 = -inf # negative infinity

    # not a number
    sf4 = nan  # actual sNaN/qNaN encoding is implementation-specific
    sf5 = +nan # same as `nan`
    sf6 = -nan # valid, actual encoding is implementation-specific
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["sf1"] == Inf
    @test d["sf2"] == Inf
    @test d["sf3"] == -Inf
    @test isnan(d["sf4"])
    @test isnan(d["sf5"])
    @test isnan(d["sf6"])
end

@testitem "tomlsyntax readme: Boolean and date-times" setup=[TomlTS, TomlReadmeTS] begin
    str = """
    bool1 = true
    bool2 = false
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["bool1"] === true
    @test d["bool2"] === false

    # Offset Date-Time. Deviation: these are values, not errors, and the
    # fraction truncates to milliseconds.
    str = "odt1 = 1979-05-27T07:32:00.99999Z"
    @test roundtrip(str)
    @test TS.parse(str)["odt1"] == OffsetDateTime(DateTime(1979, 5, 27, 7, 32, 0, 999), 0)
    @test TS.parse("odt2 = 1979-05-27T00:32:00-07:00")["odt2"] == OffsetDateTime(DateTime(1979, 5, 27, 0, 32, 0), -420)
    @test TS.parse("odt3 = 1979-05-27T00:32:00.999999-07:00")["odt3"] == OffsetDateTime(DateTime(1979, 5, 27, 0, 32, 0, 999), -420)
    str = "odt4 = 1979-05-27 07:32:00Z"
    @test roundtrip(str)
    @test TS.parse(str)["odt4"] == OffsetDateTime(DateTime(1979, 5, 27, 7, 32, 0), 0)

    # Local Date-Time
    str = """
    ldt1 = 1979-05-27T07:32:00
    ldt2 = 1979-05-27T00:32:00.999999
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["ldt1"] == DateTime(1979, 5, 27, 7, 32, 0)
    @test d["ldt2"] == DateTime(1979, 5, 27, 0, 32, 0, 999)

    # Local Date
    str = "ld1 = 1979-05-27\n"
    @test roundtrip(str)
    @test TS.parse(str)["ld1"] == Date(1979, 5, 27)

    # Local Time
    str = """
    lt1 = 07:32:00
    lt2 = 00:32:00.999999
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["lt1"] == Time(7, 32, 0)
    @test d["lt2"] == Time(0, 32, 0, 999)
end

@testitem "tomlsyntax readme: Array" setup=[TomlTS, TomlReadmeTS] begin
    str = """
    integers = [ 1, 2, 3 ]
    colors = [ "red", "yellow", "green" ]
    nested_array_of_int = [ [ 1, 2 ], [3, 4, 5] ]
    nested_mixed_array = [ [ 1, 2 ], ["a", "b", "c"] ]
    string_array = [ "all", 'strings', \"\"\"are the same\"\"\", '''type''' ]

    # Mixed-type arrays are allowed
    numbers = [ 0.1, 0.2, 0.5, 1, 2, 5 ]
    contributors = [
      "Foo Bar <foo@example.com>",
      { name = "Baz Qux", email = "bazqux@example.com", url = "https://example.com/bazqux" }
    ]
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["integers"] == [1, 2, 3]
    @test d["colors"] == ["red", "yellow", "green"]
    @test d["nested_array_of_int"] == [[1, 2], [3, 4, 5]]
    @test d["nested_mixed_array"] == [[1, 2], ["a", "b", "c"]]
    @test d["string_array"] == ["all", "strings", "are the same", "type"]
    @test all(d["numbers"] .=== Any[0.1, 0.2, 0.5, Int64(1), Int64(2), Int64(5)])
    @test d["contributors"] == [
        "Foo Bar <foo@example.com>",
        Dict("name" => "Baz Qux", "email" => "bazqux@example.com", "url" => "https://example.com/bazqux"),
    ]

    str = """
    integers2 = [
      1, 2, 3
    ]

    integers3 = [
      1,
      2, # this is ok
    ]
    """
    @test roundtrip(str)
    d = TS.parse(str)
    @test d["integers3"] == [1, 2]
    @test d["integers2"] == [1, 2, 3]
end

@testitem "tomlsyntax readme: Table" setup=[TomlTS, TomlReadmeTS] begin
    str = """
    [table]
    key1 = "some string"
    key2 = "some other string"
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict("table" => Dict("key2" => "some other string", "key1" => "some string"))

    str = """
    [dog."tater.man"]
    type.name = "pug"
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict("dog" => Dict("tater.man" => Dict("type" => Dict("name" => "pug"))))

    str = """
    [a.b.c]            # this is best practice
    [ d.e.f ]          # same as [d.e.f]
    [ g .  h  . i ]    # same as [g.h.i]
    [ j . "ʞ" . 'l' ]  # same as [j."ʞ".'l']
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict(
        "a" => Dict("b" => Dict("c" => Dict())),
        "d" => Dict("e" => Dict("f" => Dict())),
        "g" => Dict("h" => Dict("i" => Dict())),
        "j" => Dict("ʞ" => Dict("l" => Dict())),
    )

    str = """
    # [x] you
    # [x.y] don't
    # [x.y.z] need these
    [x.y.z.w] # for this to work

    [x] # defining a super-table afterward is ok
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict("x" => Dict("y" => Dict("z" => Dict("w" => Dict()))))

    str = """
    # [x] you
    # [x.y] don't
    # [x.y.z] need these
    [x.y.z.w] # for this to work
    a = 3

    [x] # defining a super-table afterward is ok
    b = 2
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict("x" => Dict("b" => 2, "y" => Dict("z" => Dict("w" => Dict("a" => 3)))))

    @test err_kind("# DO NOT DO THIS\n\n[fruit]\napple = \"red\"\n\n[fruit]\norange = \"orange\"\n") == TS.ErrDuplicatedKey
    @test err_kind("# DO NOT DO THIS EITHER\n\n[fruit]\napple = \"red\"\n\n[fruit.apple]\ntexture = \"smooth\"\n") == TS.ErrKeyAlreadyHasValue

    str = """
    # VALID BUT DISCOURAGED
    [fruit.apple]
    [animal]
    [fruit.orange]
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict("fruit" => Dict("apple" => Dict(), "orange" => Dict()), "animal" => Dict())

    str = """
    # RECOMMENDED
    [fruit.apple]
    [fruit.orange]
    [animal]
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict("fruit" => Dict("apple" => Dict(), "orange" => Dict()), "animal" => Dict())

    str = """
    [fruit]
    apple.color = "red"
    apple.taste.sweet = true

    # [fruit.apple]  # INVALID
    # [fruit.apple.taste]  # INVALID

    [fruit.apple.texture]  # you can add sub-tables
    smooth = true
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict(
        "fruit" => Dict("apple" => Dict("color" => "red", "taste" => Dict("sweet" => true), "texture" => Dict("smooth" => true))),
    )
    # The commented-out headers really are invalid (Base accepts them).
    @test err_kind("[fruit]\napple.color = \"red\"\n[fruit.apple]\n") == TS.ErrDuplicatedKey
    @test err_kind("[fruit]\napple.taste.sweet = true\n[fruit.apple.taste]\n") == TS.ErrDuplicatedKey
end

@testitem "tomlsyntax readme: Inline table and Array of Tables" setup=[TomlTS, TomlReadmeTS] begin
    str = """
    name = { first = "Tom", last = "Preston-Werner" }
    point = { x = 1, y = 2 }
    animal = { type.name = "pug" }
    """
    str2 = """
    [name]
    first = "Tom"
    last = "Preston-Werner"

    [point]
    x = 1
    y = 2

    [animal]
    type.name = "pug"
    """
    @test roundtrip(str)
    @test roundtrip(str2)
    @test TS.parse(str) == TS.parse(str2)

    @test err_kind("[product]\ntype = { name = \"Nail\" }\ntype.edible = false  # INVALID\n") == TS.ErrAddKeyToInlineTable
    # Base's test re-checks the previous error here; the actual code is this one.
    @test err_kind("[product]\ntype.name = \"Nail\"\ntype = { edible = false }  # INVALID\n") == TS.ErrInlineTableRedefine

    str = """
    [[products]]
    name = "Hammer"
    sku = 738594937

    [[products]]

    [[products]]
    name = "Nail"
    sku = 284758393

    color = "gray"
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict(
        "products" => [
            Dict("name" => "Hammer", "sku" => 738594937),
            Dict(),
            Dict("name" => "Nail", "sku" => 284758393, "color" => "gray"),
        ],
    )

    str = """
    [[fruit]]
      name = "apple"

      [fruit.physical]  # subtable
        color = "red"
        shape = "round"

      [[fruit.variety]]  # nested array of tables
        name = "red delicious"

      [[fruit.variety]]
        name = "granny smith"

    [[fruit]]
      name = "banana"

      [[fruit.variety]]
        name = "plantain"
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict(
        "fruit" => [
            Dict("name" => "apple",
                 "physical" => Dict("color" => "red", "shape" => "round"),
                 "variety" => [Dict("name" => "red delicious"), Dict("name" => "granny smith")]),
            Dict("name" => "banana", "variety" => [Dict("name" => "plantain")]),
        ],
    )

    str = """
    # INVALID TOML DOC
    [fruit.physical]  # subtable, but to which parent element should it belong?
      color = "red"
      shape = "round"

    [[fruit]]  # parser must throw an error upon discovering that "fruit" is
               # an array rather than a table
      name = "apple"
    """
    @test err_kind(str) == TS.ErrArrayTreatedAsDictionary

    @test err_kind("# INVALID TOML DOC\nfruit = []\n\n[[fruit]] # Not allowed\n") == TS.ErrAddArrayToStaticArray

    str = """
    # INVALID TOML DOC
    [[fruit]]
      name = "apple"

      [[fruit.variety]]
        name = "red delicious"

      # INVALID: This table conflicts with the previous array of tables
      [fruit.variety]
        name = "granny smith"
    """
    @test err_kind(str) == TS.ErrDuplicatedKey

    str = """
    # INVALID TOML DOC
    [[fruit]]
      name = "apple"

      [fruit.physical]
        color = "red"
        shape = "round"

      # INVALID: This array of tables conflicts with the previous table
      [[fruit.physical]]
        color = "green"
    """
    @test err_kind(str) == TS.ErrArrayTreatedAsDictionary

    str = """
    points = [ { x = 1, y = 2, z = 3 },
               { x = 7, y = 8, z = 9 },
               { x = 2, y = 4, z = 8 } ]
    """
    @test roundtrip(str)
    @test TS.parse(str) == Dict(
        "points" => [Dict("x" => 1, "y" => 2, "z" => 3), Dict("x" => 7, "y" => 8, "z" => 9), Dict("x" => 2, "y" => 4, "z" => 8)],
    )
end
