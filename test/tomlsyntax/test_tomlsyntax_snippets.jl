# Shared helpers of the TomlSyntax suite. Snippets are package-global, so
# every test_tomlsyntax_*.jl file uses `setup=[TomlTS]`.
@testsnippet TomlTS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: TomlSyntax
    using JuliaWorkspaces.TomlSyntax: TomlNode, TomlParseError, TomlDiagnostic, OffsetDateTime
    using Dates
    const TS = TomlSyntax

    # Base's `values.jl` helpers: exact value AND type, or a specific error code.
    testval(s, v) = (p = TS.parse("foo = $s")["foo"]; isequal(v, p) && typeof(v) == typeof(p))
    function failval(s, code)
        e = TS.tryparse("foo = $s")
        return e isa TomlParseError && TS.error_kind(e) == code
    end

    # The trivia-free tree as an s-expression, error nodes included.
    sexpr(src) = sprint(show, MIME"text/x.sexpression"(), TS.parsetoml(TomlNode, src; ignore_errors=true))

    # Bytes fb..lb (inclusive) of `src`; "" for a zero-width range.
    slice(src, fb, lb) = String(codeunits(src)[fb:lb])

    # Syntax diagnostics as (code, covered text) pairs.
    function diag_slices(src)
        _, ds = TS.parsetoml_with_diagnostics(src)
        return [(d.code, slice(src, d.first_byte, d.last_byte)) for d in ds]
    end

    # Every code `tryparse` reports, syntax and semantic, in byte order.
    function all_codes(src)
        e = TS.tryparse(src)
        return e isa TomlParseError ? [d.code for d in e.diagnostics] : TS.TomlErrorKind[]
    end
end
