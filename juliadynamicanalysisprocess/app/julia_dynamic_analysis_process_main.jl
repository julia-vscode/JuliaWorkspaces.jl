# Die with the host. On Windows libuv already does this (non-detached children
# live in a kill-on-close job object); on Unix an orphan would keep indexing, or
# stay deadlocked, long after the host is gone.
const host_pid = something(tryparse(Int, get(ENV, "JULIA_DJP_PARENT_PID", "")), 0)
if host_pid != 0 && !Sys.iswindows()
    @static if Sys.islinux()
        # PR_SET_PDEATHSIG (1) = SIGKILL (9): the kernel kills us when the host
        # dies, even if this process is stuck.
        ccall(:prctl, Cint, (Cint, Culong, Culong, Culong, Culong), 1, 9, 0, 0, 0)
    end

    # `_exit` skips atexit hooks: there is nothing to save, and they could block.
    exit_if_orphaned() = ccall(:getppid, Cint, ()) != host_pid && ccall(:_exit, Union{}, (Cint,), 1)

    # The host may have died before prctl ran.
    exit_if_orphaned()

    @static if !Sys.islinux()
        # No PDEATHSIG here, so poll. Best effort: only fires when this process yields.
        global host_watchdog = Timer(_ -> exit_if_orphaned(), 2.0; interval=2.0)
    end
end

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

        # Exit non-zero. A child that dies before connecting back is reported by
        # `JuliaWorkspaces.start(::DynamicJuliaProcess, ...)` as a
        # `DynamicProcessCrashException` carrying this exit code, so exiting 0 here
        # made a hard startup failure indistinguishable from a normal exit: the
        # parent logged a crash whose only detail was `exitcode = 0`.
        exit(1)
    end
end
