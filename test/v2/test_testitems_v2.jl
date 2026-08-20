# Unit tests for v2-native test item detection: the walker's `V2TestItem`
# records (layer_inventory_v2.jl) and the emission join
# `derived_v2_testitem_details` (layer_testitems.jl).
#
# Most cases run PARITY-style: the same source through the legacy
# (TestItemDetection) engine and the v2 engine, compared field for field. The
# legacy output is the specification; the differential over the package corpus
# lives in test_testitems_v2_differential.jl.

@testsnippet TestItemsV2Parity begin
    using JuliaWorkspaces
    const JW = JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace, TextFile, SourceText, add_file!, get_test_items
    using JuliaWorkspaces.URIs2: URI

    const PROJECT_TOML = """
    name = "MyPkg"
    uuid = "6c090b5c-8e37-4b6a-b4fc-a2a1e85ec9a5"
    version = "1.0.0"
    """

    function ti_make_jw(src; v2::Bool, in_package::Bool=true)
        jw = JuliaWorkspace()
        in_package && add_file!(jw, TextFile(URI("file:///pkg/Project.toml"),
            SourceText(PROJECT_TOML, "toml")))
        add_file!(jw, TextFile(URI("file:///pkg/src/a.jl"), SourceText(src, "julia")))
        v2 && JW.set_lowering_lint!(jw, true)
        return jw
    end

    "get_test_items through both engines; returns (legacy, v2)."
    function ti_both(src; in_package::Bool=true)
        uri = URI("file:///pkg/src/a.jl")
        return get_test_items(ti_make_jw(src; v2=false, in_package), uri),
               get_test_items(ti_make_jw(src; v2=true, in_package), uri)
    end

    function ti_assert_parity(src; in_package::Bool=true)
        legacy, v2 = ti_both(src; in_package)
        @test isequal(legacy.testitems, v2.testitems)
        @test isequal(legacy.testsetups, v2.testsetups)
        @test isequal(legacy.testerrors, v2.testerrors)
        return legacy
    end
end

@testitem "v2 test items: well-formed shapes match legacy byte for byte" setup=[TestItemsV2Parity] begin
    # The full kwarg set, non-literal skip, and a second item.
    r = ti_assert_parity("""
    @testitem "one" tags=[:a, :b] default_imports=false setup=[Setup] skip=x > 1 begin
        y = 1
        @test y == 1
    end
    @testmodule Setup begin
        z = 2
    end
    @testsnippet Snip begin end
    @testitem "two" begin
        @test true
    end
    """)
    @test length(r.testitems) == 2
    @test length(r.testsetups) == 2
    @test isempty(r.testerrors)
    @test r.testitems[1].option_skip == "x > 1"
    @test r.testitems[1].option_tags == [:a, :b]
    @test r.testitems[1].option_setup == [:Setup]
    @test r.testitems[1].option_default_imports == false

    # Empty blocks take the +5/-3 keyword-skipping code range.
    r = ti_assert_parity("@testitem \"empty\" begin end")
    @test length(r.testitems) == 1
    @test r.testitems[1].code == " "

    # skip as a literal Bool.
    ti_assert_parity("@testitem \"s\" skip=true begin end")
    ti_assert_parity("@testitem \"s\" skip=false begin end")

    # Items inside a module: parent module does not change detection.
    r = ti_assert_parity("""
    module Foo
    @testitem "inner" begin
        @test true
    end
    end
    """)
    @test length(r.testitems) == 1

    # An interpolated label takes its first literal chunk as the name.
    r = ti_assert_parity("@testitem \"lab \$x\" begin end")
    @test length(r.testitems) == 1
    @test r.testitems[1].name == "lab "
end

