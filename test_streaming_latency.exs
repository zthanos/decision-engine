#!/usr/bin/env elixir

# Simple script to measure current streaming latency
# This will help us establish baseline measurements before optimization

Mix.install([
  {:jason, "~> 1.4"},
  {:finch, "~> 0.16"}
])

defmodule StreamingLatencyTest do
  @moduledoc """
  Test script to measure current streaming latency in the Decision Engine.
  """

  require Logger

  def run do
    IO.puts("=== Streaming Latency Analysis ===")
    IO.puts("Analyzing current streaming implementation...")

    # Test 1: Measure chunk processing time
    test_chunk_processing_time()

    # Test 2: Measure end-to-end latency simulation
    test_end_to_end_latency()

    # Test 3: Analyze current bottlenecks
    analyze_bottlenecks()
  end

  defp test_chunk_processing_time do
    IO.puts("\n1. Testing chunk processing time...")

    chunks = [
      "## Analysis Results\n\n",
      "Based on your scenario, here are the key findings:\n\n",
      "- **Primary consideration**: Your requirements align well\n",
      "- **Technical fit**: The solution matches constraints\n\n",
      "### Recommendations\n\n1. Review approach\n2. Consider timeline"
    ]

    total_time = Enum.reduce(chunks, 0, fn chunk, acc ->
      start_time = System.monotonic_time(:microsecond)

      # Simulate current chunk processing (what StreamManager does)
      _processed = process_chunk_current_way(chunk)

      end_time = System.monotonic_time(:microsecond)
      processing_time = end_time - start_time

      IO.puts("  Chunk (#{byte_size(chunk)} bytes): #{processing_time} μs")
      acc + processing_time
    end)

    avg_time = total_time / length(chunks)
    IO.puts("  Average chunk processing time: #{Float.round(avg_time, 2)} μs (#{Float.round(avg_time / 1000, 2)} ms)")
  end

  defp test_end_to_end_latency do
    IO.puts("\n2. Testing end-to-end latency simulation...")

    # Simulate the current pipeline: LLM -> parse -> StreamManager -> SSE
    test_content = "## Test Response\n\nThis is a test streaming response with **markdown** formatting."

    start_time = System.monotonic_time(:microsecond)

    # Step 1: Simulate LLM chunk reception
    llm_chunk = simulate_llm_chunk(test_content)
    llm_time = System.monotonic_time(:microsecond)

    # Step 2: Simulate chunk parsing (current implementation)
    parsed_content = parse_chunk_current_way(llm_chunk)
    parse_time = System.monotonic_time(:microsecond)

    # Step 3: Simulate StreamManager processing
    processed_chunk = process_chunk_current_way(parsed_content)
    process_time = System.monotonic_time(:microsecond)

    # Step 4: Simulate SSE formatting
    sse_event = format_sse_event(processed_chunk)
    sse_time = System.monotonic_time(:microsecond)

    # Calculate latencies
    llm_latency = llm_time - start_time
    parse_latency = parse_time - llm_time
    process_latency = process_time - parse_time
    sse_latency = sse_time - process_time
    total_latency = sse_time - start_time

    IO.puts("  LLM reception: #{llm_latency} μs")
    IO.puts("  Chunk parsing: #{parse_latency} μs")
    IO.puts("  StreamManager processing: #{process_latency} μs")
    IO.puts("  SSE formatting: #{sse_latency} μs")
    IO.puts("  Total end-to-end: #{total_latency} μs (#{Float.round(total_latency / 1000, 2)} ms)")

    if total_latency > 100_000 do  # 100ms
      IO.puts("  ⚠️  ISSUE: Total latency exceeds 100ms requirement!")
    else
      IO.puts("  ✅ Total latency within 100ms requirement")
    end
  end

  defp analyze_bottlenecks do
    IO.puts("\n3. Analyzing potential bottlenecks...")

    bottlenecks = [
      {"JSON parsing in chunk processing", &test_json_parsing_overhead/0},
      {"Markdown rendering overhead", &test_markdown_rendering_overhead/0},
      {"String concatenation overhead", &test_string_concatenation_overhead/0},
      {"Process message passing overhead", &test_process_messaging_overhead/0}
    ]

    Enum.each(bottlenecks, fn {name, test_fn} ->
      {time, _result} = :timer.tc(test_fn)
      IO.puts("  #{name}: #{time} μs")
    end)

    IO.puts("\n=== Analysis Summary ===")
    IO.puts("Current implementation analysis complete.")
    IO.puts("Key findings:")
    IO.puts("- Chunk processing involves multiple steps that add latency")
    IO.puts("- JSON parsing and markdown rendering are potential bottlenecks")
    IO.puts("- Process messaging adds overhead to each chunk")
    IO.puts("- String operations accumulate latency over multiple chunks")
  end

  # Simulate current chunk processing as done in StreamManager
  defp process_chunk_current_way(chunk) do
    # Simulate what StreamManager.handle_info({:chunk, content}, state) does

    # 1. String concatenation
    accumulated = "" <> chunk

    # 2. Size check
    _size_check = byte_size(accumulated) < 1_048_576

    # 3. Markdown syntax detection
    _has_markdown = contains_markdown_syntax?(chunk)

    # 4. HTML escaping (fallback case)
    escaped = escape_html_simple(chunk)

    # 5. Event data preparation
    %{
      content: chunk,
      chunk_html: escaped,
      session_id: "test_session",
      timestamp: DateTime.utc_now()
    }
  end

  defp parse_chunk_current_way(chunk) do
    # Simulate parsing as done in parse_openai_stream_chunk
    case Jason.decode(chunk) do
      {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]}} ->
        content
      _ ->
        "parsed_content"
    end
  rescue
    _ -> "fallback_content"
  end

  defp simulate_llm_chunk(content) do
    # Simulate OpenAI streaming format
    Jason.encode!(%{
      "choices" => [
        %{
          "delta" => %{
            "content" => content
          }
        }
      ]
    })
  end

  defp format_sse_event(data) do
    # Simulate SSE event formatting
    "data: #{Jason.encode!(data)}\n\n"
  end

  defp contains_markdown_syntax?(content) do
    String.contains?(content, ["#", "*", "_", "`", "[", "]", "**", "__"])
  end

  defp escape_html_simple(content) do
    content
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # Bottleneck test functions
  defp test_json_parsing_overhead do
    data = %{"test" => "data", "content" => "sample content chunk"}
    json = Jason.encode!(data)
    Enum.each(1..100, fn _ ->
      Jason.decode!(json)
    end)
  end

  defp test_markdown_rendering_overhead do
    content = "## Test Header\n\nThis is **bold** text with *italic* and `code`."
    # Simulate markdown processing overhead
    Enum.each(1..100, fn _ ->
      String.contains?(content, ["#", "*", "_", "`"])
    end)
  end

  defp test_string_concatenation_overhead do
    base = ""
    Enum.reduce(1..100, base, fn i, acc ->
      acc <> "chunk_#{i} "
    end)
  end

  defp test_process_messaging_overhead do
    parent = self()
    pid = spawn(fn ->
      receive do
        {:test, data} -> send(parent, {:response, data})
      end
    end)

    Enum.each(1..100, fn i ->
      send(pid, {:test, "chunk_#{i}"})
      receive do
        {:response, _} -> :ok
      end
    end)
  end
end

# Run the test
StreamingLatencyTest.run()
