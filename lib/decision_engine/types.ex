defmodule DecisionEngine.Types do
  @moduledoc """
  Central type definitions for the multi-domain decision engine.
  
  This module defines all domain types and configuration structures used
  throughout the decision engine system.
  """

  @typedoc """
  Supported decision domains in the system.
  """
  @type domain :: :power_platform | :data_platform | :integration_platform

  @typedoc """
  Complete rule configuration structure for a domain.
  
  Contains domain metadata, signal field definitions, and decision patterns.
  """
  @type rule_config :: %{
    String.t() => term()
  }

  @typedoc """
  Individual decision pattern within a domain's rule configuration.
  
  Each pattern represents a specific recommendation scenario with conditions
  for when it should be used or avoided.
  """
  @type pattern :: %{
    String.t() => term()
  }

  @typedoc """
  Condition structure for pattern matching.
  
  Defines field-based conditions with operators for evaluating signals
  against pattern requirements.
  """
  @type condition :: %{
    String.t() => term()
  }

  @doc """
  Returns all supported domains in the system.
  """
  @spec supported_domains() :: [domain()]
  def supported_domains do
    [:power_platform, :data_platform, :integration_platform]
  end

  @doc """
  Dynamically discovers available domains from configuration files.
  
  Scans the priv/rules directory for JSON configuration files and returns
  the corresponding domain atoms for files that exist and are valid.
  
  ## Returns
  - List of domain atoms for which configuration files exist
  
  ## Examples
      iex> DecisionEngine.Types.discover_domains()
      [:power_platform, :data_platform, :integration_platform]
  """
  @spec discover_domains() :: [atom()]
  def discover_domains do
    config_dir = "priv/rules"
    
    case File.ls(config_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.rootname/1)
        |> Enum.map(&string_to_domain/1)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, domain} -> domain end)
        |> Enum.sort()
      
      {:error, _reason} ->
        # Fallback to hardcoded domains if directory doesn't exist
        supported_domains()
    end
  end

  @doc """
  Checks if a domain is supported by the system.
  
  ## Parameters
  - domain: The domain atom to check
  
  ## Returns
  - true if domain is supported, false otherwise
  """
  @spec domain_supported?(atom()) :: boolean()
  def domain_supported?(domain) do
    domain in discover_domains()
  end

  @doc """
  Creates a template configuration for a new domain.
  
  Generates a basic configuration structure that can be customized
  for a new domain. The template includes required fields and example
  patterns to help with domain setup.
  
  ## Parameters
  - domain_name: String name for the new domain (e.g., "ai_platform")
  - signals_fields: List of signal field names for the domain
  - sample_patterns: Optional list of sample patterns (defaults to basic template)
  
  ## Returns
  - Map containing the template configuration
  
  ## Examples
      iex> template = DecisionEngine.Types.create_domain_template("ai_platform", ["model_type", "use_case"])
      iex> template["domain"]
      "ai_platform"
  """
  @spec create_domain_template(String.t(), [String.t()], [map()]) :: map()
  def create_domain_template(domain_name, signals_fields, sample_patterns \\ nil) do
    patterns = sample_patterns || [
      %{
        "id" => "#{domain_name}_basic_pattern",
        "outcome" => "prefer_#{domain_name}_solution",
        "score" => 0.8,
        "summary" => "Basic recommendation for #{domain_name} domain",
        "use_when" => [
          %{"field" => "example_field", "op" => "in", "value" => ["example_value"]}
        ],
        "avoid_when" => [
          %{"field" => "example_field", "op" => "in", "value" => ["avoid_value"]}
        ],
        "typical_use_cases" => [
          "Example use case for #{domain_name}",
          "Another example scenario"
        ]
      }
    ]

    %{
      "domain" => domain_name,
      "signals_fields" => signals_fields,
      "patterns" => patterns
    }
  end

  @doc """
  Validates a new domain configuration before it's added to the system.
  
  Performs comprehensive validation including structure validation,
  field consistency checks, and pattern validation. This is more thorough
  than the basic validate_rule_config/1 function.
  
  ## Parameters
  - config: The domain configuration map to validate
  - domain_name: Expected domain name for consistency checking
  
  ## Returns
  - :ok if validation passes
  - {:error, reason} if validation fails
  """
  @spec validate_new_domain_config(map(), String.t()) :: :ok | {:error, String.t()}
  def validate_new_domain_config(config, domain_name) do
    with :ok <- validate_rule_config(config),
         :ok <- validate_domain_name_consistency(config, domain_name),
         :ok <- validate_signals_fields_usage(config),
         :ok <- validate_pattern_uniqueness(config) do
      :ok
    end
  end

  defp validate_domain_name_consistency(config, expected_domain) do
    case config["domain"] do
      ^expected_domain -> :ok
      actual_domain -> {:error, "Domain name mismatch: expected '#{expected_domain}', got '#{actual_domain}'"}
    end
  end

  defp validate_signals_fields_usage(config) do
    signals_fields = MapSet.new(config["signals_fields"])
    patterns = config["patterns"]
    
    # Check that all fields used in patterns are defined in signals_fields
    used_fields = 
      patterns
      |> Enum.flat_map(fn pattern ->
        (pattern["use_when"] ++ pattern["avoid_when"])
        |> Enum.map(& &1["field"])
      end)
      |> MapSet.new()
    
    undefined_fields = MapSet.difference(used_fields, signals_fields)
    
    if MapSet.size(undefined_fields) == 0 do
      :ok
    else
      fields_list = undefined_fields |> MapSet.to_list() |> Enum.join(", ")
      {:error, "Patterns reference undefined signal fields: #{fields_list}"}
    end
  end

  defp validate_pattern_uniqueness(config) do
    patterns = config["patterns"]
    pattern_ids = Enum.map(patterns, & &1["id"])
    unique_ids = Enum.uniq(pattern_ids)
    
    if length(pattern_ids) == length(unique_ids) do
      :ok
    else
      duplicate_ids = pattern_ids -- unique_ids
      {:error, "Duplicate pattern IDs found: #{Enum.join(duplicate_ids, ", ")}"}
    end
  end

  @doc """
  Converts a domain atom to its string representation for file naming.
  """
  @spec domain_to_string(atom()) :: String.t()
  def domain_to_string(domain) when is_atom(domain) do
    Atom.to_string(domain)
  end

  @doc """
  Converts a string to its corresponding domain atom.
  """
  @spec string_to_domain(String.t()) :: {:ok, atom()} | {:error, :invalid_domain}
  def string_to_domain(domain_string) when is_binary(domain_string) do
    # Convert string to atom and check if it's a valid domain name format
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, domain_string) do
      {:ok, String.to_atom(domain_string)}
    else
      {:error, :invalid_domain}
    end
  end
  def string_to_domain(_), do: {:error, :invalid_domain}

  @doc """
  Validates that a rule configuration has the required structure.
  """
  @spec validate_rule_config(map()) :: :ok | {:error, String.t()}
  def validate_rule_config(config) when is_map(config) do
    required_fields = ["domain", "signals_fields", "patterns"]
    
    case check_required_fields(config, required_fields) do
      :ok -> validate_patterns(config["patterns"])
      error -> error
    end
  end
  def validate_rule_config(_), do: {:error, "Configuration must be a map"}

  defp check_required_fields(config, fields) do
    missing_fields = Enum.filter(fields, &(not Map.has_key?(config, &1)))
    
    case missing_fields do
      [] -> :ok
      missing -> {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_patterns(patterns) when is_list(patterns) do
    pattern_fields = ["id", "outcome", "score", "summary", "use_when", "avoid_when", "typical_use_cases"]
    
    patterns
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {pattern, index}, _acc ->
      case check_required_fields(pattern, pattern_fields) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, "Pattern #{index}: #{msg}"}}
      end
    end)
  end
  defp validate_patterns(_), do: {:error, "Patterns must be a list"}
end