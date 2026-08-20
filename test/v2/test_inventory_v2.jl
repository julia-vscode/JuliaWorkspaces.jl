@testsnippet InvV2WS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: V2ItemRef, V2FileSkeleton, V2ItemRow, V2Decl,
        EMPTY_V2_SKELETON, derived_v2_file_walk, derived_v2_file_skeleton,
        derived_v2_file_bodies, derived_v2_file_maps, derived_v2_item_body,
        derived_v2_item_body_hash, derived_v2_item_classification,
        derived_v2_file_inventory, update_file!, JS2
    using JuliaWorkspaces.URIs2: URI

    const IV_URI = URI("file:///iv/src/F.jl")

    function iv_workspace(src::String; uri=IV_URI)
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(uri, SourceText(src, "julia")))
        return jw
    end

    iv_inv(src; uri=IV_URI) = derived_v2_file_inventory(iv_workspace(src; uri=uri).runtime, uri)
    iv_skel(src; uri=IV_URI) = derived_v2_file_skeleton(iv_workspace(src; uri=uri).runtime, uri)

    iv_names(inv) = sort([i.name for i in inv.items])
    iv_kinds(inv) = sort([(i.name, i.kind) for i in inv.items])

    function iv_ref(jw, name; uri=IV_URI)
        inv = derived_v2_file_inventory(jw.runtime, uri)
        return V2ItemRef(uri, only(filter(i -> i.name == name, inv.items)).id)
    end

    slice(content, r) = content[first(r):last(r)-1]  # ranges are exclusive-end
end

# ── value semantics ─────────────────────────────────────────────────────────

@testitem "v2 inventory: skeleton has value semantics" setup=[InvV2WS] begin
    src = "f(x) = x\nmodule M\ng() = 1\nend\nusing A\nexport f\n"
    a, b = iv_skel(src), iv_skel(src)
    @test a == b
    @test isequal(a, b)
    @test hash(a) == hash(b)
    @test a != iv_skel(src * "h() = 2\n")
end

# ── walker ──────────────────────────────────────────────────────────────────

@testitem "v2 walker: order is dense and ids are unique" setup=[InvV2WS] begin
    skel = iv_skel("""
    module M
        q() = 1
    end
    abstract type A end
    macro m(x) end
    export q
    using Printf
    z = 1
    """)
    all_ids = vcat([i.id for i in skel.items], [i.id for i in skel.imports],
                   [i.id for i in skel.exports], [i.id for i in skel.includes],
                   [i.id for i in skel.modules])
    @test allunique(all_ids)

    orders = sort(vcat([i.order for i in skel.items], [m.order for m in skel.modules],
                       [e.order for e in skel.exports], [i.order for i in skel.imports]))
    @test orders == collect(1:length(orders))
end

@testitem "v2 walker: module nesting sets parent_module" setup=[InvV2WS] begin
    inv = iv_inv("module A\nf() = 1\nmodule B\ng() = 2\nend\nend\nh() = 3\n")
    byname = Dict(i.name => i for i in inv.items)
    @test byname["f"].parent_module == ["A"]
    @test byname["g"].parent_module == ["A", "B"]
    @test byname["h"].parent_module == String[]

    mods = Dict(m.name => m for m in inv.modules)
    @test mods["A"].parent_module == String[]
    @test mods["B"].parent_module == ["A"]
    @test !mods["A"].bare
end

@testitem "v2 walker: baremodule is distinguished from module" setup=[InvV2WS] begin
    mods = Dict(m.name => m for m in iv_inv("module M end\nbaremodule B end\n").modules)
    @test mods["M"].bare == false
    @test mods["B"].bare == true
end

@testitem "v2 walker: docstring wrappers are transparent" setup=[InvV2WS] begin
    inv = iv_inv("\"\"\"\ndocs\n\"\"\"\nf(x) = x\n")
    @test iv_kinds(inv) == [("f", :function)]
end

@testitem "v2 walker: begin/if/elseif/else containers are transparent" setup=[InvV2WS] begin
    inv = iv_inv("""
    begin
        g() = 1
    end

    if VERSION >= v"1.0"
        h() = 2
    elseif VERSION >= v"0.7"
        h2() = 3
    else
        h3() = 4
    end
    """)
    @test iv_names(inv) == ["g", "h", "h2", "h3"]
    @test all(i -> i.parent_module == String[], inv.items)
end

