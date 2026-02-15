using JuliaWorkspaces

jw = JuliaWorkspaces.workspace_from_folders([joinpath(homedir(), ".julia/dev/CSTParser")], dynamic=true)
JuliaWorkspaces.set_input_active_project!(jw.runtime, JuliaWorkspaces.filepath2uri(joinpath(homedir(), ".julia/dev/CSTParser")))

add_folder_from_disc!(jw, joinpath(homedir(), ".julia/environments/v1.12"))
JuliaWorkspaces.set_input_active_project!(jw.runtime, JuliaWorkspaces.filepath2uri(joinpath(homedir(), ".julia/environments/v1.12")))


diags = get_diagnostics(jw)

for (uri,msgs) in pairs(diags)
    if length(msgs) > 0
        println("Diags for $(JuliaWorkspaces.uri2filepath(uri)):")
        for msg in msgs
            println("  $msg")
        end
    end
end
