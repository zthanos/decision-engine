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

  def extract_signals(user_scenario, config, retry_count \\ 0) do
    prompt = build_extraction_prompt(user_scenario, retry_count)

    case call_llm(prompt, config) do
      {:ok, response} ->
        parse_and_validate_signals(response, user_scenario, config, retry_count)

      {:error, reason} ->
        Logger.error("LLM API call failed: #{inspect(reason)}")
        {:error, "Failed to call LLM API: #{inspect(reason)}"}
    end
  end

  def generate_justification(signals, decision_result, config) do
    prompt = build_justification_prompt(signals, decision_result)

    case call_llm(prompt, config) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, "Failed to generate justification: #{inspect(reason)}"}
    end
  end

  defp build_extraction_prompt(scenario, retry_count) do
    base_instruction = if retry_count > 0 do
      "CRITICAL: Return ONLY valid JSON. No text, no markdown, no code blocks. Just pure JSON starting with { and ending with }."
    else
      "Extract architecture decision signals from the following scenario and return ONLY valid JSON."
    end

    """
    #{base_instruction}

    Scenario: "#{scenario}"

    Extract the following fields:
    - workload_type: one of ["user_productivity", "system_integration", "data_pipeline", "rpa_desktop", "event_driven_business_process"]
    - primary_users: array from ["citizen_developers", "business_users", "pro_developers", "integration_team", "data_team"]
    - trigger_nature: one of ["user_action", "m365_event", "business_event", "system_event", "schedule"]
    - target_systems: array from ["m365", "dataverse", "dynamics_365", "public_saas", "line_of_business_api", "on_premises_systems", "azure_paas"]
    - connectivity_needs: array from ["public_internet", "on_prem_via_gateway", "private_azure_via_vnet", "none"]
    - data_volume: one of ["very_low", "low", "medium", "high", "streaming"]
    - latency_requirement: one of ["human_scale_seconds_minutes", "near_real_time", "sub_second_oltp"]
    - process_pattern: array from ["approvals", "notifications", "document_flow", "data_sync", "human_workflow", "long_running_business_process", "integration_orchestration"]
    - complexity_level: one of ["simple", "moderate", "complex"]
    - availability_requirement: one of ["standard_business", "high", "mission_critical"]
    - devops_need: one of ["minimal", "basic_almd_solutions", "full_enterprise_devops"]
    - governance_priority: one of ["low", "medium", "high"]

    Return ONLY the JSON object, nothing else.
    """
  end

  defp build_justification_prompt(signals, decision_result) do
    """
    Based on the following architecture signals and decision outcome, provide a clear justification
    explaining why this is the proper solution for the scenario.

    Signals:
    #{Jason.encode!(signals, pretty: true)}

    Decision Outcome:
    - Pattern: #{decision_result.pattern_id}
    - Recommendation: #{decision_result.summary}
    - Score: #{decision_result.score}

    Provide a 2-3 paragraph justification that:
    1. Explains why this solution fits the scenario
    2. Highlights the key factors that led to this decision
    3. Mentions any caveats or alternatives if applicable

    Be specific and reference the actual signals from the scenario.
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

  defp parse_and_validate_signals(response, scenario, config, retry_count) do
    # Layer 1: JSON Parsing
    cleaned_response = clean_json_response(response)

    case Jason.decode(cleaned_response) do
      {:ok, signals} ->
        # Layer 2: Schema Validation
        case ExJsonSchema.Validator.validate(
          ExJsonSchema.Schema.resolve(DecisionEngine.SignalsSchema.schema()),
          signals
        ) do
          :ok ->
            # Layer 3: Apply defaults for missing fields
            final_signals = DecisionEngine.SignalsSchema.apply_defaults(signals)
            {:ok, final_signals}

          {:error, validation_errors} ->
            Logger.warning("Schema validation failed: #{inspect(validation_errors)}")

            if retry_count < @max_retries do
              Logger.info("Retrying signal extraction (attempt #{retry_count + 1})")
              extract_signals(scenario, config, retry_count + 1)
            else
              # Apply defaults and continue despite validation errors
              final_signals = DecisionEngine.SignalsSchema.apply_defaults(signals)
              {:ok, final_signals}
            end
        end

      {:error, _decode_error} ->
        if retry_count < @max_retries do
          Logger.warning("JSON parsing failed, retrying (attempt #{retry_count + 1})")
          extract_signals(scenario, config, retry_count + 1)
        else
          {:error, "Failed to parse LLM response as JSON after #{@max_retries} retries"}
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
end
