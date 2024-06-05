@testitem "SourceText constructor no eol" begin
    st = SourceText("asdf", "julia")

    @test st.content == "asdf"
    @test st.language_id == "julia"
    @test st.line_indices == [1]
end

@testitem "SourceText constructor eol in middle" begin
    st = SourceText("asdf\nasdf\nasdf", "julia")

    @test st.content == "asdf\nasdf\nasdf"
    @test st.language_id == "julia"
    @test st.line_indices == [1,6,11]
end

@testitem "SourceText constructor eol at end" begin
    st = SourceText("asdf\nasdf\nasdf\n", "julia")

    @test st.content == "asdf\nasdf\nasdf\n"
    @test st.language_id == "julia"
    @test st.line_indices == [1,6,11,16]
end

@testitem "SourceText constructor win eol in middle" begin
    st = SourceText("asdf\r\nasdf\r\nasdf", "julia")

    @test st.content == "asdf\r\nasdf\r\nasdf"
    @test st.language_id == "julia"
    @test st.line_indices == [1,7,13]
end

@testitem "SourceText constructor win eol at end" begin
    st = SourceText("asdf\r\nasdf\r\nasdf\r\n", "julia")

    @test st.content == "asdf\r\nasdf\r\nasdf\r\n"
    @test st.language_id == "julia"
    @test st.line_indices == [1,7,13,19]
end

@testitem "Test with_change with no TextChange" begin
    st = SourceText("asdf\nasdf\nasdf\n", "julia")

    st2 = with_changes(st, TextChange[], "julia")

    @test st.content == st2.content
    @test st.language_id == st2.language_id
    @test st.line_indices == st2.line_indices
end

@testitem "Test with_change with empty TextChange" begin
    st = SourceText("asdf\nasdf\nasdf\n", "julia")

    st2 = with_changes(st, [TextChange(1:0, "")], "julia")

    @test st.content == st2.content
    @test st.language_id == st2.language_id
    @test st.line_indices == st2.line_indices
end

@testitem "Test with_change with insert TextChange at beginning" begin
    st = SourceText("asdf\nasdf\nasdf\n", "julia")

    st2 = with_changes(st, [TextChange(1:0, "uiop")], "julia")

    @test st2.content == "uiopasdf\nasdf\nasdf\n"
end

@testitem "Test with_change with insert TextChange at end" begin
    st = SourceText("asdf\nasdf\nasdf\n", "julia")

    st2 = with_changes(st, [TextChange(16:0, "uiop")], "julia")

    @test st2.content == "asdf\nasdf\nasdf\nuiop"
end

@testitem "Test with_change with insert TextChange in middle" begin
    st = SourceText("asdf\nasdf\nasdf\n", "julia")

    st2 = with_changes(st, [TextChange(7:6, "uiop")], "julia")

    @test st2.content == "asdf\nauiopsdf\nasdf\n"
end

@testitem "Test with_change with replace TextChange at beginning" begin
    st = SourceText("asdf\nasdf\nasdf\n", "julia")

    st2 = with_changes(st, [TextChange(1:2, "uiop")], "julia")

    @test st2.content == "uiopdf\nasdf\nasdf\n"
end

@testitem "Test with_change with replace TextChange at end" begin
    st = SourceText("asdf\nasdf\nasdf\n", "julia")

    st2 = with_changes(st, [TextChange(7:15, "uiop")], "julia")

    @test st2.content == "asdf\nauiop"
end

@testitem "Test with_change with replace TextChange in middle" begin
    st = SourceText("asdf\nasdf\nasdf\n", "julia")

    st2 = with_changes(st, [TextChange(7:9, "uiop")], "julia")

    @test st2.content == "asdf\nauiop\nasdf\n"
end