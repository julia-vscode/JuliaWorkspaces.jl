# Port of the TOML stdlib's test/values.jl (Julia 1.12). Deviations from Base
# are marked; everything else is verbatim in spirit.

@testitem "tomlsyntax values: numbers" setup=[TomlTS] begin
    # Deviation: Base reports a multi-digit `00` as ErrParsingDateTime (it
    # tries a local time); a leading zero is reported as such here.
    @test failval("00", TS.ErrLeadingZeroNotAllowedInteger)
    @test failval("-00", TS.ErrLeadingZeroNotAllowedInteger)
    @test failval("+00", TS.ErrLeadingZeroNotAllowedInteger)
    @test failval("00.0", TS.ErrLeadingZeroNotAllowedInteger)
    @test failval("-00.0", TS.ErrLeadingZeroNotAllowedInteger)
    @test failval("+00.0", TS.ErrLeadingZeroNotAllowedInteger)

    @test failval("0.", TS.ErrNoTrailingDigitAfterDot)
    @test failval("0.e", TS.ErrNoTrailingDigitAfterDot)
    @test failval("0.E", TS.ErrNoTrailingDigitAfterDot)
    @test failval("0.0E", TS.ErrGenericValueError)
    @test failval("0.0e", TS.ErrGenericValueError)
    @test failval("0.0e-", TS.ErrGenericValueError)
    @test failval("0.0e+", TS.ErrGenericValueError)
    @test testval("0.0e+00", 0.0)   # Base: @test_broken (it rejects this valid float)

    @test testval("1.0", 1.0)
    @test testval("1.0e0", 1.0)
    @test testval("1.0e+0", 1.0)
    @test testval("1.0e-0", 1.0)
    @test testval("0e-3", 0.0)
    @test testval("1.001e-0", 1.001)
    @test testval("2e10", 2e10)
    @test testval("2e+10", 2e10)
    @test testval("2e-10", 2e-10)
    @test testval("2_0.0", 20.0)
    @test testval("2_0.0_0e0_0", 20.0)
    @test testval("2_0.1_0e1_0", 20.1e10)

    @test testval("1_0", Int64(10))
    @test testval("1_0_0", Int64(100))
    @test testval("1_000", Int64(1000))
    @test testval("+1_000", Int64(1000))
    @test testval("-1_000", Int64(-1000))

    @test testval("0x6E", UInt64(0x6E))
    @test testval("0x8f1e", UInt64(0x8f1e))
    @test testval("0x765f3173", UInt64(0x765f3173))
    @test testval("0xc13b830a807cc7f4", UInt64(0xc13b830a807cc7f4))
    @test testval("0x937efe_0a4241_edb24a04b97bd90ef363", UInt128(0x937efe0a4241edb24a04b97bd90ef363))

    @test testval("0o140", UInt64(0o140))
    @test testval("0o46244", UInt64(0o46244))
    @test testval("0o32542120656", UInt64(0o32542120656))
    @test testval("0o1526535761042630654411", UInt64(0o1526535761042630654411))
    @test testval("0o3467204325743773607311464533371572447656531", UInt128(0o3467204325743773607311464533371572447656531))
    @test testval("0o34672043257437736073114645333715724476565312", BigInt(0o34672043257437736073114645333715724476565312))

    @test testval("0b10001010", UInt64(0b10001010))
    @test testval("0b11111010001100", UInt64(0b11111010001100))
    @test testval("0b11100011110000010101000010101", UInt64(0b11100011110000010101000010101))
    @test testval("0b10000110100111011010001000000111110110000011111101101110011011",
                  UInt64(0b10000110100111011010001000000111110110000011111101101110011011))
    @test testval("0b1101101101101100110001010110111011101000111010101110011000011100110100101111110001010001011001000001000001010010011101100100111",
                  UInt128(0b1101101101101100110001010110111011101000111010101110011000011100110100101111110001010001011001000001000001010010011101100100111))
    @test testval("0b110110110110110011000101011011101110100011101010111001100001110011010010111111000101000101100100000100000101001001110110010011111",
                  BigInt(0b110110110110110011000101011011101110100011101010111001100001110011010010111111000101000101100100000100000101001001110110010011111))

    @test failval("0_", TS.ErrUnderscoreNotSurroundedByDigits)
    @test failval("0__0", TS.ErrUnderscoreNotSurroundedByDigits)
    @test failval("__0", TS.ErrUnexpectedStartOfValue)
    @test failval("1_0_", TS.ErrTrailingUnderscoreNumber)
    @test failval("1_0__0", TS.ErrUnderscoreNotSurroundedByDigits)

    # Additions: integer widths are the smallest type that fits (Base picks by
    # digit count, so `1000000000000000000` is an Int128 there).
    @test testval("9223372036854775807", typemax(Int64))
    @test testval("-9223372036854775808", typemin(Int64))
    @test testval("1000000000000000000", Int64(1000000000000000000))
    @test testval("9223372036854775808", Int128(9223372036854775807) + 1)
    @test testval("-9223372036854775809", Int128(-9223372036854775807) - 2)
    @test testval("170141183460469231731687303715884105727", typemax(Int128))
    @test testval("170141183460469231731687303715884105728", big"170141183460469231731687303715884105728")
    @test testval("0xFFFFFFFFFFFFFFFF", typemax(UInt64))
    @test testval("0x10000000000000000", UInt128(typemax(UInt64)) + 1)
    @test testval("-0", Int64(0))
    @test testval("+0", Int64(0))
    @test testval("0", Int64(0))
    @test testval("+1", Int64(1))
    @test testval("inf", Inf)
    @test testval("+inf", Inf)
    @test testval("-inf", -Inf)
    @test isnan(TS.parse("foo = nan")["foo"])
    @test isnan(TS.parse("foo = +nan")["foo"])
    @test isnan(TS.parse("foo = -nan")["foo"])
    @test testval("6.626e-34", 6.626e-34)
    @test testval("1e6", 1e6)
    @test testval("5e+22", 5e22)
    @test failval("1e", TS.ErrGenericValueError)
    @test failval("1__2", TS.ErrUnderscoreNotSurroundedByDigits)
    @test failval("1.2.3", TS.ErrGenericValueError)
    @test failval("0x", TS.ErrGenericValueError)
    @test failval("0xG1", TS.ErrGenericValueError)
    @test failval("0x_1", TS.ErrUnderscoreNotSurroundedByDigits)
    @test failval("0x1_", TS.ErrTrailingUnderscoreNumber)
    @test failval("+0x1", TS.ErrSignInNonBase10Number)
    @test failval("-0o7", TS.ErrSignInNonBase10Number)
    @test failval("0b2", TS.ErrGenericValueError)
    @test failval("0123", TS.ErrLeadingZeroNotAllowedInteger)
    @test failval("01.5", TS.ErrLeadingZeroNotAllowedInteger)
    @test failval(".5", TS.ErrLeadingDot)
    @test failval("+.5", TS.ErrLeadingDot)
    @test failval("+", TS.ErrGenericValueError)
    @test failval("1 2", TS.ErrExpectedNewLineKeyValue)
    @test failval("infinity", TS.ErrGenericValueError)
    @test failval("1.5e1.5", TS.ErrGenericValueError)
