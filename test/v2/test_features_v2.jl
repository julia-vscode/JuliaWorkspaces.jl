# v2-backed interactive features (layer_features_v2.jl): the A1
# offset→item/address family and the feature swaps built on it.
# Offsets in these tests are 0-BASED byte offsets (the `_get_*`-level
# convention); `src` strings are pure ASCII so byte == char arithmetic.

@testsnippet FeatV2WS begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_enabled!, v2_item_view, v2_item_row_at, v2_identifier_addr_at
    using JuliaWorkspaces.URIs2: URI

    const FT_URI = URI("file:///ft/src/F.jl")

    function ft_workspace(src::String; flag=true)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(FT_URI, SourceText(src, "julia")))
        flag && set_v2_enabled!(jw, true)
        return jw
    end

    # 0-based offset of the i-th occurrence of `needle` in `src`.
    function off0(src, needle; nth=1)
        pos = 0
        for _ in 1:nth
            r = findnext(needle, src, pos + 1)
            r === nothing && error("needle not found")
            pos = first(r)
        end
        return pos - 1
    end
end

@testitem "A1: item row at offset" setup=[FeatV2WS] begin
    src = "f(x) = x + 1\ng(y) = y\n"
    jw = ft_workspace(src)
    # Inside the first item. (`row.kind` is the walker's coarse kind CLASS,
    # not the inventory classification — only identity matters here.)
    row = v2_item_row_at(jw.runtime, FT_URI, off0(src, "x + 1"))
    @test row !== nothing
    # Inside the second.
    row2 = v2_item_row_at(jw.runtime, FT_URI, off0(src, "g(y)"))
    @test row2 !== nothing && row2.id != row.id
    # Far past the end: nothing.
    @test v2_item_row_at(jw.runtime, FT_URI, 1000) === nothing
end

@testitem "A1: identifier addr with both-edge inclusion and right-edge tie-break" setup=[FeatV2WS] begin
    src = "f(alpha) = alpha + beta\n"
    jw = ft_workspace(src)
    row = v2_item_row_at(jw.runtime, FT_URI, 0)
    view = v2_item_view(jw.runtime, FT_URI, row.id)
    @test view !== nothing

    ident_at(o) = (a = v2_identifier_addr_at(view, o); a === nothing ? nothing : string(view.vals[a]))

    a2 = off0(src, "alpha"; nth=2)
    # Left edge, interior, and right edge all hit the identifier.
    @test ident_at(a2) == "alpha"
    @test ident_at(a2 + 2) == "alpha"
    @test ident_at(a2 + 5) == "alpha"       # cursor just after the last char
    # `f(alpha|)` — the paren's position still belongs to the preceding
    # identifier (right-edge rule).
    @test ident_at(off0(src, "(") + 6) == "alpha"
    # Cursor on the `+` operator: `+` IS an identifier leaf in a call; the
    # names on either side win only at their own edges.
    @test ident_at(off0(src, "beta")) == "beta"
    # Cursor in whitespace between tokens: nothing (the ` = ` region).
    @test ident_at(off0(src, "= alpha")) in (nothing, "=")
end

@testitem "A1: view alignment survives nesting; macro names excluded" setup=[FeatV2WS] begin
    src = "function outer(a)\n    inner = [a for a in 1:3]\n    @show inner\n    return inner\nend\n"
    jw = ft_workspace(src)
    row = v2_item_row_at(jw.runtime, FT_URI, 0)
    view = v2_item_view(jw.runtime, FT_URI, row.id)
    @test view !== nothing
    @test length(view.ranges) == length(view.kinds) == length(view.vals)
    # Every identifier's range slices to its own spelling.
    for a in eachindex(view.ranges)
        JW._v2f_is_identifier(view, a) || continue
        r = view.ranges[a]
        @test src[first(r):last(r)-1] == string(view.vals[a])
    end
    # The cursor on `@show` never resolves to an identifier target.
    a = v2_identifier_addr_at(view, off0(src, "@show") + 1)
    @test a === nothing || string(view.vals[a]) != "@show"
    # Parent addresses are sane: root has parent 0, everyone else > 0.
    @test view.parents[1] == 0
    @test all(view.parents[2:end] .> 0)
