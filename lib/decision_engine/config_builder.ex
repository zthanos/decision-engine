# lib/decision_engine/config_builder.ex
defmodule DecisionEngine.ConfigBuilder do
  @moduledoc """
  Helper module to build LLM provider configurations.
  """

  @doc """
  Build configuration for OpenAI.

  ## Example
      config = ConfigBuilder.openai("sk-...", model: "gpt-4o")
  """
  def openai(api_key, opts \\ []) do
    %{
      provider: :openai,
      api_url: "https://api.openai.com/v1/chat/completions",
      api_key: api_key,
      model: Keyword.get(opts, :model, "gpt-4"),
      temperature: Keyword.get(opts, :temperature, 0.1),
      max_tokens: Keyword.get(opts, :max_tokens, 2000),
      json_mode: Keyword.get(opts, :json_mode, false)
    }
  end

  @doc """
  Build configuration for Anthropic Claude.

  ## Example
      config = ConfigBuilder.anthropic("sk-ant-...", model: "claude-sonnet-4-20250514")
  """
  def anthropic(api_key, opts \\ []) do
    %{
      provider: :anthropic,
      api_url: "https://api.anthropic.com/v1/messages",
      api_key: api_key,
      model: Keyword.get(opts, :model, "claude-sonnet-4-20250514"),
      temperature: Keyword.get(opts, :temperature, 0.1),
      max_tokens: Keyword.get(opts, :max_tokens, 2000)
    }
  end

  @doc """
  Build configuration for Ollama (local LLMs).

  ## Example
      config = ConfigBuilder.ollama("llama3.2", base_url: "http://localhost:11434")
  """
  def ollama(model, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, "http://127.0.0.1:11434")

    %{
      provider: :ollama,
      api_url: "#{base_url}/v1/chat/completions",
      api_key: nil,  # Ollama doesn't require API key
      model: model,
      temperature: Keyword.get(opts, :temperature, 0.1),
      max_tokens: Keyword.get(opts, :max_tokens, 2000),
      receive_timeout: Keyword.get(opts, :receive_timeout, 60_000)
    }
  end

  @doc """
  Build configuration for OpenRouter (unified API for multiple providers).

  ## Example
      config = ConfigBuilder.openrouter("sk-or-...", model: "anthropic/claude-3.5-sonnet")
  """
  def openrouter(api_key, opts \\ []) do
    %{
      provider: :openrouter,
      api_url: "https://openrouter.ai/api/v1/chat/completions",
      api_key: api_key,
      model: Keyword.get(opts, :model, "anthropic/claude-3.5-sonnet"),
      temperature: Keyword.get(opts, :temperature, 0.1),
      max_tokens: Keyword.get(opts, :max_tokens, 2000),
      extra_headers: [
        {"HTTP-Referer", Keyword.get(opts, :referer, "https://github.com/yourusername/decision-engine")},
        {"X-Title", Keyword.get(opts, :app_name, "Decision Engine")}
      ]
    }
  end

  @doc """
  Build configuration for Azure OpenAI.

  ## Example
      config = ConfigBuilder.azure_openai(
        "your-api-key",
        deployment: "gpt-4",
        resource: "your-resource-name",
        api_version: "2024-02-01"
      )
  """
  def azure_openai(api_key, opts) do
    resource = Keyword.fetch!(opts, :resource)
    deployment = Keyword.fetch!(opts, :deployment)
    api_version = Keyword.get(opts, :api_version, "2024-02-01")

    %{
      provider: :openai,
      api_url: "https://#{resource}.openai.azure.com/openai/deployments/#{deployment}/chat/completions?api-version=#{api_version}",
      api_key: api_key,
      model: deployment,  # In Azure, deployment name is used
      temperature: Keyword.get(opts, :temperature, 0.1),
      max_tokens: Keyword.get(opts, :max_tokens, 2000),
      extra_headers: [{"api-key", api_key}]  # Azure uses different auth header
    }
  end

  @doc """
  Build configuration for any custom OpenAI-compatible endpoint.

  ## Example
      config = ConfigBuilder.custom(
        api_url: "https://api.together.xyz/v1/chat/completions",
        api_key: "your-key",
        model: "meta-llama/Llama-3-70b-chat-hf"
      )
  """
  def custom(opts) do
    %{
      provider: :custom,
      api_url: Keyword.fetch!(opts, :api_url),
      api_key: Keyword.get(opts, :api_key),
      model: Keyword.fetch!(opts, :model),
      temperature: Keyword.get(opts, :temperature, 0.1),
      max_tokens: Keyword.get(opts, :max_tokens, 2000),
      extra_headers: Keyword.get(opts, :extra_headers, []),
      json_mode: Keyword.get(opts, :json_mode, false)
    }
  end

  @doc """
  Build configuration for LM Studio (local OpenAI-compatible server).

  ## Example
      config = ConfigBuilder.lm_studio("local-model", port: 1234)
  """
  def lm_studio(model, opts \\ []) do
    port = Keyword.get(opts, :port, 1234)

    %{
      # LM Studio exposes an OpenAI-compatible API
      provider: :lm_studio,
      api_url: "http://172.22.176.1:#{port}/v1/chat/completions",
      api_key: nil,
      model: model,
      temperature: Keyword.get(opts, :temperature, 0.1),
      max_tokens: Keyword.get(opts, :max_tokens, 2000)
    }
  end
end
