@testitem "readline(TCPSocket) - cancel" setup=[SpawnHelper] begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8000)

    src = CancellationTokenSource()
    token = get_token(src)

    @spawn begin
        conn = Sockets.accept(server)
        # Don't send anything — let readline block
        sleep(5.0)
        close(conn)
    end

    client = Sockets.connect(Sockets.localhost, port)

    @spawn begin
        sleep(0.2)
        cancel(src)
    end

    @test_throws OperationCanceledException readline(client, token)
    # Socket should be closed after cancellation
    @test !isopen(client)

    close(server)
end

@testitem "readline(TCPSocket) - data arrives before cancel" setup=[SpawnHelper] begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8001)

    src = CancellationTokenSource()

    @spawn begin
        conn = Sockets.accept(server)
        sleep(0.1)
        println(conn, "hello")
        close(conn)
    end

    client = Sockets.connect(Sockets.localhost, port)
    line = readline(client, get_token(src))
    @test line == "hello"
    @test !is_cancellation_requested(get_token(src))

    close(client)
    close(server)
end

@testitem "readline(TCPSocket) - cancel does not crash other readers" setup=[SpawnHelper] begin
    import Sockets

    # Regression test for issue #24:
    # Cancelling one reader must not inject errors into other tasks
    # waiting on the same socket. The cancellation closes the socket,
    # so other readers get a clean I/O error — not OperationCanceledException.
    port, server = Sockets.listenany(Sockets.localhost, 8002)

    @spawn begin
        conn = Sockets.accept(server)
        # Don't send anything — let both readers block
        sleep(5.0)
        close(conn)
    end

    client = Sockets.connect(Sockets.localhost, port)

    src = CancellationTokenSource()

    # Task 1: readline with cancellation token (will be cancelled)
    task1 = @spawn begin
        try
            readline(client, get_token(src))
        catch ex
            ex
        end
    end

    # Task 2: plain readline on the same socket (no cancellation token)
    task2 = @spawn begin
        try
            readline(client)
            :ok
        catch ex
            ex
        end
    end

    # Give both tasks time to start blocking
    sleep(0.2)

    # Cancel the token — this closes the socket
    cancel(src)

    # Wait for both tasks to finish
    result1 = fetch(task1)
    result2 = fetch(task2)

    # Task 1 should get OperationCanceledException
    @test result1 isa OperationCanceledException

    # Task 2 should NOT get OperationCanceledException —
    # it should get a regular I/O error from the socket closing
    @test !(result2 isa OperationCanceledException)

    close(server)
end

@testitem "read(TCPSocket, nb) - cancel" begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8003)

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        conn = Sockets.accept(server)
        # Don't send anything — let read block
        sleep(5.0)
        close(conn)
    end

    client = Sockets.connect(Sockets.localhost, port)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    @test_throws OperationCanceledException read(client, 100, token)
    # Socket should be closed after cancellation
    @test !isopen(client)

    close(server)
end

@testitem "accept(TCPServer) - cancel before call" begin
    import Sockets

    _port, server = Sockets.listenany(Sockets.localhost, 8004)

    src = CancellationTokenSource()
    token = get_token(src)
    cancel(src)

    @test_throws OperationCanceledException Sockets.accept(server, token)

    close(server)
end

@testitem "accept(TCPServer) - cancel while blocking" begin
    import Sockets

    _port, server = Sockets.listenany(Sockets.localhost, 8005)

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    ex = try
        Sockets.accept(server, token)
        nothing
    catch err
        err
    end

    @test ex isa OperationCanceledException
    @test get_token(ex) === token

    close(server)
end

@testitem "accept(TCPServer) - client arrives before cancel" begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8006)

    src = CancellationTokenSource()
    token = get_token(src)

    client_task = @async Sockets.connect(Sockets.localhost, port)

    server_conn = Sockets.accept(server, token)
    client_conn = fetch(client_task)

    @test isa(server_conn, Sockets.TCPSocket)
    @test !is_cancellation_requested(token)

    close(server_conn)
    close(client_conn)
    close(server)
end

@testitem "accept(TCPServer) - server reusable after cancel" begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8007)

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    @test_throws OperationCanceledException Sockets.accept(server, token)

    client_task = @async Sockets.connect(Sockets.localhost, port)

    server_conn = Sockets.accept(server)
    client_conn = fetch(client_task)

    @test isa(server_conn, Sockets.TCPSocket)

    close(server_conn)
    close(client_conn)
    close(server)