end

@testitem "A1: include rows now carry bodies and maps" setup=[FeatV2WS] begin
    src = "include(\"other.jl\")\nf() = 1\n"
    jw = ft_workspace(src)
    skel = JW.derived_v2_file_skeleton(jw.runtime, FT_URI)
    inc = only(skel.includes)
    @test haskey(JW.derived_v2_file_maps(jw.runtime, FT_URI), inc.id)
    @test haskey(JW.derived_v2_file_bodies(jw.runtime, FT_URI), inc.id)
    view = v2_item_view(jw.runtime, FT_URI, inc.id)
    @test view !== nothing
    # The path string literal's range slices to the quoted text.
    sa = findfirst(a -> view.kinds[a] == JW.JS2.K"string" ||
                        string(view.kinds[a]) == "String", eachindex(view.ranges))
    @test sa !== nothing
end

# ── local references family ─────────────────────────────────────────────────

@testitem "local refs: plain, reassigned, and argument locals" setup=[FeatV2WS] begin
    src = "function f(a)\n    x = a + 1\n    x = x + 2\n    return x\nend\n"
    jw = ft_workspace(src)

    # `x`: two write sites (both assignments) and two reads.
    refs = JW._get_references(jw.runtime, FT_URI, off0(src, "x ="))
    @test length(refs) == 4
    his = JW._get_highlights(jw.runtime, FT_URI, off0(src, "x ="))
    @test count(h -> h.kind === :write, his) == 2
    @test count(h -> h.kind === :read, his) == 2

    # `a`: declaration (argument) + one read; goto-def lands on the argument name.
    refs_a = JW._get_references(jw.runtime, FT_URI, off0(src, "a + 1"))
    @test length(refs_a) == 2
    defs_a = JW._get_definitions(jw.runtime, FT_URI, off0(src, "a + 1"))
    @test length(defs_a) == 1
    @test defs_a[1].start.line == 1

    # Rename rewrites every occurrence with the bare name.
    edits = JW._get_rename_edits(jw.runtime, FT_URI, off0(src, "x ="), "y")
    @test length(edits) == 4
    @test all(e -> e.new_text == "y", edits)
    @test JW._can_rename(jw.runtime, FT_URI, off0(src, "x =")) !== nothing
end

@testitem "local refs: closures, comprehensions, where params, kwargs" setup=[FeatV2WS] begin
    # A captured local: definition + closure read unify.
    src = "function f()\n    c = 1\n    g = () -> c + 1\n    return g()\nend\n"
    jw = ft_workspace(src)
    @test length(JW._get_references(jw.runtime, FT_URI, off0(src, "c = 1"))) == 2

    # Comprehension variable: filter + body closures merge by decl addr.
    src = "f(d) = [n + 1 for n in d if n > 0]\n"
    jw = ft_workspace(src)
    refs = JW._get_references(jw.runtime, FT_URI, off0(src, "n in d"))
    @test length(refs) == 3   # decl + body read + filter read

    # `where` param: signature and body occurrences unify via the
    # typevar/static_parameter pair.
    src = "f(x::T) where {T} = zero(T)\n"
    jw = ft_workspace(src)
    refs = JW._get_references(jw.runtime, FT_URI, off0(src, "T} ="))
    @test length(refs) == 3   # ::T, {T}, zero(T)

    # A kwarg with a default: the forwarding-method duplicate collapses to
    # source occurrences only.
    src = "f(a; b = 2) = a + b\n"
    jw = ft_workspace(src)
    refs = JW._get_references(jw.runtime, FT_URI, off0(src, "b = 2"))
    @test length(refs) == 2
end