@testitem "v2 walker: a ternary is NOT an if chain" setup=[InvV2WS] begin
    # `c ? a : b` parses as K"if" just like a real conditional, and "child 2 is a
    # block" does not discriminate — `c ? begin … end : g()` has one. The walker
    # separates them by byte position: a real `if` starts at its keyword, before
    # its condition; a ternary starts exactly where its condition does.
    inv = iv_inv("z = c ? begin f() = 1 end : g()\n")
    @test iv_names(inv) == ["z"]
    @test !any(i -> i.name == "f", inv.items)

    # And a real `if` still descends.
    @test iv_names(iv_inv("if c\n  f() = 1\nend\n")) == ["f"]
end

@testitem "v2 walker: non-isolating macrocalls are transparent" setup=[InvV2WS] begin
    inv = iv_inv("""
    @inline f(x) = x
    Base.@propagate_inbounds g(x) = x
    @static if VERSION >= v"1.0"
        h() = 1
    end
    """)
    @test iv_names(inv) == ["f", "g", "h"]
end

@testitem "v2 walker: isolating macrocalls are opaque" setup=[InvV2WS] begin
    for m in ("@testitem", "@testset", "@safetestset", "@testmodule", "@testsnippet")
        inv = iv_inv("$m \"t\" begin\n  inner() = 1\nend\n")
        @test iv_kinds(inv) == [(m, :opaque_macrocall)]
        @test !any(i -> i.name == "inner", inv.items)
    end
end

@testitem "v2 walker: unmodelled macrocalls mark the module blind but bind nothing" setup=[InvV2WS] begin
    inv = iv_inv("@some_unknown_macro foo bar\ng() = 1\n")
    # It is not a declaration...
    @test iv_names(inv) == ["g"]
    # ...but it IS recorded, which is what suppresses missing-reference noise.
    @test length(inv.opaque_macros) == 1
end

@testitem "v2 walker: ids are content-addressed, not positional" setup=[InvV2WS] begin
    a = iv_inv("f(x) = x + 1\n")
    b = iv_inv("# header\n\n\ng() = 2\n\nf(x) = x + 1\n")
    fa = only(filter(i -> i.name == "f", a.items))
    fb = only(filter(i -> i.name == "f", b.items))
    @test fa.id == fb.id

    # Records minted from ONE statement share an id.
    c = iv_inv("a, b = 1, 2\n@enum E x y\n")
    @test only(filter(i -> i.name == "a", c.items)).id ==
          only(filter(i -> i.name == "b", c.items)).id
    enum_ids = [i.id for i in c.items if i.kind in (:enum, :enum_member)]
    @test length(enum_ids) == 3 && all(==(enum_ids[1]), enum_ids)
end

# ── extraction coverage ─────────────────────────────────────────────────────

@testitem "v2 inventory: kinds and struct fields" setup=[InvV2WS] begin
    inv = iv_inv("""
    f(x) = x
    function g(y) y end
    macro m(x) x end
    struct S
        a::Int
        b
    end
    mutable struct MS
        c
    end
    abstract type A end
    primitive type P 8 end
    const X = 1
    global Y = 2
    Z = 3
    """)
    k = Dict(iv_kinds(inv))
    @test k["f"] == :function
    @test k["g"] == :function
    @test k["@m"] == :macro
    @test k["S"] == :struct
    @test k["MS"] == :mutable_struct
    @test k["A"] == :abstract
    @test k["P"] == :primitive
    @test k["X"] == :const
    @test k["Y"] == :global
    @test k["Z"] == :assignment

    @test only(filter(i -> i.name == "S", inv.items)).field_names == ["a", "b"]
end

@testitem "v2 inventory: qualified method extensions carry a qualifier" setup=[InvV2WS] begin
    inv = iv_inv("Base.foo(x) = 1\nfunction Base.Iterators.bar(y) end\nlocal_one(z) = 3\n")
    q = Dict(i.name => i.qualifier for i in inv.items)
    @test q["foo"] == ["Base"]
    @test q["bar"] == ["Base", "Iterators"]
    @test q["local_one"] == String[]
end

@testitem "v2 inventory: operator definitions, var\"\" names, where and return types" setup=[InvV2WS] begin
    inv = iv_inv("""
    Base.:(==)(a::T, b::T) where {T} = true
    var"weird name"() = 1
    typed(x)::Int = 2
    Vector2{T} = Array{T,1}
    """)
    k = Dict(iv_kinds(inv))
    @test k["=="] == :function
    @test only(filter(i -> i.name == "==", inv.items)).qualifier == ["Base"]
    @test k["weird name"] == :function
    @test k["typed"] == :function
    @test k["Vector2"] == :assignment
end

