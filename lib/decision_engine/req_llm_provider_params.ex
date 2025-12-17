# lib/decision_engine/req_llm_provider_params.ex
defmodule DecisionEngine.ReqLLMProviderParams do
  @moduledoc """
  Provider-specific parameter support for ReqLLM integration.

  This module implements provider-specific configuration options, model-specific
  parameter validation, and provider capability mapping and validation.
  Supports requirements 8.3 and 8.5 for provider-specific parameter support
  and capability abstraction.
  """

  require Logger

  # Provider capability definitions
  @provider_capabilities %{
    openai: %{
      streaming: true,
      function_calling: true,
      json_mode: true,
      vision: true,
      system_messages: true,
      temperature_range: {0.0, 2.0},
      max_tokens_limit: 128_000,
      supported_models: [
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-4-turbo",
        "gpt-4",
        "gpt-3.5-turbo"
      ],
      model_specific_params: %{
        "gpt-4o" => %{
          max_tokens: 128_000,
          supports_vision: true,
          supports_function_calling: true
        },
        "gpt-4o-mini" => %{
          max_tokens: 128_000,
          supports_vision: true,
          supports_function_calling: true
        },
        "gpt-4-turbo" => %{
          max_tokens: 128_000,
          supports_vision: true,
          supports_function_calling: true
        },
        "gpt-4" => %{
          max_tokens: 8_192,
          supports_vision: false,
          supports_function_calling: true
        },
        "gpt-3.5-turbo" => %{
          max_tokens: 16_385,
          supports_vision: false,
          supports_function_calling: true
        }
      },
      provider_specific_params: [
        :response_format,
        :seed,
        :logit_bias,
        :logprobs,
        :top_logprobs,
        :user,
        :tools,
        :tool_choice,
        :parallel_tool_calls
      ]
    },
    anthropic: %{
      streaming: true,
      function_calling: true,
      json_mode: false,
      vision: true,
      system_messages: true,
      temperature_range: {0.0, 1.0},
      max_tokens_limit: 200_000,
      supported_models: [
        "claude-3-5-sonnet-20241022",
        "claude-3-5-haiku-20241022",
        "claude-3-opus-20240229",
        "claude-3-sonnet-20240229",
        "claude-3-haiku-20240307"
      ],
      model_specific_params: %{
        "claude-3-5-sonnet-20241022" => %{
          max_tokens: 200_000,
          supports_vision: true,
          supports_function_calling: true
        },
        "claude-3-5-haiku-20241022" => %{
          max_tokens: 200_000,
          supports_vision: true,
          supports_function_calling: true
        },
        "claude-3-opus-20240229" => %{
          max_tokens: 200_000,
          supports_vision: true,
          supports_function_calling: true
        },
        "claude-3-sonnet-20240229" => %{
          max_tokens: 200_000,
          supports_vision: true,
          supports_function_calling: true
        },
        "claude-3-haiku-20240307" => %{
          max_tokens: 200_000,
          supports_vision: true,
          supports_function_calling: true
        }
      },
      provider_specific_params: [
        :system,
        :stop_sequences,
        :top_k,
        :top_p,
        :tools,
        :tool_choice,
        :metadata
      ]
    },
    ollama: %{
      streaming: true,
      function_calling: false,
      json_mode: true,
      vision: false,
      system_messages: true,
      temperature_range: {0.0, 2.0},
      max_tokens_limit: nil,  # Depends on model
      supported_models: [
        "llama3.1",
        "llama3.1:8b",
        "llama3.1:70b",
        "llama3.1:405b",
        "llama2",
        "codellama",
        "mistral",
        "mixtral"
      ],
      model_specific_params: %{
        "llama3.1" => %{
          max_tokens: nil,
          supports_vision: false,
          supports_function_calling: false
        },
        "llama3.1:8b" => %{
          max_tokens: nil,
          supports_vision: false,
          supports_function_calling: false
        },
        "llama3.1:70b" => %{
          max_tokens: nil,
          supports_vision: false,
          supports_function_calling: false
        },
        "llama3.1:405b" => %{
          max_tokens: nil,
          supports_vision: false,
          supports_function_calling: false
        }
      },
      provider_specific_params: [
        :format,
        :options,
        :system,
        :template,
        :context,
        :stream,
        :raw,
        :keep_alive
      ]
    },
    openrouter: %{
      streaming: true,
      function_calling: true,
      json_mode: true,
      vision: true,
      system_messages: true,
      temperature_range: {0.0, 2.0},
      max_tokens_limit: 200_000,  # Varies by model
      supported_models: [
        "anthropic/claude-3.5-sonnet",
        "anthropic/claude-3-opus",
        "openai/gpt-4o",
        "openai/gpt-4-turbo",
        "meta-llama/llama-3.1-405b-instruct",
        "google/gemini-pro-1.5"
      ],
      model_specific_params: %{
        "anthropic/claude-3.5-sonnet" => %{
          max_tokens: 200_000,
          supports_vision: true,
          supports_function_calling: true
        },
        "openai/gpt-4o" => %{
          max_tokens: 128_000,
          supports_vision: true,
          supports_function_calling: true
        }
      },
      provider_specific_params: [
        :transforms,
        :models,
        :route,
        :provider,
        :fallbacks
      ]
    },
    lm_studio: %{
      streaming: true,
      function_calling: false,
      json_mode: true,
      vision: false,
      system_messages: true,
      temperature_range: {0.0, 2.0},
      max_tokens_limit: nil,  # Depends on loaded model
      supported_models: [],  # Dynamic based on loaded models
      model_specific_params: %{},
      provider_specific_params: [
        :format,
        :options,
        :system,
        :template,
        :context,
        :stream,
        :raw
      ]
    },
    custom: %{
      streaming: true,
      function_calling: false,
      json_mode: false,
      vision: false,
      system_messages: true,
      temperature_range: {0.0, 2.0},
      max_tokens_limit: nil,
      supported_models: [],
      model_specific_params: %{},
      provider_specific_params: []
    }
  }

  # Client API

  @doc """
  Gets provider capabilities for a specific provider.

  ## Parameters
  - provider: Atom representing the provider

  ## Returns
  - {:ok, capabilities} with provider capabilities map
  - {:error, reason} if provider not supported
  """
  @spec get_provider_capabilities(atom()) :: {:ok, map()} | {:error, term()}
  def get_provider_capabilities(provider) do
    case Map.get(@provider_capabilities, provider) do
      nil ->
        {:error, "Unsupported provider: #{provider}"}
      capabilities ->
        {:ok, capabilities}
    end
  end

  @doc """
  Validates provider-specific parameters for a given provider and model.

  ## Parameters
  - provider: Atom representing the provider
  - model: String representing the model
  - params: Map containing parameters to validate

  ## Returns
  - {:ok, validated_params} if validation passes
  - {:error, validation_errors} if validation fails
  """
  @spec validate_provider_params(atom(), String.t(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate_provider_params(provider, model, params) do
    with {:ok, capabilities} <- get_provider_capabilities(provider),
         {:ok, model_params} <- get_model_specific_params(provider, model),
         :ok <- validate_temperature(params, capabilities),
         :ok <- validate_max_tokens(params, model_params),
         :ok <- validate_provider_specific_params(params, capabilities),
         :ok <- validate_model_capabilities(params, model_params) do
      {:ok, params}
    else
      {:error, errors} when is_list(errors) ->
        {:error, errors}
      {:error, error} ->
        {:error, [error]}
    end
  end

  @doc """
  Gets model-specific parameters for a provider and model.

  ## Parameters
  - provider: Atom representing the provider
  - model: String representing the model

  ## Returns
  - {:ok, model_params} with model-specific parameters
  - {:error, reason} if model not supported
  """
  @spec get_model_specific_params(atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_model_specific_params(provider, model) do
    case get_provider_capabilities(provider) do
      {:ok, capabilities} ->
        model_params = get_in(capabilities, [:model_specific_params, model])
        case model_params do
          nil ->
            # Check if model is in supported models list
            supported_models = Map.get(capabilities, :supported_models, [])
            if model in supported_models do
              {:ok, %{}}  # Model supported but no specific params
            else
              {:error, "Model #{model} not supported by provider #{provider}"}
            end
          params ->
            {:ok, params}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds provider-specific configuration with parameter validation.

  ## Parameters
  - provider: Atom representing the provider
  - model: String representing the model
  - base_params: Map containing base parameters
  - provider_params: Map containing provider-specific parameters

  ## Returns
  - {:ok, config} with validated provider configuration
  - {:error, validation_errors} if validation fails
  """
  @spec build_provider_config(atom(), String.t(), map(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def build_provider_config(provider, model, base_params, provider_params) do
    # Merge base and provider-specific parameters
    merged_params = Map.merge(base_params, provider_params)

    # Validate the merged parameters
    case validate_provider_params(provider, model, merged_params) do
      {:ok, validated_params} ->
        # Build final configuration
        config = %{
          provider: provider,
          model: model,
          parameters: validated_params,
          capabilities: get_provider_capabilities(provider) |> elem(1),
          model_params: get_model_specific_params(provider, model) |> elem(1)
        }
        {:ok, config}

      {:error, errors} ->
        {:error, errors}
    end
  end

  @doc """
  Maps provider capabilities to a standardized format.

  ## Parameters
  - provider: Atom representing the provider

  ## Returns
  - {:ok, capability_map} with standardized capabilities
  - {:error, reason} if provider not supported
  """
  @spec map_provider_capabilities(atom()) :: {:ok, map()} | {:error, term()}
  def map_provider_capabilities(provider) do
    case get_provider_capabilities(provider) do
      {:ok, capabilities} ->
        standardized = %{
          streaming_supported: Map.get(capabilities, :streaming, false),
          function_calling_supported: Map.get(capabilities, :function_calling, false),
          json_mode_supported: Map.get(capabilities, :json_mode, false),
          vision_supported: Map.get(capabilities, :vision, false),
          system_messages_supported: Map.get(capabilities, :system_messages, false),
          temperature_range: Map.get(capabilities, :temperature_range, {0.0, 1.0}),
          max_tokens_limit: Map.get(capabilities, :max_tokens_limit),
          supported_models: Map.get(capabilities, :supported_models, []),
          provider_specific_params: Map.get(capabilities, :provider_specific_params, [])
        }
        {:ok, standardized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validates if a specific capability is supported by a provider.

  ## Parameters
  - provider: Atom representing the provider
  - capability: Atom representing the capability to check

  ## Returns
  - {:ok, supported} with boolean indicating support
  - {:error, reason} if provider not supported
  """
  @spec check_capability_support(atom(), atom()) :: {:ok, boolean()} | {:error, term()}
  def check_capability_support(provider, capability) do
    case get_provider_capabilities(provider) do
      {:ok, capabilities} ->
        supported = Map.get(capabilities, capability, false)
        {:ok, supported}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets all supported models for a provider.

  ## Parameters
  - provider: Atom representing the provider

  ## Returns
  - {:ok, models} with list of supported models
  - {:error, reason} if provider not supported
  """
  @spec get_supported_models(atom()) :: {:ok, [String.t()]} | {:error, term()}
  def get_supported_models(provider) do
    case get_provider_capabilities(provider) do
      {:ok, capabilities} ->
        models = Map.get(capabilities, :supported_models, [])
        {:ok, models}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validates model compatibility with provider.

  ## Parameters
  - provider: Atom representing the provider
  - model: String representing the model

  ## Returns
  - :ok if model is compatible
  - {:error, reason} if model is not compatible
  """
  @spec validate_model_compatibility(atom(), String.t()) :: :ok | {:error, term()}
  def validate_model_compatibility(provider, model) do
    case get_supported_models(provider) do
      {:ok, []} ->
        # Empty list means all models are supported (e.g., custom provider)
        :ok

      {:ok, supported_models} ->
        if model in supported_models do
          :ok
        else
          {:error, "Model #{model} is not supported by provider #{provider}. Supported models: #{Enum.join(supported_models, ", ")}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private Functions

  defp validate_temperature(params, capabilities) do
    case Map.get(params, :temperature) do
      nil ->
        :ok  # Temperature is optional

      temperature when is_number(temperature) ->
        {min_temp, max_temp} = Map.get(capabilities, :temperature_range, {0.0, 1.0})
        if temperature >= min_temp and temperature <= max_temp do
          :ok
        else
          {:error, "Temperature #{temperature} is outside valid range #{min_temp}-#{max_temp} for this provider"}
        end

      _ ->
        {:error, "Temperature must be a number"}
    end
  end

  defp validate_max_tokens(params, model_params) do
    case Map.get(params, :max_tokens) do
      nil ->
        :ok  # max_tokens is optional

      max_tokens when is_integer(max_tokens) and max_tokens > 0 ->
        case Map.get(model_params, :max_tokens) do
          nil ->
            :ok  # No limit specified for this model

          model_limit when max_tokens <= model_limit ->
            :ok

          model_limit ->
            {:error, "max_tokens #{max_tokens} exceeds model limit of #{model_limit}"}
        end

      _ ->
        {:error, "max_tokens must be a positive integer"}
    end
  end

  defp validate_provider_specific_params(params, capabilities) do
    allowed_params = Map.get(capabilities, :provider_specific_params, [])
    param_keys = Map.keys(params)

    # Check for any provider-specific parameters that aren't allowed
    invalid_params = param_keys
    |> Enum.filter(fn key ->
      # Skip common parameters that are always allowed
      key not in [:temperature, :max_tokens, :model, :provider, :streaming] and
      key not in allowed_params
    end)

    case invalid_params do
      [] ->
        :ok
      _ ->
        {:error, "Invalid provider-specific parameters: #{Enum.join(invalid_params, ", ")}. Allowed: #{Enum.join(allowed_params, ", ")}"}
    end
  end

  defp validate_model_capabilities(params, model_params) do
    errors = []

    # Check function calling support
    errors = if Map.has_key?(params, :tools) or Map.has_key?(params, :functions) do
      if Map.get(model_params, :supports_function_calling, false) do
        errors
      else
        ["Function calling is not supported by this model" | errors]
      end
    else
      errors
    end

    # Check vision support
    errors = if has_vision_content?(params) do
      if Map.get(model_params, :supports_vision, false) do
        errors
      else
        ["Vision/image processing is not supported by this model" | errors]
      end
    else
      errors
    end

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp has_vision_content?(params) do
    # Check if messages contain image content
    messages = Map.get(params, :messages, [])
    Enum.any?(messages, fn message ->
      content = Map.get(message, :content, [])
      if is_list(content) do
        Enum.any?(content, fn item ->
          Map.get(item, :type) == "image_url"
        end)
      else
        false
      end
    end)
  end
end
