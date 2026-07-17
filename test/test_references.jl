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
