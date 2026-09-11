# The fused JuliaSyntax parse (design doc §12.1).
#
# Three consumers used to run their own JuliaSyntax parse of every file on
# every pass: syntax diagnostics, test item detection and the syntax lint
# tier — measured at 10.4% of a cold pass. This query parses once and returns
# all three products; each consumer reads its slice through a selector query,
# so the products backdate independently even though the parse is shared.
#
# The tree itself is deliberately NOT part of the product (see the note at
# `parse_julia_syntax_tree`): a `SyntaxNode` never backdates and retains
# ~20× the source text. Only small, structurally comparable values leave
# this query.

# Typed plain-data capture of `TestItemDetection.find_test_detail!` output.
# Ranges are STRING-INDEX ranges with an inclusive end (`our_range`), unlike
# the byte/exclusive-end ranges used elsewhere — they are consumed by
# `derived_testitems`, which slices file text with them directly.
@auto_hash_equals struct RawTestItemDetail
    name::String
    range::UnitRange{Int64}
    code_range::UnitRange{Int64}
    option_default_imports::Bool
    option_tags::Vector{Symbol}
    option_setup::Vector{Symbol}
    option_skip::Union{Bool,UnitRange{Int64}}   # range = source of a non-literal skip expression
end

@auto_hash_equals struct RawTestSetupDetail
    name::Symbol
    kind::Symbol            # :module | :snippet
    range::UnitRange{Int64}
    code_range::UnitRange{Int64}
end

@auto_hash_equals struct RawTestErrorDetail
    name::String
    message::String
    range::UnitRange{Int64}
end

@auto_hash_equals struct RawTestDetails
    testitems::Vector{RawTestItemDetail}
    testsetups::Vector{RawTestSetupDetail}
    testerrors::Vector{RawTestErrorDetail}
end

# A PLAIN struct with `===` equality, like `V2FileWalk`: the bundle always
# differs after a reparse, so early cutoff happens in the selectors below,
# never here.
struct JuliaParseProducts
    syntax_diagnostics::Vector{Diagnostic}
    raw_test_details::RawTestDetails
    syntax_findings::Vector{LintFinding}   # ALL syntax rules, unfiltered
end

Salsa.@derived function derived_julia_parse_products(rt, uri)
    @debug "derived_julia_parse_products" uri=uri

    tf = derived_text_file_content(rt, uri)
    content = tf.content.content

    tree, syntax_diagnostics = parse_julia_syntax_tree(content)

    diag_results = map(syntax_diagnostics) do i
        Diagnostic(
            _range(i),
            i.level,
            i.message,
            nothing,
            Symbol[],
            "JuliaSyntax.jl"
        )
    end

    testitems = []
    testsetups = []
    testerrors = []
    TestItemDetection.find_test_detail!(tree, testitems, testsetups, testerrors)

    raw_test_details = RawTestDetails(
        [RawTestItemDetail(string(ti.name), ti.range, ti.code_range,
                           ti.option_default_imports, ti.option_tags,
                           ti.option_setup, ti.option_skip) for ti in testitems],
        [RawTestSetupDetail(ts.name, ts.kind, ts.range, ts.code_range) for ts in testsetups],
        [RawTestErrorDetail(string(te.name), te.message, te.range) for te in testerrors],
    )

    # Every check runs, unconditionally: they are cheap walks over the tree the
    # parse already paid for, and running them all keeps this query independent
    # of the lint configuration — a config edit backdates in the filtering
    # selector (`derived_syntax_lint_findings`) and never reaches the parse.
    syntax_findings = run_syntax_rules(tree, SYNTAX_CHECK_RULE_IDS, SyntaxRuleContext(uri))

    return JuliaParseProducts(diag_results, raw_test_details, syntax_findings)
end

Salsa.@derived function derived_raw_test_details(rt, uri)
    return derived_julia_parse_products(rt, uri).raw_test_details
end

Salsa.@derived function derived_all_syntax_lint_findings(rt, uri)
    return derived_julia_parse_products(rt, uri).syntax_findings
end