@testitem "v2 test items: every malformed shape matches legacy" setup=[TestItemsV2Parity] begin
    for src in [
        # @testitem shape errors
        "@testitem",
        "@testitem begin end",
        "@testitem 42 begin end",
        "@testitem \"noblock\"",
        "@testitem \"nb\" tags=[:a]",
        "@testitem \"x\" 42 begin end",
        # kwarg errors
        "@testitem \"x\" tags=[:a] tags=[:b] begin end",
        "@testitem \"x\" tags=:a begin end",
        "@testitem \"x\" tags=[a] begin end",
        "@testitem \"x\" default_imports=1 begin end",
        "@testitem \"x\" default_imports=true default_imports=false begin end",
        "@testitem \"x\" setup=Setup begin end",
        "@testitem \"x\" setup=[:Setup] begin end",
        "@testitem \"x\" setup=[A] setup=[B] begin end",
        "@testitem \"x\" skip=true skip=false begin end",
        "@testitem \"x\" skip=f() skip=g() begin end",
        "@testitem \"x\" foo=1 begin end",
        # @testmodule / @testsnippet shape errors
        "@testmodule",
        "@testmodule begin end",
        "@testmodule \"Str\" begin end",
        "@testmodule Name",
        "@testmodule Name tags=[:a] begin end",
        "@testsnippet 42 begin end",
        # duplicates
        "@testitem \"dup\" begin end\n@testitem \"dup\" begin end",
        "@testmodule Dup begin end\n@testmodule Dup begin end",
    ]
        ti_assert_parity(src)
    end
end

@testitem "v2 test items: outside-package errors match legacy" setup=[TestItemsV2Parity] begin
    ti_assert_parity("""
    @testitem "one" begin end
    @testmodule Setup begin end
    @testitem bad begin end
    """; in_package=false)
end

@testitem "v2 test items: multibyte text before and inside an item" setup=[TestItemsV2Parity] begin
    # α is 2 bytes: everything after it has byte index ≠ string index, so this
    # exercises the byte→string-index conversion in the join.
    r = ti_assert_parity("""
    # préfix α β
    @testitem "ünïcode" skip=α > 1 begin
        s = "αβγ"
        @test length(s) == 3
    end
    """)
    @test length(r.testitems) == 1
    @test r.testitems[1].option_skip == "α > 1"
end

@testitem "v2 test items: position-only and body edits backdate the records" setup=[TestItemsV2Parity] begin
    src = """
    @testitem "one" tags=[:a] begin
        y = 1
    end
    """
    uri = URI("file:///pkg/src/a.jl")
    jw = ti_make_jw(src; v2=true)
    recs1 = JW.derived_v2_file_testitems(jw.runtime, uri)
    @test length(recs1.testitems) == 1
    ref = JW.V2ItemRef(uri, recs1.testitems[1].id)
    hash1 = JW.derived_v2_item_body_hash(jw.runtime, ref)

    # Prepending a comment line shifts every position: the position-free
    # records are UNCHANGED, while the joined output shifts.
    JuliaWorkspaces.update_file!(jw, TextFile(uri, SourceText("# comment\n" * src, "julia")))
    recs2 = JW.derived_v2_file_testitems(jw.runtime, uri)
    @test isequal(recs1, recs2)
    joined = get_test_items(jw, uri)
    @test length(joined.testitems) == 1
    @test first(joined.testitems[1].range) == 1 + ncodeunits("# comment\n")

    # A body edit changes the item's body hash but not its record: the test
    # LIST backdates, and "did this test change?" is the hash query.
    JuliaWorkspaces.update_file!(jw, TextFile(uri, SourceText("# comment\n" * replace(src, "y = 1" => "y = 2"), "julia")))
    recs3 = JW.derived_v2_file_testitems(jw.runtime, uri)
    @test isequal(recs2, recs3)
    @test JW.derived_v2_item_body_hash(jw.runtime, ref) != hash1

    # An option edit is a real change and must NOT backdate.
    JuliaWorkspaces.update_file!(jw, TextFile(uri, SourceText(replace(src, "tags=[:a]" => "tags=[:b]"), "julia")))
    recs4 = JW.derived_v2_file_testitems(jw.runtime, uri)
    @test !isequal(recs3, recs4)
end

@testitem "v2 test items: JuliaTestItems.toml gating applies under the flag" setup=[TestItemsV2Parity] begin
    src = "@testitem \"one\" begin end"
    uri = URI("file:///pkg/src/a.jl")
    jw = ti_make_jw(src; v2=true)
    add_file!(jw, TextFile(URI("file:///pkg/JuliaTestItems.toml"),
        SourceText("exclude = [\"src/**\"]\n", "toml")))
    r = get_test_items(jw, uri)
    @test isempty(r.testitems) && isempty(r.testerrors)
end
