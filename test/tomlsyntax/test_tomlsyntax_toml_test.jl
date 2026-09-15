# The official toml-test conformance corpus (testdata/toml-test, see its
# VENDORED.md), TOML 1.0 subset. Expected values come as tagged JSON
# (`{"type": "integer", "value": "1"}`), decoded here into the Julia values
# TomlSyntax produces.

@testsnippet TomlTestCorpus begin
    using JSON
    using Dates
    using JuliaWorkspaces.TomlSyntax: OffsetDateTime
    const CORPUS_ROOT = normpath(joinpath(@__DIR__, "..", "..", "testdata", "toml-test", "tests"))

    # Cases that are known not to conform. Empty is the goal; an entry here
    # documents a deliberate deviation, and an accidental fix shows up as an
    # unexpected pass.
    const TOML_TEST_KNOWN_FAILURES = String[]

    function corpus_cases(prefix)
        lines = readlines(joinpath(CORPUS_ROOT, "files-toml-1.0.0"))
        return [l for l in lines if startswith(l, prefix) && endswith(l, ".toml")]
    end
    corpus_path(rel) = joinpath(CORPUS_ROOT, split(rel, '/')...)

    function parse_fraction_ms(s)
        isempty(s) && return 0
        digits = rpad(first(s, 3), 3, '0')
        return Base.parse(Int, digits)
    end

    # RFC 3339 as toml-test writes it; fractions truncate to milliseconds.
    function parse_datetime_tag(s, kind)
        s = replace(s, ' ' => 'T', 't' => 'T', 'z' => 'Z')
        if kind == "time-local"
            m = match(r"^(\d\d):(\d\d):(\d\d)(?:\.(\d+))?$", s)
            m === nothing && error("bad time-local $s")
            return Time(Base.parse.(Int, m.captures[1:3])..., parse_fraction_ms(something(m.captures[4], "")))
        elseif kind == "date-local"
            return Date(s, dateformat"yyyy-mm-dd")
        end
        m = match(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)?$", s)
        m === nothing && error("bad datetime $s")
        y, mo, d, h, mi, sec = Base.parse.(Int, m.captures[1:6])
        dt = DateTime(y, mo, d, h, mi, min(sec, 59), parse_fraction_ms(something(m.captures[7], "")))
        kind == "datetime-local" && return dt
        off = m.captures[8]
        offset = off === nothing || off == "Z" ? 0 :
            (off[1] == '-' ? -1 : 1) * (60 * Base.parse(Int, off[2:3]) + Base.parse(Int, off[5:6]))
        return OffsetDateTime(dt, offset)
    end

    function jsn2data(x)
        if x isa AbstractDict && length(x) == 2 && haskey(x, "type") && haskey(x, "value") && x["type"] isa String
            t = x["type"]
            v = x["value"]
            t == "string" && return v
            t == "integer" && return Base.parse(Int64, v)
            t == "bool" && return v == "true"
            if t == "float"
                lv = lowercase(v)
                lv in ("inf", "+inf") && return Inf
                lv == "-inf" && return -Inf
                lv in ("nan", "+nan", "-nan") && return NaN
                return Base.parse(Float64, v)
            end
            t in ("datetime", "datetime-local", "date-local", "time-local") && return parse_datetime_tag(v, t)
            error("unknown toml-test type $t")
        elseif x isa AbstractDict
            return Dict{String,Any}(String(k) => jsn2data(v) for (k, v) in x)
        elseif x isa AbstractVector
            return Any[jsn2data(v) for v in x]
        end
        error("unexpected JSON $x")
    end
end

@testitem "tomlsyntax toml-test: valid cases parse to the expected values" setup=[TomlTS, TomlTestCorpus] begin
    cases = corpus_cases("valid/")
    @test length(cases) >= 150
    for rel in cases
        toml = read(corpus_path(rel), String)
        expected = jsn2data(JSON.parsefile(corpus_path(rel[1:end-5] * ".json")))
        got = TS.tryparse(toml)
        ok = got isa Dict && isequal(got, expected)
        if !ok && !(rel in TOML_TEST_KNOWN_FAILURES)
            @info "toml-test valid case failed" rel got expected
        end
        @test ok broken = (rel in TOML_TEST_KNOWN_FAILURES)
        # The tree API never throws on corpus input either.
        @test TS.parsetoml(TomlNode, toml; ignore_errors=true) isa TomlNode
    end
end

@testitem "tomlsyntax toml-test: invalid cases are rejected" setup=[TomlTS, TomlTestCorpus] begin
    cases = corpus_cases("invalid/")
    @test length(cases) >= 300
    for rel in cases
        toml = read(corpus_path(rel), String)
        got = TS.tryparse(toml)
        ok = got isa TomlParseError
        if !ok && !(rel in TOML_TEST_KNOWN_FAILURES)
            @info "toml-test invalid case accepted" rel got
        end
        @test ok broken = (rel in TOML_TEST_KNOWN_FAILURES)
        # Recovery never throws, whatever the input.
        @test TS.parsetoml(TomlNode, toml; ignore_errors=true) isa TomlNode
    end
end

@testitem "tomlsyntax toml-test: truncated inputs never throw" setup=[TomlTS, TomlTestCorpus] begin
    # Every corpus file cut at a handful of byte offsets: the parser must
    # recover, not crash, and the table builder must cope with the result.
    n = Ref(0)
    for rel in vcat(corpus_cases("valid/"), corpus_cases("invalid/"))
        bytes = read(corpus_path(rel))
        L = length(bytes)
        L == 0 && continue
        for cut in unique(round.(Int, range(1, L; length=min(L, 6))))
            text = String(bytes[1:cut])
            tree = TS.parsetoml(TomlNode, text; ignore_errors=true)
            TS.build_table(tree)
            n[] += 1
        end
    end
    @test n[] > 1000
end