end

@testitem "tomlsyntax values: booleans" setup=[TomlTS] begin
    @test testval("true", true)
    @test testval("false", false)

    @test failval("true2", TS.ErrExpectedNewLineKeyValue)
    @test failval("false2", TS.ErrExpectedNewLineKeyValue)
    @test failval("talse", TS.ErrGenericValueError)
    @test failval("frue", TS.ErrGenericValueError)
    @test failval("t1", TS.ErrGenericValueError)
    @test failval("f1", TS.ErrGenericValueError)
    @test failval("True", TS.ErrGenericValueError)
    @test failval("FALSE", TS.ErrGenericValueError)
end

@testitem "tomlsyntax values: datetime" setup=[TomlTS] begin
    @test testval("2016-09-09T09:09:09", DateTime(2016, 9, 9, 9, 9, 9))
    @test testval("2016-09-09T09:09:09.012", DateTime(2016, 9, 9, 9, 9, 9, 12))
    @test testval("2016-09-09T09:09:09.2", DateTime(2016, 9, 9, 9, 9, 9, 200))
    @test testval("2016-09-09T09:09:09.20", DateTime(2016, 9, 9, 9, 9, 9, 200))
    @test testval("2016-09-09T09:09:09.02", DateTime(2016, 9, 9, 9, 9, 9, 20))
    @test testval("2016-09-09 09:09:09", DateTime(2016, 9, 9, 9, 9, 9))
    @test testval("2016-09-09t09:09:09", DateTime(2016, 9, 9, 9, 9, 9))

    # Deviation: offset date-times are values (Base: ErrOffsetDateNotSupported).
    @test testval("2016-09-09T09:09:09Z", OffsetDateTime(DateTime(2016, 9, 9, 9, 9, 9), 0))
    @test testval("2016-09-09T09:09:09.0Z", OffsetDateTime(DateTime(2016, 9, 9, 9, 9, 9), 0))
    @test testval("2016-09-09T09:09:09z", OffsetDateTime(DateTime(2016, 9, 9, 9, 9, 9), 0))
    @test testval("2016-09-09T09:09:09.0+10:00", OffsetDateTime(DateTime(2016, 9, 9, 9, 9, 9), 600))
    @test testval("2016-09-09T09:09:09.012-02:00", OffsetDateTime(DateTime(2016, 9, 9, 9, 9, 9, 12), -120))
    @test testval("2016-09-09T09:09:09+00:30", OffsetDateTime(DateTime(2016, 9, 9, 9, 9, 9), 30))
    @test DateTime(OffsetDateTime(DateTime(2016, 9, 9, 9, 9, 9), -120)) == DateTime(2016, 9, 9, 11, 9, 9)
    @test sprint(show, OffsetDateTime(DateTime(2016, 9, 9, 9, 9, 9), -120)) == "OffsetDateTime(2016-09-09T09:09:09, -02:00)"
    @test sprint(show, OffsetDateTime(DateTime(2016, 9, 9, 9, 9, 9), 0)) == "OffsetDateTime(2016-09-09T09:09:09, Z)"

    @test failval("2016-09-09T09:09:09.Z", TS.ErrParsingDateTime)
    @test failval("2016-9-09T09:09:09Z", TS.ErrParsingDateTime)
    @test failval("2016-13-09T09:09:09Z", TS.ErrParsingDateTime)
    @test failval("2016-02-31T09:09:09Z", TS.ErrParsingDateTime)
    @test failval("2016-09-09T09:09:09x", TS.ErrParsingDateTime)
    @test failval("2016-09-09s09:09:09Z", TS.ErrParsingDateTime)
    @test failval("2016-09-09T09:09:09x", TS.ErrParsingDateTime)

    # Additions.
    @test testval("2016-02-29T00:00:00", DateTime(2016, 2, 29))
    @test failval("2015-02-29T00:00:00", TS.ErrParsingDateTime)
    @test failval("2016-09-09T24:00:00", TS.ErrParsingDateTime)
    @test failval("2016-09-09T23:60:00", TS.ErrParsingDateTime)
    @test failval("2016-09-09T23:59:61", TS.ErrParsingDateTime)
    @test failval("2016-09-09T09:09:09+24:00", TS.ErrParsingDateTime)
    @test failval("2016-09-09T09:09:09+23:60", TS.ErrParsingDateTime)
    @test failval("2016-09-09T09:09:09+2:00", TS.ErrParsingDateTime)
    @test failval("2016-09-09T09:09", TS.ErrParsingDateTime)
    @test failval("2016-09-09T09", TS.ErrParsingDateTime)
    @test failval("2016-09-09T", TS.ErrParsingDateTime)
    @test failval("2016-09-09 9:09:09", TS.ErrParsingDateTime)
    @test failval("-2016-09-09", TS.ErrParsingDateTime)
    @test failval("2016-09-09Z", TS.ErrParsingDateTime)
    # A leap second is accepted and clamped (Dates cannot represent it).
    @test testval("1990-12-31T23:59:60Z", OffsetDateTime(DateTime(1990, 12, 31, 23, 59, 59), 0))
    # Fractions beyond milliseconds truncate.
    @test testval("2016-09-09T09:09:09.999999", DateTime(2016, 9, 9, 9, 9, 9, 999))
    @test testval("2016-09-09T09:09:09.9995Z", OffsetDateTime(DateTime(2016, 9, 9, 9, 9, 9, 999), 0))