@testitem "v2 inventory: imports, exports and includes" setup=[InvV2WS] begin
    inv = iv_inv("""
    using A
    using B.C: d, e as f
    import G as H
    import I, J, K
    export foo, bar
    public baz
    include("other.jl")
    """)
    imps = Dict((i.kind, i.path) => i for i in inv.imports)
    @test haskey(imps, (:using, ["A"]))
    @test imps[(:using, ["B", "C"])].symbols == [(name="d", alias=nothing), (name="e", alias="f")]
    @test imps[(:import, ["G"])].alias == "H"
    # One statement naming several modules produces one row each.
    for m in ("I", "J", "K")
        @test haskey(imps, (:import, [m]))
    end

    exps = Dict(e.kind => e.names for e in inv.exports)
    @test exps[:export] == ["foo", "bar"]
    @test exps[:public] == ["baz"]

    @test only(inv.includes).path == "other.jl"
end

@testitem "v2 inventory: relative import paths encode their level" setup=[InvV2WS] begin
    inv = iv_inv("using ..Sibling: x\nusing .Child\n")
    paths = sort([i.path for i in inv.imports])
    @test [".", ".", "Sibling"] in paths
    @test [".", "Child"] in paths
end

@testitem "v2 inventory: enum members, inline and block forms" setup=[InvV2WS] begin
    for src in ("@enum Color red green\n",
                "@enum Color begin\n  red\n  green\nend\n")
        inv = iv_inv(src)
        @test iv_kinds(inv) == [("Color", :enum), ("green", :enum_member), ("red", :enum_member)]
    end
end

@testitem "v2 inventory: assignment-wrapped include is both a binding and an edge" setup=[InvV2WS] begin
    inv = iv_inv("const DATA = include(\"data.jl\")\n")
    @test iv_kinds(inv) == [("DATA", :const)]
    @test only(inv.includes).path == "data.jl"
    # Both records come from the one statement, so they share an id.
    @test only(inv.items).id == only(inv.includes).id
end

@testitem "v2 inventory: a computed include has no literal path" setup=[InvV2WS] begin
    inv = iv_inv("include(joinpath(@__DIR__, \"x.jl\"))\n")
    @test only(inv.includes).path === nothing
end

# ── the firewall ────────────────────────────────────────────────────────────

@testitem "v2 inventory: body, comment and docstring edits leave the skeleton equal" setup=[InvV2WS] begin
    base = iv_skel("f(x) = x + 1\ng() = 2\n")
    @test base == iv_skel("f(x) = x * 42\ng() = 2\n")              # body edit
    @test base == iv_skel("# comment\n\nf(x) = x + 1\ng() = 2\n")  # comment above
    @test base == iv_skel("f(x) =\n    x + 1\ng() = 2\n")          # reformat
    @test base != iv_skel("f(x) = x + 1\nh() = 2\n")               # API edit
end

