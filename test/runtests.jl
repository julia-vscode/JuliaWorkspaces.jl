using TestItemRunner

@run_package_tests filter=ti->!startswith(ti.filename, joinpath(@__DIR__, "..", "testdata")) && !startswith(ti.filename, joinpath(@__DIR__, "data"))
