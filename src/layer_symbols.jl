Salsa.@derived function derived_required_symbol_info(rt)
    all_projects = [derived_project(rt, i) for i in derived_project_folders(rt)]

    regular_packages = unique(Iterators.flatten(values(i.regular_packages) for i in all_projects))

    return (;regular_packages)
end
