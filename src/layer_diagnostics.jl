function get_diagnostic(jw::JuliaWorkspace, uri::URI)
    syntax_diagnostics = derived_julia_syntax_diagnostics(jw.runtime, uri)
    testitem_diagnostics = [Diagnostic(i.range, :error, i.message, "Testitem") for i in derived_testitems(jw.runtime, uri).testerrors]
    return [syntax_diagnostics...; testitem_diagnostics...]
end