@testitem "v2 inventory: skeleton backdates, per-item classification is isolated" setup=[InvV2WS] begin
    import JuliaWorkspaces.Salsa as Salsa
    import JuliaWorkspaces.Salsa.TraceLogging as TL

    mutable struct CountReceiver <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver() = CountReceiver(Dict{String,Int}())
    TL.receive_span(r::CountReceiver, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    Salsa.@derived function probe_skeleton(rt, uri)
        return sort([r.id for r in JuliaWorkspaces.derived_v2_file_skeleton(rt, uri).items])
    end

    jw = iv_workspace("f(x) = x + 1\ng() = 2\n")
    rt = jw.runtime
    fref = iv_ref(jw, "f")
    gref = iv_ref(jw, "g")
    probe_skeleton(rt, IV_URI)
    derived_v2_item_classification(rt, fref)
    derived_v2_item_classification(rt, gref)

    # Body edit to `f`: the walk re-executes, but the skeleton VALUE is equal, so
    # the probe does not. `g`'s body is untouched, so its classification does not
    # re-execute either.
    recv = CountReceiver()
    update_file!(jw, TextFile(IV_URI, SourceText("f(x) = x * 42\ng() = 2\n", "julia")))
    TL.with_tracing(recv) do
        probe_skeleton(rt, IV_URI)
        derived_v2_item_classification(rt, gref)
    end
    @test get(recv.counts, "derived_v2_file_walk", 0) == 1
    @test get(recv.counts, "probe_skeleton", 0) == 0
    @test get(recv.counts, "derived_v2_item_classification", 0) == 0

    # API edit: the probe does re-execute.
    recv2 = CountReceiver()
    update_file!(jw, TextFile(IV_URI, SourceText("f(x) = x * 42\nh() = 2\n", "julia")))
    TL.with_tracing(() -> probe_skeleton(rt, IV_URI), recv2)
    @test get(recv2.counts, "probe_skeleton", 0) == 1
end

@testitem "v2 inventory: one parse serves skeleton, bodies and maps" setup=[InvV2WS] begin
    import JuliaWorkspaces.Salsa.TraceLogging as TL

    mutable struct CountReceiver2 <: TL.AbstractTraceReceiver
        counts::Dict{String,Int}
    end
    CountReceiver2() = CountReceiver2(Dict{String,Int}())
    TL.receive_span(r::CountReceiver2, span::TL.TraceSpan) =
        (r.counts[span.name] = get(r.counts, span.name, 0) + 1; nothing)

    jw = iv_workspace("f(x) = x + 1\ng() = 2\n")
    recv = CountReceiver2()
    TL.with_tracing(recv) do
        derived_v2_file_skeleton(jw.runtime, IV_URI)
        derived_v2_file_bodies(jw.runtime, IV_URI)
        derived_v2_file_maps(jw.runtime, IV_URI)
    end
    @test get(recv.counts, "derived_v2_file_walk", 0) == 1
end

@testitem "v2 inventory: bodies backdate across position-only edits, maps shift" setup=[InvV2WS] begin
    src = "function f(x)\n    @assert x > 0\n    x + 1\nend\n"
    jw = iv_workspace(src)
    ref = iv_ref(jw, "f")

    b1 = derived_v2_item_body(jw.runtime, ref)
    h1 = derived_v2_item_body_hash(jw.runtime, ref)
    m1 = derived_v2_file_maps(jw.runtime, IV_URI)[ref.id]
    @test b1 !== nothing && h1 == b1.hash

    update_file!(jw, TextFile(IV_URI, SourceText("# comment\n\n\n" * src, "julia")))
    @test isequal(b1, derived_v2_item_body(jw.runtime, ref))
    @test derived_v2_item_body_hash(jw.runtime, ref) == h1
    @test m1 != derived_v2_file_maps(jw.runtime, IV_URI)[ref.id]

    update_file!(jw, TextFile(IV_URI, SourceText("function f(x)\n    x + 2\nend\n", "julia")))
    @test derived_v2_item_body_hash(jw.runtime, ref) != h1
end

@testitem "v2 inventory: map addresses align with the tree" setup=[InvV2WS] begin
    src = "f(x) = x + 1\n"
    jw = iv_workspace(src)
    ref = iv_ref(jw, "f")
    body = derived_v2_item_body(jw.runtime, ref)
    ranges = derived_v2_file_maps(jw.runtime, IV_URI)[ref.id]

    @test length(ranges) == JuliaWorkspaces.bt_node_count(body)
    @test slice(src, ranges[1]) == "f(x) = x + 1"
end

# ── EST shape contract (vendored-parser refresh canary) ─────────────────────

@testitem "v2 inventory: EST shape assumptions still hold" setup=[InvV2WS] begin
    # The walker and the classifier read these shapes directly. If a vendored
    # JuliaSyntax refresh changes `_green_to_est`, this fails loudly instead of
    # silently reclassifying every struct in the workspace.
    p(src) = JS2.children(JS2.parseall(JS2.SyntaxTree, src; filename="t.jl"))[1]

    st = p("struct S end")
    @test JS2.kind(st) == JS2.K"struct"
    @test JS2.children(st)[1].value === false          # mutability as a Value leaf
    @test JS2.children(p("mutable struct S end"))[1].value === true

    m = p("module M end")
    @test JS2.kind(m) == JS2.K"module"
    @test JS2.children(m)[1].value === true            # not-bare as a Value leaf
    @test JS2.children(p("baremodule B end"))[1].value === false

    # Short vs long form are different KINDS, not a flag.
    @test JS2.kind(p("f(x) = 1")) == JS2.K"="
    @test JS2.kind(p("function f(x) 1 end")) == JS2.K"function"

    # A docstring is a 4-child `@doc` macrocall with the LineNumberNode at 2.
    doc = p("\"\"\"d\"\"\"\nf() = 1")
    @test JS2.kind(doc) == JS2.K"macrocall"
    @test length(JS2.children(doc)) == 4
    @test JS2.children(doc)[2].value isa LineNumberNode

    # Getfield names quote their right-hand side.
    call = JS2.children(p("Base.foo(x) = 1"))[1]
    @test JS2.kind(JS2.children(call)[1]) == JS2.K"."
    @test JS2.kind(JS2.children(JS2.children(call)[1])[2]) == JS2.K"inert"
end

# ── degradation ─────────────────────────────────────────────────────────────

@testitem "v2 inventory: missing, empty and malformed files degrade quietly" setup=[InvV2WS] begin
    jw = iv_workspace("f(x) = x\n")
    missing_uri = URI("file:///iv/src/Missing.jl")
    @test derived_v2_file_skeleton(jw.runtime, missing_uri) == EMPTY_V2_SKELETON
    @test isempty(derived_v2_file_bodies(jw.runtime, missing_uri))
    @test derived_v2_item_body(jw.runtime, V2ItemRef(missing_uri, Int64(1))) === nothing
    @test derived_v2_item_body_hash(jw.runtime, V2ItemRef(missing_uri, Int64(1))) == UInt64(0)

    @test iv_skel("") == EMPTY_V2_SKELETON
    @test iv_skel("# only a comment\n") == EMPTY_V2_SKELETON

    # Malformed: no crash, whatever the parser recovers is fine.
    update_file!(jw, TextFile(IV_URI, SourceText("f(x = ) := nonsense +\n", "julia")))
    @test derived_v2_file_skeleton(jw.runtime, IV_URI) isa V2FileSkeleton
    @test derived_v2_file_maps(jw.runtime, IV_URI) isa Dict{Int64,Vector{UnitRange{Int}}}
end

# ── the boundary guard ──────────────────────────────────────────────────────

@testitem "v2 is free of CSTParser and StaticLint" begin
    # The v2 stack must not reach back into the v1 pipeline. If this fails, the
    # layer you need under src/v2/ is missing, not optional.
    dir = joinpath(pkgdir(JuliaWorkspaces), "src", "v2")
    forbidden = ["CSTParser", "StaticLint", "derived_julia_legacy_syntax_tree",
                 "_foreach_toplevel_item", "derived_file_inventory",
                 "derived_item_positions", "parse_julia_syntax_tree"]

    # Prose may still discuss the v1 pipeline — the whole point of several
    # comments here is to say what v2 replaced. Only executable code counts, so
    # strip `#` comments and `"""…"""` docstrings before looking.
    function strip_prose(src)
        without_docstrings = replace(src, r"\"\"\".*?\"\"\""s => "")
        io = IOBuffer()
        for line in eachline(IOBuffer(without_docstrings))
            i = findfirst('#', line)
            println(io, i === nothing ? line : line[1:prevind(line, i)])
        end
        return String(take!(io))
    end

    offenders = String[]
    for f in readdir(dir; join=true)
        endswith(f, ".jl") || continue
        code = strip_prose(read(f, String))
        for token in forbidden
            occursin(token, code) && push!(offenders, "$(basename(f)): $token")
        end
    end
    @test offenders == String[]
end

@testitem "v2 inventory: a syntax error yields the recovered tree, not an empty walk" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: URI

    # The walk parses with `ignore_errors=true`: definitions after (and around)
    # a syntax error stay in the inventory, matching CSTParser's recovery in v1.
    src = """
    function broken(x
        y = 1
    end

    f() = 2
    module M
    g() = 3
    end
    """
    jw = JuliaWorkspace()
    uri = URI("file:///pr/src/a.jl")
    add_file!(jw, TextFile(uri, SourceText(src, "julia")))

    inv = JW.derived_v2_file_inventory(jw.runtime, uri)
    names = Set((i.name, join(i.parent_module, ".")) for i in inv.items)
    @test ("f", "") in names
    @test ("g", "M") in names
    @test any(m -> m.name == "M", inv.modules)
end

@testitem "v2 inventory: module and import rows carry address maps, not bodies" begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!
    using JuliaWorkspaces.URIs2: URI

    src = """
    module Outer
    using ..Somewhere
    module Outer
    end
    end
    """
    jw = JuliaWorkspace()
    uri = URI("file:///pr/src/a.jl")
    add_file!(jw, TextFile(uri, SourceText(src, "julia")))

    skel = JW.derived_v2_file_skeleton(jw.runtime, uri)
    maps = JW.derived_v2_file_maps(jw.runtime, uri)
    bodies = JW.derived_v2_file_bodies(jw.runtime, uri)

    @test length(skel.modules) == 2
    @test length(skel.imports) == 1
    for m in skel.modules
        @test haskey(maps, m.id)
        @test !haskey(bodies, m.id)
        # Module EST children are [bare-flag, name, block]: preorder address 3
        # is the name token. Pinned here because `module_name` findings report
        # at that address.
        rng = maps[m.id][3]
        @test src[first(rng):last(rng)-1] == "Outer"
    end
    imp = skel.imports[1]
    @test haskey(maps, imp.id)
    @test !haskey(bodies, imp.id)
    rng = maps[imp.id][1]
    @test src[first(rng):last(rng)-1] == "using ..Somewhere"
end
