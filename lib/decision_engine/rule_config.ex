defmodule DecisionEngine.RuleConfig do
  @moduledoc """
  Configuration loader for domain-specific rule configurations.
  
  This module handles loading, validation, and caching of JSON configuration files
  for different decision domains. Each domain has its own configuration file
  containing signal fields and decision patterns.
  """

  require Logger
  alias DecisionEngine.Types

  # GenServer for caching configurations
  use GenServer

  @config_dir "priv/rules"
  @cache_table :rule_config_cache

  ## Public API

  @doc """
  Starts the RuleConfig GenServer for configuration caching.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Loads a domain-specific rule configuration.
  
  Attempts to load from cache first, then from file if not cached.
  Validates the configuration structure before returning.
  
  ## Parameters
  - domain: The domain atom (:power_platform, :data_platform, :integration_platform)
  
  ## Returns
  - {:ok, rule_config} on success
  - {:error, reason} on failure
  
  ## Examples
      iex> DecisionEngine.RuleConfig.load(:power_platform)
      {:ok, %{"domain" => "power_platform", "signals_fields" => [...], "patterns" => [...]}}
      
      iex> DecisionEngine.RuleConfig.load(:invalid_domain)
      {:error, :invalid_domain}
  """
  @spec load(atom()) :: {:ok, Types.rule_config()} | {:error, term()}
  def load(domain) when is_atom(domain) do
    # Check if domain is supported before attempting to load
    unless Types.domain_supported?(domain) do
      Logger.error("Invalid domain requested: #{inspect(domain)}")
      {:error, :invalid_domain}
    else
    
      case get_from_cache(domain) do
        {:ok, config} -> 
          Logger.debug("Loaded #{domain} configuration from cache")
          {:ok, config}
        :not_found -> 
          load_from_file(domain)
      end
    end
  end
  def load(domain) do
    Logger.error("Invalid domain requested: #{inspect(domain)}")
    {:error, :invalid_domain}
  end

  @doc """
  Reloads a domain configuration from file, bypassing cache.
  
  Useful for configuration updates without application restart.
  
  ## Parameters
  - domain: The domain atom to reload
  
  ## Returns
  - {:ok, rule_config} on success
  - {:error, reason} on failure
  """
  @spec reload(atom()) :: {:ok, Types.rule_config()} | {:error, term()}
  def reload(domain) when is_atom(domain) do
    # Check if domain is supported before attempting to reload
    unless Types.domain_supported?(domain) do
      Logger.error("Invalid domain for reload: #{inspect(domain)}")
      {:error, :invalid_domain}
    else
      Logger.info("Reloading configuration for domain: #{domain}")
      
      case load_from_file(domain, bypass_cache: true) do
        {:ok, config} ->
          # Update cache with new configuration
          put_in_cache(domain, config)
          {:ok, config}
        error ->
          error
      end
    end
  end
  def reload(domain) do
    Logger.error("Invalid domain for reload: #{inspect(domain)}")
    {:error, :invalid_domain}
  end

  @doc """
  Clears the configuration cache.
  
  Forces all subsequent loads to read from file.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    GenServer.call(__MODULE__, :clear_cache)
  end

  @doc """
  Returns the file path for a domain's configuration.
  
  ## Parameters
  - domain: The domain atom
  
  ## Returns
  - String path to the configuration file
  """
  @spec config_path(atom()) :: String.t()
  def config_path(domain) do
    domain_string = Types.domain_to_string(domain)
    Path.join(@config_dir, "#{domain_string}.json")
  end

  @doc """
  Discovers all available domains by scanning configuration files.
  
  Returns a list of domain atoms for which valid configuration files exist.
  This enables dynamic domain discovery without hardcoding domain lists.
  
  ## Returns
  - List of available domain atoms
  
  ## Examples
      iex> DecisionEngine.RuleConfig.discover_available_domains()
      [:power_platform, :data_platform, :integration_platform]
  """
  @spec discover_available_domains() :: [Types.domain()]
  def discover_available_domains do
    Types.discover_domains()
  end

  @doc """
  Adds a new domain configuration to the system.
  
  Creates a new configuration file for the specified domain and validates
  the configuration structure. The domain becomes immediately available
  for use after successful addition.
  
  ## Parameters
  - domain_name: String name for the new domain
  - config: Configuration map for the domain
  
  ## Returns
  - {:ok, domain_atom} on success
  - {:error, reason} on failure
  
  ## Examples
      iex> config = %{"domain" => "ai_platform", "signals_fields" => [...], "patterns" => [...]}
      iex> DecisionEngine.RuleConfig.add_domain("ai_platform", config)
      {:ok, :ai_platform}
  """
  @spec add_domain(String.t(), map()) :: {:ok, atom()} | {:error, term()}
  def add_domain(domain_name, config) when is_binary(domain_name) and is_map(config) do
    Logger.info("Adding new domain: #{domain_name}")
    
    with :ok <- validate_domain_name(domain_name),
         :ok <- Types.validate_new_domain_config(config, domain_name),
         domain_atom <- String.to_atom(domain_name),
         :ok <- ensure_config_directory(),
         path <- Path.join(@config_dir, "#{domain_name}.json"),
         :ok <- write_config_file(path, config, domain_name),
         :ok <- validate_written_config(domain_atom) do
      
      Logger.info("Successfully added domain: #{domain_name}")
      {:ok, domain_atom}
    else
      {:error, reason} = error ->
        Logger.error("Failed to add domain #{domain_name}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Removes a domain configuration from the system.
  
  Deletes the configuration file and clears any cached data for the domain.
  The domain becomes unavailable for use after removal.
  
  ## Parameters
  - domain: The domain atom to remove
  
  ## Returns
  - :ok on success
  - {:error, reason} on failure
  
  ## Examples
      iex> DecisionEngine.RuleConfig.remove_domain(:ai_platform)
      :ok
  """
  @spec remove_domain(atom()) :: :ok | {:error, term()}
  def remove_domain(domain) do
    Logger.info("Removing domain: #{domain}")
    
    path = config_path(domain)
    
    case File.rm(path) do
      :ok ->
        # Clear from cache
        GenServer.cast(__MODULE__, {:remove, domain})
        Logger.info("Successfully removed domain: #{domain}")
        :ok
      
      {:error, :enoent} ->
        Logger.warning("Domain configuration file not found: #{path}")
        # Still clear from cache in case it was cached
        GenServer.cast(__MODULE__, {:remove, domain})
        :ok
      
      {:error, reason} = error ->
        Logger.error("Failed to remove domain #{domain}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Validates that a domain configuration file exists and is valid.
  
  ## Parameters
  - domain: The domain atom to validate
  
  ## Returns
  - :ok if domain is valid and available
  - {:error, reason} if domain is invalid or unavailable
  """
  @spec validate_domain_availability(atom()) :: :ok | {:error, term()}
  def validate_domain_availability(domain) do
    case load(domain) do
      {:ok, _config} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ## Private Functions

  defp load_from_file(domain, opts \\ []) do
    bypass_cache = Keyword.get(opts, :bypass_cache, false)
    path = config_path(domain)
    
    Logger.debug("Loading #{domain} configuration from file: #{path}")
    
    with {:ok, content} <- read_config_file(path, domain),
         {:ok, config} <- parse_json(content, domain),
         :ok <- validate_config(config, domain) do
      
      unless bypass_cache do
        put_in_cache(domain, config)
      end
      
      Logger.info("Successfully loaded configuration for domain: #{domain}")
      {:ok, config}
    else
      {:error, reason} = error ->
        Logger.error("Failed to load configuration for #{domain}: #{inspect(reason)}")
        error
    end
  end

  defp read_config_file(path, domain) do
    case File.read(path) do
      {:ok, content} -> 
        {:ok, content}
      {:error, :enoent} -> 
        {:error, {:file_not_found, domain, path}}
      {:error, reason} -> 
        {:error, {:file_read_error, domain, path, reason}}
    end
  end

  defp parse_json(content, domain) do
    case Jason.decode(content) do
      {:ok, config} when is_map(config) -> 
        {:ok, config}
      {:ok, _} -> 
        {:error, {:invalid_json_structure, domain, "Configuration must be a JSON object"}}
      {:error, %Jason.DecodeError{} = error} -> 
        {:error, {:json_parse_error, domain, Jason.DecodeError.message(error)}}
    end
  end

  defp validate_config(config, domain) do
    case Types.validate_rule_config(config) do
      :ok -> 
        validate_domain_consistency(config, domain)
      {:error, reason} -> 
        {:error, {:validation_error, domain, reason}}
    end
  end

  defp validate_domain_consistency(config, expected_domain) do
    config_domain = config["domain"]
    expected_domain_string = Types.domain_to_string(expected_domain)
    
    if config_domain == expected_domain_string do
      :ok
    else
      {:error, {:domain_mismatch, expected_domain, config_domain, expected_domain_string}}
    end
  end

  # Cache operations
  defp get_from_cache(domain) do
    case GenServer.call(__MODULE__, {:get, domain}) do
      nil -> :not_found
      config -> {:ok, config}
    end
  end

  defp put_in_cache(domain, config) do
    GenServer.cast(__MODULE__, {:put, domain, config})
  end

  # Domain management helpers
  defp validate_domain_name(domain_name) do
    cond do
      not is_binary(domain_name) ->
        {:error, "Domain name must be a string"}
      
      String.length(domain_name) == 0 ->
        {:error, "Domain name cannot be empty"}
      
      not Regex.match?(~r/^[a-z][a-z0-9_]*$/, domain_name) ->
        {:error, "Domain name must start with lowercase letter and contain only lowercase letters, numbers, and underscores"}
      
      String.length(domain_name) > 50 ->
        {:error, "Domain name must be 50 characters or less"}
      
      true ->
        :ok
    end
  end

  defp ensure_config_directory do
    case File.mkdir_p(@config_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, @config_dir, reason}}
    end
  end

  defp write_config_file(path, config, domain_name) do
    case File.exists?(path) do
      true ->
        {:error, {:domain_already_exists, domain_name, path}}
      
      false ->
        json_content = Jason.encode!(config, pretty: true)
        
        case File.write(path, json_content) do
          :ok -> :ok
          {:error, reason} -> {:error, {:file_write_error, domain_name, path, reason}}
        end
    end
  end

  defp validate_written_config(domain_atom) do
    # Attempt to load the newly written configuration to ensure it's valid
    case load_from_file(domain_atom, bypass_cache: true) do
      {:ok, _config} -> :ok
      {:error, reason} -> {:error, {:validation_after_write_failed, reason}}
    end
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for caching configurations
    :ets.new(@cache_table, [:named_table, :set, :protected])
    Logger.info("RuleConfig cache initialized")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get, domain}, _from, state) do
    result = case :ets.lookup(@cache_table, domain) do
      [{^domain, config}] -> config
      [] -> nil
    end
    {:reply, result, state}
  end

  @impl true
  def handle_call(:clear_cache, _from, state) do
    :ets.delete_all_objects(@cache_table)
    Logger.info("RuleConfig cache cleared")
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:put, domain, config}, state) do
    :ets.insert(@cache_table, {domain, config})
    Logger.debug("Cached configuration for domain: #{domain}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:remove, domain}, state) do
    :ets.delete(@cache_table, domain)
    Logger.debug("Removed domain from cache: #{domain}")
    {:noreply, state}
  end

  ## Error Formatting

  @doc """
  Formats error reasons into human-readable messages.
  
  ## Parameters
  - error_reason: The error tuple returned by load/1 or reload/1
  
  ## Returns
  - String describing the error with context and suggestions
  """
  @spec format_error(term()) :: String.t()
  def format_error({:file_not_found, domain, path}) do
    """
    [DOMAIN: #{domain}] Configuration file not found: #{path}
    Context: The system expected to find a JSON configuration file for this domain
    Suggestion: Create the configuration file or verify the domain name is correct
    """
  end

  def format_error({:file_read_error, domain, path, reason}) do
    """
    [DOMAIN: #{domain}] Failed to read configuration file: #{path}
    Context: File exists but could not be read due to: #{inspect(reason)}
    Suggestion: Check file permissions and disk space
    """
  end

  def format_error({:invalid_json_structure, domain, message}) do
    """
    [DOMAIN: #{domain}] Invalid JSON structure: #{message}
    Context: Configuration file contains invalid JSON format
    Suggestion: Validate JSON syntax and ensure root element is an object
    """
  end

  def format_error({:json_parse_error, domain, message}) do
    """
    [DOMAIN: #{domain}] JSON parsing failed: #{message}
    Context: Configuration file contains malformed JSON
    Suggestion: Use a JSON validator to check file syntax
    """
  end

  def format_error({:validation_error, domain, reason}) do
    """
    [DOMAIN: #{domain}] Configuration validation failed: #{reason}
    Context: JSON structure is valid but doesn't match expected schema
    Suggestion: Review configuration format requirements and ensure all required fields are present
    """
  end

  def format_error({:domain_mismatch, expected_domain, config_domain, expected_string}) do
    """
    [DOMAIN: #{expected_domain}] Domain mismatch in configuration
    Context: Expected domain '#{expected_string}' but configuration contains '#{config_domain}'
    Suggestion: Update the 'domain' field in the configuration file to match the expected domain
    """
  end

  def format_error(:invalid_domain) do
    """
    Invalid domain specified
    Context: Domain must be one of: #{Enum.join(Types.supported_domains(), ", ")}
    Suggestion: Use a supported domain type
    """
  end

  def format_error({:domain_already_exists, domain_name, path}) do
    """
    [DOMAIN: #{domain_name}] Domain already exists: #{path}
    Context: A configuration file for this domain already exists
    Suggestion: Use a different domain name or remove the existing domain first
    """
  end

  def format_error({:file_write_error, domain_name, path, reason}) do
    """
    [DOMAIN: #{domain_name}] Failed to write configuration file: #{path}
    Context: Could not write configuration due to: #{inspect(reason)}
    Suggestion: Check file permissions and disk space
    """
  end

  def format_error({:mkdir_failed, dir, reason}) do
    """
    Failed to create configuration directory: #{dir}
    Context: Could not create directory due to: #{inspect(reason)}
    Suggestion: Check parent directory permissions
    """
  end

  def format_error({:validation_after_write_failed, reason}) do
    """
    Configuration validation failed after writing
    Context: File was written but failed validation: #{inspect(reason)}
    Suggestion: Check configuration structure and try again
    """
  end

  def format_error(reason) do
    """
    Unknown error occurred: #{inspect(reason)}
    Context: An unexpected error was encountered
    Suggestion: Check logs for more details or contact support
    """
  end
end