end

@testitem "accept(TCPServer, client) - cancel while blocking" begin
    import Sockets

    _port, server = Sockets.listenany(Sockets.localhost, 8008)
    client = Sockets.TCPSocket()

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    ex = try
        Sockets.accept(server, client, token)
        nothing
    catch err
        err
    end

    @test ex isa OperationCanceledException
    @test get_token(ex) === token

    close(client)
    close(server)
end

@testitem "accept(PipeServer) - cancel before call" begin
    import Sockets

    path = Sys.iswindows() ? string(raw"\\.\pipe\CancellationTokens-", time_ns()) : tempname()
    server = Sockets.listen(path)

    src = CancellationTokenSource()
    token = get_token(src)
    cancel(src)

    try
        @test_throws OperationCanceledException Sockets.accept(server, token)
    finally
        close(server)
        if !Sys.iswindows() && ispath(path)
            rm(path; force=true)
        end
    end
end

@testitem "accept(PipeServer) - cancel while blocking" begin
    import Sockets

    path = Sys.iswindows() ? string(raw"\\.\pipe\CancellationTokens-", time_ns()) : tempname()
    server = Sockets.listen(path)

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    try
        ex = try
            Sockets.accept(server, token)
            nothing
        catch err
            err
        end

        @test ex isa OperationCanceledException
        @test get_token(ex) === token
    finally
        close(server)
        if !Sys.iswindows() && ispath(path)
            rm(path; force=true)
        end
    end
end

@testitem "accept(PipeServer) - client arrives before cancel" begin
    import Sockets

    path = Sys.iswindows() ? string(raw"\\.\pipe\CancellationTokens-", time_ns()) : tempname()
    server = Sockets.listen(path)

    src = CancellationTokenSource()
    token = get_token(src)

    client_task = @async Sockets.connect(path)

    try
        server_conn = Sockets.accept(server, token)
        client_conn = fetch(client_task)

        @test isa(server_conn, Sockets.PipeEndpoint)
        @test !is_cancellation_requested(token)

        close(server_conn)
        close(client_conn)
    finally
        close(server)
        if !Sys.iswindows() && ispath(path)
            rm(path; force=true)
        end
    end
end

@testitem "accept(PipeServer) - server reusable after cancel" begin
    import Sockets

    path = Sys.iswindows() ? string(raw"\\.\pipe\CancellationTokens-", time_ns()) : tempname()
    server = Sockets.listen(path)

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    try
        @test_throws OperationCanceledException Sockets.accept(server, token)

        client_task = @async Sockets.connect(path)

        server_conn = Sockets.accept(server)
        client_conn = fetch(client_task)

        @test isa(server_conn, Sockets.PipeEndpoint)

        close(server_conn)
        close(client_conn)
    finally
        close(server)
        if !Sys.iswindows() && ispath(path)
            rm(path; force=true)
        end
    end
end

@testitem "accept(PipeServer, client) - cancel while blocking" begin
    import Sockets

    path = Sys.iswindows() ? string(raw"\\.\pipe\CancellationTokens-", time_ns()) : tempname()
    server = Sockets.listen(path)
    client = Sockets.PipeEndpoint()

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    try
        ex = try
            Sockets.accept(server, client, token)
            nothing
        catch err
            err
        end

        @test ex isa OperationCanceledException
        @test get_token(ex) === token
    finally
        close(client)
        close(server)
        if !Sys.iswindows() && ispath(path)
            rm(path; force=true)
        end
    end
end

@testitem "read(TCPSocket, nb) - data arrives before cancel" begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8009)

    src = CancellationTokenSource()

    @async begin
        conn = Sockets.accept(server)
        sleep(0.1)
        write(conn, UInt8[1, 2, 3, 4, 5])
        close(conn)
    end

    client = Sockets.connect(Sockets.localhost, port)
    data = read(client, 5, get_token(src))
    @test data == UInt8[1, 2, 3, 4, 5]
    @test !is_cancellation_requested(get_token(src))

    close(client)
    close(server)
end

