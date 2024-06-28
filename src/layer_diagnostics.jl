function get_diagnostic(jw::JuliaWorkspace, uri::URI)
    return derived_julia_syntax_diagnostics(jw.runtime, uri)
end
