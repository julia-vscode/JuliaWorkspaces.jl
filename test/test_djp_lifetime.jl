@testitem "DJP lifetime: a child that ignores SIGTERM is SIGKILLed" begin
    using JuliaWorkspaces: _terminate_process, default_djp_julia_exe

    # Stands in for a child deadlocked inside `malloc` (JuliaLang/julia#63307),
    # which SIGTERM cannot end either. Not a Julia process: Julia's own SIGTERM
    # handling overrides SIG_IGN. On Windows SIGTERM is a hard kill anyway.
    cmd = if Sys.iswindows()
        `$(default_djp_julia_exe()) --startup-file=no -e 'println("ready"); flush(stdout); sleep(300)'`
    else
        `sh -c 'trap "" TERM; echo ready; exec sleep 300'`
    end
    out = Pipe()
    proc = run(pipeline(cmd; stdout=out); wait=false)
    close(out.in)
    try
        @test readline(out) == "ready"

        _terminate_process(proc, 1.0)
        if !Sys.iswindows()
            # Guards the test itself: SIGTERM alone must not have ended it.
            sleep(0.5)
            @test process_running(proc)
        end
        @test timedwait(() -> process_exited(proc), 30.0) === :ok
        Sys.iswindows() || @test proc.termsignal == Base.SIGKILL
    finally
        kill(proc, Base.SIGKILL)
    end
end

@testitem "DJP lifetime: an indexing child dies with its host" begin
    using JuliaWorkspaces: _djp_child_cmd, _djp_main_script, djp_runtime, default_djp_julia_exe,
        JSONRPC, Sockets

    exe = default_djp_julia_exe()
    pipe_name = JSONRPC.generate_pipe_name()
    server = Sockets.listen(pipe_name)
    child = _djp_child_cmd(djp_runtime(exe), _djp_main_script(), pipe_name)

    # A stand-in host that launches the child exactly the way JuliaWorkspaces
    # does, while the connection comes back to this process, so killing the
    # host does not close the child's socket for it.
    host_code = """
        ENV["JULIA_DJP_PARENT_PID"] = string(getpid())
        wait(run(Cmd(ARGS); wait=false))
        """
    host_output = IOBuffer()
    host = run(pipeline(setenv(`$exe --startup-file=no -e $host_code -- $(collect(child.exec))`, child.env);
        stdout=host_output, stderr=host_output); wait=false)
    try
        accept_task = @async Sockets.accept(server)
        connected = timedwait(() -> istaskdone(accept_task), 600.0) === :ok
        @test connected
        connected || error("child never connected:\n" * String(take!(host_output)))
        socket = fetch(accept_task)

        # The child now idles waiting for requests. Kill the host the way a
        # crash or the OOM killer would: no chance to clean up.
        kill(host, Base.SIGKILL)
        wait(host)

        # The child is the only holder of the socket, so EOF means it is gone.
        eof_task = @async eof(socket)
        @test timedwait(() -> istaskdone(eof_task), 30.0) === :ok
        close(socket)
    finally
        close(server)
        kill(host, Base.SIGKILL)
    end
end

@testitem "DJP lifetime: a child that starts orphaned exits before doing anything" begin
    using JuliaWorkspaces: _djp_child_cmd, _djp_main_script, djp_runtime, default_djp_julia_exe

    # Windows needs no check: a non-detached child is killed with its host.
    if !Sys.iswindows()
        cmd = _djp_child_cmd(djp_runtime(default_djp_julia_exe()), _djp_main_script(), "unused-pipe")
        # Our pid is the child's real parent, so any other value reads as the
        # host having died before the child got going.
        cmd = addenv(cmd, "JULIA_DJP_PARENT_PID" => string(getpid() + 1))
        err = IOBuffer()
        proc = run(pipeline(ignorestatus(cmd); stderr=err))
        @test proc.exitcode == 1
        @test !occursin("launching", String(take!(err)))
    end
end

@testitem "DJP lifetime: shutdown! stops the dynamic feature and is idempotent" begin
    using JuliaWorkspaces: DynamicControllerStopped, state

    jw = JuliaWorkspace(store_path=mktempdir(), dynamic=DynamicIndexingOnly)
    shutdown!(jw)
    @test state(jw.dynamic_feature.controller_fsm) == DynamicControllerStopped
    shutdown!(jw)
    @test state(jw.dynamic_feature.controller_fsm) == DynamicControllerStopped

    # Nothing to stop without a dynamic feature.
    @test shutdown!(JuliaWorkspace()) === nothing
end
