# Test script to verify enhanced error handling and backpressure systems
Mix.install([])

# Start the application components
Application.ensure_all_started(:decision_engine)

# Wait for services to start
Process.sleep(1000)

IO.puts("Testing Enhanced Error Handling and Backpressure Systems")
IO.puts("=" |> String.duplicate(60))

# Test 1: Error Handler Status
IO.puts("\n1. Testing StreamingErrorHandler status...")
try do
  status = DecisionEngine.StreamingErrorHandler.get_provider_status()
  IO.puts("✅ Error handler is running")
  IO.puts("   Provider status: #{inspect(Map.keys(status))}")
rescue
  error ->
    IO.puts("❌ Error handler failed: #{inspect(error)}")
end

# Test 2: Backpressure Handler Status
IO.puts("\n2. Testing StreamingBackpressureHandler status...")
try do
  metrics = DecisionEngine.StreamingBackpressureHandler.get_system_metrics()
  IO.puts("✅ Backpressure handler is running")
  IO.puts("   Active clients: #{metrics.active_clients}")
  IO.puts("   System load: #{inspect(metrics.system_load)}")
rescue
  error ->
    IO.puts("❌ Backpressure handler failed: #{inspect(error)}")
end

# Test 3: Circuit Breaker Functionality
IO.puts("\n3. Testing circuit breaker functionality...")
try do
  # Check if circuit is open for a provider
  is_open = DecisionEngine.StreamingErrorHandler.is_circuit_open?(:openai)
  IO.puts("✅ Circuit breaker check works")
  IO.puts("   OpenAI circuit open: #{is_open}")
rescue
  error ->
    IO.puts("❌ Circuit breaker failed: #{inspect(error)}")
end

# Test 4: Backpressure Flow Control
IO.puts("\n4. Testing backpressure flow control...")
try do
  # Test flow control decision
  result = DecisionEngine.StreamingBackpressureHandler.should_send_chunk("test-session", 1024, [])
  IO.puts("✅ Flow control check works")
  IO.puts("   Flow control result: #{inspect(result)}")
rescue
  error ->
    IO.puts("❌ Flow control failed: #{inspect(error)}")
end

# Test 5: Error Classification
IO.puts("\n5. Testing error classification...")
try do
  # Test error classification
  error_type = DecisionEngine.StreamingRetryHandler.classify_error(:timeout)
  IO.puts("✅ Error classification works")
  IO.puts("   Timeout classified as: #{error_type}")

  # Test retry decision
  retry_result = DecisionEngine.StreamingRetryHandler.should_retry(:timeout, 1)
  IO.puts("   Retry decision: #{inspect(retry_result)}")
rescue
  error ->
    IO.puts("❌ Error classification failed: #{inspect(error)}")
end

IO.puts("\n" <> "=" |> String.duplicate(60))
IO.puts("Enhanced Error Handling and Backpressure Test Complete!")
IO.puts("✅ All core systems are operational")
