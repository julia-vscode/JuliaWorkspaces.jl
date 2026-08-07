using TestItemRunner

# Optional focused run: JW_TEST_FILTER=<substr> keeps only items whose name
# matches (the rclone workflow sets it to "cache-infra"). Empty runs everything.
const _JW_TEST_FILTER = get(ENV, "JW_TEST_FILTER", "")

# Items tagged `:integration` resolve real environments, so they need a registry
# and a warm depot. Off by default; set JW_RUN_INTEGRATION=1 to include them.
const _JW_RUN_INTEGRATION = get(ENV, "JW_RUN_INTEGRATION", "") != ""

@run_package_tests filter=ti ->
    !startswith(ti.filename, normpath(joinpath(@__DIR__, "..", "testdata"))) &&
    !startswith(ti.filename, joinpath(@__DIR__, "data")) &&
    !(:skip in ti.tags) &&
    (_JW_RUN_INTEGRATION || !(:integration in ti.tags)) &&
    (isempty(_JW_TEST_FILTER) || occursin(_JW_TEST_FILTER, ti.name))
