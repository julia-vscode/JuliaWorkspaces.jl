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

            code_block = child_nodes[end]
            code_range = if haschildren(code_block) && length(children(code_block)) > 0
                first_byte(code_block[1]):last_byte(code_block[end])
            else
                (first_byte(code_block)+5):(last_byte(code_block)-3)
            end

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
        elseif length(child_nodes)>2 || kind(child_nodes[2]) != K"module" || length(children(child_nodes[2])) != 2 || child_nodes[2][1] == false
            push!(errors, TestErrorDetail(uri, "Your `@testsetup` must have a single `module ... end` argument.", range))
            return
        else
            # TODO + 1 here is from the space before the module block. We might have to detect that,
            # not sure whether that is always assigned to the module end EXPR
            mod = child_nodes[2]
            mod_name = mod[1].val
            code_range = first_byte(mod[2]):last_byte(mod[2])
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
        find_test_detail!(node[2], uri, project_uri, package_uri, package_name, testitems, testsetups, errors)
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

function find_package_for_file(packages::Vector{URI}, file::URI)
    file_path = uri2filepath(file)
    package = packages |>
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

function find_project_for_file(projects::Vector{URI}, file::URI)
    file_path = uri2filepath(file)
    project = projects |>
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

Salsa.@derived function derived_testitems(rt, uri)
    projects = derived_project_folders(rt)
    packages = derived_package_folders(rt)

    project_uri = find_project_for_file(projects, uri)
    package_uri = find_package_for_file(packages, uri)

    if project_uri === nothing
        project_uri = input_fallback_test_project(rt)
    end

    if package_uri === nothing
        package_name = ""
    else
        package_name = derived_package(rt, package_uri).name
    end

    if project_uri == package_uri
    elseif project_uri in projects
        relevant_project = derived_project(rt, project_uri)

        if !haskey(relevant_project.deved_packages, package_uri)
            project_uri = nothing
        end
    else
        project_uri = nothing
    end

    testitems = []
    testsetups = []
    testerrors = []

    syntax_tree = derived_julia_syntax_tree(rt, uri)

    find_test_detail!(syntax_tree[1], uri, project_uri, package_uri, package_name, testitems, testsetups, testerrors)

    return (testitems=testitems, testsetups=testsetups, testerrors=testerrors)
end
