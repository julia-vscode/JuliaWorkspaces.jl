using JuliaWorkspaces

jw = JuliaWorkspaces.workspace_from_folders([joinpath(homedir(), ".julia/dev/CSTParser")], dynamic=true)

add_folder_from_disc!(jw, joinpath(homedir(), ".julia/environments/v1.12"))

JuliaWorkspaces.set_input_active_project!(jw.runtime, JuliaWorkspaces.filepath2uri(joinpath(homedir(), ".julia/environments/v1.12")))

get_diagnostics(jw)
