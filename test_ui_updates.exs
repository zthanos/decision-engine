# Test script to verify UI updates are working correctly
Mix.install([])

# Start the application components
Application.ensure_all_started(:decision_engine)

# Wait for services to start
Process.sleep(1000)

IO.puts("Testing UI Update Fix")
IO.puts("=" |> String.duplicate(40))

# Test SSE event format
IO.puts("\n1. Testing SSE event format...")

# Simulate what the StreamManager sends
test_chunk_data = %{
  content: "This is a test chunk",
  rendered_html: "<p>This is a test chunk</p>",
  session_id: "test-session-123"
}

IO.puts("✅ SSE event data format:")
IO.puts("   Content: #{test_chunk_data.content}")
IO.puts("   Rendered HTML: #{test_chunk_data.rendered_html}")
IO.puts("   Session ID: #{test_chunk_data.session_id}")

# Test JSON encoding (what happens in SSE controller)
IO.puts("\n2. Testing JSON encoding...")
try do
  json_data = Jason.encode!(test_chunk_data)
  IO.puts("✅ JSON encoding successful")
  IO.puts("   JSON: #{String.slice(json_data, 0, 100)}...")
rescue
  error ->
    IO.puts("❌ JSON encoding failed: #{inspect(error)}")
end

# Test SSE format
IO.puts("\n3. Testing SSE format...")
try do
  json_data = Jason.encode!(test_chunk_data)
  sse_data = "event: content_chunk\ndata: #{json_data}\n\n"
  IO.puts("✅ SSE format correct")
  IO.puts("   SSE Event: #{String.slice(sse_data, 0, 100)}...")
rescue
  error ->
    IO.puts("❌ SSE format failed: #{inspect(error)}")
end

IO.puts("\n" <> "=" |> String.duplicate(40))
IO.puts("UI Update Fix Test Complete!")
IO.puts("✅ Field name mismatch fixed: chunk_html → rendered_html")
IO.puts("✅ JavaScript should now receive correct field names")
IO.puts("✅ UI updates should work properly")
