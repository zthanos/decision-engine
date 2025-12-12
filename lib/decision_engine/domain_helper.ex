defmodule DecisionEngine.DomainHelper do
  @moduledoc """
  Helper functions for domain extensibility and management.
  
  This module provides utilities for creating, validating, and managing
  domain configurations dynamically. It supports the extensibility features
  that allow new domains to be added without modifying core engine logic.
  """

  require Logger
  alias DecisionEngine.{Types, RuleConfig, SignalsSchema, DomainManager}

  @doc """
  Creates a complete domain setup including configuration file and validation.
  
  This is a high-level function that handles the entire process of adding
  a new domain to the system, including validation, file creation, and
  verification.
  
  ## Parameters
  - domain_name: String name for the new domain
  - signals_fields: List of signal field names
  - patterns: List of decision patterns
  - options: Optional configuration
  
  ## Returns
  - {:ok, domain_info} on success with complete domain information
  - {:error, reason} on failure
  
  ## Examples
      iex> patterns = [create_sample_pattern("ai_platform", "model_type")]
      iex> DecisionEngine.DomainHelper.create_complete_domain("ai_platform", ["model_type"], patterns)
      {:ok, %{domain: :ai_platform, config_path: "priv/rules/ai_platform.json", ...}}
  """
  @spec create_complete_domain(String.t(), [String.t()], [map()], keyword()) :: 
    {:ok, map()} | {:error, term()}
  def create_complete_domain(domain_name, signals_fields, patterns, options \\ []) do
    Logger.info("Creating complete domain setup for: #{domain_name}")
    
    with {:ok, domain_atom} <- DomainManager.add_domain(domain_name, signals_fields, patterns, options),
         {:ok, domain_info} <- DomainManager.get_domain_info(domain_atom),
         :ok <- validate_domain_functionality(domain_atom) do
      
      Logger.info("Successfully created complete domain: #{domain_name}")
      {:ok, domain_info}
    else
      {:error, reason} = error ->
        Logger.error("Failed to create complete domain #{domain_name}: #{inspect(reason)}")
        # Cleanup on failure
        cleanup_failed_domain(domain_name)
        error
    end
  end

  @doc """
  Creates a sample pattern for a new domain.
  
  Generates a basic pattern structure that can be used as a template
  for creating domain-specific patterns.
  
  ## Parameters
  - domain_name: String name of the domain
  - primary_field: Primary signal field for the pattern
  - options: Optional configuration for pattern generation
  
  ## Returns
  - Map containing a sample pattern structure
  """
  @spec create_sample_pattern(String.t(), String.t(), keyword()) :: map()
  def create_sample_pattern(domain_name, primary_field, options \\ []) do
    pattern_id = Keyword.get(options, :pattern_id, "#{domain_name}_basic_recommendation")
    outcome = Keyword.get(options, :outcome, "prefer_#{domain_name}_solution")
    score = Keyword.get(options, :score, 0.8)
    
    %{
      "id" => pattern_id,
      "outcome" => outcome,
      "score" => score,
      "summary" => "Basic recommendation for #{String.replace(domain_name, "_", " ")} domain",
      "use_when" => [
        %{"field" => primary_field, "op" => "in", "value" => ["recommended_value"]}
      ],
      "avoid_when" => [
        %{"field" => primary_field, "op" => "in", "value" => ["avoid_value"]}
      ],
      "typical_use_cases" => [
        "Primary use case for #{String.replace(domain_name, "_", " ")}",
        "Secondary scenario for #{String.replace(domain_name, "_", " ")}"
      ]
    }
  end

  @doc """
  Validates that a domain configuration file can be reloaded without restart.
  
  Tests the configuration reloading functionality by modifying and reloading
  a domain configuration to ensure the system supports dynamic updates.
  
  ## Parameters
  - domain: The domain atom to test
  
  ## Returns
  - :ok if reloading works correctly
  - {:error, reason} if reloading fails
  """
  @spec test_configuration_reloading(atom()) :: :ok | {:error, term()}
  def test_configuration_reloading(domain) do
    Logger.info("Testing configuration reloading for domain: #{domain}")
    
    with {:ok, original_config} <- RuleConfig.load(domain),
         :ok <- validate_config_structure(original_config),
         {:ok, reloaded_config} <- RuleConfig.reload(domain),
         :ok <- validate_config_consistency(original_config, reloaded_config) do
      
      Logger.info("Configuration reloading test passed for domain: #{domain}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Configuration reloading test failed for domain #{domain}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Discovers and validates all available domains in the system.
  
  Performs a comprehensive scan of the system to find all available domains
  and validates their configurations and schema modules.
  
  ## Returns
  - {:ok, domain_report} with detailed information about all domains
  - {:error, issues} if problems are found
  """
  @spec discover_and_validate_domains() :: {:ok, map()} | {:error, map()}
  def discover_and_validate_domains do
    Logger.info("Discovering and validating all domains")
    
    discovered_domains = Types.discover_domains()
    
    domain_details = 
      discovered_domains
      |> Enum.map(&analyze_domain/1)
      |> Enum.into(%{})
    
    healthy_domains = 
      domain_details
      |> Enum.filter(fn {_domain, info} -> info.status == :healthy end)
      |> Enum.map(fn {domain, _info} -> domain end)
    
    problematic_domains = 
      domain_details
      |> Enum.filter(fn {_domain, info} -> info.status != :healthy end)
      |> Enum.into(%{})
    
    report = %{
      total_discovered: length(discovered_domains),
      healthy_domains: healthy_domains,
      healthy_count: length(healthy_domains),
      problematic_domains: problematic_domains,
      problematic_count: map_size(problematic_domains),
      discovery_timestamp: DateTime.utc_now(),
      domain_details: domain_details
    }
    
    if map_size(problematic_domains) == 0 do
      {:ok, report}
    else
      {:error, report}
    end
  end

  @doc """
  Creates a schema module template for a new domain.
  
  Generates the basic structure for a domain-specific schema module
  that can be customized for the domain's specific signal fields.
  
  ## Parameters
  - domain_name: String name of the domain
  - signals_fields: List of signal field names with their types
  
  ## Returns
  - String containing the module template code
  """
  @spec create_schema_module_template(String.t(), [map()]) :: String.t()
  def create_schema_module_template(domain_name, signals_fields) do
    module_name = domain_name |> Macro.camelize()
    
    properties = 
      signals_fields
      |> Enum.map(&format_schema_property/1)
      |> Enum.join(",\n      ")
    
    required_fields = 
      signals_fields
      |> Enum.filter(& &1[:required])
      |> Enum.map(& &1.name)
      |> Jason.encode!()
    
    """
    defmodule DecisionEngine.SignalsSchema.#{module_name} do
      @moduledoc \"\"\"
      Signal schema for #{String.replace(domain_name, "_", " ")} domain.
      
      This module defines the signal structure and validation rules
      for #{String.replace(domain_name, "_", " ")} decision scenarios.
      \"\"\"

      @behaviour DecisionEngine.SignalsSchema.Behaviour

      @schema %{
        "type" => "object",
        "properties" => %{
          #{properties}
        },
        "required" => #{required_fields}
      }

      @impl true
      def schema, do: @schema

      @impl true
      def apply_defaults(signals) do
        # Apply domain-specific defaults
        signals
        |> Map.put_new("default_field", "default_value")
        # Add more defaults as needed
      end
    end
    """
  end

  ## Private Functions

  defp validate_domain_functionality(domain_atom) do
    # Test that the domain can be loaded and basic operations work
    with {:ok, _config} <- RuleConfig.load(domain_atom),
         :ok <- test_configuration_reloading(domain_atom) do
      :ok
    end
  end

  defp cleanup_failed_domain(domain_name) do
    # Attempt to clean up any partially created domain files
    domain_atom = String.to_atom(domain_name)
    RuleConfig.remove_domain(domain_atom)
  end

  defp validate_config_structure(config) do
    required_fields = ["domain", "signals_fields", "patterns"]
    
    missing_fields = Enum.filter(required_fields, &(not Map.has_key?(config, &1)))
    
    case missing_fields do
      [] -> :ok
      missing -> {:error, {:missing_fields, missing}}
    end
  end

  defp validate_config_consistency(original, reloaded) do
    if original == reloaded do
      :ok
    else
      {:error, :config_inconsistency}
    end
  end

  defp analyze_domain(domain) do
    analysis = %{
      domain: domain,
      config_available: false,
      schema_available: false,
      status: :unknown,
      issues: []
    }
    
    # Check configuration availability
    config_result = RuleConfig.load(domain)
    analysis = case config_result do
      {:ok, _config} -> 
        %{analysis | config_available: true}
      {:error, reason} -> 
        %{analysis | issues: [[:config_error, reason] | analysis.issues]}
    end
    
    # Check schema module availability
    schema_available = SignalsSchema.schema_module_exists?(domain)
    analysis = %{analysis | schema_available: schema_available}
    
    # Determine overall status
    status = cond do
      analysis.config_available and analysis.schema_available -> :healthy
      analysis.config_available -> :partial
      true -> :unhealthy
    end
    
    %{analysis | status: status}
  end

  defp format_schema_property(%{name: name, type: type, enum: enum}) when is_list(enum) do
    ~s("#{name}" => %{
        "type" => "#{type}",
        "enum" => #{Jason.encode!(enum)},
        "description" => "#{String.replace(name, "_", " ") |> String.capitalize()}"
      })
  end

  defp format_schema_property(%{name: name, type: "array", items: items}) do
    ~s("#{name}" => %{
        "type" => "array",
        "items" => %{
          "type" => "string",
          "enum" => #{Jason.encode!(items)}
        },
        "description" => "#{String.replace(name, "_", " ") |> String.capitalize()}"
      })
  end

  defp format_schema_property(%{name: name, type: type}) do
    ~s("#{name}" => %{
        "type" => "#{type}",
        "description" => "#{String.replace(name, "_", " ") |> String.capitalize()}"
      })
  end

  defp format_schema_property(name) when is_binary(name) do
    ~s("#{name}" => %{
        "type" => "string",
        "description" => "#{String.replace(name, "_", " ") |> String.capitalize()}"
      })
  end
end