@testitem "local refs: shadowing keeps inner and outer distinct" setup=[FeatV2WS] begin
    src = "function f(v)\n    x = 1\n    let x = 2\n        v += x\n    end\n    return x\nend\n"
    jw = ft_workspace(src)
    outer = JW._get_references(jw.runtime, FT_URI, off0(src, "x = 1"))
    inner = JW._get_references(jw.runtime, FT_URI, off0(src, "x = 2"))
    @test length(outer) == 2   # decl + return read
    @test length(inner) == 2   # let binding + the += read
    @test isempty(intersect(Set(r.start for r in outer), Set(r.start for r in inner)))
end

@testitem "local refs: fallbacks decline to v1" setup=[FeatV2WS] begin
    using JuliaWorkspaces: v2_local_occurrences

    # A quoted identifier: fabricated reads anchor at the quote address, so
    # the resolver declines.
    src = "f(x) = :(alpha + 1)\n"
    jw = ft_workspace(src)
    @test v2_local_occurrences(jw.runtime, FT_URI, off0(src, "alpha")) === nothing

    # Inside an opaque macrocall's arguments: item has expansion sites.
    src = "function f(y)\n    @some_dsl y + 1\nend\n"
    jw = ft_workspace(src)
    @test v2_local_occurrences(jw.runtime, FT_URI, off0(src, "y + 1")) === nothing

    # A module-level (global) name: declined — the v1 :tree route answers.
    src = "g() = 1\nf() = g()\n"
    jw = ft_workspace(src)
    @test v2_local_occurrences(jw.runtime, FT_URI, off0(src, "g()"; nth=2)) === nothing

    # Flag off: the branch never runs (structural — internal helper still
    # works, but _get_references must follow the v1 path; smoke-check no
    # crash and plausible output for a local).
    src = "function f()\n    z = 1\n    return z\nend\n"
    jw = ft_workspace(src; flag=false)
    refs = JW._get_references(jw.runtime, FT_URI, off0(src, "z = 1"))
    @test refs isa Vector{JW.ReferenceResult}
end

# ── workspace symbols ───────────────────────────────────────────────────────

@testitem "workspace symbols: v2 swap" setup=[FeatV2WS] begin
    src = """
    module Outer
    f() = 1
    struct Thing end
    macro mymac(x) end
    @testitem "t" begin
        hidden_in_test() = 1
    end
    end
    """
    jw = ft_workspace(src)
    syms = JW._get_workspace_symbols(jw.runtime, "")
    names = Set(s.name for s in syms)
    @test "f" in names
    @test "Thing" in names
    @test "Outer" in names
    # Testitem bodies are opaque in v2: no leakage.
    @test !("hidden_in_test" in names)
    # Prefix matching, with the @-stripped variant for macros.
    @test any(s -> s.name == "@mymac", JW._get_workspace_symbols(jw.runtime, "mymac"))
    @test any(s -> s.name == "@mymac", JW._get_workspace_symbols(jw.runtime, "@mymac"))
    @test isempty(JW._get_workspace_symbols(jw.runtime, "zzz_nothing"))
    # The range slices to the declaration.
    fsym = only(filter(s -> s.name == "f", syms))
    @test fsym.start.line == 2

    # Flag off: the v1 path still answers.
    jw = ft_workspace(src; flag=false)
    @test any(s -> s.name == "f", JW._get_workspace_symbols(jw.runtime, ""))
end

# ── module-at-position ──────────────────────────────────────────────────────

@testitem "module-at: header corrections and nesting" setup=[FeatV2WS] begin
    src = """
    module Outer
    f() = 1
    module Inner
    g() = 2
    end
    end
    top() = 3
    """
    jw = ft_workspace(src)
    mat(o) = JW._get_module_at(jw.runtime, FT_URI, o)

    # Inside Outer's body, outside Inner.
    @test mat(off0(src, "f() = 1")) == "Outer"
    # Inside Inner's body.
    @test mat(off0(src, "g() = 2")) == "Outer.Inner"
    # Cursor on the `module` keyword, the name, and `end` all attribute to
    # the ENCLOSING module.
    @test mat(off0(src, "module Inner")) == "Outer"
    @test mat(off0(src, "Inner")) == "Outer"
    @test mat(off0(src, "end")) == "Outer"        # Inner's `end`
    # Top level outside every module (v2 has no splice prefix for a
    # single-file root).
    @test mat(off0(src, "top()")) == "Main"

    # Flag off still answers (v1 path).
    jw = ft_workspace(src; flag=false)
    @test JW._get_module_at(jw.runtime, FT_URI, off0(src, "g() = 2")) == "Outer.Inner"
