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
    prompt = build_extraction_prompt(user_scenario, domain, schema_module, rule_config, retry_count)

    case call_llm(prompt, config) do
      {:ok, response} ->
        case parse_and_validate_signals(response, user_scenario, config, domain, schema_module, retry_count) do
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
    prompt = build_justification_prompt(signals, decision_result, domain)

    case call_llm(prompt, config) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, "Failed to generate justification for domain #{domain}: #{inspect(reason)}"}
    end
  end

  # Backward compatibility - delegates to PowerPlatform domain
  def generate_justification(signals, decision_result, config) do
    generate_justification(signals, decision_result, config, :power_platform)
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
    prompt = build_justification_prompt(signals, decision_result, domain)
    
    # Configure LLM for streaming mode
    streaming_config = Map.put(config, :stream, true)
    
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
    provider = Map.get(config, :provider) || Map.get(config, "provider")
    
    case provider do
      :anthropic ->
        call_anthropic_stream(prompt, config, stream_pid)

      provider when provider in [:openai, :openrouter, :custom, :lm_studio] ->
        call_openai_compatible_stream(prompt, config, stream_pid)

      :ollama ->
        # Temporarily use simulation for Ollama to test streaming infrastructure
        Logger.info("Using simulation mode for Ollama streaming")
        simulate_streaming(prompt, stream_pid)

      nil ->
        # If no provider is specified, simulate streaming for testing
        simulate_streaming(prompt, stream_pid)

      _ ->
        {:error, "Unsupported provider for streaming: #{provider}"}
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

    auth_header = case config.api_key do
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

  # Streaming implementation for OpenAI-compatible providers
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
        
        case Finch.stream(request, DecisionEngine.Finch, nil, fn
          {:status, status}, acc when status == 200 ->
            {:cont, acc}
          
          {:status, status}, _acc ->
            send(stream_pid, {:error, "HTTP #{status}"})
            {:halt, :error}
          
          {:headers, _headers}, acc ->
            {:cont, acc}
          
          {:data, chunk}, acc ->
            Logger.debug("Received streaming chunk: #{inspect(chunk)}")
            case parse_openai_stream_chunk(chunk) do
              {:content, content} ->
                Logger.debug("Sending content chunk: #{inspect(content)}")
                send(stream_pid, {:chunk, content})
                {:cont, acc}
              
              :continue ->
                Logger.debug("Continuing stream parsing")
                {:cont, acc}
              
              :done ->
                Logger.debug("Stream completed")
                send(stream_pid, {:complete})
                {:halt, :done}
              
              {:error, reason} ->
                Logger.error("Stream parsing error: #{inspect(reason)}")
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

  # Streaming implementation for Anthropic
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
        
        case Finch.stream(request, DecisionEngine.Finch, nil, fn
          {:status, status}, acc when status == 200 ->
            {:cont, acc}
          
          {:status, status}, _acc ->
            send(stream_pid, {:error, "HTTP #{status}"})
            {:halt, :error}
          
          {:headers, _headers}, acc ->
            {:cont, acc}
          
          {:data, chunk}, acc ->
            case parse_anthropic_stream_chunk(chunk) do
              {:content, content} ->
                send(stream_pid, {:chunk, content})
                {:cont, acc}
              
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



  # Parse OpenAI-compatible streaming chunks
  defp parse_openai_stream_chunk(chunk) do
    # OpenAI streaming format: "data: {json}\n\n"
    lines = String.split(chunk, "\n")
    
    Enum.reduce_while(lines, :continue, fn line, _acc ->
      case String.trim(line) do
        "data: [DONE]" ->
          {:halt, :done}
        
        "data: " <> json_data ->
          case Jason.decode(json_data) do
            {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]}} when is_binary(content) ->
              {:halt, {:content, content}}
            
            {:ok, %{"choices" => [%{"finish_reason" => reason} | _]}} when not is_nil(reason) ->
              {:halt, :done}
            
            {:ok, _} ->
              {:cont, :continue}
            
            {:error, reason} ->
              {:halt, {:error, "Failed to parse stream chunk: #{inspect(reason)}"}}
          end
        
        "" ->
          {:cont, :continue}
        
        _ ->
          {:cont, :continue}
      end
    end)
  end

  # Parse Anthropic streaming chunks
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
end
