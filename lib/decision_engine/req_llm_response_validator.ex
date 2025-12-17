# lib/decision_engine/req_llm_response_validator.ex
defmodule DecisionEngine.ReqLLMResponseValidator do
  @moduledoc """
  Response validation and normalization for ReqLLM integration.

  This module implements ReqLLM response validation, response normalization across
  providers, and response integrity checking and sanitization to ensure consistent
  and safe response handling.
  """

  require Logger

  @doc """
  Validates and normalizes a response from any LLM provider.

  ## Parameters
  - response: Raw response from the LLM API
  - provider: Provider atom (:openai, :anthropic, etc.)
  - config: Configuration map with validation settings

  ## Returns
  - {:ok, normalized_response} on success
  - {:error, reason} on validation failure
  """
  @spec validate_and_normalize(term(), atom(), map()) :: {:ok, map()} | {:error, term()}
  def validate_and_normalize(response, provider, config \\ %{}) do
    with {:ok, validated} <- validate_response_structure(response, provider),
         {:ok, normalized} <- normalize_response(validated, provider),
         {:ok, sanitized} <- sanitize_response(normalized, config) do
      {:ok, sanitized}
    else
      {:error, reason} ->
        Logger.warning("Response validation failed for #{provider}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Validates the basic structure of a response from a specific provider.

  ## Parameters
  - response: Raw response from the LLM API
  - provider: Provider atom

  ## Returns
  - {:ok, response} if structure is valid
  - {:error, reason} if structure is invalid
  """
  @spec validate_response_structure(term(), atom()) :: {:ok, term()} | {:error, term()}
  def validate_response_structure(response, provider) do
    case provider do
      :openai ->
        validate_openai_structure(response)

      :anthropic ->
        validate_anthropic_structure(response)

      :ollama ->
        validate_ollama_structure(response)

      :openrouter ->
        validate_openai_structure(response)  # OpenRouter uses OpenAI format

      :lm_studio ->
        validate_openai_structure(response)  # LM Studio uses OpenAI format

      :custom ->
        validate_custom_structure(response)

      _ ->
        {:error, "Unsupported provider: #{provider}"}
    end
  end

  @doc """
  Normalizes a response to a common format across all providers.

  ## Parameters
  - response: Validated response from the LLM API
  - provider: Provider atom

  ## Returns
  - {:ok, normalized_response} with common format
  - {:error, reason} if normalization fails
  """
  @spec normalize_response(term(), atom()) :: {:ok, map()} | {:error, term()}
  def normalize_response(response, provider) do
    case provider do
      :openai ->
        normalize_openai_response(response)

      :anthropic ->
        normalize_anthropic_response(response)

      :ollama ->
        normalize_ollama_response(response)

      :openrouter ->
        normalize_openai_response(response)  # OpenRouter uses OpenAI format

      :lm_studio ->
        normalize_openai_response(response)  # LM Studio uses OpenAI format

      :custom ->
        normalize_custom_response(response)

      _ ->
        {:error, "Unsupported provider: #{provider}"}
    end
  end

  @doc """
  Sanitizes response content to remove potentially harmful or unwanted content.

  ## Parameters
  - response: Normalized response map
  - config: Sanitization configuration

  ## Returns
  - {:ok, sanitized_response} with cleaned content
  - {:error, reason} if sanitization fails
  """
  @spec sanitize_response(map(), map()) :: {:ok, map()} | {:error, term()}
  def sanitize_response(response, config \\ %{}) do
    try do
      with {:ok, html_sanitized} <- sanitize_html_content(response.content, config),
           {:ok, sensitive_sanitized} <- sanitize_sensitive_data(html_sanitized, config),
           {:ok, whitespace_normalized} <- normalize_whitespace(sensitive_sanitized, config),
           {:ok, length_validated} <- validate_content_length(whitespace_normalized, config) do
        {:ok, %{response | content: length_validated}}
      else
        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error ->
        Logger.error("Response sanitization failed: #{inspect(error)}")
        {:error, "Sanitization failed: #{inspect(error)}"}
    end
  end

  @doc """
  Checks the integrity of a response to ensure it's complete and valid.

  ## Parameters
  - response: Response map to check
  - expected_fields: List of required fields

  ## Returns
  - :ok if integrity check passes
  - {:error, reason} if integrity check fails
  """
  @spec check_response_integrity(map(), list()) :: :ok | {:error, term()}
  def check_response_integrity(response, expected_fields \\ [:content, :metadata]) do
    missing_fields = expected_fields -- Map.keys(response)

    cond do
      length(missing_fields) > 0 ->
        {:error, "Missing required fields: #{inspect(missing_fields)}"}

      not is_binary(response.content) ->
        {:error, "Content must be a string"}

      String.length(response.content) == 0 ->
        {:error, "Content cannot be empty"}

      true ->
        :ok
    end
  end

  # Private Functions - Structure Validation

  defp validate_openai_structure(response) do
    case response do
      %{"choices" => choices} when is_list(choices) and length(choices) > 0 ->
        case List.first(choices) do
          %{"message" => %{"content" => content}} when is_binary(content) ->
            {:ok, response}

          %{"message" => message} ->
            {:error, "Invalid message structure: #{inspect(message)}"}

          choice ->
            {:error, "Invalid choice structure: #{inspect(choice)}"}
        end

      %{"error" => error} ->
        {:error, "API error in response: #{inspect(error)}"}

      _ ->
        {:error, "Invalid OpenAI response structure: #{inspect(response)}"}
    end
  end

  defp validate_anthropic_structure(response) do
    case response do
      %{"content" => content} when is_list(content) and length(content) > 0 ->
        case List.first(content) do
          %{"text" => text} when is_binary(text) ->
            {:ok, response}

          %{"type" => "text", "text" => text} when is_binary(text) ->
            {:ok, response}

          content_block ->
            {:error, "Invalid content block structure: #{inspect(content_block)}"}
        end

      %{"error" => error} ->
        {:error, "API error in response: #{inspect(error)}"}

      _ ->
        {:error, "Invalid Anthropic response structure: #{inspect(response)}"}
    end
  end

  defp validate_ollama_structure(response) do
    case response do
      %{"message" => %{"content" => content}} when is_binary(content) ->
        {:ok, response}

      %{"response" => content} when is_binary(content) ->
        {:ok, response}

      %{"error" => error} ->
        {:error, "API error in response: #{inspect(error)}"}

      _ ->
        {:error, "Invalid Ollama response structure: #{inspect(response)}"}
    end
  end

  defp validate_custom_structure(response) do
    # For custom providers, we try to be flexible and accept various formats
    cond do
      is_binary(response) ->
        {:ok, %{"content" => response}}

      is_map(response) and Map.has_key?(response, "content") ->
        {:ok, response}

      is_map(response) and Map.has_key?(response, "message") ->
        {:ok, response}

      is_map(response) and Map.has_key?(response, "text") ->
        {:ok, response}

      true ->
        {:error, "Unrecognized custom response format: #{inspect(response)}"}
    end
  end

  # Private Functions - Response Normalization

  defp normalize_openai_response(response) do
    case response do
      %{"choices" => [%{"message" => %{"content" => content}} | _]} = full_response ->
        metadata = extract_openai_metadata(full_response)

        {:ok, %{
          content: content,
          provider: :openai,
          metadata: metadata,
          raw_response: full_response
        }}

      _ ->
        {:error, "Cannot normalize OpenAI response"}
    end
  end

  defp normalize_anthropic_response(response) do
    case response do
      %{"content" => [%{"type" => "text", "text" => content} | _]} = full_response ->
        metadata = extract_anthropic_metadata(full_response)

        {:ok, %{
          content: content,
          provider: :anthropic,
          metadata: metadata,
          raw_response: full_response
        }}

      %{"content" => [%{"text" => content} | _]} = full_response ->
        metadata = extract_anthropic_metadata(full_response)

        {:ok, %{
          content: content,
          provider: :anthropic,
          metadata: metadata,
          raw_response: full_response
        }}

      _ ->
        {:error, "Cannot normalize Anthropic response"}
    end
  end

  defp normalize_ollama_response(response) do
    content = case response do
      %{"message" => %{"content" => content}} -> content
      %{"response" => content} -> content
      _ -> ""
    end

    metadata = extract_ollama_metadata(response)

    {:ok, %{
      content: content,
      provider: :ollama,
      metadata: metadata,
      raw_response: response
    }}
  end

  defp normalize_custom_response(response) do
    content = case response do
      %{"content" => content} -> content
      %{"message" => %{"content" => content}} -> content
      %{"text" => content} -> content
      content when is_binary(content) -> content
      _ -> ""
    end

    metadata = extract_custom_metadata(response)

    {:ok, %{
      content: content,
      provider: :custom,
      metadata: metadata,
      raw_response: response
    }}
  end

  # Private Functions - Metadata Extraction

  defp extract_openai_metadata(response) do
    %{
      model: Map.get(response, "model"),
      usage: Map.get(response, "usage", %{}),
      id: Map.get(response, "id"),
      created: Map.get(response, "created"),
      finish_reason: get_in(response, ["choices", Access.at(0), "finish_reason"])
    }
  end

  defp extract_anthropic_metadata(response) do
    %{
      model: Map.get(response, "model"),
      usage: Map.get(response, "usage", %{}),
      id: Map.get(response, "id"),
      stop_reason: Map.get(response, "stop_reason"),
      stop_sequence: Map.get(response, "stop_sequence")
    }
  end

  defp extract_ollama_metadata(response) do
    %{
      model: Map.get(response, "model"),
      created_at: Map.get(response, "created_at"),
      done: Map.get(response, "done"),
      total_duration: Map.get(response, "total_duration"),
      load_duration: Map.get(response, "load_duration"),
      prompt_eval_count: Map.get(response, "prompt_eval_count"),
      eval_count: Map.get(response, "eval_count")
    }
  end

  defp extract_custom_metadata(response) when is_map(response) do
    # Extract any metadata fields that might be present
    response
    |> Map.drop(["content", "message", "text"])
    |> Map.take(["model", "usage", "id", "created", "metadata"])
  end

  defp extract_custom_metadata(_response), do: %{}

  # Private Functions - Content Sanitization

  defp sanitize_html_content(content, config) do
    if Map.get(config, :sanitize_html, true) do
      # Remove potentially harmful HTML tags and scripts
      sanitized = content
      |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
      |> String.replace(~r/<iframe[^>]*>.*?<\/iframe>/is, "")
      |> String.replace(~r/<object[^>]*>.*?<\/object>/is, "")
      |> String.replace(~r/<embed[^>]*>/i, "")
      |> String.replace(~r/javascript:/i, "")
      |> String.replace(~r/on\w+\s*=/i, "")

      {:ok, sanitized}
    else
      {:ok, content}
    end
  end

  defp sanitize_sensitive_data(content, config) do
    if Map.get(config, :sanitize_sensitive, true) do
      # Remove potential sensitive data patterns
      sanitized = content
      |> String.replace(~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/, "[EMAIL]")
      |> String.replace(~r/\b\d{3}-\d{2}-\d{4}\b/, "[SSN]")
      |> String.replace(~r/\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/, "[CARD]")
      |> String.replace(~r/\b(?:sk-|pk_)[a-zA-Z0-9]{20,}\b/, "[API_KEY]")

      {:ok, sanitized}
    else
      {:ok, content}
    end
  end

  defp normalize_whitespace(content, config) do
    if Map.get(config, :normalize_whitespace, true) do
      # Normalize excessive whitespace
      normalized = content
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

      {:ok, normalized}
    else
      {:ok, content}
    end
  end

  defp validate_content_length(content, config) do
    max_length = Map.get(config, :max_content_length, 100_000)

    if String.length(content) > max_length do
      {:error, "Content exceeds maximum length of #{max_length} characters"}
    else
      {:ok, content}
    end
  end
end