end

# ── document links ──────────────────────────────────────────────────────────

@testitem "document links: v2 swap" setup=[FeatV2WS] begin
    mktempdir() do dir
        # Real files on disk, workspace file located in `dir`.
        target = joinpath(dir, "linked.jl")
        write(target, "x = 1\n")
        uri = JuliaWorkspaces.URIs2.filepath2uri(joinpath(dir, "main.jl"))
        abs_esc = replace(target, "\\" => "\\\\")
        src = """
        include("linked.jl")
        s = "linked.jl"
        a = "$abs_esc"
        missing_file = "no_such_file_xyz.jl"
        """
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        set_v2_enabled!(jw, true)

        links = JW._get_document_links(jw.runtime, uri)
        # The include path, the bare relative literal, and the absolute
        # literal each link; the missing file does not.
        @test length(links) == 3
        @test all(l -> string(l.target_uri) ==
            string(JuliaWorkspaces.URIs2.filepath2uri(target)), links)
        @test length(unique((l.start, l.stop) for l in links)) == 3

        # Flag off: the v1 path answers the same targets.
        jw2 = JuliaWorkspace()
        add_file!(jw2, TextFile(uri, SourceText(src, "julia")))
        links_v1 = JW._get_document_links(jw2.runtime, uri)
        @test Set(string(l.target_uri) for l in links_v1) ==
              Set(string(l.target_uri) for l in links)
    end
end

# ── code actions under both flags ───────────────────────────────────────────

@testitem "actions: the structural set still works with both v2 flags on" begin
    # The finding-driven `when` predicates read StaticLint's meta marks, which
    # the still-running v1 pass sets even when input_v2_enabled suppresses
    # the corresponding DIAGNOSTICS at emission — so both flags on must offer
    # exactly the actions flag-off offers, at every probed cursor. Parity is
    # the contract; absolute expectations live in test/test_actions.jl.
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!,
        set_v2_enabled!, set_v2_enabled!, get_code_actions, execute_code_action
    using JuliaWorkspaces.URIs2: URI

    project_toml = "name = \"ActV2\"
uuid = \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee51\"
version = \"0.1.0\"
"
    manifest_toml = "julia_version = \"1.11.0\"
manifest_format = \"2.0\"
project_hash = \"abc\"

