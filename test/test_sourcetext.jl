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

@testitem "Test position_at start" begin
    st = SourceText("asdf\nasdf\nasdf\n", "julia")

    @test position_at(st, 1) == (1,1)
end

@testitem "Test position_at end" begin
    st = SourceText("asdf\nasdf\nasdf\n", "julia")

    @test position_at(st, 14) == (3,4)
end

@testitem "Test position_at mid" begin
    st = SourceText("asdf\nasdf\nasdf\n", "julia")

    @test position_at(st, 8) == (2,3)
end