@testitem "References: find references basic" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_references
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "RefTest"
    uuid = "12345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """

    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module RefTest
    func(arg) = 1
    func()
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///reftest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///reftest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///reftest/src/RefTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///reftest/src/RefTest.jl")

    # Helper: get 1-based string index for (1-based line, 1-based col)
    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # "func" on line 3 col 1 — should find both the definition and the call
    idx = string_index(source, 3, 1)
    refs = get_references(jw, uri, idx)
    @test length(refs) == 2
    @test all(r -> r.uri == uri, refs)
end

@testitem "References: definitions basic" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_definitions
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "DefTest"
    uuid = "22345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """

    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module DefTest
    func(arg) = 1
    func()
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///deftest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///deftest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///deftest/src/DefTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///deftest/src/DefTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # "func" on line 3 (the call site) — should go to the definition
    idx = string_index(source, 3, 1)
    defs = get_definitions(jw, uri, idx)
    @test !isempty(defs)
    @test all(d -> d.uri == uri, defs)
end

@testitem "References: go-to-definition on a using'd module name" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_definitions
    using JuliaWorkspaces.URIs2: URI

    # `using Base` — the module name resolves to an external module store, which
    # the per-file strip rewrites to a `:external_module` TreeRef. Go-to-def must
    # follow it to the module's source, not return nothing (regression: a
    # `using Foo` name yielded no definition).
    source = "module DefUsing\nusing Base\nfoo() = Base\nend\n"
    jw = JuliaWorkspace()
    uri = URI("file:///defusing/src/DefUsing.jl")
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    p_using = first(findfirst("using Base", source)) + length("using ")
    @test !isempty(get_definitions(jw, uri, p_using))

    # a bare `Base` usage in the body resolves the same way
    p_body = first(findlast("Base", source))
    @test !isempty(get_definitions(jw, uri, p_body))
end

@testitem "Definitions: an external package module lands in its source file" begin
    using JuliaWorkspaces: JuliaWorkspaces, DefinitionResult
    using JuliaWorkspaces.URIs2: filepath2uri
    using JuliaWorkspaces.SymbolServer: ModuleStore, FunctionStore, MethodStore, VarRef

    # A package `using`'d in a resolved environment binds to a `ModuleStore`
    # (not a workspace EXPR/TreeRef) whose members carry real source files.
    # Go-to-def on the module name must land in the module's main source file
    # `<Name>.jl`, not return nothing — regression: the handler only produced a
    # location for modules exposing an `eval` FunctionStore (e.g. Base) and
    # yielded nothing for every package module, whose `eval` is a `VarRef`.
    dir = mktempdir()
    main = joinpath(dir, "Foo.jl")
    util = joinpath(dir, "helpers.jl")
    write(main, "module Foo\nf() = 1\nend\n")
    write(util, "g() = 2\n")

    modref = VarRef(nothing, :Foo)
    ms = ModuleStore(modref, Dict{Symbol,Any}(), "", true, Symbol[:f], Symbol[])
    ms.vals[:f] = FunctionStore(VarRef(modref, :f),
        [MethodStore(:f, :Foo, main, Int32(2), Pair{Any,Any}[], Symbol[], nothing)],
        "", VarRef(modref, :f), true)
    ms.vals[:g] = FunctionStore(VarRef(modref, :g),
        [MethodStore(:g, :Foo, util, Int32(1), Pair{Any,Any}[], Symbol[], nothing)],
        "", VarRef(modref, :g), false)

    results = DefinitionResult[]
    JuliaWorkspaces._get_definitions_from_val(ms, nothing, nothing, results, nothing, nothing)

    @test !isempty(results)
    @test any(d -> d.uri == filepath2uri(main), results)

    # Wrapper package: `Bar.jl` only `include`s; the definitions live in
    # `impl.jl`, so no member's basename is `Bar.jl`. Go-to-def must still land
    # on the entry file `Bar.jl` sitting in the same `src` dir, not on `impl.jl`
    # (JuliaInterpreter/LoweredCodeUtils are shaped this way).
    dir2 = mktempdir()
    src2 = mkpath(joinpath(dir2, "src"))
    entry = joinpath(src2, "Bar.jl")
    impl = joinpath(src2, "impl.jl")
    write(entry, "module Bar\ninclude(\"impl.jl\")\nend\n")
    write(impl, "h() = 3\n")
    barref = VarRef(nothing, :Bar)
    ms2 = ModuleStore(barref, Dict{Symbol,Any}(), "", true, Symbol[:h], Symbol[])
    ms2.vals[:h] = FunctionStore(VarRef(barref, :h),
        [MethodStore(:h, :Bar, impl, Int32(1), Pair{Any,Any}[], Symbol[], nothing)],
        "", VarRef(barref, :h), true)

    results2 = DefinitionResult[]
    JuliaWorkspaces._get_definitions_from_val(ms2, nothing, nothing, results2, nothing, nothing)

    @test any(d -> d.uri == filepath2uri(entry), results2)
