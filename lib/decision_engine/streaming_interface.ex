# lib/decision_engine/streaming_interface.ex
defmodule DecisionEngine.StreamingInterface do
  @moduledoc """
  Unified streaming interface that abstracts provider-specific differences
  and ensures consistent behavior across all LLM providers.

  This module provides a provider-agnostic streaming interface that:
  - Normalizes chunk forwarding behavior across providers
  - Ensures consistent latency and performance characteristics
  - Provides unified error handling and recovery mechanisms
  - Implements provider-specific optimizations transparently
  """

  require Logger

  @typedoc """
  Streaming configuration that works across all providers.
  """
  @type streaming_config :: %{
    provider: atom(),
    api_url: String.t(),
    api_key: String.t(),
    model: String.t(),
    temperature: float(),
    max_tokens: integer(),
    stream: boolean(),
    extra_headers: list(),
    # Unified streaming options
    chunk_timeout_ms: integer(),
    max_chunk_size: integer(),
    enable_flow_control: boolean(),
    enable_sequence_tracking: boolean()
  }

  @typedoc """
  Streaming session state for provider-agnostic management.
  """
  @type streaming_session :: %{
    session_id: String.t(),
    provider: atom(),
    stream_pid: pid(),
    start_time: integer(),
    chunk_count: integer(),
    total_bytes: integer(),
    last_chunk_time: integer(),
    sequence_counter: reference() | nil,
    error_count: integer(),
    status: :active | :completed | :error | :timeout
  }

  # Default streaming configuration
  @default_streaming_config %{
    chunk_timeout_ms: 5000,
    max_chunk_size: 8192,
    enable_flow_control: true,
    enable_sequence_tracking: true
  }

  @doc """
  Initiates streaming with unified interface across all providers.

  ## Parameters
  - prompt: The prompt to send to the LLM
  - config: Provider-specific configuration
  - stream_pid: Process to receive streaming chunks
  - opts: Additional streaming options

  ## Returns
  - {:ok, session} on successful stream initiation
  - {:error, reason} if streaming fails to start
  """
  @spec start_stream(String.t(), map(), pid(), keyword()) ::
    {:ok, streaming_session()} | {:error, term()}
  def start_stream(prompt, config, stream_pid, opts \\ []) do
    # Normalize configuration for unified interface
    unified_config = normalize_streaming_config(config, opts)
    session_id = generate_session_id()

    # Create streaming session state
    session = %{
      session_id: session_id,
      provider: unified_config.provider,
      stream_pid: stream_pid,
      start_time: System.monotonic_time(:microsecond),
      chunk_count: 0,
      total_bytes: 0,
      last_chunk_time: 0,
      sequence_counter: if(unified_config.enable_sequence_tracking, do: :counters.new(1, [:atomics]), else: nil),
      error_count: 0,
      status: :active
    }

    Logger.info("Starting unified streaming session #{session_id} with provider #{unified_config.provider}")

    # Start provider-specific streaming with unified wrapper
    case start_provider_stream(prompt, unified_config, session) do
      :ok ->
        # Register session for monitoring
        register_streaming_session(session)
        {:ok, session}

      {:error, reason} ->
        Logger.error("Failed to start streaming session #{session_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets streaming session metrics for monitoring.

  ## Parameters
  - session_id: The streaming session identifier

  ## Returns
  - {:ok, metrics} with session performance metrics
  - {:error, :not_found} if session doesn't exist
  """
  @spec get_session_metrics(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_session_metrics(session_id) do
    case get_streaming_session(session_id) do
      {:ok, session} ->
        metrics = calculate_session_metrics(session)
        {:ok, metrics}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists all active streaming sessions across all providers.

  ## Returns
  - List of active streaming sessions with basic metrics
  """
  @spec list_active_sessions() :: [map()]
  def list_active_sessions do
    get_all_streaming_sessions()
    |> Enum.filter(&(&1.status == :active))
    |> Enum.map(&session_summary/1)
  end

  @doc """
  Cancels a streaming session gracefully.

  ## Parameters
  - session_id: The session to cancel

  ## Returns
  - :ok if cancellation succeeded
  - {:error, reason} if cancellation failed
  """
  @spec cancel_session(String.t()) :: :ok | {:error, term()}
  def cancel_session(session_id) do
    case get_streaming_session(session_id) do
      {:ok, session} ->
        Logger.info("Cancelling streaming session #{session_id}")
        send(session.stream_pid, {:cancel_stream, session_id})
        update_session_status(session_id, :cancelled)
        :ok

      {:error, :not_found} ->
        {:error, :session_not_found}
    end
  end

  ## Private Functions

  # Normalize configuration to unified format
  defp normalize_streaming_config(config, opts) do
    base_config = Map.merge(@default_streaming_config, config)

    # Apply options overrides
    Enum.reduce(opts, base_config, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
    |> ensure_streaming_enabled()
    |> validate_provider_config()
  end

  # Ensure streaming is enabled in configuration
  defp ensure_streaming_enabled(config) do
    Map.put(config, :stream, true)
  end

  # Validate provider-specific configuration
  defp validate_provider_config(config) do
    case Map.get(config, :provider) do
      provider when provider in [:openai, :anthropic, :ollama, :openrouter, :custom, :lm_studio] ->
        config

      nil ->
        raise ArgumentError, "Provider must be specified for streaming"

      invalid_provider ->
        raise ArgumentError, "Unsupported provider for streaming: #{invalid_provider}"
    end
  end

  # Start provider-specific streaming with unified wrapper
  defp start_provider_stream(prompt, config, session) do
    # Wrap the stream_pid to intercept and normalize chunks
    wrapper_pid = spawn_link(fn ->
      stream_wrapper_loop(session.stream_pid, session, config)
    end)

    # Start provider-specific streaming
    case config.provider do
      :anthropic ->
        start_anthropic_stream(prompt, config, wrapper_pid)

      provider when provider in [:openai, :openrouter, :custom, :lm_studio] ->
        start_openai_compatible_stream(prompt, config, wrapper_pid)

      :ollama ->
        # Use simulation for Ollama until native streaming is implemented
        simulate_ollama_streaming(prompt, wrapper_pid)

      _ ->
        {:error, "Unsupported provider for streaming: #{config.provider}"}
    end
  end

  # Stream wrapper loop that normalizes chunks across providers
  defp stream_wrapper_loop(target_pid, session, config) do
    receive do
      {:chunk, content} ->
        # Normalize chunk and forward with unified format
        normalized_chunk = normalize_chunk(content, session, config)
        forward_normalized_chunk(target_pid, normalized_chunk, session)

        # Update session metrics
        updated_session = update_chunk_metrics(session, content)
        stream_wrapper_loop(target_pid, updated_session, config)

      {:sequenced_chunk, content, sequence} ->
        # Handle sequenced chunks with order preservation
        normalized_chunk = normalize_sequenced_chunk(content, sequence, session, config)
        forward_normalized_chunk(target_pid, normalized_chunk, session)

        updated_session = update_chunk_metrics(session, content)
        stream_wrapper_loop(target_pid, updated_session, config)

      {:complete} ->
        # Forward completion signal
        send(target_pid, {:complete})
        finalize_session(session)

      {:error, reason} ->
        # Use enhanced error handling
        case DecisionEngine.StreamingErrorHandler.handle_streaming_error(
          session.session_id,
          reason,
          session.provider,
          target_pid,
          []
        ) do
          {:ok, :recovered} ->
            Logger.info("Error recovered for streaming session #{session.session_id}")

          {:ok, :fallback} ->
            Logger.info("Fallback activated for streaming session #{session.session_id}")
            update_session_status(session.session_id, :fallback)

          {:error, :session_terminated} ->
            Logger.error("Streaming session #{session.session_id} terminated")
            update_session_status(session.session_id, :terminated)

          {:error, _} ->
            # Fall back to original error handling
            normalized_error = normalize_error(reason, session.provider)
            send(target_pid, {:error, normalized_error})
            update_session_status(session.session_id, :error)
        end

      {:cancel_stream, _session_id} ->
        # Handle cancellation
        send(target_pid, {:stream_cancelled})
        update_session_status(session.session_id, :cancelled)

      {:delayed_forward, target_pid, normalized_chunk} ->
        # Handle delayed chunk forwarding from flow control
        send(target_pid, normalized_chunk)
        stream_wrapper_loop(target_pid, session, config)

      other ->
        Logger.warning("Unexpected message in stream wrapper: #{inspect(other)}")
        stream_wrapper_loop(target_pid, session, config)
    end
  end

  # Normalize chunk content across providers
  defp normalize_chunk(content, session, config) do
    # Apply consistent processing regardless of provider
    processed_content = content
    |> ensure_utf8_encoding()
    |> apply_chunk_size_limit(config.max_chunk_size)

    # Add sequence number if tracking is enabled
    if config.enable_sequence_tracking and session.sequence_counter do
      sequence = :counters.get(session.sequence_counter, 1)
      :counters.add(session.sequence_counter, 1, 1)
      {:sequenced_chunk, processed_content, sequence}
    else
      {:chunk, processed_content}
    end
  end

  # Normalize sequenced chunks
  defp normalize_sequenced_chunk(content, sequence, _session, config) do
    processed_content = content
    |> ensure_utf8_encoding()
    |> apply_chunk_size_limit(config.max_chunk_size)

    {:sequenced_chunk, processed_content, sequence}
  end

  # Forward normalized chunk with flow control
  defp forward_normalized_chunk(target_pid, normalized_chunk, session) do
    current_time = System.monotonic_time(:microsecond)

    # Apply flow control if enabled - temporarily disabled for debugging
    # if should_apply_flow_control?(session, current_time) do
    #   # Delay forwarding to prevent overwhelming the client
    #   Process.send_after(self(), {:delayed_forward, target_pid, normalized_chunk}, 10)
    # else
      send(target_pid, normalized_chunk)
    # end
  end

  # Check if flow control should be applied
  defp should_apply_flow_control?(session, current_time) do
    # Simple flow control: limit to 50 chunks per second
    time_since_last = current_time - session.last_chunk_time
    time_since_last < 20_000  # 20ms minimum between chunks
  end

  # Ensure UTF-8 encoding for consistent handling
  defp ensure_utf8_encoding(content) when is_binary(content) do
    case String.valid?(content) do
      true -> content
      false ->
        # Attempt to fix encoding issues
        content
        |> :unicode.characters_to_binary(:latin1, :utf8)
        |> case do
          {:error, _, _} -> ""  # Drop invalid content
          {:incomplete, valid, _} -> valid
          valid when is_binary(valid) -> valid
        end
    end
  end

  defp ensure_utf8_encoding(_content), do: ""

  # Apply chunk size limits for consistency
  defp apply_chunk_size_limit(content, max_size) when byte_size(content) <= max_size do
    content
  end

  defp apply_chunk_size_limit(content, max_size) do
    # Split large chunks at UTF-8 boundaries
    binary_part(content, 0, max_size)
    |> ensure_utf8_boundary()
  end

  # Ensure we don't split in the middle of a UTF-8 character
  defp ensure_utf8_boundary(content) do
    case String.valid?(content) do
      true -> content
      false ->
        # Find the last valid UTF-8 boundary
        size = byte_size(content)
        find_utf8_boundary(content, size - 1)
    end
  end

  defp find_utf8_boundary(content, pos) when pos > 0 do
    case binary_part(content, 0, pos) do
      valid_content when is_binary(valid_content) ->
        if String.valid?(valid_content) do
          valid_content
        else
          find_utf8_boundary(content, pos - 1)
        end
    end
  end

  defp find_utf8_boundary(_content, _pos), do: ""

  # Normalize errors across providers
  defp normalize_error(reason, provider) do
    %{
      reason: reason,
      provider: provider,
      timestamp: System.system_time(:second),
      recoverable: is_recoverable_error?(reason)
    }
  end

  # Determine if an error is recoverable
  defp is_recoverable_error?(reason) do
    case reason do
      "HTTP 429" -> true  # Rate limiting
      "HTTP 502" -> true  # Bad gateway
      "HTTP 503" -> true  # Service unavailable
      {:timeout, _} -> true
      :timeout -> true
      _ -> false
    end
  end

  # Update chunk metrics for session
  defp update_chunk_metrics(session, content) do
    current_time = System.monotonic_time(:microsecond)

    %{session |
      chunk_count: session.chunk_count + 1,
      total_bytes: session.total_bytes + byte_size(content),
      last_chunk_time: current_time
    }
  end

  # Calculate comprehensive session metrics
  defp calculate_session_metrics(session) do
    current_time = System.monotonic_time(:microsecond)
    duration_us = current_time - session.start_time
    duration_ms = duration_us / 1000

    %{
      session_id: session.session_id,
      provider: session.provider,
      status: session.status,
      duration_ms: Float.round(duration_ms, 2),
      chunk_count: session.chunk_count,
      total_bytes: session.total_bytes,
      avg_chunk_size: if(session.chunk_count > 0, do: session.total_bytes / session.chunk_count, else: 0),
      chunks_per_second: if(duration_ms > 0, do: session.chunk_count / (duration_ms / 1000), else: 0),
      bytes_per_second: if(duration_ms > 0, do: session.total_bytes / (duration_ms / 1000), else: 0),
      error_count: session.error_count,
      last_activity: session.last_chunk_time
    }
  end

  # Generate unique session ID
  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # Session summary for listing
  defp session_summary(session) do
    %{
      session_id: session.session_id,
      provider: session.provider,
      status: session.status,
      chunk_count: session.chunk_count,
      duration_ms: (System.monotonic_time(:microsecond) - session.start_time) / 1000
    }
  end

  # Simulate Ollama streaming for testing
  defp simulate_ollama_streaming(_prompt, stream_pid) do
    spawn_link(fn ->
      # Simulate realistic Ollama streaming behavior
      chunks = [
        "Based on your scenario, ",
        "I can provide the following analysis:\n\n",
        "## Key Considerations\n\n",
        "- **Technical Requirements**: ",
        "Your requirements align well with available solutions\n",
        "- **Implementation Approach**: ",
        "Consider a phased rollout strategy\n\n",
        "## Recommendations\n\n",
        "1. Start with a pilot implementation\n",
        "2. Gather feedback and iterate\n",
        "3. Scale based on results"
      ]

      Enum.each(chunks, fn chunk ->
        Process.sleep(50 + :rand.uniform(100))  # Realistic delay variation
        send(stream_pid, {:chunk, chunk})
      end)

      send(stream_pid, {:complete})
    end)

    :ok
  end

  # Session management functions (would integrate with existing registry)
  defp register_streaming_session(session) do
    # Store session in ETS table or Registry for tracking
    :ets.insert(:streaming_sessions, {session.session_id, session})
  end

  defp get_streaming_session(session_id) do
    case :ets.lookup(:streaming_sessions, session_id) do
      [{^session_id, session}] -> {:ok, session}
      [] -> {:error, :not_found}
    end
  end

  defp get_all_streaming_sessions do
    :ets.tab2list(:streaming_sessions)
    |> Enum.map(fn {_id, session} -> session end)
  end

  defp update_session_status(session_id, status) do
    case get_streaming_session(session_id) do
      {:ok, session} ->
        updated_session = %{session | status: status}
        :ets.insert(:streaming_sessions, {session_id, updated_session})

      {:error, :not_found} ->
        Logger.warning("Attempted to update status for non-existent session: #{session_id}")
    end
  end

  defp finalize_session(session) do
    update_session_status(session.session_id, :completed)
    Logger.info("Streaming session #{session.session_id} completed - #{session.chunk_count} chunks, #{session.total_bytes} bytes")
  end

  # Provider-specific streaming implementations

  # Start OpenAI-compatible streaming
  defp start_openai_compatible_stream(prompt, config, stream_pid) do
    headers = build_openai_headers(config)
    body = build_openai_streaming_body(prompt, config)

    Logger.debug("Starting OpenAI-compatible streaming at #{config.api_url} provider=#{config.provider} model=#{config.model}")

    # Start streaming in a separate process to avoid blocking
    spawn_link(fn ->
      try do
        # Use Finch for streaming support
        json_body = Jason.encode!(body)
        request = Finch.build(:post, config.api_url, headers, json_body)

        # Initialize sequence counter for chunk ordering
        sequence_counter = :counters.new(1, [:atomics])

        case Finch.stream(request, DecisionEngine.Finch, nil, fn
          {:status, status}, acc when status == 200 ->
            {:cont, acc}

          {:status, status}, _acc ->
            send(stream_pid, {:error, "HTTP #{status}"})
            {:halt, :error}

          {:headers, _headers}, acc ->
            {:cont, acc}

          {:data, chunk}, acc ->
            # Process chunk with sequence tracking
            case parse_openai_stream_chunk_optimized(chunk, stream_pid, sequence_counter) do
              :continue ->
                {:cont, acc}

              :done ->
                send(stream_pid, {:complete})
                {:halt, :done}

              {:error, reason} ->
                send(stream_pid, {:error, reason})
                {:halt, :error}
            end
        end) do
          {:ok, _acc} ->
            :ok

          {:error, reason} ->
            send(stream_pid, {:error, reason})
        end
      rescue
        error ->
          Logger.error("OpenAI streaming error: #{inspect(error)}")
          send(stream_pid, {:error, "Streaming failed: #{inspect(error)}"})
      end
    end)

    :ok
  end

  # Start Anthropic streaming
  defp start_anthropic_stream(prompt, config, stream_pid) do
    headers = [
      {"x-api-key", config.api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ] ++ Map.get(config, :extra_headers, [])

    body = %{
      model: config.model,
      max_tokens: Map.get(config, :max_tokens, 2000),
      temperature: Map.get(config, :temperature, 0.1),
      stream: true,
      messages: [
        %{
          role: "user",
          content: prompt
        }
      ]
    }

    Logger.debug("Starting Anthropic streaming")

    # Start streaming in a separate process
    spawn_link(fn ->
      try do
        json_body = Jason.encode!(body)
        request = Finch.build(:post, config.api_url, headers, json_body)

        # Initialize sequence counter for chunk ordering
        sequence_counter = :counters.new(1, [:atomics])

        case Finch.stream(request, DecisionEngine.Finch, nil, fn
          {:status, status}, acc when status == 200 ->
            {:cont, acc}

          {:status, status}, _acc ->
            send(stream_pid, {:error, "HTTP #{status}"})
            {:halt, :error}

          {:headers, _headers}, acc ->
            {:cont, acc}

          {:data, chunk}, acc ->
            # Process chunk with sequence tracking
            case parse_anthropic_stream_chunk_optimized(chunk, stream_pid, sequence_counter) do
              :continue ->
                {:cont, acc}

              :done ->
                send(stream_pid, {:complete})
                {:halt, :done}

              {:error, reason} ->
                send(stream_pid, {:error, reason})
                {:halt, :error}
            end
        end) do
          {:ok, _acc} ->
            :ok

          {:error, reason} ->
            send(stream_pid, {:error, reason})
        end
      rescue
        error ->
          Logger.error("Anthropic streaming error: #{inspect(error)}")
          send(stream_pid, {:error, "Streaming failed: #{inspect(error)}"})
      end
    end)

    :ok
  end

  # Build OpenAI headers
  defp build_openai_headers(config) do
    base_headers = [
      {"content-type", "application/json"}
    ]

    auth_header = case Map.get(config, :api_key) do
      nil -> []
      key -> [{"authorization", "Bearer #{key}"}]
    end

    extra_headers = Map.get(config, :extra_headers, [])

    base_headers ++ auth_header ++ extra_headers
  end

  # Build OpenAI streaming body
  defp build_openai_streaming_body(prompt, config) do
    %{
      model: config.model,
      messages: [
        %{
          role: "system",
          content: "You are a helpful assistant that provides architectural recommendations. Format your response using markdown for better readability with headers, lists, and emphasis where appropriate."
        },
        %{
          role: "user",
          content: prompt
        }
      ],
      temperature: Map.get(config, :temperature, 0.1),
      max_tokens: Map.get(config, :max_tokens, 2000),
      stream: true
    }
  end

  # Optimized OpenAI chunk parsing with immediate forwarding
  defp parse_openai_stream_chunk_optimized(chunk, stream_pid, sequence_counter) do
    # Process chunk with minimal latency and immediate forwarding
    lines = String.split(chunk, "\n", trim: true)

    Enum.reduce_while(lines, :continue, fn line, _acc ->
      case line do
        "data: [DONE]" ->
          {:halt, :done}

        <<"data: ", json_data::binary>> ->
          case fast_extract_openai_content(json_data) do
            {:content, content} when byte_size(content) > 0 ->
              sequence_num = :counters.get(sequence_counter, 1)
              :counters.add(sequence_counter, 1, 1)
              send(stream_pid, {:sequenced_chunk, content, sequence_num})
              {:cont, :continue}

            :done ->
              {:halt, :done}

            :continue ->
              {:cont, :continue}

            {:error, _reason} ->
              # Fallback to full JSON parsing
              case Jason.decode(json_data) do
                {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]}} when is_binary(content) and byte_size(content) > 0 ->
                  sequence_num = :counters.get(sequence_counter, 1)
                  :counters.add(sequence_counter, 1, 1)
                  send(stream_pid, {:sequenced_chunk, content, sequence_num})
                  {:cont, :continue}

                {:ok, %{"choices" => [%{"finish_reason" => reason} | _]}} when not is_nil(reason) ->
                  {:halt, :done}

                {:ok, _} ->
                  {:cont, :continue}

                {:error, reason} ->
                  {:halt, {:error, "Failed to parse stream chunk: #{inspect(reason)}"}}
              end
          end

        _ ->
          {:cont, :continue}
      end
    end)
  end

  # Optimized Anthropic chunk parsing with immediate forwarding
  defp parse_anthropic_stream_chunk_optimized(chunk, stream_pid, sequence_counter) do
    lines = String.split(chunk, "\n", trim: true)

    Enum.reduce_while(lines, :continue, fn line, _acc ->
      case line do
        <<"data: ", json_data::binary>> ->
          case fast_extract_anthropic_content(json_data) do
            {:content, content} when byte_size(content) > 0 ->
              sequence_num = :counters.get(sequence_counter, 1)
              :counters.add(sequence_counter, 1, 1)
              send(stream_pid, {:sequenced_chunk, content, sequence_num})
              {:cont, :continue}

            :done ->
              {:halt, :done}

            :continue ->
              {:cont, :continue}

            {:error, _reason} ->
              # Fallback to full JSON parsing
              case Jason.decode(json_data) do
                {:ok, %{"type" => "content_block_delta", "delta" => %{"text" => content}}} when is_binary(content) and byte_size(content) > 0 ->
                  sequence_num = :counters.get(sequence_counter, 1)
                  :counters.add(sequence_counter, 1, 1)
                  send(stream_pid, {:sequenced_chunk, content, sequence_num})
                  {:cont, :continue}

                {:ok, %{"type" => "message_stop"}} ->
                  {:halt, :done}

                {:ok, _} ->
                  {:cont, :continue}

                {:error, reason} ->
                  {:halt, {:error, "Failed to parse Anthropic stream chunk: #{inspect(reason)}"}}
              end
          end

        _ ->
          {:cont, :continue}
      end
    end)
  end

  # Fast content extraction for OpenAI format
  defp fast_extract_openai_content(json_data) do
    case json_data do
      json when is_binary(json) ->
        case Regex.run(~r/"content":"([^"]*)"/, json, capture: :all_but_first) do
          [content] when byte_size(content) > 0 ->
            decoded_content = decode_json_string(content)
            {:content, decoded_content}

          _ ->
            case Regex.run(~r/"finish_reason":"([^"]*)"/, json) do
              [_reason] -> :done
              _ -> :continue
            end
        end

      _ ->
        {:error, :invalid_format}
    end
  rescue
    _ ->
      {:error, :parsing_error}
  end

  # Fast content extraction for Anthropic format
  defp fast_extract_anthropic_content(json_data) do
    case json_data do
      json when is_binary(json) ->
        cond do
          String.contains?(json, "content_block_delta") and String.contains?(json, "\"text\":") ->
            case Regex.run(~r/"text":"([^"]*)"/, json, capture: :all_but_first) do
              [content] when byte_size(content) > 0 ->
                decoded_content = decode_json_string(content)
                {:content, decoded_content}

              _ ->
                :continue
            end

          String.contains?(json, "message_stop") ->
            :done

          true ->
            :continue
        end

      _ ->
        {:error, :invalid_format}
    end
  rescue
    _ ->
      {:error, :parsing_error}
  end

  # Decode JSON string escape sequences
  defp decode_json_string(content) do
    content
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\r", "\r")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  # Initialize ETS table for session tracking (called during application startup)
  @doc false
  def init_session_storage do
    :ets.new(:streaming_sessions, [:named_table, :public, :set])
  end
end
