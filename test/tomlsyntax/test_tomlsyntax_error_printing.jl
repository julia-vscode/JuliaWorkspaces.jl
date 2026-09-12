# The TOML stdlib's test/error_printing.jl, rewritten for TomlSyntax's
# rendering: `# Error @ file:line:col`, the highlighted source and the
# message. Positions are token ranges, so columns differ from Base's
# "after the character just eaten" convention.

@testitem "tomlsyntax error printing" setup=[TomlTS] begin
    tmp = tempname()

    write(tmp, "fooα = 3")
    p = TS.tryparsefile(tmp)
    err = sprint(showerror, p)
    @test contains(err, "$tmp:1:4")
    @test contains(err, "invalid bare key character: 'α'")
    @test contains(err, "fooα = 3")

    # Error at EOF: a zero-width diagnostic just past the input.
    write(tmp, "foo = [1, 2,")
    p = TS.tryparsefile(tmp)
    err = sprint(showerror, p)
    @test contains(err, "$tmp:1:13")
    @test contains(err, "unexpected end of file, expected a value")

    # Columns count characters, not bytes.
    write(tmp, "\"fαβ\" = [1.2, 1.2.3]")
    p = TS.tryparsefile(tmp)
    err = sprint(showerror, p)
    @test contains(err, "$tmp:1:15")
    @test contains(err, "failed to parse value")

    # Every error is rendered, in order, with its own location.
    write(tmp, "a = 1\nb = \n[t\n")
    err = sprint(showerror, TS.tryparsefile(tmp))
    @test contains(err, "$tmp:2:5")
    @test contains(err, "$tmp:3:3")
    @test findfirst("2:5", err) < findfirst("3:3", err)
    rm(tmp)

    # In-memory sources render with a line number only.
    err = sprint(showerror, TS.tryparse("a = ?"))
    @test contains(err, "line 1:5")
end