@testitem "read(TCPSocket, nb) - data arrived, cancel after completion returns data" begin
    import Sockets

    # .NET semantics: if the operation completed successfully, it should
    # return the result even if the token is cancelled afterwards.
    port, server = Sockets.listenany(Sockets.localhost, 8010)

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        conn = Sockets.accept(server)
        write(conn, UInt8[10, 20, 30])
        # Keep connection open
        sleep(5.0)
        close(conn)
    end

    client = Sockets.connect(Sockets.localhost, port)

    # Cancel the token right after data arrives but before we check
    @async begin
        sleep(0.3)
        cancel(src)
    end

    # Give data time to arrive
    sleep(0.2)
    data = read(client, 3, token)
    @test data == UInt8[10, 20, 30]

    close(client)
    close(server)
end

@testitem "read(TCPSocket, nb) - cancel does not crash other readers" begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8011)

    @async begin
        conn = Sockets.accept(server)
        # Don't send anything — let both readers block
        sleep(5.0)
        close(conn)
    end

    client = Sockets.connect(Sockets.localhost, port)

    src = CancellationTokenSource()

    # Task 1: read with cancellation token (will be cancelled)
    task1 = @async begin
        try
            read(client, 100, get_token(src))
        catch ex
            ex
        end
    end

    # Task 2: plain read on the same socket (no cancellation token)
    task2 = @async begin
        try
            read(client, 100)
            :ok
        catch ex
            ex
        end
    end

    # Give both tasks time to start blocking
    sleep(0.2)

    # Cancel the token — this closes the socket
    cancel(src)

    # Wait for both tasks to finish
    result1 = fetch(task1)
    result2 = fetch(task2)

    # Task 1 should get OperationCanceledException
    @test result1 isa OperationCanceledException

    # Task 2 should NOT get OperationCanceledException —
    # it should get a regular I/O error from the socket closing
    @test !(result2 isa OperationCanceledException)

    close(server)
end

@testitem "readavailable(TCPSocket) - cancel" begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8012)

    src = CancellationTokenSource()
    token = get_token(src)

    @async begin
        conn = Sockets.accept(server)
        # Don't send anything — let readavailable block
        sleep(5.0)
        close(conn)
    end

    client = Sockets.connect(Sockets.localhost, port)

    @async begin
        sleep(0.2)
        cancel(src)
    end

    @test_throws OperationCanceledException readavailable(client, token)
    # Socket should be closed after cancellation
    @test !isopen(client)

    close(server)
end

@testitem "readavailable(TCPSocket) - data arrives before cancel" begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8013)

    src = CancellationTokenSource()

    @async begin
        conn = Sockets.accept(server)
        sleep(0.1)
        write(conn, UInt8[1, 2, 3, 4, 5])
        # Keep connection open so readavailable returns just these bytes
        sleep(5.0)
        close(conn)
    end

    client = Sockets.connect(Sockets.localhost, port)
    data = readavailable(client, get_token(src))
    @test !isempty(data)
    @test data == UInt8[1, 2, 3, 4, 5]
    @test !is_cancellation_requested(get_token(src))

    close(client)
    close(server)
end

@testitem "readavailable(TCPSocket) - cancel does not crash other readers" begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8014)

    @async begin
        conn = Sockets.accept(server)
        # Don't send anything — let both readers block
        sleep(5.0)
        close(conn)
    end

    client = Sockets.connect(Sockets.localhost, port)

    src = CancellationTokenSource()

    # Task 1: readavailable with cancellation token (will be cancelled)
    task1 = @async begin
        try
            readavailable(client, get_token(src))
        catch ex
            ex
        end
    end

    # Task 2: plain readavailable on the same socket (no cancellation token)
    task2 = @async begin
        try
            readavailable(client)
        catch ex
            ex
        end
    end

    # Give both tasks time to start blocking
    sleep(0.2)

    # Cancel the token — this closes the socket
    cancel(src)

    # Wait for both tasks to finish
    result1 = fetch(task1)
    result2 = fetch(task2)

    # Task 1 should get OperationCanceledException
    @test result1 isa OperationCanceledException

    # Task 2 should NOT get OperationCanceledException —
    # it either returns an empty buffer from the closed socket or gets a
    # regular I/O error, but never a cancellation exception.
    @test !(result2 isa OperationCanceledException)

    close(server)
end
