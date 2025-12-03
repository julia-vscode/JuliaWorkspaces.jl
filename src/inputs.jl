Salsa.@declare_input input_files(rt)::Set{URI}
Salsa.@declare_input input_text_file(rt, uri)::TextFile
Salsa.@declare_input input_notebook_file(rt, uri)::NotebookFile
Salsa.@declare_input input_fallback_test_project(rt)::Union{URI,Nothing}
Salsa.@declare_input input_project_environments(rt)::Set{URI}
Salsa.@declare_input input_project_environment(rt, uri)::StaticLint.ExternalEnv
