# Port of the TOML stdlib's test/parse.jl plus the tree-level entry points.
# The explicit `Parser` object variants are dropped: TomlSyntax has no
# reusable parser object.

@testitem "tomlsyntax api: (try)parse(file) entry points" setup=[TomlTS] begin
    dict = Dict{String,Any}("a" => 1)
    str = "a = 1"
    invalid_str = "a"
    path, io = mktemp(); write(io, str); close(io)
    invalid_path, io = mktemp(); write(io, invalid_str); close(io)

    @test TS.parse(str) == TS.parse(SubString(str)) == TS.parse(IOBuffer(str)) == dict
    @test TS.parse("a\t=1") == dict
    @test_throws TomlParseError TS.parse(invalid_str)
    @test_throws TomlParseError TS.parse(SubString(invalid_str))
    @test_throws TomlParseError TS.parse(IOBuffer(invalid_str))

    @test TS.tryparse(str) == TS.tryparse(SubString(str)) == TS.tryparse(IOBuffer(str)) == dict
    @test TS.tryparse(invalid_str) isa TomlParseError
    @test TS.tryparse(SubString(invalid_str)) isa TomlParseError
    @test TS.tryparse(IOBuffer(invalid_str)) isa TomlParseError

    @test TS.parsefile(path) == TS.parsefile(SubString(path)) == dict
    @test_throws TomlParseError TS.parsefile(invalid_path)
    @test_throws TomlParseError TS.parsefile(SubString(invalid_path))
    @test_throws ErrorException TS.parsefile(homedir())

    @test TS.tryparsefile(path) == TS.tryparsefile(SubString(path)) == dict
    @test TS.tryparsefile(invalid_path) isa TomlParseError
    @test TS.tryparsefile(SubString(invalid_path)) isa TomlParseError
    @test_throws ErrorException TS.tryparsefile(homedir())

    # The file name travels into the diagnostics.
    err = TS.tryparsefile(invalid_path)
    @test TS.JuliaSyntax.filename(err.source) == invalid_path

    @inferred TS.parse("foo = 3")
    @test isempty(Docs.undocumented_names(TS))
end

@testitem "tomlsyntax api: tree entry points" setup=[TomlTS] begin
    JS = TS.JuliaSyntax
    tree = TS.parsetoml(TomlNode, "a = 1\n")
    @test tree isa TomlNode
    @test JS.kind(tree) == TS.K"toml_document"
    @test JS.numchildren(tree) == 1
    kv = tree[1]
    @test JS.kind(kv) == TS.K"toml_keyval"
    @test kv[1][1].val == "a"
    @test kv[2].val === Int64(1)
    @test kv.parent === tree
    @test JS.sourcefile(tree) isa JS.SourceFile

    green = TS.parsetoml(JS.GreenNode, "a = 1\n")
    @test green isa JS.GreenNode
    @test JS.kind(green) == TS.K"toml_document"

    @test_throws TomlParseError TS.parsetoml(TomlNode, "a = \n")
    recovered = TS.parsetoml(TomlNode, "a = \nb = 2\n"; ignore_errors=true)
    @test JS.numchildren(recovered) == 2
    @test JS.is_error(recovered[1][2])
    @test recovered[2][2].val === Int64(2)

    tree, diags = TS.parsetoml_with_diagnostics("a = \nb = 2\n")
    @test length(diags) == 1
    @test diags[1].code == TS.ErrUnexpectedStartOfValue
    @test JS.numchildren(tree) == 2

    # Semantic errors are not syntax errors: the tree builds, the table complains.
    tree = TS.parsetoml(TomlNode, "a = 1\na = 2\n")
    table, sem = TS.build_table(tree)
    @test table == Dict("a" => 1)
    @test [d.code for d in sem] == [TS.ErrKeyAlreadyHasValue]

    # Printing.
    @test sprint(show, tree) == "(toml_document (toml_keyval (toml_key a) 1) (toml_keyval (toml_key a) 2))"
    @test occursin("toml_document", sprint(show, MIME"text/plain"(), tree))
    @test occursin("toml_keyval", sprint(show, MIME"text/plain"(), green))

    # Error object.
    err = TS.tryparse("a = 1\nb = \n")
    @test err isa TomlParseError
    @test err.table == Dict("a" => 1)
    @test TS.error_kind(err) == TS.ErrUnexpectedStartOfValue
    msg = sprint(showerror, err)
    @test occursin("TomlParseError", msg)
    @test occursin("unexpected start of value", msg)
    @test occursin("2:", msg)
end

@testitem "tomlsyntax api: versions and BOM" setup=[TomlTS] begin
    bom = "﻿"
    @test TS.parse(bom * "a = 1\n") == Dict("a" => 1)
    tree = TS.parsetoml(TomlNode, bom * "a = 1\n")
    r = TS.JuliaSyntax.byte_range(tree[1])
    @test first(r) == 4   # the BOM's three bytes precede the first item
    @test TS.parse(bom) == Dict()
    @test TS.parse("a = 1"; version=v"1.0.0") == Dict("a" => 1)
end
