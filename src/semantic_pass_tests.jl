module SemanticPassTests

import JuliaSyntax
using JuliaSyntax: @K_str, kind, children, haschildren, first_byte, last_byte, SyntaxNode

import ..URIs2
using ..URIs2: URI, uri2filepath

import ...JuliaWorkspaces
using ...JuliaWorkspaces: TestItemDetail, TestSetupDetail, TestErrorDetail, JuliaPackage, JuliaProject, splitpath

function find_test_detail!(node, uri, project_uri, package_uri, package_name, testitems, testsetups, errors)
    if kind(node) == K"macrocall" && haschildren(node) && node[1].val == Symbol("@testitem")
        range = first_byte(node):last_byte(node)

        child_nodes = children(node)

        # Check for various syntax errors
        if length(child_nodes)==1
            push!(errors, TestErrorDetail(uri, "Your @testitem is missing a name and code block.", range))
            return
        elseif length(child_nodes)>1 && !(kind(child_nodes[2]) == K"string")
            push!(errors, TestErrorDetail(uri, "Your @testitem must have a first argument that is of type String for the name.", range))
            return
        elseif length(child_nodes)==2
            push!(errors, TestErrorDetail(uri, "Your @testitem is missing a code block argument.", range))
            return
        elseif !(kind(child_nodes[end]) == K"block")
            push!(errors, TestErrorDetail(uri, "The final argument of a @testitem must be a begin end block.", range))
            return
        else
            option_tags = nothing
            option_default_imports = nothing
            option_setup = nothing

            # Now check our keyword args
            for i in child_nodes[3:end-1]
                if kind(i) != K"="
                    push!(errors, TestErrorDetail(uri, "The arguments to a @testitem must be in keyword format.", range))
                    return
                elseif !(length(children(i))==2)
                    error("This code path should not be possible.")
                elseif kind(i[1]) == K"Identifier" && i[1].val == :tags
                    if option_tags!==nothing
                        push!(errors, TestErrorDetail(uri, "The keyword argument tags cannot be specified more than once.", range))
                        return
                    end

                    if kind(i[2]) != K"vect"
                        push!(errors, TestErrorDetail(uri, "The keyword argument tags only accepts a vector of symbols.", range))
                        return
                    end

                    option_tags = Symbol[]

                    for j in children(i[2])
                        if kind(j) != K"quote" || length(children(j)) != 1 || kind(j[1]) != K"Identifier"
                            push!(errors, TestErrorDetail(uri, "The keyword argument tags only accepts a vector of symbols.", range))
                            return
                        end

                        push!(option_tags, j[1].val)
                    end
                elseif kind(i[1]) == K"Identifier" && i[1].val == :default_imports
                    if option_default_imports !== nothing
                        push!(errors, TestErrorDetail(uri, "The keyword argument default_imports cannot be specified more than once.", range))
                        return
                    end

                    if !(i[2].val in (true, false))
                        push!(errors, TestErrorDetail(uri, "The keyword argument default_imports only accepts bool values.", range))
                        return
                    end

                    option_default_imports = i[2].val
                elseif kind(i[1]) == K"Identifier" && i[1].val == :setup
                    if option_setup!==nothing
                        push!(errors, TestErrorDetail(uri, "The keyword argument setup cannot be specified more than once.", range))
                        return
                    end

                    if kind(i[2]) != K"vect"
                        push!(errors, TestErrorDetail(uri, "The keyword argument `setup` only accepts a vector of `@testsetup module` names.", range))
                        return
                    end

                    option_setup = Symbol[]

                    for j in children(i[2])
                        if kind(j) != K"Identifier"
                            push!(errors, TestErrorDetail(uri, "The keyword argument `setup` only accepts a vector of `@testsetup module` names.", range))
                            return
                        end

                        push!(option_setup, j.val)
                    end
                else
                    push!(errors, TestErrorDetail(uri, "Unknown keyword argument.", range))
                    return
                end
            end

            if option_tags===nothing
                option_tags = Symbol[]
            end

            if option_default_imports===nothing
                option_default_imports = true
            end

            if option_setup===nothing
                option_setup = Symbol[]
            end

            code_range = first_byte(child_nodes[end][1]):last_byte(child_nodes[end][end])

            push!(testitems, 
                TestItemDetail(
                    uri,
                    node[2,1].val,
                    project_uri,
                    package_uri,
                    package_name, 
                    range,
                    code_range,
                    option_default_imports,
                    option_tags,
                    option_setup
                )
            )
        end
    elseif kind(node) == K"macrocall" && haschildren(node) && node[1].val == Symbol("@testsetup")
        range = first_byte(node):last_byte(node)

        child_nodes = children(node)

        # Check for various syntax errors
        if length(child_nodes)==1
            push!(errors, TestErrorDetail(uri, "Your `@testsetup` is missing a `module ... end` block.", range))
            return
        elseif length(child_nodes)>2 || kind(child_nodes[2]) != K"module" || length(children(child_nodes[2])) < 3 || child_nodes[2][1] == false
            push!(errors, TestErrorDetail(uri, "Your `@testsetup` must have a single `module ... end` argument.", range))
            return
        else
            # TODO + 1 here is from the space before the module block. We might have to detect that,
            # not sure whether that is always assigned to the module end EXPR
            mod = child_nodes[2]
            mod_name = mod[2].val
            code_range = first_byte(mod[3]):last_byte(mod[end])
            push!(
                testsetups,
                TestSetupDetail(
                    uri,
                    mod_name,
                    package_uri,
                    package_name,
                    range,
                    code_range
                )
            )
        end
    elseif kind(node) == K"toplevel"
        for i in children(node)
            find_test_detail!(i, uri, project_uri, package_uri, package_name, testitems, testsetups, errors)
        end
    elseif kind(node) == K"module"
        find_test_detail!(node[3], uri, project_uri, package_uri, package_name, testitems, testsetups, errors)
    elseif kind(node) == K"block"
        for i in children(node)
            find_test_detail!(i, uri, project_uri, package_uri, package_name, testitems, testsetups, errors)
        end
    end
