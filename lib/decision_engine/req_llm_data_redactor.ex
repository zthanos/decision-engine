# lib/decision_engine/req_llm_data_redactor.ex
defmodule DecisionEngine.ReqLLMDataRedactor do
  @moduledoc """
  Sensitive data redaction for ReqLLM integration.

  This module provides automatic sensitive data detection and redaction,
  configurable redaction rules for different data types, and secure logging
  practices for API interactions.

  Features:
  - Automatic detection of sensitive data patterns
  - Configurable redaction rules and patterns
  - Support for multiple data formats (JSON, XML, plain text)
  - Secure logging practices with data sanitization
  - Performance-optimized redaction algorithms
  """

  require Logger

  @default_redaction_rules %{
    # API Keys and tokens
    api_keys: [
      ~r/sk-[a-zA-Z0-9]{48}/,  # OpenAI API keys
      ~r/sk-ant-[a-zA-Z0-9-]{95}/,  # Anthropic API keys
      ~r/Bearer\s+[a-zA-Z0-9\-._~+\/]+=*/i,  # Bearer tokens
      ~r/[a-zA-Z0-9]{32,}/  # Generic long alphanumeric strings
    ],

    # Authentication headers
    auth_headers: [
      ~r/"authorization"\s*:\s*"[^"]+"/i,
      ~r/"x-api-key"\s*:\s*"[^"]+"/i,
      ~r/"cookie"\s*:\s*"[^"]+"/i,
      ~r/"set-cookie"\s*:\s*"[^"]+"/i
    ],

    # Sensitive JSON fields
    json_fields: [
      ~r/"(?:api_key|apikey|api-key)"\s*:\s*"[^"]+"/i,
      ~r/"(?:token|access_token|refresh_token)"\s*:\s*"[^"]+"/i,
      ~r/"(?:password|passwd|pwd)"\s*:\s*"[^"]+"/i,
      ~r/"(?:secret|client_secret)"\s*:\s*"[^"]+"/i,
      ~r/"(?:key|private_key|public_key)"\s*:\s*"[^"]+"/i
    ],

    # Personal information
    personal_info: [
      ~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/,  # Email addresses
      ~r/\b\d{3}-\d{2}-\d{4}\b/,  # SSN format
      ~r/\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/,  # Credit card numbers
      ~r/\b\d{3}-\d{3}-\d{4}\b/  # Phone numbers
    ],

    # URLs with sensitive parameters
    sensitive_urls: [
      ~r/[?&](?:api_key|token|password|secret)=[^&\s]+/i,
      ~r/\/\/[^:]+:[^@]+@/  # URLs with credentials
    ]
  }

  @redaction_markers %{
    api_keys: "[API_KEY_REDACTED]",
    auth_headers: "[AUTH_HEADER_REDACTED]",
    json_fields: "[SENSITIVE_FIELD_REDACTED]",
    personal_info: "[PII_REDACTED]",
    sensitive_urls: "[SENSITIVE_URL_REDACTED]",
    generic: "[REDACTED]"
  }

  defstruct [
    :rules,
    :markers,
    :enabled_categories,
    :custom_patterns,
    :performance_mode,
    :max_content_size
  ]

  @type t :: %__MODULE__{
    rules: map(),
    markers: map(),
    enabled_categories: list(atom()),
    custom_patterns: list(),
    performance_mode: boolean(),
    max_content_size: integer()
  }

  @doc """
  Initializes the data redactor with the given configuration.

  ## Parameters
  - config: Redaction configuration (optional, uses defaults if not provided)
  - opts: Additional options for redaction behavior

  ## Returns
  - {:ok, redactor} on success
  - {:error, reason} on failure

  ## Examples
      iex> init_redactor(%{enabled_categories: [:api_keys, :personal_info]})
      {:ok, %ReqLLMDataRedactor{}}
  """
  @spec init_redactor(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def init_redactor(config \\ %{}, opts \\ []) do
    redactor = %__MODULE__{
      rules: Map.get(config, :rules, @default_redaction_rules),
      markers: Map.get(config, :markers, @redaction_markers),
      enabled_categories: Map.get(config, :enabled_categories, Map.keys(@default_redaction_rules)),
      custom_patterns: Keyword.get(opts, :custom_patterns, []),
      performance_mode: Keyword.get(opts, :performance_mode, false),
      max_content_size: Keyword.get(opts, :max_content_size, 1_000_000)
    }

    {:ok, redactor}
  end

  @doc """
  Redacts sensitive data from the given content.

  ## Parameters
  - content: The content to redact (string, map, or list)
  - redactor: The redactor configuration
  - opts: Optional redaction parameters

  ## Returns
  - {:ok, redacted_content} on success
  - {:error, reason} on failure

  ## Examples
      iex> redact_sensitive_data("API key: sk-1234567890", redactor)
      {:ok, "API key: [API_KEY_REDACTED]"}
  """
  @spec redact_sensitive_data(term(), t(), keyword()) :: {:ok, term()} | {:error, term()}
  def redact_sensitive_data(content, redactor, opts \\ []) do
    try do
      # Check content size limits
      if exceeds_size_limit?(content, redactor.max_content_size) do
        {:error, :content_too_large}
      else
        redacted_content = perform_redaction(content, redactor, opts)
        {:ok, redacted_content}
      end
    rescue
      error ->
        Logger.error("Data redaction failed: #{inspect(error)}")
        {:error, :redaction_failed}
    end
  end

  @doc """
  Redacts sensitive data from HTTP request information.

  ## Parameters
  - request: HTTP request map containing headers, body, url, etc.
  - redactor: The redactor configuration
  - opts: Optional redaction parameters

  ## Returns
  - {:ok, redacted_request} on success
  - {:error, reason} on failure
  """
  @spec redact_request_data(map(), t(), keyword()) :: {:ok, map()} | {:error, term()}
  def redact_request_data(request, redactor, opts \\ []) do
    try do
      redacted_request = request
      |> redact_request_headers(redactor, opts)
      |> redact_request_body(redactor, opts)
      |> redact_request_url(redactor, opts)
      |> redact_request_params(redactor, opts)

      {:ok, redacted_request}
    rescue
      error ->
        Logger.error("Request data redaction failed: #{inspect(error)}")
        {:error, :request_redaction_failed}
    end
  end

  @doc """
  Redacts sensitive data from HTTP response information.

  ## Parameters
  - response: HTTP response map containing headers, body, status, etc.
  - redactor: The redactor configuration
  - opts: Optional redaction parameters

  ## Returns
  - {:ok, redacted_response} on success
  - {:error, reason} on failure
  """
  @spec redact_response_data(map(), t(), keyword()) :: {:ok, map()} | {:error, term()}
  def redact_response_data(response, redactor, opts \\ []) do
    try do
      redacted_response = response
      |> redact_response_headers(redactor, opts)
      |> redact_response_body(redactor, opts)

      {:ok, redacted_response}
    rescue
      error ->
        Logger.error("Response data redaction failed: #{inspect(error)}")
        {:error, :response_redaction_failed}
    end
  end

  @doc """
  Adds custom redaction patterns to the redactor.

  ## Parameters
  - redactor: Current redactor configuration
  - category: Category name for the new patterns
  - patterns: List of regex patterns to add
  - marker: Redaction marker to use (optional)

  ## Returns
  - {:ok, updated_redactor} on success
  - {:error, reason} on failure
  """
  @spec add_custom_patterns(t(), atom(), list(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def add_custom_patterns(redactor, category, patterns, marker \\ nil) do
    try do
      # Validate patterns
      validated_patterns = Enum.map(patterns, fn pattern ->
        case pattern do
          %Regex{} -> pattern
          pattern when is_binary(pattern) -> Regex.compile!(pattern)
          _ -> raise ArgumentError, "Invalid pattern: #{inspect(pattern)}"
        end
      end)

      # Update rules
      updated_rules = Map.put(redactor.rules, category, validated_patterns)

      # Update markers if provided
      updated_markers = if marker do
        Map.put(redactor.markers, category, marker)
      else
        redactor.markers
      end

      # Update enabled categories
      updated_categories = if category in redactor.enabled_categories do
        redactor.enabled_categories
      else
        [category | redactor.enabled_categories]
      end

      updated_redactor = %{redactor |
        rules: updated_rules,
        markers: updated_markers,
        enabled_categories: updated_categories
      }

      {:ok, updated_redactor}
    rescue
      error ->
        Logger.error("Failed to add custom patterns: #{inspect(error)}")
        {:error, :invalid_patterns}
    end
  end

  @doc """
  Validates that sensitive data has been properly redacted.

  ## Parameters
  - original_content: The original content before redaction
  - redacted_content: The content after redaction
  - redactor: The redactor configuration

  ## Returns
  - :ok if validation passes
  - {:error, violations} if sensitive data is still present
  """
  @spec validate_redaction(term(), term(), t()) :: :ok | {:error, list()}
  def validate_redaction(original_content, redacted_content, redactor) do
    violations = []

    # Check each enabled category for remaining sensitive data
    violations = Enum.reduce(redactor.enabled_categories, violations, fn category, acc ->
      patterns = Map.get(redactor.rules, category, [])

      category_violations = Enum.reduce(patterns, [], fn pattern, pattern_acc ->
        case find_sensitive_matches(redacted_content, pattern) do
          [] -> pattern_acc
          matches -> [{category, pattern, matches} | pattern_acc]
        end
      end)

      category_violations ++ acc
    end)

    case violations do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  # Private functions

  defp perform_redaction(content, redactor, opts) when is_binary(content) do
    if redactor.performance_mode do
      fast_redact_string(content, redactor, opts)
    else
      thorough_redact_string(content, redactor, opts)
    end
  end

  defp perform_redaction(content, redactor, opts) when is_map(content) do
    Map.new(content, fn {key, value} ->
      redacted_key = perform_redaction(key, redactor, opts)
      redacted_value = perform_redaction(value, redactor, opts)
      {redacted_key, redacted_value}
    end)
  end

  defp perform_redaction(content, redactor, opts) when is_list(content) do
    Enum.map(content, fn item ->
      perform_redaction(item, redactor, opts)
    end)
  end

  defp perform_redaction(content, _redactor, _opts), do: content

  defp fast_redact_string(content, redactor, _opts) do
    # Fast redaction using only the most critical patterns
    critical_categories = [:api_keys, :auth_headers]

    Enum.reduce(critical_categories, content, fn category, acc ->
      if category in redactor.enabled_categories do
        patterns = Map.get(redactor.rules, category, [])
        marker = Map.get(redactor.markers, category, @redaction_markers.generic)

        Enum.reduce(patterns, acc, fn pattern, string_acc ->
          String.replace(string_acc, pattern, marker)
        end)
      else
        acc
      end
    end)
  end

  defp thorough_redact_string(content, redactor, _opts) do
    Enum.reduce(redactor.enabled_categories, content, fn category, acc ->
      patterns = Map.get(redactor.rules, category, [])
      marker = Map.get(redactor.markers, category, @redaction_markers.generic)

      Enum.reduce(patterns, acc, fn pattern, string_acc ->
        String.replace(string_acc, pattern, marker)
      end)
    end)
  end

  defp redact_request_headers(request, redactor, opts) do
    case Map.get(request, :headers) do
      nil -> request
      headers when is_list(headers) ->
        redacted_headers = Enum.map(headers, fn {name, value} ->
          redacted_value = perform_redaction(value, redactor, opts)
          {name, redacted_value}
        end)
        Map.put(request, :headers, redacted_headers)

      headers when is_map(headers) ->
        redacted_headers = Map.new(headers, fn {name, value} ->
          redacted_value = perform_redaction(value, redactor, opts)
          {name, redacted_value}
        end)
        Map.put(request, :headers, redacted_headers)

      _ -> request
    end
  end

  defp redact_request_body(request, redactor, opts) do
    case Map.get(request, :body) do
      nil -> request
      body ->
        redacted_body = perform_redaction(body, redactor, opts)
        Map.put(request, :body, redacted_body)
    end
  end

  defp redact_request_url(request, redactor, opts) do
    case Map.get(request, :url) do
      nil -> request
      url ->
        redacted_url = perform_redaction(url, redactor, opts)
        Map.put(request, :url, redacted_url)
    end
  end

  defp redact_request_params(request, redactor, opts) do
    case Map.get(request, :params) do
      nil -> request
      params ->
        redacted_params = perform_redaction(params, redactor, opts)
        Map.put(request, :params, redacted_params)
    end
  end

  defp redact_response_headers(response, redactor, opts) do
    case Map.get(response, :headers) do
      nil -> response
      headers ->
        redacted_headers = perform_redaction(headers, redactor, opts)
        Map.put(response, :headers, redacted_headers)
    end
  end

  defp redact_response_body(response, redactor, opts) do
    case Map.get(response, :body) do
      nil -> response
      body ->
        redacted_body = perform_redaction(body, redactor, opts)
        Map.put(response, :body, redacted_body)
    end
  end

  defp exceeds_size_limit?(content, max_size) when is_binary(content) do
    byte_size(content) > max_size
  end

  defp exceeds_size_limit?(content, max_size) when is_map(content) or is_list(content) do
    # Rough estimation of content size
    estimated_size = content |> inspect() |> byte_size()
    estimated_size > max_size
  end

  defp exceeds_size_limit?(_content, _max_size), do: false

  defp find_sensitive_matches(content, pattern) when is_binary(content) do
    case Regex.scan(pattern, content) do
      [] -> []
      matches -> matches
    end
  end

  defp find_sensitive_matches(content, pattern) when is_map(content) or is_list(content) do
    content_string = inspect(content)
    find_sensitive_matches(content_string, pattern)
  end

  defp find_sensitive_matches(_content, _pattern), do: []
end