end

@testitem "tomlsyntax values: date and time" setup=[TomlTS] begin
    @test testval("1979-05-27", Date(1979, 5, 27))
    @test failval("1979-05-32", TS.ErrParsingDateTime)
    @test failval("1979-00-01", TS.ErrParsingDateTime)
    @test failval("1979-05", TS.ErrParsingDateTime)

    @test testval("09:09:09.99", Time(9, 9, 9, 990))
    @test testval("09:09:09.99999", Time(9, 9, 9, 999))
    @test testval("00:00:00.2", Time(0, 0, 0, 200))
    @test testval("00:00:00.20", Time(0, 0, 0, 200))
    @test testval("00:00:00.23", Time(0, 0, 0, 230))
    @test testval("00:00:00.234", Time(0, 0, 0, 234))
    @test testval("07:32:00", Time(7, 32, 0))

    @test failval("09:09x09", TS.ErrParsingDateTime)
    @test failval("24:00:00", TS.ErrParsingDateTime)
    @test failval("09:09:09.", TS.ErrParsingDateTime)
    @test failval("09:09", TS.ErrParsingDateTime)
    @test failval("9:09:09", TS.ErrGenericValueError)
    @test failval("09:09:09Z", TS.ErrParsingDateTime)
end

@testitem "tomlsyntax values: strings" setup=[TomlTS] begin
    @test failval("\"foooo", TS.ErrUnexpectedEndString)
    @test failval("'foooo", TS.ErrUnexpectedEndString)
    @test failval("\"\"\"foooo", TS.ErrUnexpectedEndString)
    @test failval("\"foo\nbar\"", TS.ErrNewLineInString)
    @test failval("'foo\nbar'", TS.ErrNewLineInString)

    @test testval("\"\"", "")
    @test testval("''", "")
    @test testval("\"a\\tb\\n\\\"\\\\\"", "a\tb\n\"\\")
    @test testval("\"\\u00E9\\U0001F600\"", "é😀")
    @test testval("'C:\\\\Users'", "C:\\\\Users")
    @test testval("\"\"\"\nline1\nline2\"\"\"", "line1\nline2")
    @test testval("\"\"\"\r\nline1\r\nline2\"\"\"", "line1\r\nline2")
    @test testval("'''\nraw\\n'''", "raw\\n")
    @test testval("\"\"\"a \\\n   b\"\"\"", "a b")
    @test testval("\"\"\"a\\\n\n\n   b\"\"\"", "ab")

    # The multi-line quote cases Base leaves commented out.
    @test testval("\"\"\" \"\"\"", " ")
    @test testval("\"\"\" \"\"\"\"", " \"")
    @test testval("\"\"\" \"\"\"\"\"", " \"\"")
    @test TS.tryparse("foo = \"\"\" \"\"\"\"\"\"") isa TomlParseError
    @test testval("''' '''", " ")
    @test testval("''' ''''", " '")
    @test testval("''' '''''", " ''")
    @test TS.tryparse("foo = ''' ''''''") isa TomlParseError
    @test testval("\"\"\"\"\"\"", "")
    @test testval("\"\"\"\" \"\"\"", "\" ")
    @test testval("\"\"\"\"\" \"\"\"", "\"\" ")
    @test TS.tryparse("foo = \"\"\"\"\"\" \"\"\"") isa TomlParseError
    @test testval("''''''", "")
    @test testval("'''' '''", "' ")
    @test testval("''''' '''", "'' ")
    @test TS.tryparse("foo = '''''' '''") isa TomlParseError
    # quot8/quot9: five at the start, an escaped quote, then the two content
    # quotes and the delimiter.
    @test testval("\"\"\"\"\"\\\"\"\"\"\"\"", "\"\"\"\"\"")
    @test testval("\"\"\"\"\"\\\"\"\"\\\"\"\"\"\"\"", "\"\"\"\"\"\"\"\"")
    @test testval("\"\"\"\"\"\\\"\"\"\"\"", "\"\"\"\"")
    @test testval("\"\"\"lol\\\"\"\"\"\"\"", "lol\"\"\"")
