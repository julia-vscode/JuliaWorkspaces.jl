# The v2 signature-help arm (`_get_signature_help_v2`): workspace callees
# answered from signature slices, everything else declining to v1.

@testsnippet SigV2WS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_enabled!, get_signature_help
    using JuliaWorkspaces.URIs2: URI

    const SGV_URI = URI("file:///sgv/src/SigV.jl")

    function sgv_workspace(files::Pair{String,String}...; flag=true)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///sgv/Project.toml"),
            SourceText("name = \"SigV\"\nuuid = \"a2345678-1234-1234-1234-123456789abe\"\nversion = \"0.1.0\"\n", "toml")))
        add_file!(jw, TextFile(URI("file:///sgv/Manifest.toml"),
            SourceText("julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc\"\n\n[deps]\n", "toml")))
        for (path, src) in files
            add_file!(jw, TextFile(URI("file:///sgv/src/$path"), SourceText(src, "julia")))
        end
        flag && set_v2_enabled!(jw, true)
        return jw
    end

    # UTF-16 slice, as the LSP client applies parameter label ranges.
    function utf16_slice(s, range)
        units = Char[]
        for c in s
            push!(units, c)
            codepoint(c) >= 0x10000 && push!(units, c)
        end
        return String(units[(range[1] + 1):range[2]])
    end
    param_texts(sig) = [utf16_slice(sig.label, p.label) for p in sig.parameters]

    # 1-based index of the last byte of `needle` (public-API form), and its
    # 0-based twin for the internal `_get_signature_help_v2` (which takes the
    # already-converted offset, exactly like `_get_signature_help`).
    at(src, needle) = findfirst(needle, src).stop
    at0(src, needle) = findfirst(needle, src).stop - 1
end

@testitem "signature help v2: workspace function" setup=[SigV2WS] begin
    src = """
    module SigV
    func(arg, b::Int; kw=1) = 1
    func(x) = 2
    caller() = func(1)
    end
    """
    jw = sgv_workspace("SigV.jl" => src)
    r = JW._get_signature_help_v2(jw.runtime, SGV_URI, at0(src, "caller() = func("))
    @test r !== nothing
    @test length(r.signatures) == 2
    @test r.signatures[1].label == "func(arg, b::Int; kw=1)"
    @test param_texts(r.signatures[1]) == ["arg", "b::Int"]
    @test r.signatures[2].label == "func(x)"
    @test r.active_parameter == 0

    # Byte-level agreement with v1 on labels modulo whitespace.
    jw_off = sgv_workspace("SigV.jl" => src; flag=false)
    v1 = get_signature_help(jw_off, SGV_URI, at(src, "caller() = func("))
    nows(s) = replace(s, r"\s+" => "")
    @test [nows(s.label) for s in v1.signatures] == [nows(s.label) for s in r.signatures]
    @test [s.parameters |> length for s in v1.signatures] ==
        [s.parameters |> length for s in r.signatures]
end

@testitem "signature help v2: active parameter and filtering" setup=[SigV2WS] begin
    src = """
    module SigV
    f(a) = 1
    f(a, b, c) = 2
    caller() = f(1, 2, 3)
    end
    """
    jw = sgv_workspace("SigV.jl" => src)
    # Cursor after the second comma: v1's rule reports the call's comma count.
    r = JW._get_signature_help_v2(jw.runtime, SGV_URI, at0(src, "f(1, 2,"))
    @test r !== nothing
    @test r.active_parameter == 2
    # Only the 3-parameter method still fits.
    @test [s.label for s in r.signatures] == ["f(a, b, c)"]
    # At the opening paren every method is offered.
    r0 = JW._get_signature_help_v2(jw.runtime, SGV_URI, at0(src, "caller() = f("))
    @test r0 !== nothing && length(r0.signatures) == 2 && r0.active_parameter == 0
    # Nested commas don't count.
    src2 = """
    module SigV
    g(a, b) = 1
    h(x) = g(h([1, 2]), 3)
    end
    """
    jw2 = sgv_workspace("SigV.jl" => src2)
    r2 = JW._get_signature_help_v2(jw2.runtime, SGV_URI, at0(src2, "g(h([1, 2]),"))
    @test r2 !== nothing && r2.active_parameter == 1
end

@testitem "signature help v2: structs and qualified callees" setup=[SigV2WS] begin
    src = """
    module SigV
    module Sub
    struct S
        a::Int
        b
    end
    struct P
        x
        P(v) = new(v)
    end
    end
    using .Sub
    mk() = Sub.S(1, 2)
    mk2() = Sub.P(1)
    end
    """
    jw = sgv_workspace("SigV.jl" => src)
    r = JW._get_signature_help_v2(jw.runtime, SGV_URI, at0(src, "mk() = Sub.S("))
    @test r !== nothing
    @test [s.label for s in r.signatures] == ["S(a::Int, b)"]
    r = JW._get_signature_help_v2(jw.runtime, SGV_URI, at0(src, "mk2() = Sub.P("))
    @test r !== nothing
    @test [s.label for s in r.signatures] == ["P(v)"]
end

@testitem "signature help v2: declines" setup=[SigV2WS] begin
    src = """
    module SigV
    import Base: push!
    push!(v::Vector, a, b, c) = v
    f(a) = 1
    use1() = sort([1])
    use2(f) = f(1)
    use3() = push!([1], 2)
    def(sig) = 1
    use4() = :(f(1))
    end
    """
    jw = sgv_workspace("SigV.jl" => src)
    dec(needle) = JW._get_signature_help_v2(jw.runtime, SGV_URI, at0(src, needle))
    # A store callee declines (v1 renders store methods).
    @test dec("use1() = sort(") === nothing
    # A locally-shadowed callee declines.
    @test dec("use2(f) = f(") === nothing
    # A store-extending name declines.
    @test dec("use3() = push!(") === nothing
    # A definition's own signature is not a call.
    @test dec("def(sig") === nothing
    # Quoted code declines.
    @test dec("use4() = :(f(") === nothing
    # Flag off: the internal arm is not consulted by the public API.
    jw_off = sgv_workspace("SigV.jl" => src; flag=false)
    @test get_signature_help(jw_off, SGV_URI, at(src, "use2(f) = f(")) isa JW.SignatureResult
end
