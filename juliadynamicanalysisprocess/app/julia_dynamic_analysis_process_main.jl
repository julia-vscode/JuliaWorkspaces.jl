@info "Julia dynamic analysis process launching"

version_specific_env_path = normpath(joinpath(@__DIR__, "../environments", "v$(VERSION.major).$(VERSION.minor)", "Project.toml"))
if isfile(version_specific_env_path)
    Base.ACTIVE_PROJECT[] = version_specific_env_path
else
    Base.ACTIVE_PROJECT[] = normpath(joinpath(@__DIR__, "../environments", "fallback"))
end

let
    # Try to lower the priority of this process so that it doesn't block the
    # user system.
    @static if Sys.iswindows()
        # Get process handle
        p_handle = ccall(:GetCurrentProcess, stdcall, Ptr{Cvoid}, ())

        # Set BELOW_NORMAL_PRIORITY_CLASS
        ret = ccall(:SetPriorityClass, stdcall, Cint, (Ptr{Cvoid}, Culong), p_handle, 0x00004000)
        ret != 1 && @warn "Something went wrong when setting BELOW_NORMAL_PRIORITY_CLASS."
    else
        ret = ccall(:nice, Cint, (Cint,), 1)
        # We don't check the return value because it doesn't really matter
    end

    has_error_handler = false

    try

        if length(ARGS) > 1
            include(ARGS[2])
            has_error_handler = true
        end

        using JuliaDynamicAnalysisProcess

        JuliaDynamicAnalysisProcess.serve(
            ARGS[1],
            has_error_handler ? (err, bt) -> global_err_handler(err, bt, Base.ARGS[3], "Julia Dynamic Analysis Process") : nothing)
    catch err
        bt = catch_backtrace()
        if has_error_handler
            global_err_handler(err, bt, Base.ARGS[3], "Julia Dynamic Analysis Process")
        else
            Base.display_error(err, bt)
        end
    end
end