end

@testitem "tomlsyntax values: arrays" setup=[TomlTS] begin
    @test testval("[1,2,3]", Int64[1, 2, 3])
    @test testval("[1.0, 2.0, 3.0]", Float64[1.0, 2.0, 3.0])
    @test testval("[1.0, 2.0, 3]", Any[1.0, 2.0, Int64(3)])
    @test testval("[1.0, 2, \"foo\"]", Any[1.0, Int64(2), "foo"])
    @test testval("[]", Any[])
    @test testval("[ ]", Any[])
    @test testval("[\"a\", 'b']", String["a", "b"])
    @test testval("[true, false]", Bool[true, false])
    @test testval("[0x1, 0x2]", UInt64[1, 2])
    @test testval("[[1], [2, 3]]", Any[Int64[1], Int64[2, 3]])
    @test testval("[1979-05-27]", Any[Date(1979, 5, 27)])
    @test testval("[\n  1, # one\n  2,\n]", Int64[1, 2])
    @test testval("[1,\n2]", Int64[1, 2])

    @test failval("[1 2]", TS.ErrExpectedCommaBetweenItemsArray)
    @test failval("[1,,2]", TS.ErrUnexpectedStartOfValue)
    @test failval("[1,", TS.ErrUnexpectedEofExpectedValue)
    @test failval("[1", TS.ErrExpectedCommaBetweenItemsArray)
    @test failval("[", TS.ErrUnexpectedEofExpectedValue)
    @test failval("[1]]", TS.ErrExpectedNewLineKeyValue)
end
