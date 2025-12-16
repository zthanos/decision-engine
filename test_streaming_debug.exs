# Test script to debug streaming issues
Mix.install([])

# Start the application components
Application.ensure_all_started(:decision_engine)

# Wait for services to start
Process.sleep(1000)

IO.puts("Testing Streaming Debug")
IO.puts("=" |> String.duplicate(40))

# Test 1: Check if StreamManager can be started
IO.puts("\n1. Testing StreamManager startup...")
test_session_id = "debug-session-#{:rand.uniform(1000)}"

try do
  # Start a test process to receive messages
  test_pid = spawn(fn ->
    receive do
      {:sse_event, event_type, data} ->
        IO.puts("   📨 Received SSE event: #{event_type}")
        IO.puts("      Data: #{inspect(data)}")
      other ->
        IO.puts("   📨 Received other message: #{inspect(other)}")
    after
      5000 ->
        IO.puts("   ⏰ No messages received in 5 seconds")
    end
  end)

  case DecisionEngine.StreamManager.start_link(test_session_id, test_pid) do
    {:ok, _pid} ->
      IO.puts("✅ StreamManager started successfully")

      # Test sending a chunk directly
      send(Process.whereis({:via, Registry, {DecisionEngine.StreamRegistry, test_session_id}}),
           {:chunk, "Test chunk content"})

      Process.sleep(1000)

    {:error, reason} ->
      IO.puts("❌ StreamManager failed to start: #{inspect(reason)}")
  end
rescue
  error ->
    IO.puts("❌ StreamManager startup error: #{inspect(error)}")
end

# Test 2: Check streaming interface
IO.puts("\n2. Testing StreamingInterface...")
try do
  test_config = %{
    provider: :ollama,
    api_url: "http://localhost:11434/api/chat",
    model: "llama2",
    temperature: 0.1
  }

  test_pid2 = spawn(fn ->
    receive do
      {:chunk, content} ->
        IO.puts("   📨 Received chunk: #{String.slice(content, 0, 50)}...")
      {:complete} ->
        IO.puts("   ✅ Streaming completed")
      {:error, reason} ->
        IO.puts("   ❌ Streaming error: #{inspect(reason)}")
      other ->
        IO.puts("   📨 Received: #{inspect(other)}")
    after
      3000 ->
        IO.puts("   ⏰ No streaming messages received")
    end
  end)

  case DecisionEngine.StreamingInterface.start_stream("Test prompt", test_config, test_pid2) do
    {:ok, session} ->
      IO.puts("✅ StreamingInterface started successfully")
      IO.puts("   Session ID: #{session.session_id}")
    {:error, reason} ->
      IO.puts("❌ StreamingInterface failed: #{inspect(reason)}")
  end

  Process.sleep(2000)
rescue
  error ->
    IO.puts("❌ StreamingInterface error: #{inspect(error)}")
end

IO.puts("\n" <> "=" |> String.duplicate(40))
IO.puts("Streaming Debug Test Complete!")
IO.puts("✅ Flow control and backpressure temporarily disabled")
IO.puts("✅ Check if chunks are now flowing through")