end

@testitem "References: rename basic" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_rename_edits
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "RenTest"
    uuid = "32345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """

    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module RenTest
    func(arg) = 1
    func()
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///rentest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///rentest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///rentest/src/RenTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///rentest/src/RenTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # "func" on line 3 col 1 (the call site) — rename to "myfunc"
    idx = string_index(source, 3, 1)
    edits = get_rename_edits(jw, uri, idx, "myfunc")
    @test length(edits) == 2
    @test all(e -> e.new_text == "myfunc", edits)
    @test all(e -> e.uri == uri, edits)
end

@testitem "References: rename locals/structs/globals/consts" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_rename_edits
    using JuliaWorkspaces.URIs2: URI

    # Guards the common (non-macro) rename path across binding kinds: every edit
    # must carry the verbatim new name (no stray `@`, no duplicated ranges) and
    # cover exactly the definition plus each use.
    source = """
    module CoverTest
    const MAX = 100
    glob = 1
    struct Point
        x
        y
    end
    function f()
        local_var = glob + MAX
        p = Point(local_var, 2)
        return local_var + p.x
    end
    end
    """
    uri = URI("file:///cover/src/CoverTest.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # (kind, line, col-inside-the-identifier, new name, expected occurrence count)
    cases = [
        ("const", 2, 8, "LIMIT", 2),   # `MAX`: definition + one use
        ("global", 3, 2, "gg", 2),     # `glob`: definition + one use
        ("struct", 4, 10, "Coord", 2), # `Point`: definition + one use
        ("local", 9, 9, "lv", 3),      # `local_var`: definition + two uses
    ]

    for (kind, line, col, new_name, expected) in cases
        idx = string_index(source, line, col)
        edits = get_rename_edits(jw, uri, idx, new_name)
        @test length(edits) == expected                              # $kind
        @test all(e -> e.new_text == new_name, edits)                # verbatim, no `@`
        @test all(e -> e.uri == uri, edits)
        ranges = [(e.start.line, e.start.column, e.stop.line, e.stop.column) for e in edits]
        @test length(unique(ranges)) == length(ranges)               # no duplicate edits
    end

    # Cursor on the very first character of a type name right after the `struct`
    # keyword (the `P` of `Point`, col 8): a zero-width mutability-flag node sits
    # at the same offset as the identifier, and `get_expr1` used to resolve to it
    # (missing the identifier, producing no edits). It now skips the zero-width
    # node and resolves the identifier.
    @test length(get_rename_edits(jw, uri, string_index(source, 4, 8), "Coord")) == 2
end

@testitem "References: rename macro" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_rename_edits, get_references
    using JuliaWorkspaces.URIs2: URI

    # A macro definition uses the bare name (`add_2`), while every invocation
    # carries the leading `@` (`@add_2`). Renaming must keep those consistent:
    # the definition edit must not gain a stray `@`, invocation edits must keep
    # it, and the definition must not be emitted twice.
    source = """
    module RenMacro
    macro add_2(x)
        return :(\$x + 2)
    end
    f() = @add_2 1
    g(x) = @add_2(x)
    end
    """
    uri = URI("file:///renmacro/src/RenMacro.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # Renaming from the definition and from an invocation must behave the same.
    for (line, col) in ((2, 7), (5, 8))
        idx = string_index(source, line, col)

        # The macro binding has one definition + two invocations = 3 occurrences,
        # each emitted exactly once (no duplicate for the definition).
        refs = get_references(jw, uri, idx)
        @test length(refs) == 3

        # Client may send the new name with or without the leading `@`.
        for new_name in ("@sub_2", "sub_2")
            edits = get_rename_edits(jw, uri, idx, new_name)
            @test length(edits) == 3

            # Definition edit (line 2): bare name, no `@`.
            def_edits = filter(e -> e.start.line == 2, edits)
            @test length(def_edits) == 1
            @test def_edits[1].new_text == "sub_2"

            # Invocation edits (lines 5 and 6): keep the leading `@`.
            inv_edits = filter(e -> e.start.line != 2, edits)
            @test length(inv_edits) == 2
            @test all(e -> e.new_text == "@sub_2", inv_edits)
        end
    end
end

@testitem "References: rename an enum member touches only that member" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_rename_edits, get_references
    using JuliaWorkspaces.URIs2: URI

    # An `@enum` declares the type AND every member from one statement, so they
    # share a walker id (and thus an `ItemRef`). References/rename must still
    # resolve to the specific member by name — renaming `green` must not rewrite
    # the enum type `Color` or a sibling member `red`.
    source = """
    module EnumRen
    @enum Color red green blue
    f() = green
    g() = (red, green)
    h() = Color
    end
    """
    uri = URI("file:///enumren/src/EnumRen.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # `green`: declaration in the `@enum` (line 2) + two uses (f, g) = 3.
    lines = split(source, '\n')
    enum_line = 2
    gcol = first(findfirst("green", lines[enum_line]))
    gidx = string_index(source, enum_line, gcol)

    refs = get_references(jw, uri, gidx)
    @test length(refs) == 3

    edits = get_rename_edits(jw, uri, gidx, "verde")
    @test length(edits) == 3
    @test all(e -> e.new_text == "verde", edits)
    # Every edited range must currently span the text "green" — never `Color`
    # (line 5) or the sibling member `red` (line 3). Position is 1-based.
    for e in edits
        line_text = lines[e.start.line]
        @test line_text[e.start.column:(e.stop.column - 1)] == "green"
    end
end

@testitem "References: rename a tuple-destructure name touches only that name" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_rename_edits, get_references
    using JuliaWorkspaces.URIs2: URI

    # `a, b = …` at module level declares both names from one statement, so they
    # share a walker id (and `ItemRef`), exactly like `@enum` members. Renaming
    # `a` must not rewrite the sibling `b`.
    source = """
    module TupRen
    a, b = 1, 2
    f() = a + b
    g() = b
    end
    """
    uri = URI("file:///tupren/src/TupRen.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    lines = split(source, '\n')
    # Query `b` — the SECOND name of the shared-id statement. `_inventory_item_name`
    # returns the first name (`a`), so the old id-only code would have resolved `b`
    # to `a`'s binding and rewritten `a`; the fix must target `b` only.
    # `b`: declaration (line 2) + two uses (f line 3, g line 4) = 3 occurrences.
    bcol = first(findfirst("b", lines[2]))
    bidx = string_index(source, 2, bcol)
    refs = get_references(jw, uri, bidx)
    @test length(refs) == 3

    edits = get_rename_edits(jw, uri, bidx, "bb")
    @test length(edits) == 3
    @test all(e -> e.new_text == "bb", edits)
    for e in edits
        line_text = lines[e.start.line]
        @test line_text[e.start.column:(e.stop.column - 1)] == "b"
    end
end

@testitem "References: highlight basic" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_highlights
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "HLTest"
    uuid = "42345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """

    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module HLTest
    x = 1
    y = x + 2
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///hltest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hltest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///hltest/src/HLTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///hltest/src/HLTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # "x" on line 3 (the usage) — should highlight the definition on line 2 (:write) and usage on line 3 (:read)
    idx = string_index(source, 3, 5)
    highlights = get_highlights(jw, uri, idx)
    @test length(highlights) >= 2
    @test any(h -> h.kind == :write, highlights)
    @test any(h -> h.kind == :read, highlights)
end

@testitem "References: can_rename basic" begin
    using JuliaWorkspaces: JuliaWorkspaces, JuliaWorkspace, add_file!, TextFile, SourceText, can_rename
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "CanRenTest"
    uuid = "52345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """

    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module CanRenTest
    func(arg) = 1
    func()
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///canrentest/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///canrentest/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///canrentest/src/CanRenTest.jl"), SourceText(source, "julia")))

    uri = URI("file:///canrentest/src/CanRenTest.jl")

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # "func" on line 3 — should be renamable
    idx = string_index(source, 3, 1)
    result = can_rename(jw, uri, idx)
    @test result !== nothing
    @test result.start isa JuliaWorkspaces.Position
    @test result.stop isa JuliaWorkspaces.Position
    @test (result.stop.line, result.stop.column) > (result.start.line, result.start.column)
end

@testitem "References: empty results on whitespace" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_definitions, get_highlights, get_references
    using JuliaWorkspaces.URIs2: URI

    project_toml = """
    name = "EmptyRef"
    uuid = "62345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """

    manifest_toml = """
    # This file is machine-generated - editing it directly is not advised

    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    source = """
    module EmptyRef
    x = 1
    end
    """

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///emptyref/Project.toml"), SourceText(project_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///emptyref/Manifest.toml"), SourceText(manifest_toml, "toml")))
    add_file!(jw, TextFile(URI("file:///emptyref/src/EmptyRef.jl"), SourceText(source, "julia")))

    uri = URI("file:///emptyref/src/EmptyRef.jl")

    # Beginning of file — should return empty results
    refs = get_references(jw, uri, 1)
    @test isempty(refs)

    defs = get_definitions(jw, uri, 1)
    @test isempty(defs)

    highlights = get_highlights(jw, uri, 1)
    @test isempty(highlights)
end

@testitem "References: definition of reassigned local (issue #101)" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_definitions
    using JuliaWorkspaces.URIs2: URI

    # A local reassigned inside a (soft) loop scope is a single variable; every
    # occurrence of `a` should resolve go-to-definition to the original
    # declaration `a = 0`, not the loop reassignment `a = x`.
    source = "function foo()\n    a = 0\n    for x in [1, 2, 3]\n        a = x\n    end\n    a\nend\n"
    uri = URI("file:///reassign.jl")

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(uri, SourceText(source, "julia")))

    function string_index(src, line, col)
        lines = split(src, '\n')
        off = 0
        for l in 1:(line - 1)
            off += ncodeunits(lines[l]) + 1
        end
        return off + col
    end

    # (line, col) of `a` at: the declaration, the loop reassignment, the use.
    for (line, col) in ((2, 5), (4, 9), (6, 5))
        idx = string_index(source, line, col)
        defs = get_definitions(jw, uri, idx)
        @test length(defs) == 1
        @test defs[1].uri == uri
        @test defs[1].start.line == 2      # the `a = 0` line (1-based)
        @test defs[1].start.column == 5    # the `a`
    end
end

@testsnippet DefCrossWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_definitions
    using JuliaWorkspaces.URIs2: URI

    const DEF_PROJECT_TOML = """
    name = "DefCross"
    uuid = "e2345678-1234-1234-1234-123456789abc"
    version = "0.1.0"
    """
    const DEF_MANIFEST_TOML = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    const DEF_ENTRY_URI = URI("file:///defcross/src/DefCross.jl")
    const DEF_A_URI = URI("file:///defcross/src/a.jl")
    const DEF_B_URI = URI("file:///defcross/src/b.jl")

    # A three-file package: `b.jl` references names DECLARED in the sibling
    # `a.jl`, which per-file mode resolves as plain-data `TreeRef`s.
    function defcross_workspace(a_src::String, b_src::String)
        entry = """
        module DefCross
        include("a.jl")
        include("b.jl")
        end
        """
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///defcross/Project.toml"), SourceText(DEF_PROJECT_TOML, "toml")))
        add_file!(jw, TextFile(URI("file:///defcross/Manifest.toml"), SourceText(DEF_MANIFEST_TOML, "toml")))
        add_file!(jw, TextFile(DEF_ENTRY_URI, SourceText(entry, "julia")))
        add_file!(jw, TextFile(DEF_A_URI, SourceText(a_src, "julia")))
        add_file!(jw, TextFile(DEF_B_URI, SourceText(b_src, "julia")))
        return jw
    end
end

@testitem "Definitions: cross-file function lands at all method locations" setup=[DefCrossWS] begin
    a_src = """
    greet(name) = 1
    greet(first, last) = 2
    struct S
        x
    end
    """
    b_src = "caller(x) = greet(x)\n"
    jw = defcross_workspace(a_src, b_src)

    off = findfirst("greet(x)", b_src).start  # 1-based index of `greet`
    defs = get_definitions(jw, DEF_B_URI, off)

    # Both methods of `greet` are offered, both located in the defining file.
    @test length(defs) == 2
    @test all(d -> d.uri == DEF_A_URI, defs)

    # Ground truth: the two method items' offsets via derived_item_positions.
    rt = jw.runtime
    root = JuliaWorkspaces.derived_best_root_for_uri(rt, DEF_B_URI)
    qroot = JuliaWorkspaces._method_items_root(rt, root, ["DefCross"])
    refs = JuliaWorkspaces.derived_method_items(rt, qroot, ["DefCross"], "greet")
    pos = JuliaWorkspaces.derived_item_positions(rt, DEF_A_URI)
    expected = sort([JuliaWorkspaces._offset_to_position(rt, DEF_A_URI, pos[r.id].offset) for r in refs], by = p -> (p.line, p.column))
    got = sort([d.start for d in defs], by = p -> (p.line, p.column))
    @test got == expected
end

@testitem "Definitions: cross-file struct without constructors lands at its declaration" setup=[DefCrossWS] begin
    a_src = """
    greet(name) = 1
    struct S
        x
    end
    """
    b_src = "maker() = S(1)\n"
    jw = defcross_workspace(a_src, b_src)

    # A struct with no outer constructors: exactly one location (byte-identical
    # to a single-item resolution; the method-items selector returns just it).
    off = findfirst("S(1)", b_src).start
    defs = get_definitions(jw, DEF_B_URI, off)
    @test length(defs) == 1
    @test defs[1].uri == DEF_A_URI
    @test defs[1].start.line == 2   # `struct S` on line 2 of a.jl
end

@testitem "Definitions: cross-file struct offers its constructor locations" setup=[DefCrossWS] begin
    # F12 on a struct call offers the declaration AND its outer constructors,
    # exactly as F12 on a function offers all its methods (old whole-closure
    # parity: `_get_definitions_from_val(::Binding)` walked a DataType binding's
    # refs/get_method just like a Function).
    a_src = """
    struct S
        x
    end
    S(a, b) = S(a + b)
    """
    b_src = "maker() = S(1)\n"
    jw = defcross_workspace(a_src, b_src)

    off = findfirst("S(1)", b_src).start
    defs = get_definitions(jw, DEF_B_URI, off)
    @test length(defs) == 2
    @test all(d -> d.uri == DEF_A_URI, defs)
    lines = sort([d.start.line for d in defs])
    @test lines == [1, 4]   # `struct S` (line 1) + `S(a, b) = ...` (line 4)

    # Ground truth: the two datatype items via derived_method_items.
    rt = jw.runtime
    root = JuliaWorkspaces.derived_best_root_for_uri(rt, DEF_B_URI)
    qroot = JuliaWorkspaces._method_items_root(rt, root, ["DefCross"])
    refs = JuliaWorkspaces.derived_method_items(rt, qroot, ["DefCross"], "S")
    @test length(refs) == 2
end

@testitem "Definitions: a file-local binding shadows a sibling name" setup=[DefCrossWS] begin
    a_src = "greet(name) = 1\n"
    b_src = """
    function shadow()
        greet = 99
        return greet
    end
    """
    jw = defcross_workspace(a_src, b_src)

    # `greet` in `return greet` resolves to the local assignment, not a.jl.
    off = findlast("greet", b_src).start
    defs = get_definitions(jw, DEF_B_URI, off)
    @test length(defs) == 1
    @test defs[1].uri == DEF_B_URI
    @test defs[1].start.line == 2   # `greet = 99` on line 2 of b.jl
end

@testitem "Definitions: qualified sibling-module member resolves cross-file" setup=[DefCrossWS] begin
    a_src = """
    module Sib
    export f
    f() = 1
    end
    """
    b_src = """
    using .Sib
    g() = Sib.f()
    """
    jw = defcross_workspace(a_src, b_src)

    off = findfirst("Sib.f()", b_src).start + 4  # index of `f` in `Sib.f()`
    defs = get_definitions(jw, DEF_B_URI, off)
    @test length(defs) == 1
    @test defs[1].uri == DEF_A_URI
    @test defs[1].start.line == 3   # `f() = 1` on line 3 of a.jl
end

@testitem "Definitions: local target resolves through the expr-uri map" setup=[DefCrossWS] begin
    # Rule 3: per-file meta EXPRs belong to the same CST objects
    # `derived_expr_uri_map` indexes, so `_get_file_loc` works for local
    # (same-file, Binding-resolved) targets. Assert both the resolution AND the
    # map indexing invariant it relies on.
    a_src = "greet(name) = 1\n"
    b_src = """
    function withlocal()
        v = 10
        return v
    end
    """
    jw = defcross_workspace(a_src, b_src)

    off = findlast("v", b_src).start
    defs = get_definitions(jw, DEF_B_URI, off)
    @test length(defs) == 1
    @test defs[1].uri == DEF_B_URI
    @test defs[1].start.line == 2   # `v = 10`

    # The per-file meta's CST root IS the object the expr-uri map indexes.
    rt = jw.runtime
    cst = JuliaWorkspaces.derived_julia_legacy_syntax_tree(rt, DEF_B_URI)
    m = JuliaWorkspaces.derived_expr_uri_map(rt)
    @test get(m, objectid(cst), nothing) == DEF_B_URI
end

# ============================================================================
# References aggregation over per-file outbound tables (M4 Task 7)
# ============================================================================

@testsnippet RefAggWS begin
    using JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText,
        get_references, get_rename_edits, get_highlights
    using JuliaWorkspaces.URIs2: URI

    const RA_MANIFEST = """
    julia_version = "1.11.0"
    manifest_format = "2.0"
    project_hash = "abc123"

    [deps]
    """

    # A single-project package with `files` (uri => src) plus a generated entry
    # file that `include`s them in order.
    function refagg_workspace(name::String, uuid::String, entry_body::String, files::Vector{Pair{URI,String}})
        jw = JuliaWorkspace()
        add_file!(jw, TextFile(URI("file:///$name/Project.toml"),
            SourceText("name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n", "toml")))
        add_file!(jw, TextFile(URI("file:///$name/Manifest.toml"), SourceText(RA_MANIFEST, "toml")))
        add_file!(jw, TextFile(URI("file:///$name/src/$name.jl"), SourceText(entry_body, "julia")))
        for (u, s) in files
            add_file!(jw, TextFile(u, SourceText(s, "julia")))
        end
        return jw
    end

    refset(jw, uri, idx) = sort([(string(r.uri), r.start.line, r.start.column) for r in get_references(jw, uri, idx)])
    renset(jw, uri, idx, nn) = sort([(string(e.uri), e.start.line, e.start.column, e.new_text) for e in get_rename_edits(jw, uri, idx, nn)])
end

@testitem "References: sibling-declared function across 3 files (target-join)" setup=[RefAggWS] begin
    A = URI("file:///RA1/src/a.jl")
    B = URI("file:///RA1/src/b.jl")
    C = URI("file:///RA1/src/c.jl")
    jw = refagg_workspace("RA1", "11111111-1234-1234-1234-123456789abc",
        "module RA1\ninclude(\"a.jl\")\ninclude(\"b.jl\")\ninclude(\"c.jl\")\nend\n",
        [A => "greet(name) = 1\ngreet(first, last) = 2\n",
         B => "caller(x) = greet(x)\n",
         C => "other() = greet(3)\n"])

    # The exact set (captured from the OLD whole-closure path before the switch):
    # both method declarations in a.jl + the two cross-file call sites.
    expected = [("file:///RA1/src/a.jl", 1, 1), ("file:///RA1/src/a.jl", 2, 1),
                ("file:///RA1/src/b.jl", 1, 13), ("file:///RA1/src/c.jl", 1, 11)]
    # Same result no matter which occurrence the cursor starts on.
    @test refset(jw, B, findfirst("greet(x)", "caller(x) = greet(x)\n").start) == expected
    @test refset(jw, A, 1) == expected                       # from a declaration
    @test refset(jw, C, findfirst("greet", "other() = greet(3)\n").start) == expected
end

@testitem "References: alias `f as g` includes the g-call sites (target-join)" setup=[RefAggWS] begin
    SIB = URI("file:///RA2/src/sib.jl")
    USE = URI("file:///RA2/src/use.jl")
    sib = "module Sib\nexport f\nf() = 1\nend\n"
    use = "using .Sib: f as g\nh() = g() + g()\n"
    jw = refagg_workspace("RA2", "22222222-1234-1234-1234-123456789abc",
        "module RA2\ninclude(\"sib.jl\")\ninclude(\"use.jl\")\nend\n",
        [SIB => sib, USE => use])

    refs = refset(jw, SIB, findfirst("f()", sib).start)
    # The outbound rows for the `g` uses carry `f`'s ItemRef as target (join on
    # target, not name), so references of `f` reach the `g`-call sites — which
    # the old whole-closure pass missed. Declaration + export in sib.jl, and in
    # use.jl the import source `f`, the alias `g`, and both `g()` calls.
    @test ("file:///RA2/src/sib.jl", 3, 1) in refs      # f() = 1
    @test ("file:///RA2/src/sib.jl", 2, 8) in refs      # export f
    @test ("file:///RA2/src/use.jl", 1, 13) in refs     # `f` in `using .Sib: f as g`
    @test ("file:///RA2/src/use.jl", 2, 7) in refs      # first g()
    @test ("file:///RA2/src/use.jl", 2, 13) in refs     # second g()
    @test length(refs) == 6
end

@testitem "References: enum member across files stays disjoint from the type" setup=[RefAggWS] begin
    SIB = URI("file:///RAEnum/src/sib.jl")
    USE = URI("file:///RAEnum/src/use.jl")
    sib = "module EnumSib\n@enum Color red green blue\nend\n"
    use = "using .EnumSib: green, Color\nh() = green\nk() = Color\n"
    jw = refagg_workspace("RAEnum", "55555555-1234-1234-1234-123456789abc",
        "module RAEnum\ninclude(\"sib.jl\")\ninclude(\"use.jl\")\nend\n",
        [SIB => sib, USE => use])

    # The `@enum` type and every member share one walker id (one `ItemRef`).
    # Cross-file, the outbound name filter must keep `green` references disjoint
    # from `Color` references — the exact branch this fix added.
    green_refs = refset(jw, USE, findfirst("green", use).start)
    color_refs = refset(jw, USE, findfirst("Color", use).start)

    @test isempty(intersect(Set(green_refs), Set(color_refs)))
    @test ("file:///RAEnum/src/use.jl", 2, 7) in green_refs   # `green` in h()
    @test !(("file:///RAEnum/src/use.jl", 2, 7) in color_refs)
    @test ("file:///RAEnum/src/use.jl", 3, 7) in color_refs   # `Color` in k()
    @test !(("file:///RAEnum/src/use.jl", 3, 7) in green_refs)
end

@testitem "References: rename a module-level function edits all files, not the alias" setup=[RefAggWS] begin
    SIB = URI("file:///RA3/src/sib.jl")
    USE = URI("file:///RA3/src/use.jl")
    sib = "module Sib\nexport f\nf() = 1\nend\n"
    use = "using .Sib: f as g\nh() = g() + g()\n"
    jw = refagg_workspace("RA3", "33333333-1234-1234-1234-123456789abc",
        "module RA3\ninclude(\"sib.jl\")\ninclude(\"use.jl\")\nend\n",
        [SIB => sib, USE => use])

    edits = renset(jw, SIB, findfirst("f()", sib).start, "xyz")
    # Rename edits only the SOURCE-name occurrences (incl. the `as`-alias
    # statement's `f`), never the alias `g` uses — renaming those would corrupt
    # the alias. Matches the old rename's source-name-only behavior.
    @test edits == [("file:///RA3/src/sib.jl", 2, 8, "xyz"),
                    ("file:///RA3/src/sib.jl", 3, 1, "xyz"),
                    ("file:///RA3/src/use.jl", 1, 13, "xyz")]
end

@testitem "References: rename a cross-file function edits every call site" setup=[RefAggWS] begin
    A = URI("file:///RA4/src/a.jl")
    B = URI("file:///RA4/src/b.jl")
    jw = refagg_workspace("RA4", "44444444-1234-1234-1234-123456789abc",
        "module RA4\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        [A => "greet(name) = 1\n", B => "p() = greet(1)\nq() = greet(2)\n"])

    edits = renset(jw, B, findfirst("greet", "p() = greet(1)\nq() = greet(2)\n").start, "hello")
    @test all(e -> e[4] == "hello", edits)
    @test ("file:///RA4/src/a.jl", 1, 1, "hello") in edits
    @test ("file:///RA4/src/b.jl", 1, 7, "hello") in edits
    @test ("file:///RA4/src/b.jl", 2, 7, "hello") in edits
    @test length(edits) == 3
end

@testitem "References: highlights of a module-level name stay current-file" setup=[RefAggWS] begin
    A = URI("file:///RA5/src/a.jl")
    B = URI("file:///RA5/src/b.jl")
    a = "greet(name) = 1\ncaller() = greet(0)\n"
    jw = refagg_workspace("RA5", "55555555-1234-1234-1234-123456789abc",
        "module RA5\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        [A => a, B => "other() = greet(9)\n"])

    # Highlights of `greet` from a.jl show a.jl's declaration + a.jl's use
    # ONLY — never b.jl's cross-file call (highlights stay current-file).
    hls = get_highlights(jw, A, findfirst("greet(0)", a).start)
    @test length(hls) == 2
    @test all(h -> h.kind in (:read, :write), hls)
    # And from the referencing file, only that file's own call is highlighted.
    hlb = get_highlights(jw, B, findfirst("greet", "other() = greet(9)\n").start)
    @test length(hlb) == 1
end

@testitem "References: file-local variable references stay current-file" setup=[RefAggWS] begin
    A = URI("file:///RA6/src/a.jl")
    B = URI("file:///RA6/src/b.jl")
    b = "function shadow()\n    greet = 99\n    return greet\nend\n"
    jw = refagg_workspace("RA6", "66666666-1234-1234-1234-123456789abc",
        "module RA6\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n",
        [A => "greet(name) = 1\n", B => b])

    # The local `greet` (shadowing the sibling function) resolves only to its
    # two in-function occurrences — never a.jl's declaration.
    refs = refset(jw, B, findlast("greet", b).start)
    @test refs == [("file:///RA6/src/b.jl", 2, 5), ("file:///RA6/src/b.jl", 3, 12)]
end

@testitem "References: two-root deved package found from both roots" setup=[RefAggWS] begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_references
    using JuliaWorkspaces.URIs2: URI

    MP = URI("file:///wsp2/Main/src/MainP.jl")
    BP = URI("file:///wsp2/B/src/B.jl")
    main = "module MainP\nusing B\nf() = myfunc(1, 2)\ng() = B.myfunc(3, 4)\nend\n"
    bmod = "module B\nexport myfunc\nmyfunc(alpha, beta) = 1\nend\n"

    jw = JuliaWorkspace()
    add_file!(jw, TextFile(URI("file:///wsp2/Main/Project.toml"),
        SourceText("name = \"MainP\"\nuuid = \"77777777-1234-1234-1234-123456789abc\"\nversion = \"0.1.0\"\n", "toml")))
    add_file!(jw, TextFile(URI("file:///wsp2/Main/Manifest.toml"),
        SourceText("julia_version = \"1.11.0\"\nmanifest_format = \"2.0\"\nproject_hash = \"abc\"\n\n[deps]\n", "toml")))
    add_file!(jw, TextFile(MP, SourceText(main, "julia")))
    add_file!(jw, TextFile(URI("file:///wsp2/B/Project.toml"),
        SourceText("name = \"B\"\nuuid = \"88888888-1234-1234-1234-123456789abc\"\nversion = \"0.1.0\"\n", "toml")))
    add_file!(jw, TextFile(BP, SourceText(bmod, "julia")))

    rs(uri, idx) = sort([(string(r.uri), r.start.line, r.start.column) for r in get_references(jw, uri, idx)])
    # A single query returns B's declaration/export AND MainP's use sites — the
    # consuming root reaches the package by `import`, not `include`, so the
    # aggregation scans all workspace roots (not just include-reachable ones).
    expected = [("file:///wsp2/B/src/B.jl", 2, 8), ("file:///wsp2/B/src/B.jl", 3, 1),
                ("file:///wsp2/Main/src/MainP.jl", 3, 7), ("file:///wsp2/Main/src/MainP.jl", 4, 9)]
    @test rs(BP, findfirst("myfunc(alpha", bmod).start) == expected      # from B's decl
    @test rs(MP, findfirst("myfunc(1", main).start) == expected          # from MainP's use
end

@testitem "Definitions: workspace overload of a store-backed function is offered" setup=[DefCrossWS] begin
    # The sibling a.jl extends Base's `relpath`; go-to-definition on the call
    # must offer that workspace overload (the env store's method set misses it).
    a_src = "struct P end\nBase.relpath(x::AbstractString, p::P) = x\n"
    b_src = "caller(x, p) = relpath(x, p)\n"
    jw = defcross_workspace(a_src, b_src)

    off = findfirst("relpath(x, p)", b_src).start
    defs = get_definitions(jw, DEF_B_URI, off)
    # the overload is defined on line 2 of a.jl
    @test any(d -> d.uri == DEF_A_URI && d.start.line == 2, defs)
end

@testitem "Definitions: length resolves Base-submodule method locations" begin
    using JuliaWorkspaces: JuliaWorkspace, add_file!, TextFile, SourceText, get_definitions
    using JuliaWorkspaces.URIs2: URI
    uri = URI("file:///nav/Foo.jl")
    jw = JuliaWorkspace()
    src = "module Foo\nlength([])\nend\n"
    add_file!(jw, TextFile(uri, SourceText(src, "julia")))
    defs = get_definitions(jw, uri, first(findfirst("length", src)))
    @test length(defs) > 62
end