[deps]
"
    source = """
    module ActV2
    using Base: string, Meta
    import Base
    f(x) = x + 1
    function g(unused_arg)
        return 1
    end
    function h()
        dead = 2
        s = "plain"
        return isnothing(s)
    end
    check(y) = y == nothing
    \"\"\"
        documented(a)
    \"\"\"
    documented(a, b) = a + b
    function undocumented_fn(q)
        return q
    end
    end
    """
    uri = URI("file:///actv2/src/ActV2.jl")
    function mk(flags)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///actv2/Project.toml"), SourceText(project_toml, "toml")))
        add_file!(jw, TextFile(URI("file:///actv2/Manifest.toml"), SourceText(manifest_toml, "toml")))
        add_file!(jw, TextFile(uri, SourceText(source, "julia")))
        if flags
            set_v2_enabled!(jw, true)
            set_v2_enabled!(jw, true)
        end
        return jw
    end
    jw_on, jw_off = mk(true), mk(false)

    function string_index(src, line, col)
        lines = split(src, '
')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    saw_ids = Set{String}()
    for line in 2:19, col in (1, 5, 10, 14)
        idx = string_index(source, line, col)
        on = sort([a.id for a in get_code_actions(jw_on, uri, idx, String[])])
        off = sort([a.id for a in get_code_actions(jw_off, uri, idx, String[])])
        @test on == off
        union!(saw_ids, on)
        # Every offered action must EXECUTE identically under the flags.
        for id in on
            e_on = execute_code_action(jw_on, id, uri, idx)
            e_off = execute_code_action(jw_off, id, uri, idx)
            @test [(e.uri, e.edits) for e in e_on] == [(e.uri, e.edits) for e in e_off]
        end
    end
    # The probe grid actually exercises the structural set, the docstring
    # actions, and OrganizeImports.
    for want in ("ExpandFunction", "RewriteAsRawString", "OrganizeImports",
                 "AddDocstringTemplate", "UpdateDocstringSignature")
        @test want in saw_ids
    end
    println("actions parity probe covered: ", sort!(collect(saw_ids)))
end

# ── docstrings (A2) ─────────────────────────────────────────────────────────

@testitem "A2: doc ranges captured for every documented shape" setup=[FeatV2WS] begin
    using JuliaWorkspaces: v2_item_docstring, v2_item_doc_range, V2ItemRef
    src = """
    \"\"\"
    documented function
    \"\"\"
    f(x) = x

    "short doc" const C = 1

    \"\"\"
    a struct
    \"\"\"
    struct S
        a::Int
    end

    "mod doc" module M
    end

    "enum doc" @enum E ea eb

    "opaque doc" @some_unknown_macro foo

    undocumented() = 1
    """
    jw = ft_workspace(src)
    docs = JW.derived_v2_file_doc_ranges(jw.runtime, FT_URI)
    inv = JW.derived_v2_file_inventory(jw.runtime, FT_URI)
    id_of(name) = only(filter(i -> i.name == name, inv.items)).id

    @test v2_item_docstring(jw.runtime, V2ItemRef(FT_URI, id_of("f"))) == "documented function\n"
    @test v2_item_docstring(jw.runtime, V2ItemRef(FT_URI, id_of("C"))) == "short doc"
    @test v2_item_docstring(jw.runtime, V2ItemRef(FT_URI, id_of("S"))) == "a struct\n"
    @test v2_item_docstring(jw.runtime, V2ItemRef(FT_URI, id_of("E"))) == "enum doc"
    @test v2_item_doc_range(jw.runtime, FT_URI, id_of("undocumented")) === nothing

    # Module rows and opaque macrocalls carry doc ranges too.
    skel = JW.derived_v2_file_skeleton(jw.runtime, FT_URI)
    m = only(skel.modules)
    @test haskey(docs, m.id)
    om = only(skel.opaque_macros)
    @test haskey(docs, om.id)

    # The raw range slices to the literal's CONTENT (the EST string node's
    # range excludes the quotes — which is the useful range for consumers).
    r = v2_item_doc_range(jw.runtime, FT_URI, id_of("C"))
    @test src[first(r):last(r)-1] == "short doc"
end

@testitem "A2: docstring edits backdate skeleton and bodies" setup=[FeatV2WS] begin
    using JuliaWorkspaces: update_file!
    src1 = "\"\"\"one\"\"\"\nf(x) = x\n"
    src2 = "\"\"\"two, longer text\"\"\"\nf(x) = x\n"
    jw = ft_workspace(src1)
    skel1 = JW.derived_v2_file_skeleton(jw.runtime, FT_URI)
    bodies1 = JW.derived_v2_file_bodies(jw.runtime, FT_URI)
    docs1 = JW.derived_v2_file_doc_ranges(jw.runtime, FT_URI)
    update_file!(jw, TextFile(FT_URI, SourceText(src2, "julia")))
    @test JW.derived_v2_file_skeleton(jw.runtime, FT_URI) == skel1
    @test JW.derived_v2_file_bodies(jw.runtime, FT_URI) == bodies1
    @test JW.derived_v2_file_doc_ranges(jw.runtime, FT_URI) != docs1
end

@testitem "A2: export rows now carry maps" setup=[FeatV2WS] begin
    src = "export foo, bar\npublic baz\nfoo() = 1\n"
    jw = ft_workspace(src)
    skel = JW.derived_v2_file_skeleton(jw.runtime, FT_URI)
    maps = JW.derived_v2_file_maps(jw.runtime, FT_URI)
    for e in skel.exports
        @test haskey(maps, e.id)
        r = maps[e.id][1]
        @test occursin(e.kind === :export ? "export" : "public", src[first(r):last(r)-1])
    end
end

# ── document symbols ────────────────────────────────────────────────────────

@testitem "document symbols: v2 outline nesting and kinds" setup=[FeatV2WS] begin
    src = """
    module Outer
    function compute(arg)
        temp = arg + 1
        return temp
    end
    generic(x::T) where {T} = zero(T)
    struct Point
        x::Int
        y::Int
    end
    const GREETING = "hi"
    const COUNT = 42
    const handler = () -> 1
    plain = nothing
    @testset "grouped" begin
        inner_helper() = 1
    end
    end
    @testitem "checks" begin
        invisible() = 1
    end
    """
    jw = ft_workspace(src)
    syms = JW._get_document_symbols(jw.runtime, FT_URI)

    outer = only(filter(s -> s.name == "Outer", syms))
    @test outer.kind == 2
    names(v) = Dict(s.name => s for s in v)
    kids = names(outer.children)

    @test kids["compute"].kind == 12
    ckids = names(kids["compute"].children)
    @test haskey(ckids, "arg") && ckids["arg"].kind == 13
    @test haskey(ckids, "temp") && ckids["temp"].kind == 13

    gkids = names(kids["generic"].children)
    @test haskey(gkids, "T") && gkids["T"].kind == 26
    @test haskey(gkids, "x") && gkids["x"].kind == 13

    @test kids["Point"].kind == 23
    pkids = names(kids["Point"].children)
    @test pkids["x"].kind == 8
    @test pkids["y"].kind == 8

    # Value-family shape kinds.
    @test kids["GREETING"].kind == 15
    @test kids["COUNT"].kind == 16
    @test kids["handler"].kind == 12
    @test kids["plain"].kind == 13

    # @testset gets a title symbol; its inner definitions surface as LOCALS of
    # the test-block item (test blocks lower let-wrapped), kind 13.
    ts = only(filter(s -> startswith(s.name, "@testset"), outer.children))
    @test ts.name == "@testset \"grouped\""
    @test ts.kind == 3
    @test any(c -> c.name == "inner_helper" && c.kind == 13, ts.children)

    # @testitem gets a title symbol; body definitions appear as locals too.
    ti = only(filter(s -> startswith(s.name, "@testitem"), syms))
    @test ti.name == "@testitem \"checks\""
    @test any(c -> c.name == "invisible" && c.kind == 13, ti.children)

    # Flag off: the v1 path still answers with the same top-level names.
    jw2 = ft_workspace(src; flag=false)
    v1_syms = JW._get_document_symbols(jw2.runtime, FT_URI)
    @test any(s -> s.name == "Outer", v1_syms)
end

# ── same-file global highlights ─────────────────────────────────────────────

@testitem "global highlights: same-file occurrences" setup=[FeatV2WS] begin
    using JuliaWorkspaces: v2_global_occurrences
    src = """
    const LIMIT = 10
    check(x) = x < LIMIT
    clamp2(x) = min(x, LIMIT)
    helper() = 1
    run() = helper() + helper()
    """
    jw = ft_workspace(src)

    # A const and its two use sites; the declaration is the write.
    his = JW._get_highlights(jw.runtime, FT_URI, off0(src, "LIMIT"))
    @test length(his) == 3
    @test count(h -> h.kind === :write, his) == 1

    # A function name: declaration + call sites.
    his = JW._get_highlights(jw.runtime, FT_URI, off0(src, "helper()"; nth=2))
    @test length(his) == 3

    # Module-scoping: same name in two modules stays separate.
    src2 = """
    module A
    shared = 1
    use_a() = shared
    end
    module B
    shared = 2
    use_b() = shared
    end
    """
    jw = ft_workspace(src2)
    his_a = JW._get_highlights(jw.runtime, FT_URI, off0(src2, "shared = 1"))
    @test length(his_a) == 2

    # Alias imports decline the name-keyed resolver (flag-on == flag-off).
    src3 = "using Base: sum as total\nf(v) = total(v)\n"
    jw = ft_workspace(src3)
    @test v2_global_occurrences(jw.runtime, FT_URI, off0(src3, "total(v)")) === nothing

    # Qualified member cursors decline.
    src4 = "g() = Base.print\n"
    jw = ft_workspace(src4)
    @test v2_global_occurrences(jw.runtime, FT_URI, off0(src4, "print")) === nothing
end

# ── selection ranges + block range ──────────────────────────────────────────

@testitem "selection ranges: v2 chains nest strictly outward" setup=[FeatV2WS] begin
    src = """
    module M
    f(x) = x + g(x)
    end
    export nothing_here
    """
    jw = ft_workspace(src)
    o = off0(src, "g(x)")
    res = only(JW._get_selection_ranges(jw.runtime, FT_URI, [o]))
    @test res !== nothing
    # Walk outward: each range must contain the previous, ending at the file.
    outermost, depth = let prev = nothing, n = res, count = 0
        while n !== nothing
            if prev !== nothing
                @test (n.start.line < prev.start.line ||
                       (n.start.line == prev.start.line && n.start.column <= prev.start.column))
                @test (prev.stop.line < n.stop.line ||
                       (prev.stop.line == n.stop.line && prev.stop.column <= n.stop.column))
            end
            prev = n
            n = n.parent
            count += 1
        end
        prev, count
    end
    @test depth >= 4   # node .. item .. module body .. module .. file
    @test outermost.start.line == 1 && outermost.start.column == 1   # outermost = file

    # Cursor on an export statement: per-offset v1 fallback still answers.
    res2 = only(JW._get_selection_ranges(jw.runtime, FT_URI, [off0(src, "export")]))
    @test res2 !== nothing
end

@testitem "block range: windows, docstrings, and module structure" setup=[FeatV2WS] begin
    src = """
    first_fn() = 1

    \"\"\"
    docs
    \"\"\"
    documented() = 2

    module M
    inner_a() = 1
    module Deep
    end
    end
    last_fn() = 3
    """
    jw = ft_workspace(src)
    br(o) = JW._get_current_block_range(jw.runtime, FT_URI, o)

    # A plain statement: highlight covers the statement, block extends to the
    # next statement's start.
    b = br(off0(src, "first_fn"))
    @test b !== nothing
    @test b.block_start == b.highlight_start
    @test b.block_start.line == 1

    # Trailing trivia after a statement belongs to the NEXT block.
    b = br(off0(src, "first_fn") + ncodeunits("first_fn() = 1") + 1)
    @test b !== nothing && b.highlight_start.line >= 3

    # A documented item's block INCLUDES the docstring (A2 doc range).
    b = br(off0(src, "documented()"))
    @test b.block_start.line == 3
    @test b.highlight_stop.line >= 6

    # Module keyword and `end`: the whole module.
    b = br(off0(src, "module M"))
    @test b.block_start.line == 8
    @test b.highlight_stop.line >= 12
    # Inside the body: the inner statement.
    b = br(off0(src, "inner_a"))
    @test b.block_start.line == 9
    @test b.highlight_stop.line == 9
    # A nested module inside the body is returned whole, no recursion.
    b = br(off0(src, "module Deep"))
    @test b.block_start.line == 10
    @test b.highlight_stop.line >= 11

    # A statement under `@static if`: v2 declines, flag-on equals flag-off.
    src2 = "@static if true\n    cond_fn() = 1\nend\n"
    jw_on = ft_workspace(src2)
    jw_off = ft_workspace(src2; flag=false)
    o = off0(src2, "cond_fn")
    @test br === br   # keep bindings distinct below
    b_on = JW._get_current_block_range(jw_on.runtime, FT_URI, o)
    b_off = JW._get_current_block_range(jw_off.runtime, FT_URI, o)
    @test b_on == b_off
end
