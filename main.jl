using JuliaWorkspaces

jw = JuliaWorkspaces.workspace_from_folders([joinpath(homedir(), ".julia/dev/CSTParser")], dynamic=true)

add_folder_from_disc!(jw, joinpath(homedir(), ".julia/dev/environments/v1.12"))

JuliaWorkspaces.set_input_active_project!(jw.runtime, JuliaWorkspaces.filepath2uri(joinpath(homedir(), ".julia/dev/environments/v1.12")))

get_diagnostics(jw)

x = JuliaWorkspaces.derived_all_includes(jw.runtime)

for (k,v) in pairs(x)
    println("$k:")
    for i in v
        println("  $i")
    end
end

z = JuliaWorkspaces.derived_roots(jw.runtime)

for i in z
    println("Root: $i")
end