end

function vec_startswith(a, b)
    if length(a) < length(b)
        return false
    end

    for (i,v) in enumerate(b)
        if a[i] != v
            return false
        end
    end
    return true
end

function find_package_for_file(packages::Dict{URI,JuliaPackage}, file::URI)
    file_path = uri2filepath(file)
    package = packages |>
        keys |>
        collect |>
        x -> map(x) do i
            package_folder_path = uri2filepath(i)
            parts = splitpath(package_folder_path)
            return (uri = i, parts = parts)
        end |>
        x -> filter(x) do i
            return vec_startswith(splitpath(file_path), i.parts)
        end |>
        x -> sort(x, by=i->length(i.parts), rev=true) |>
        x -> length(x) == 0 ? nothing : first(x).uri

    return package
end

function find_project_for_file(projects::Dict{URI,JuliaProject}, file::URI)
    file_path = uri2filepath(file)
    project = projects |>
        keys |>
        collect |>
        x -> map(x) do i
            project_folder_path = uri2filepath(i)
            parts = splitpath(project_folder_path)
            return (uri = i, parts = parts)
        end |>
        x -> filter(x) do i
            return vec_startswith(splitpath(file_path), i.parts)
        end |>
        x -> sort(x, by=i->length(i.parts), rev=true) |>
        x -> length(x) == 0 ? nothing : first(x).uri

    return project
end

function semantic_pass_tests(workspace_folders::Set{URI}, syntax_trees::Dict{URI,SyntaxNode}, packages::Dict{URI,JuliaPackage}, projects::Dict{URI,JuliaProject}, fallback_project_uri::URI)
    all_testitems = Dict{URI,Vector{TestItemDetail}}()
    all_testsetups = Dict{URI,Vector{TestSetupDetail}}()
    all_testerrors = Dict{URI,Vector{TestErrorDetail}}()
    for uri in keys(syntax_trees)
        # Find which workspace folder the doc is in.
        parent_workspaceFolders = sort(filter(f -> startswith(string(uri), string(f)), collect(workspace_folders)), by=length ∘ string, rev=true)

        # If the file is not in the workspace, we don't report nothing
        if isempty(parent_workspaceFolders)
            all_testitems[uri] = []
            all_testsetups[uri] = []
            all_testerrors[uri] = []
        else
            project_uri = find_project_for_file(projects, uri)
            package_uri = find_package_for_file(packages, uri)

            if project_uri === nothing
                project_uri = fallback_project_uri
            end

            if package_uri === nothing
                package_name = ""
            else
                package_name = packages[package_uri].name
            end

            if project_uri == package_uri
            elseif haskey(projects, project_uri)
                relevant_project = projects[project_uri]

                if !haskey(relevant_project.deved_packages, package_uri)
                    project_uri = nothing
                end
            else
                project_uri = nothing
            end

            testitems = []
            testsetups = []
            testerrors = []

            find_test_detail!(syntax_trees[uri], uri, project_uri, package_uri, package_name, testitems, testsetups, testerrors)

            all_testitems[uri] = testitems
            all_testsetups[uri] = testsetups
            all_testerrors[uri] = testerrors
        end
    end

    return all_testitems, all_testsetups, all_testerrors
end

end
