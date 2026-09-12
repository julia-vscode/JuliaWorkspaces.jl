# The v2 test item detection, behind `input_v2_enabled`: the twin of
# `derived_testitems` (layer_testitems.jl gates to it). Detection comes off
# the v2 skeleton (`derived_v2_file_testitems`), so position-only and body
# edits backdate instead of re-detecting; everything below detection is the
# same assembly as v1's, copied here as `_assemble_test_details` over the
# `RawTest*Detail` records of main's fused parse (layer_parse_products.jl).

"""
    _assemble_test_details(rt, uri, text, testitems, testsetups, testerrors) -> TestDetails

Everything below the detection step — the outside-package check, id minting,
duplicate-label errors, and the `code`/skip slicing — a verbatim copy of the
second half of `derived_testitems` (the v1 query keeps its inlined original). Inputs are `RawTest*Detail`-shaped records whose ranges are
string-index ranges with an inclusive end.
"""
function _assemble_test_details(rt, uri, text, testitems, testsetups, testerrors)
    package_uri = derived_package_for_file(rt, uri)

    if isnothing(package_uri) && (!isempty(testitems) || !isempty(testsetups))
        all_testerrors = [
            TestErrorDetail(
                uri,
                "$uri:error$i",
                string(te.name),
                te.message,
                te.range
            ) for (i,te) in enumerate(testerrors)
        ]

        error_offset = length(testerrors)

        for (i, ti) in enumerate(testitems)
            push!(all_testerrors, TestErrorDetail(
                uri,
                "$uri:error$(error_offset + i)",
                ti.name,
                "Test items must be defined inside a Julia package.",
                ti.range
            ))
        end

        for (i, ts) in enumerate(testsetups)
            push!(all_testerrors, TestErrorDetail(
                uri,
                "$uri:error$(error_offset + length(testitems) + i)",
                string(ts.name),
                "Test setups must be defined inside a Julia package.",
                ts.range
            ))
        end

        return TestDetails(
            TestItemDetail[],
            TestSetupDetail[],
            all_testerrors
        )
    end

    all_testerrors = TestErrorDetail[
        TestErrorDetail(
            uri,
            "$uri:error$i",
            string(te.name),
            te.message,
            te.range
        ) for (i,te) in enumerate(testerrors)
    ]

    # Ids are `<package>/<path relative to the package>::<label>`, so inserting a test
    # item above another one no longer renumbers it, and two packages that both contain
    # `test/runtests.jl` no longer mint the same id. A label used more than once in one
    # file is a definition error, but the run must still degrade rather than break, so
    # *every* occurrence gets a `#N` suffix — that keeps ids unique within the file,
    # keeps each item individually addressable, and makes the error state visible in
    # the id.
    relpath = testitem_id_scope(
        package_uri === nothing ? nothing : derived_package(rt, package_uri),
        package_uri,
        uri,
    )

    item_labels = String[ti.name for ti in testitems]
    item_counts = _label_counts(item_labels)
    seen_items = Dict{String,Int}()
    item_ids = Vector{String}(undef, length(testitems))

    for (i, label) in enumerate(item_labels)
        if item_counts[label] > 1
            occurrence = seen_items[label] = get(seen_items, label, 0) + 1
            item_ids[i] = "$relpath::$label#$occurrence"

            push!(all_testerrors, TestErrorDetail(
                uri,
                "$uri:error$(length(all_testerrors) + 1)",
                label,
                "The test item name \"$label\" is used more than once in this file. Test item names must be unique within a file.",
                testitems[i].range
            ))
        else
            item_ids[i] = "$relpath::$label"
        end
    end

    setup_counts = _label_counts(String[string(ts.name) for ts in testsetups])

    for ts in testsetups
        if setup_counts[string(ts.name)] > 1
            push!(all_testerrors, TestErrorDetail(
                uri,
                "$uri:error$(length(all_testerrors) + 1)",
                string(ts.name),
                "The test setup name `$(ts.name)` is used more than once in this file. Test setup names must be unique within a file.",
                ts.range
            ))
        end
    end

    return TestDetails(
        [TestItemDetail(
            uri,
            item_ids[i],
            ti.name,
            text[ti.code_range],
            ti.range,
            ti.code_range,
            ti.option_default_imports,
            ti.option_tags,
            ti.option_setup,
            ti.option_skip isa Bool ? ti.option_skip : text[ti.option_skip]
            ) for (i,ti) in enumerate(testitems)],
        [TestSetupDetail(
            uri,
            i.name,
            i.kind,
            text[i.code_range],
            i.range,
            i.code_range
            ) for i in testsetups],
        all_testerrors
    )
end

"""
    derived_testitems_v2(rt, uri) -> TestDetails

The v2 emission join (design doc §13): `derived_v2_file_testitems` carries the
position-free facts, and this query — mirroring `derived_semantic_lint_findings`
— reattaches what only positions can provide: `range`, `code_range`, the `code`
slice, and a non-literal skip expression's source text. Volatile by design; it
is one of the two legitimate readers of `derived_v2_file_maps`.

Lives here rather than in `src/v2/` because ids and the outside-package check
need `derived_package_for_file` and `testitem_id_scope`, which the v2 layer must
not touch.
"""
Salsa.@derived function derived_testitems_v2(rt, uri)
    @debug "derived_testitems_v2" uri=uri

    if !derived_testitems_selected(rt, uri)
        return TestDetails(TestItemDetail[], TestSetupDetail[], TestErrorDetail[])
    end

    recs = derived_v2_file_testitems(rt, uri)
    if isempty(recs.testitems) && isempty(recs.testerrors)
        return TestDetails(TestItemDetail[], TestSetupDetail[], TestErrorDetail[])
    end

    # The Julia view, not the raw content: code slices for a markdown document
    # must be the blanked view the parse saw (see derived_testitems).
    text = derived_julia_source_view(rt, uri)
    maps = derived_v2_file_maps(rt, uri)
    bodies = derived_v2_file_bodies(rt, uri)

    # Map ranges are byte ranges with an exclusive end; the raw detail shape
    # wants string-index ranges with an inclusive end (`our_range`).
    incl(r) = first(r):prevind(text, last(r))

    testitems = RawTestItemDetail[]
    testsetups = RawTestSetupDetail[]
    for t in recs.testitems
        rngs = get(maps, t.id, nothing)
        body = get(bodies, t.id, nothing)
        (rngs === nothing || body === nothing) && continue
        addrs = _v2_test_macro_addresses(body)
        addrs === nothing && continue

        range = incl(rngs[1])
        code_range = if addrs.block_first === nothing
            # The legacy shape for `begin end`: skip past the keywords.
            block = incl(rngs[addrs.block])
            (first(block) + 5):(last(block) - 3)
        else
            first(rngs[addrs.block_first]):last(incl(rngs[addrs.block_last]))
        end

        if t.kind === :testitem
            skip = if t.option_skip === nothing
                addrs.skip_value === nothing ? false : incl(rngs[addrs.skip_value])
            else
                t.option_skip
            end
            push!(testitems, RawTestItemDetail(
                t.label, range, code_range, t.option_default_imports,
                t.option_tags, t.option_setup, skip))
        else
            push!(testsetups, RawTestSetupDetail(
                Symbol(t.label), t.kind === :testsetup_module ? :module : :snippet,
                range, code_range))
        end
    end

    testerrors = RawTestErrorDetail[
        RawTestErrorDetail(e.name, e.message, incl(maps[e.id][1]))
        for e in recs.testerrors if haskey(maps, e.id)]

    return _assemble_test_details(rt, uri, text, testitems, testsetups, testerrors)
end
