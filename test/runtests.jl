using TestItemRunner

# Optional focused run: JW_TEST_FILTER=<substr> keeps only items whose name
# matches (the rclone workflow sets it to "cache-infra"). Empty runs everything.
const _JW_TEST_FILTER = get(ENV, "JW_TEST_FILTER", "")

@run_package_tests filter=ti ->
    !startswith(ti.filename, joinpath(@__DIR__, "..", "testdata")) &&
    !startswith(ti.filename, joinpath(@__DIR__, "data")) &&
    (isempty(_JW_TEST_FILTER) || occursin(_JW_TEST_FILTER, ti.name))
