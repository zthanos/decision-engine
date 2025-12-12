defmodule DecisionEngine.SignalsSchema do
  @moduledoc """
  Domain coordinator for signal schema modules.
  
  This module provides a unified interface for accessing domain-specific
  signal schemas and their associated functionality. It maps domains to
  their corresponding schema modules and provides convenience functions
  for schema operations.
  """

  alias DecisionEngine.Types
  alias DecisionEngine.SignalsSchema.{PowerPlatform, DataPlatform, IntegrationPlatform}

  @doc """
  Returns the schema module for the specified domain.
  
  ## Examples
  
      iex> DecisionEngine.SignalsSchema.module_for(:power_platform)
      DecisionEngine.SignalsSchema.PowerPlatform
      
      iex> DecisionEngine.SignalsSchema.module_for(:data_platform)
      DecisionEngine.SignalsSchema.DataPlatform
  """
  @spec module_for(atom()) :: module()
  def module_for(:power_platform), do: PowerPlatform
  def module_for(:data_platform), do: DataPlatform
  def module_for(:integration_platform), do: IntegrationPlatform
  def module_for(domain) when is_atom(domain) do
    # For dynamic domains, try to construct the module name
    # This is a fallback - in a real system, you'd want a registry
    domain_string = domain |> Atom.to_string() |> Macro.camelize()
    Module.concat([DecisionEngine.SignalsSchema, domain_string])
  end

  @doc """
  Returns the JSON schema for the specified domain.
  
  ## Examples
  
      iex> schema = DecisionEngine.SignalsSchema.schema_for(:power_platform)
      iex> schema["type"]
      "object"
  """
  @spec schema_for(atom()) :: map()
  def schema_for(domain) do
    domain
    |> module_for()
    |> apply(:schema, [])
  end

  @doc """
  Applies domain-specific defaults to signals.
  
  ## Examples
  
      iex> signals = %{"workload_type" => "user_productivity"}
      iex> DecisionEngine.SignalsSchema.apply_defaults(:power_platform, signals)
      %{"workload_type" => "user_productivity", "primary_users" => ["business_users"], ...}
  """
  @spec apply_defaults(atom(), map()) :: map()
  def apply_defaults(domain, signals) do
    domain
    |> module_for()
    |> apply(:apply_defaults, [signals])
  end

  @doc """
  Returns all supported domains with their schema modules.
  
  ## Examples
  
      iex> DecisionEngine.SignalsSchema.supported_domains()
      [
        {:power_platform, DecisionEngine.SignalsSchema.PowerPlatform},
        {:data_platform, DecisionEngine.SignalsSchema.DataPlatform},
        {:integration_platform, DecisionEngine.SignalsSchema.IntegrationPlatform}
      ]
  """
  @spec supported_domains() :: [{Types.domain(), module()}]
  def supported_domains do
    [
      {:power_platform, PowerPlatform},
      {:data_platform, DataPlatform},
      {:integration_platform, IntegrationPlatform}
    ]
  end

  @doc """
  Discovers available domains dynamically from configuration files.
  
  For extensibility, this returns all domains with valid configurations,
  regardless of schema module availability. Schema modules are optional
  for basic domain functionality.
  
  ## Returns
  - List of domain atoms that have valid configurations
  
  ## Examples
      iex> DecisionEngine.SignalsSchema.discover_available_domains()
      [:power_platform, :data_platform, :integration_platform]
  """
  @spec discover_available_domains() :: [Types.domain()]
  def discover_available_domains do
    # For extensibility, return all domains with valid configurations
    Types.discover_domains()
  end

  @doc """
  Checks if a schema module exists for the given domain.
  
  ## Parameters
  - domain: The domain atom to check
  
  ## Returns
  - true if schema module exists, false otherwise
  """
  @spec schema_module_exists?(atom()) :: boolean()
  def schema_module_exists?(domain) do
    try do
      module = module_for(domain)
      Code.ensure_loaded?(module) and function_exported?(module, :schema, 0)
    rescue
      _ -> false
    end
  end

  @doc """
  Validates that a domain has both configuration and schema support.
  
  ## Parameters
  - domain: The domain atom to validate
  
  ## Returns
  - :ok if domain is fully supported
  - {:error, reason} if domain is missing components
  """
  @spec validate_domain_support(atom()) :: :ok | {:error, term()}
  def validate_domain_support(domain) do
    with :ok <- validate_config_exists(domain),
         :ok <- validate_schema_module_exists(domain) do
      :ok
    end
  end

  defp validate_config_exists(domain) do
    case DecisionEngine.RuleConfig.validate_domain_availability(domain) do
      :ok -> :ok
      {:error, reason} -> {:error, {:config_unavailable, domain, reason}}
    end
  end

  defp validate_schema_module_exists(domain) do
    if schema_module_exists?(domain) do
      :ok
    else
      {:error, {:schema_module_missing, domain, module_for(domain)}}
    end
  end

  # Backward compatibility - delegate to PowerPlatform for existing code
  @doc false
  def schema, do: PowerPlatform.schema()

  @doc false
  def apply_defaults(signals), do: PowerPlatform.apply_defaults(signals)
end
