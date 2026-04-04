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

    port, server = Sockets.listenany(Sockets.localhost, 8000)

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
    port, server = Sockets.listenany(Sockets.localhost, 8000)

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

    port, server = Sockets.listenany(Sockets.localhost, 8000)

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

@testitem "read(TCPSocket, nb) - data arrives before cancel" begin
    import Sockets

    port, server = Sockets.listenany(Sockets.localhost, 8000)

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
    port, server = Sockets.listenany(Sockets.localhost, 8000)

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

    port, server = Sockets.listenany(Sockets.localhost, 8000)

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
