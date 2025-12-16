# Test script to check LM Studio connection
Mix.install([{:req, "~> 0.4"}])

IO.puts("Testing LM Studio Connection")
IO.puts("=" |> String.duplicate(40))

# Test LM Studio endpoint
endpoint = "http://host.docker.internal:1234/v1/chat/completions"
IO.puts("Testing endpoint: #{endpoint}")

headers = [
  {"content-type", "application/json"}
]

body = %{
  model: "openai/gpt-oss-20b",
  messages: [
    %{
      role: "user",
      content: "Hello, this is a test message."
    }
  ],
  temperature: 0.7,
  max_tokens: 100,
  stream: false
}

IO.puts("\n1. Testing non-streaming request...")
try do
  case Req.post(endpoint, json: body, headers: headers, receive_timeout: 10_000) do
    {:ok, %{status: 200, body: response_body}} ->
      IO.puts("✅ Non-streaming request successful")
      IO.puts("   Response: #{inspect(response_body)}")

    {:ok, %{status: status, body: body}} ->
      IO.puts("❌ HTTP #{status}: #{inspect(body)}")

    {:error, reason} ->
      IO.puts("❌ Request failed: #{inspect(reason)}")
  end
rescue
  error ->
    IO.puts("❌ Request error: #{inspect(error)}")
end

IO.puts("\n2. Testing streaming request...")
streaming_body = Map.put(body, :stream, true)

try do
  case Req.post(endpoint, json: streaming_body, headers: headers, receive_timeout: 10_000) do
    {:ok, %{status: 200, body: response_body}} ->
      IO.puts("✅ Streaming request successful")
      IO.puts("   Response: #{String.slice(inspect(response_body), 0, 200)}...")

    {:ok, %{status: status, body: body}} ->
      IO.puts("❌ HTTP #{status}: #{inspect(body)}")

    {:error, reason} ->
      IO.puts("❌ Streaming request failed: #{inspect(reason)}")
  end
rescue
  error ->
    IO.puts("❌ Streaming request error: #{inspect(error)}")
end

IO.puts("\n" <> "=" |> String.duplicate(40))
IO.puts("LM Studio Connection Test Complete!")
