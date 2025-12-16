# lib/decision_engine/llm_client.ex
defmodule DecisionEngine.LLMClient do
  @moduledoc """
  Handles API calls to LLM providers (OpenAI-compatible and Anthropic).
  Supports multiple providers through configuration.
  """

  require Logger

  @max_retries 3

  @doc """
  Configuration structure:
  %{
    provider: :openai | :anthropic | :ollama | :openrouter | :custom | :lm_studio,
    api_url: "https://api.openai.com/v1/chat/completions",
    api_key: "sk-...",
    model: "gpt-4",
    # Optional
    extra_headers: [{"X-Custom-Header", "value"}],
    temperature: 0.1
  }
  """

  # New domain-aware extract_signals function
  def extract_signals(user_scenario, config, domain, schema_module, rule_config, retry_count \\ 0) do
    with {:ok, final_config} <- get_unified_config(config) do
      prompt = build_extraction_prompt(user_scenario, domain, schema_module, rule_config, retry_count)

      case call_llm(prompt, final_config) do
        {:ok, response} ->
          case parse_and_validate_signals(response, user_scenario, final_config, domain, schema_module, retry_count) do
            {:retry_needed, scenario, config, domain, schema_module, new_retry_count} ->
              extract_signals(scenario, config, domain, schema_module, rule_config, new_retry_count)

            result ->
              result
          end

        {:error, reason} ->
          Logger.error("LLM API call failed for domain #{domain}: #{inspect(reason)}")
          {:error, "Failed to call LLM API: #{inspect(reason)}"}
      end
    end
  end

  # Backward compatibility - delegates to PowerPlatform domain
  def extract_signals(user_scenario, config, retry_count \\ 0) do
    schema_module = DecisionEngine.SignalsSchema.PowerPlatform
    # We need to load the rule config for backward compatibility
    case DecisionEngine.RuleConfig.load(:power_platform) do
      {:ok, rule_config} ->
        extract_signals(user_scenario, config, :power_platform, schema_module, rule_config, retry_count)

      {:error, reason} ->
        Logger.error("Failed to load power_platform config for backward compatibility: #{inspect(reason)}")
        {:error, "Failed to load configuration: #{inspect(reason)}"}
    end
  end

  def generate_justification(signals, decision_result, config, domain) do
    with {:ok, final_config} <- get_unified_config(config) do
      prompt = build_justification_prompt(signals, decision_result, domain)

      case call_llm(prompt, final_config) do
        {:ok, response} ->
          {:ok, response}

        {:error, reason} ->
          {:error, "Failed to generate justification for domain #{domain}: #{inspect(reason)}"}
      end
    end
  end

  # Backward compatibility - delegates to PowerPlatform domain
  def generate_justification(signals, decision_result, config) do
    generate_justification(signals, decision_result, config, :power_platform)
  end

  @doc """
  Generates text using LLM for general purposes like description generation.

  ## Parameters
  - prompt: String prompt to send to LLM
  - config: LLM configuration map (optional, uses LLMConfigManager if nil)

  ## Returns
  - {:ok, String.t()} with generated text
  - {:error, term()} on failure
  """
  @spec generate_text(String.t(), map() | nil) :: {:ok, String.t()} | {:error, term()}
  def generate_text(prompt, config \\ nil) do
    with {:ok, final_config} <- get_unified_config(config) do
      case call_llm(prompt, final_config) do
        {:ok, response} ->
          {:ok, response}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Streams LLM justification generation to a StreamManager process.

  This function initiates streaming LLM response generation and sends content
  chunks to the specified stream_pid as they become available from the LLM provider.

  ## Parameters
  - signals: Extracted signals from scenario processing
  - decision_result: Result from rule engine evaluation
  - config: LLM client configuration (must include streaming support)
  - domain: The domain being processed
  - stream_pid: Process ID of the StreamManager to receive chunks

  ## Returns
  - :ok if streaming started successfully
  - {:error, reason} if streaming failed to start

  ## Streaming Protocol
  The stream_pid will receive messages in the following format:
  - {:chunk, content} - Partial content chunk from LLM
  - {:complete} - Streaming completed successfully
  - {:error, reason} - Streaming failed with error
  """
  @spec stream_justification(map(), map(), map(), atom(), pid()) :: :ok | {:error, term()}
  def stream_justification(signals, decision_result, config, domain, stream_pid) do
    with {:ok, final_config} <- get_unified_config(config) do
      prompt = build_justification_prompt(signals, decision_result, domain)

      # Configure LLM for streaming mode
      streaming_config = Map.put(final_config, :stream, true)

      Logger.info("Starting LLM streaming for domain #{domain}")

      case call_llm_stream(prompt, streaming_config, stream_pid) do
        :ok ->
          Logger.debug("LLM streaming initiated successfully for domain #{domain}")
          :ok
        {:error, reason} ->
          Logger.error("Failed to start LLM streaming for domain #{domain}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # Reflection-specific LLM operations

  @doc """
  Evaluates domain configuration quality using LLM-based reflection.

  Sends a domain configuration to the LLM for comprehensive quality evaluation
  across multiple dimensions including signal fields, decision patterns, and overall structure.

  ## Parameters
  - domain_config: The domain configuration map to evaluate
  - config: LLM configuration (optional, uses system config if nil)
  - content_type: Content type classification for adaptive prompting

  ## Returns
  - {:ok, evaluation_response} on successful evaluation
  - {:error, reason} if evaluation fails
  """
  @spec evaluate_domain_configuration(map(), map() | nil, atom()) :: {:ok, String.t()} | {:error, term()}
  def evaluate_domain_configuration(domain_config, config \\ nil, content_type \\ :general) do
    with {:ok, final_config} <- get_unified_config(config),
         {:ok, rate_limited_config} <- apply_reflection_rate_limiting(final_config) do

      prompt = build_reflection_evaluation_prompt(domain_config, content_type)

      Logger.debug("Evaluating domain configuration for content type: #{content_type}")

      case call_llm_with_retry(prompt, rate_limited_config, :evaluation) do
        {:ok, response} ->
          {:ok, response}
        {:error, reason} ->
          Logger.error("Domain configuration evaluation failed: #{inspect(reason)}")
          {:error, "Failed to evaluate domain configuration: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Generates improvement suggestions for domain configuration using LLM.

  Analyzes evaluation results and generates specific, actionable recommendations
  for enhancing domain configuration quality.

  ## Parameters
  - domain_config: The domain configuration to improve
  - evaluation_results: Previous evaluation results for context
  - config: LLM configuration (optional)
  - content_type: Content type for adaptive prompting

  ## Returns
  - {:ok, improvement_suggestions} on success
  - {:error, reason} if generation fails
  """
  @spec generate_improvement_suggestions(map(), map(), map() | nil, atom()) :: {:ok, String.t()} | {:error, term()}
  def generate_improvement_suggestions(domain_config, evaluation_results, config \\ nil, content_type \\ :general) do
    with {:ok, final_config} <- get_unified_config(config),
         {:ok, rate_limited_config} <- apply_reflection_rate_limiting(final_config) do

      prompt = build_reflection_improvement_prompt(domain_config, evaluation_results, content_type)

      Logger.debug("Generating improvement suggestions for content type: #{content_type}")

      case call_llm_with_retry(prompt, rate_limited_config, :improvement) do
        {:ok, response} ->
          {:ok, response}
        {:error, reason} ->
          Logger.error("Improvement suggestion generation failed: #{inspect(reason)}")
          {:error, "Failed to generate improvement suggestions: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Conducts multi-turn reflection conversation for iterative improvement.

  Manages a conversation history for iterative domain configuration refinement,
  maintaining context across multiple reflection iterations.

  ## Parameters
  - conversation_history: List of previous messages in the conversation
  - current_config: Current domain configuration state
  - config: LLM configuration (optional)
  - content_type: Content type for adaptive prompting

  ## Returns
  - {:ok, {response, updated_history}} on success
  - {:error, reason} if conversation fails
  """
  @spec conduct_reflection_conversation([map()], map(), map() | nil, atom()) ::
    {:ok, {String.t(), [map()]}} | {:error, term()}
  def conduct_reflection_conversation(conversation_history, current_config, config \\ nil, content_type \\ :general) do
    with {:ok, final_config} <- get_unified_config(config),
         {:ok, rate_limited_config} <- apply_reflection_rate_limiting(final_config) do

      # Build conversation prompt with history
      prompt = build_reflection_conversation_prompt(conversation_history, current_config, content_type)

      Logger.debug("Conducting reflection conversation with #{length(conversation_history)} previous messages")

      case call_llm_with_retry(prompt, rate_limited_config, :conversation) do
        {:ok, response} ->
          # Add the new response to conversation history
          new_message = %{
            role: "assistant",
            content: response,
            timestamp: System.system_time(:second),
            iteration: length(conversation_history) + 1
          }
          updated_history = conversation_history ++ [new_message]

          {:ok, {response, updated_history}}
        {:error, reason} ->
          Logger.error("Reflection conversation failed: #{inspect(reason)}")
          {:error, "Failed to conduct reflection conversation: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Validates refined domain configuration using LLM analysis.

  Compares original and refined configurations to validate that improvements
  are beneficial and maintain configuration integrity.

  ## Parameters
  - original_config: The original domain configuration
  - refined_config: The refined domain configuration
  - config: LLM configuration (optional)

  ## Returns
  - {:ok, validation_response} on successful validation
  - {:error, reason} if validation fails
  """
  @spec validate_configuration_refinement(map(), map(), map() | nil) :: {:ok, String.t()} | {:error, term()}
  def validate_configuration_refinement(original_config, refined_config, config \\ nil) do
    with {:ok, final_config} <- get_unified_config(config),
         {:ok, rate_limited_config} <- apply_reflection_rate_limiting(final_config) do

      prompt = build_reflection_validation_prompt(original_config, refined_config)

      Logger.debug("Validating configuration refinement")

      case call_llm_with_retry(prompt, rate_limited_config, :validation) do
        {:ok, response} ->
          {:ok, response}
        {:error, reason} ->
          Logger.error("Configuration validation failed: #{inspect(reason)}")
          {:error, "Failed to validate configuration refinement: #{inspect(reason)}"}
      end
    end
  end

  defp build_extraction_prompt(scenario, domain, schema_module, rule_config, retry_count) do
    base_instruction = if retry_count > 0 do
      "CRITICAL: Return ONLY valid JSON. No text, no markdown, no code blocks. Just pure JSON starting with { and ending with }."
    else
      "Extract architecture decision signals from the following scenario and return ONLY valid JSON."
    end

    domain_context = build_domain_context(domain, rule_config)
    field_descriptions = build_field_descriptions(schema_module)
    pattern_summaries = build_pattern_summaries(rule_config)
    retry_guidance = if retry_count > 0, do: build_retry_guidance(domain, retry_count), else: ""

    """
    #{base_instruction}

    #{domain_context}

    Scenario: "#{scenario}"

    #{field_descriptions}

    #{pattern_summaries}

    #{retry_guidance}

    Return ONLY the JSON object, nothing else.
    """
  end

  defp build_justification_prompt(signals, decision_result, domain) do
    domain_name = domain |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

    # Handle different decision result structures
    {pattern_id, recommendation, score} = case decision_result do
      %{pattern_id: pid, summary: summary, score: s} ->
        {pid, summary, s}

      %{"pattern_id" => pid, "summary" => summary, "score" => s} ->
        {pid, summary, s}

      %{recommendation: rec} ->
        {"unknown", rec, "N/A"}

      %{"recommendation" => rec} ->
        {"unknown", rec, "N/A"}

      _ ->
        {"unknown", "No specific recommendation", "N/A"}
    end

    """
    Based on the following architecture signals and decision outcome for the #{domain_name} domain,
    provide a clear justification explaining why this is the proper solution for the scenario.

    Domain: #{domain_name}

    Signals:
    #{Jason.encode!(signals, pretty: true)}

    Decision Outcome:
    - Pattern: #{pattern_id}
    - Recommendation: #{recommendation}
    - Score: #{score}

    Provide a 2-3 paragraph justification that:
    1. Explains why this solution fits the scenario within the #{domain_name} context
    2. Highlights the key factors that led to this decision
    3. Mentions any domain-specific considerations, caveats, or alternatives if applicable

    Format your response using markdown with headers, lists, and emphasis for better readability.
    Be specific and reference the actual signals from the scenario, considering the #{domain_name} domain context.
    """
  end

  defp build_domain_context(domain, rule_config) do
    domain_name = domain |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
    domain_from_config = rule_config["domain"] || "unknown"

    """
    DOMAIN CONTEXT: #{domain_name}
    You are extracting signals for architectural decisions in the #{domain_name} domain.
    Configuration domain: #{domain_from_config}
    Focus on signals that are relevant to #{domain_name} technologies and patterns.
    """
  end

  defp build_field_descriptions(schema_module) do
    schema = schema_module.schema()
    properties = schema["properties"] || %{}

    field_descriptions =
      properties
      |> Enum.map(fn {field, definition} ->
        description = definition["description"] || "No description available"
        enum_values = case definition do
          %{"enum" => values} -> " (options: #{inspect(values)})"
          %{"items" => %{"enum" => values}} -> " (array of options: #{inspect(values)})"
          _ -> ""
        end
        "- #{field}: #{description}#{enum_values}"
      end)
      |> Enum.join("\n")

    """
    Extract the following fields based on the domain-specific schema:
    #{field_descriptions}
    """
  end

  defp build_pattern_summaries(rule_config) do
    patterns = rule_config["patterns"] || []

    if Enum.empty?(patterns) do
      ""
    else
      pattern_summaries =
        patterns
        |> Enum.map(fn pattern ->
          "- #{pattern["summary"]} (#{pattern["id"]})"
        end)
        |> Enum.join("\n")

      """
      AVAILABLE PATTERNS IN THIS DOMAIN:
      The following patterns are available for recommendations. Extract signals that align with these patterns:
      #{pattern_summaries}
      """
    end
  end

  defp build_retry_guidance(domain, retry_count) do
    domain_name = domain |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

    """
    RETRY GUIDANCE (Attempt #{retry_count + 1}):
    Previous extraction failed validation. Please ensure:
    1. All field values match the exact enum options provided for #{domain_name}
    2. Array fields contain only valid enum values
    3. Required fields are included
    4. JSON structure is valid and complete
    5. Focus on #{domain_name}-specific signals and patterns
    """
  end

  defp call_llm(prompt, config) do
    case config.provider do
      :anthropic ->
        call_anthropic(prompt, config)

      provider when provider in [:openai, :ollama, :openrouter, :custom, :lm_studio] ->
        call_openai_compatible(prompt, config)

      _ ->
        {:error, "Unsupported provider: #{config.provider}"}
    end
  end

  # Initiates streaming LLM API call and sends chunks to the specified process.
  @spec call_llm_stream(String.t(), map(), pid()) :: :ok | {:error, term()}
  defp call_llm_stream(prompt, config, stream_pid) do
    # Use the unified streaming interface for consistent behavior across providers
    case DecisionEngine.StreamingInterface.start_stream(prompt, config, stream_pid) do
      {:ok, _session} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_openai_compatible(prompt, config) do
    headers = build_openai_headers(config)
    body = build_openai_body(prompt, config)

    Logger.debug("Calling LLM at #{config.api_url} provider=#{config.provider} model=#{config.model}")



    case Req.post(config.api_url, json: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: response_body}} ->
        extract_openai_content(response_body)

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_anthropic(prompt, config) do
    headers = [
      {"x-api-key", config.api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ] ++ Map.get(config, :extra_headers, [])

    body = %{
      model: config.model,
      max_tokens: Map.get(config, :max_tokens, 2000),
      temperature: Map.get(config, :temperature, 0.1),
      messages: [
        %{
          role: "user",
          content: prompt
        }
      ]
    }

    case Req.post(config.api_url, json: body, headers: headers) do
      {:ok, %{status: 200, body: response_body}} ->
        text_content =
          response_body["content"]
          |> Enum.find(&(&1["type"] == "text"))
          |> Map.get("text", "")

        {:ok, text_content}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

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

  defp build_openai_body(prompt, config) do
    %{
      model: config.model,
      messages: [
        %{
          role: "system",
          content: "You are a helpful assistant that extracts structured data and provides architectural recommendations."
        },
        %{
          role: "user",
          content: prompt
        }
      ],
      temperature: Map.get(config, :temperature, 0.1),
      max_tokens: Map.get(config, :max_tokens, 2000)
    }
    |> maybe_add_json_mode(config)
  end

  defp maybe_add_json_mode(body, config) do
    # Some providers support response_format for JSON mode
    if Map.get(config, :json_mode, false) do
      Map.put(body, :response_format, %{type: "json_object"})
    else
      body
    end
  end

  defp extract_openai_content(response_body) do
    case response_body do
      %{"choices" => [%{"message" => %{"content" => content}} | _]} ->
        {:ok, content}

      %{"error" => error} ->
        {:error, "API error: #{inspect(error)}"}

      _ ->
        {:error, "Unexpected response format: #{inspect(response_body)}"}
    end
  end

  defp parse_and_validate_signals(response, scenario, config, domain, schema_module, retry_count) do
    # Layer 1: JSON Parsing
    cleaned_response = clean_json_response(response)

    case Jason.decode(cleaned_response) do
      {:ok, signals} ->
        # Layer 2: Schema Validation using domain-specific schema
        schema = schema_module.schema()
        case ExJsonSchema.Validator.validate(
          ExJsonSchema.Schema.resolve(schema),
          signals
        ) do
          :ok ->
            # Layer 3: Apply domain-specific defaults for missing fields
            final_signals = schema_module.apply_defaults(signals)
            {:ok, final_signals}

          {:error, validation_errors} ->
            Logger.warning("Schema validation failed for domain #{domain}: #{inspect(validation_errors)}")

            if retry_count < @max_retries do
              Logger.info("Retrying signal extraction for domain #{domain} (attempt #{retry_count + 1})")
              # Need to get rule_config for retry - this will be passed from the calling function
              {:retry_needed, scenario, config, domain, schema_module, retry_count + 1}
            else
              # Apply defaults and continue despite validation errors
              final_signals = schema_module.apply_defaults(signals)
              {:ok, final_signals}
            end
        end

      {:error, _decode_error} ->
        if retry_count < @max_retries do
          Logger.warning("JSON parsing failed for domain #{domain}, retrying (attempt #{retry_count + 1})")
          {:retry_needed, scenario, config, domain, schema_module, retry_count + 1}
        else
          {:error, "Failed to parse LLM response as JSON after #{@max_retries} retries for domain #{domain}"}
        end
    end
  end

  defp clean_json_response(response) do
    response
    |> String.trim()
    |> String.replace(~r/^```json\s*/, "")
    |> String.replace(~r/```\s*$/, "")
    |> String.trim()
  end

  # Streaming implementation for OpenAI-compatible providers with immediate forwarding
  defp call_openai_compatible_stream(prompt, config, stream_pid) do
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
            # OPTIMIZATION: Immediate forwarding with minimal processing and sequence tracking
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
            # Stream completed successfully
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

  # Streaming implementation for Anthropic with immediate forwarding
  defp call_anthropic_stream(prompt, config, stream_pid) do
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
            # OPTIMIZATION: Immediate forwarding with minimal processing and sequence tracking
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
            # Stream completed successfully
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



  # Parse OpenAI-compatible streaming chunks (legacy - kept for compatibility)
  defp parse_openai_stream_chunk(chunk) do
    # OpenAI streaming format: "data: {json}\n\n"
    lines = String.split(chunk, "\n")

    Enum.reduce_while(lines, :continue, fn line, _acc ->
      case String.trim(line) do
        "data: [DONE]" ->
          Logger.info("LM Studio: Received [DONE] signal")
          {:halt, :done}

        "data: " <> json_data ->
          Logger.debug("LM Studio: Parsing JSON data: #{String.slice(json_data, 0, 100)}")
          case Jason.decode(json_data) do
            {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]}} when is_binary(content) ->
              Logger.debug("LM Studio: Extracted content: #{String.slice(content, 0, 50)}")
              {:halt, {:content, content}}

            {:ok, %{"choices" => [%{"finish_reason" => reason} | _]}} when not is_nil(reason) ->
              Logger.info("LM Studio: Received finish_reason: #{reason}")
              {:halt, :done}

            {:ok, parsed_data} ->
              Logger.debug("LM Studio: Received other data: #{inspect(parsed_data)}")
              {:cont, :continue}

            {:error, reason} ->
              Logger.error("LM Studio: Failed to parse JSON: #{inspect(reason)}, data: #{json_data}")
              {:halt, {:error, "Failed to parse stream chunk: #{inspect(reason)}"}}
          end

        "" ->
          {:cont, :continue}

        line ->
          Logger.debug("LM Studio: Ignoring line: #{line}")
          {:cont, :continue}
      end
    end)
  end

  # Optimized OpenAI-compatible chunk parsing with immediate forwarding
  defp parse_openai_stream_chunk_optimized(chunk, stream_pid, sequence_counter \\ nil) do
    # OPTIMIZATION: Process chunk with minimal latency and immediate forwarding
    # Split only once and process lines efficiently
    lines = String.split(chunk, "\n", trim: true)

    Enum.reduce_while(lines, :continue, fn line, _acc ->
      case line do
        "data: [DONE]" ->
          # Stream completion signal
          {:halt, :done}

        <<"data: ", json_data::binary>> ->
          # OPTIMIZATION: Fast path for content extraction
          case fast_extract_content(json_data) do
            {:content, content} when byte_size(content) > 0 ->
              # IMMEDIATE FORWARDING: Send content as soon as extracted with sequence number
              if sequence_counter do
                sequence_num = :counters.get(sequence_counter, 1)
                :counters.add(sequence_counter, 1, 1)
                send(stream_pid, {:sequenced_chunk, content, sequence_num})
              else
                send(stream_pid, {:chunk, content})
              end
              {:cont, :continue}

            :done ->
              {:halt, :done}

            :continue ->
              {:cont, :continue}

            {:error, _reason} ->
              # Fallback to full JSON parsing only on error
              case Jason.decode(json_data) do
                {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]}} when is_binary(content) and byte_size(content) > 0 ->
                  if sequence_counter do
                    sequence_num = :counters.get(sequence_counter, 1)
                    :counters.add(sequence_counter, 1, 1)
                    send(stream_pid, {:sequenced_chunk, content, sequence_num})
                  else
                    send(stream_pid, {:chunk, content})
                  end
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
          # Skip empty lines and other data
          {:cont, :continue}
      end
    end)
  end

  # Fast content extraction without full JSON parsing
  defp fast_extract_content(json_data) do
    # OPTIMIZATION: Pattern match for common content structure without full JSON decode
    # This handles the most common case: {"choices":[{"delta":{"content":"text"}}]}

    case json_data do
      # Fast path: Look for content pattern in JSON string
      json when is_binary(json) ->
        case Regex.run(~r/"content":"([^"]*)"/, json, capture: :all_but_first) do
          [content] when byte_size(content) > 0 ->
            # Decode escaped characters in content
            decoded_content = decode_json_string(content)
            {:content, decoded_content}

          _ ->
            # Check for finish_reason pattern
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

  # Decode JSON string escape sequences
  defp decode_json_string(content) do
    content
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\r", "\r")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  # Parse Anthropic streaming chunks (legacy - kept for compatibility)
  defp parse_anthropic_stream_chunk(chunk) do
    # Anthropic streaming format: "data: {json}\n\n"
    lines = String.split(chunk, "\n")

    Enum.reduce_while(lines, :continue, fn line, _acc ->
      case String.trim(line) do
        "data: " <> json_data ->
          case Jason.decode(json_data) do
            {:ok, %{"type" => "content_block_delta", "delta" => %{"text" => content}}} ->
              {:halt, {:content, content}}

            {:ok, %{"type" => "message_stop"}} ->
              {:halt, :done}

            {:ok, _} ->
              {:cont, :continue}

            {:error, reason} ->
              {:halt, {:error, "Failed to parse Anthropic stream chunk: #{inspect(reason)}"}}
          end

        "" ->
          {:cont, :continue}

        _ ->
          {:cont, :continue}
      end
    end)
  end

  # Optimized Anthropic chunk parsing with immediate forwarding
  defp parse_anthropic_stream_chunk_optimized(chunk, stream_pid, sequence_counter \\ nil) do
    # OPTIMIZATION: Process chunk with minimal latency and immediate forwarding
    # Split only once and process lines efficiently
    lines = String.split(chunk, "\n", trim: true)

    Enum.reduce_while(lines, :continue, fn line, _acc ->
      case line do
        <<"data: ", json_data::binary>> ->
          # OPTIMIZATION: Fast path for Anthropic content extraction
          case fast_extract_anthropic_content(json_data) do
            {:content, content} when byte_size(content) > 0 ->
              # IMMEDIATE FORWARDING: Send content as soon as extracted with sequence number
              if sequence_counter do
                sequence_num = :counters.get(sequence_counter, 1)
                :counters.add(sequence_counter, 1, 1)
                send(stream_pid, {:sequenced_chunk, content, sequence_num})
              else
                send(stream_pid, {:chunk, content})
              end
              {:cont, :continue}

            :done ->
              {:halt, :done}

            :continue ->
              {:cont, :continue}

            {:error, _reason} ->
              # Fallback to full JSON parsing only on error
              case Jason.decode(json_data) do
                {:ok, %{"type" => "content_block_delta", "delta" => %{"text" => content}}} when is_binary(content) and byte_size(content) > 0 ->
                  if sequence_counter do
                    sequence_num = :counters.get(sequence_counter, 1)
                    :counters.add(sequence_counter, 1, 1)
                    send(stream_pid, {:sequenced_chunk, content, sequence_num})
                  else
                    send(stream_pid, {:chunk, content})
                  end
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
          # Skip empty lines and other data
          {:cont, :continue}
      end
    end)
  end

  # Fast content extraction for Anthropic format without full JSON parsing
  defp fast_extract_anthropic_content(json_data) do
    # OPTIMIZATION: Pattern match for Anthropic content structure without full JSON decode
    # This handles: {"type":"content_block_delta","delta":{"text":"content"}}

    case json_data do
      json when is_binary(json) ->
        cond do
          # Fast path: Look for content_block_delta with text
          String.contains?(json, "content_block_delta") and String.contains?(json, "\"text\":") ->
            case Regex.run(~r/"text":"([^"]*)"/, json, capture: :all_but_first) do
              [content] when byte_size(content) > 0 ->
                # Decode escaped characters in content
                decoded_content = decode_json_string(content)
                {:content, decoded_content}

              _ ->
                :continue
            end

          # Check for message_stop
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

  # Build OpenAI-compatible request body for streaming
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

  # Gets unified LLM configuration from LLMConfigManager or uses provided config
  @spec get_unified_config(map() | nil) :: {:ok, map()} | {:error, term()}
  defp get_unified_config(nil) do
    # Use LLMConfigManager for centralized configuration
    case DecisionEngine.LLMConfigManager.get_current_config() do
      {:ok, config} ->
        # Convert string keys to atoms for compatibility with existing LLMClient code
        normalized_config = normalize_config_keys(config)
        {:ok, normalized_config}

      {:error, :api_key_required} ->
        {:error, :no_api_key_configured}

      {:error, reason} ->
        Logger.warning("Failed to get LLM config from LLMConfigManager: #{inspect(reason)}")
        {:error, "LLM configuration not available. Please configure LLM settings in the Settings page."}
    end
  end

  defp get_unified_config(config) when is_map(config) do
    # Use provided config but normalize keys for consistency
    normalized_config = normalize_config_keys(config)
    {:ok, normalized_config}
  end

  # Normalizes configuration keys to atoms for compatibility with existing LLMClient code
  defp normalize_config_keys(config) do
    config
    |> Enum.map(fn
      {key, value} when is_binary(key) ->
        case key do
          "provider" -> {:provider, String.to_existing_atom(value)}
          "api_url" -> {:api_url, value}
          "endpoint" -> {:api_url, value}  # Map endpoint to api_url
          "api_key" -> {:api_key, value}
          "model" -> {:model, value}
          "temperature" -> {:temperature, value}
          "max_tokens" -> {:max_tokens, value}
          "timeout" -> {:timeout, value}
          "streaming" -> {:streaming, value}
          "extra_headers" -> {:extra_headers, value}
          "json_mode" -> {:json_mode, value}
          _ -> {String.to_atom(key), value}
        end
      {key, value} when is_atom(key) ->
        case key do
          :provider when is_binary(value) -> {:provider, String.to_existing_atom(value)}
          :endpoint -> {:api_url, value}  # Map endpoint to api_url
          _ -> {key, value}
        end
    end)
    |> Map.new()
  end

  # Simulate streaming for testing purposes when no provider is configured
  defp simulate_streaming(_prompt, stream_pid) do
    spawn_link(fn ->
      try do
        # Simulate streaming chunks with delays
        Process.sleep(50)
        send(stream_pid, {:chunk, "## Recommendation Analysis\n\n"})

        Process.sleep(100)
        send(stream_pid, {:chunk, "Based on your scenario, here are the key findings:\n\n"})

        Process.sleep(150)
        send(stream_pid, {:chunk, "- **Primary consideration**: Your requirements align well with the platform capabilities\n"})

        Process.sleep(100)
        send(stream_pid, {:chunk, "- **Technical fit**: The proposed solution matches your technical constraints\n\n"})

        Process.sleep(125)
        send(stream_pid, {:chunk, "### Next Steps\n\n1. Review the recommended approach\n2. Consider implementation timeline\n3. Plan for testing and validation"})

        Process.sleep(50)
        send(stream_pid, {:complete})
      rescue
        error ->
          Logger.error("Simulated streaming error: #{inspect(error)}")
          send(stream_pid, {:error, "Simulated streaming failed: #{inspect(error)}"})
      end
    end)

    :ok
  end

  # Reflection-specific prompt builders

  defp build_reflection_evaluation_prompt(domain_config, content_type) do
    content_context = get_content_type_context(content_type)

    """
    #{content_context}

    Please evaluate the following domain configuration for quality across multiple dimensions.
    Provide a comprehensive analysis focusing on:

    1. **Signal Fields Quality**:
       - Relevance to domain decisions
       - Naming consistency and clarity
       - Coverage completeness for decision patterns

    2. **Decision Patterns Quality**:
       - Logical consistency of conditions
       - Mutual exclusivity between patterns
       - Practical applicability in real scenarios

    3. **Domain Description Quality**:
       - Clarity and descriptiveness
       - Accuracy relative to patterns and fields
       - Alignment with overall configuration

    4. **Overall Structure Quality**:
       - Completeness of required sections
       - Internal coherence and consistency
       - Usability for decision automation

    Domain Configuration:
    ```json
    #{Jason.encode!(domain_config, pretty: true)}
    ```

    Provide your evaluation in structured format with:
    - Scores (0.0-1.0) for each dimension
    - Specific observations and issues identified
    - Priority areas for improvement
    - Overall quality assessment

    Focus on actionable insights that can guide configuration refinement.
    """
  end

  defp build_reflection_improvement_prompt(domain_config, evaluation_results, content_type) do
    content_context = get_content_type_context(content_type)

    """
    #{content_context}

    Based on the evaluation results below, generate specific improvement suggestions for the domain configuration.

    Current Domain Configuration:
    ```json
    #{Jason.encode!(domain_config, pretty: true)}
    ```

    Evaluation Results:
    ```json
    #{Jason.encode!(evaluation_results, pretty: true)}
    ```

    Please provide improvement suggestions in the following categories:

    1. **Signal Field Improvements**:
       - Add missing relevant fields
       - Improve field naming consistency
       - Enhance field coverage for decision patterns

    2. **Decision Pattern Enhancements**:
       - Resolve logical inconsistencies
       - Improve pattern differentiation
       - Add missing decision scenarios

    3. **Domain Description Refinements**:
       - Clarify domain scope and purpose
       - Improve alignment with patterns
       - Enhance descriptive accuracy

    4. **Structural Optimizations**:
       - Complete missing required sections
       - Improve internal consistency
       - Enhance overall usability

    For each suggestion, provide:
    - Specific action to take
    - Rationale for the improvement
    - Expected impact on quality
    - Implementation priority (high/medium/low)

    Focus on actionable, specific recommendations that can be directly applied.
    """
  end

  defp build_reflection_conversation_prompt(conversation_history, current_config, content_type) do
    content_context = get_content_type_context(content_type)

    # Build conversation context from history
    conversation_context = if length(conversation_history) > 0 do
      history_text = conversation_history
      |> Enum.map(fn msg ->
        "#{String.capitalize(msg.role)}: #{msg.content}"
      end)
      |> Enum.join("\n\n")

      """
      Previous Conversation:
      #{history_text}

      """
    else
      ""
    end

    """
    #{content_context}

    You are conducting an iterative reflection conversation to improve a domain configuration.
    #{conversation_context}
    Current Domain Configuration State:
    ```json
    #{Jason.encode!(current_config, pretty: true)}
    ```

    Continue the conversation by:
    1. Acknowledging previous discussion points
    2. Analyzing the current configuration state
    3. Identifying the next most important improvement area
    4. Providing specific, actionable guidance
    5. Asking clarifying questions if needed

    Maintain conversation continuity and build upon previous insights.
    Focus on one primary improvement area per iteration to ensure focused progress.
    """
  end

  defp build_reflection_validation_prompt(original_config, refined_config) do
    """
    Please validate whether the refined domain configuration represents a beneficial improvement over the original.

    Original Configuration:
    ```json
    #{Jason.encode!(original_config, pretty: true)}
    ```

    Refined Configuration:
    ```json
    #{Jason.encode!(refined_config, pretty: true)}
    ```

    Analyze the changes and provide validation covering:

    1. **Quality Improvements**:
       - What specific aspects were improved?
       - Are the improvements meaningful and beneficial?
       - Do improvements address real quality issues?

    2. **Integrity Preservation**:
       - Is the core domain logic preserved?
       - Are all essential elements maintained?
       - Are there any unintended degradations?

    3. **Change Assessment**:
       - Are changes appropriate in scope and scale?
       - Do changes align with domain requirements?
       - Are modifications technically sound?

    4. **Recommendation**:
       - Should the refined configuration be accepted?
       - Are there any concerns or risks?
       - What additional improvements might be needed?

    Provide a clear recommendation: ACCEPT, REJECT, or CONDITIONAL_ACCEPT with specific reasoning.
    """
  end

  defp get_content_type_context(content_type) do
    case content_type do
      :high_quality ->
        """
        CONTENT TYPE: High-Quality Structured Document
        This domain configuration was generated from a well-structured, clear PDF document.
        Focus on pattern optimization and rule refinement rather than basic completeness.
        Expect higher baseline quality and look for sophisticated improvements.
        """

      :low_quality ->
        """
        CONTENT TYPE: Low-Quality or Unclear Document
        This domain configuration was generated from a document with unclear or incomplete information.
        Focus on identifying content gaps and suggesting conservative, robust default patterns.
        Prioritize completeness and safety over optimization.
        """

      :technical ->
        """
        CONTENT TYPE: Technical Domain-Specific Document
        This domain configuration was generated from technical documentation with specialized terminology.
        Focus on validating terminology consistency and technical accuracy.
        Ensure patterns align with domain-specific best practices and standards.
        """

      :business ->
        """
        CONTENT TYPE: General Business Document
        This domain configuration was generated from general business documentation.
        Focus on ensuring broad applicability and clear business rule extraction.
        Prioritize practical usability and business logic clarity.
        """

      _ ->
        """
        CONTENT TYPE: General Document
        This domain configuration was generated from a general document.
        Apply standard evaluation criteria across all quality dimensions.
        """
    end
  end

  # Rate limiting and retry logic for reflection operations

  defp apply_reflection_rate_limiting(config) do
    # Add reflection-specific rate limiting configuration
    rate_limited_config = config
    |> Map.put(:reflection_mode, true)
    |> Map.put(:max_tokens, Map.get(config, :max_tokens, 3000))  # Higher token limit for reflection
    |> Map.put(:temperature, Map.get(config, :temperature, 0.2))  # Lower temperature for consistency
    |> Map.put(:timeout, Map.get(config, :timeout, 90_000))  # 90 second timeout for reflection calls
    |> Map.put(:receive_timeout, 120_000)  # 2 minute receive timeout

    {:ok, rate_limited_config}
  end

  defp call_llm_with_retry(prompt, config, operation_type, retry_count \\ 0) do
    max_retries = 3
    base_delay = 1000  # 1 second base delay

    case call_llm(prompt, config) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} when retry_count < max_retries ->
        # Exponential backoff with jitter
        delay = base_delay * :math.pow(2, retry_count) + :rand.uniform(1000)

        Logger.warning("LLM call failed for #{operation_type}, retrying in #{delay}ms (attempt #{retry_count + 1}/#{max_retries}): #{inspect(reason)}")

        Process.sleep(trunc(delay))
        call_llm_with_retry(prompt, config, operation_type, retry_count + 1)

      {:error, reason} ->
        Logger.error("LLM call failed for #{operation_type} after #{max_retries} retries: #{inspect(reason)}")
        {:error, "LLM #{operation_type} failed after retries: #{inspect(reason)}"}
    end
  end
end
