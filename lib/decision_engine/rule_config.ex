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
      
      # First invalidate the cache entry to ensure clean reload
      invalidate_cache(domain)
      
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
  Reloads multiple domain configurations from files.
  
  Efficiently reloads multiple domains in a single operation with proper
  cache management. This is useful for bulk configuration updates.
  
  ## Parameters
  - domains: List of domain atoms to reload
  
  ## Returns
  - {:ok, configs} with map of domain -> config on success
  - {:error, failures} with map of domain -> error on failure
  
  ## Examples
      iex> DecisionEngine.RuleConfig.reload_multiple([:power_platform, :data_platform])
      {:ok, %{power_platform: %{...}, data_platform: %{...}}}
  """
  @spec reload_multiple([atom()]) :: {:ok, %{atom() => Types.rule_config()}} | {:error, %{atom() => term()}}
  def reload_multiple(domains) when is_list(domains) do
    Logger.info("Reloading configurations for domains: #{inspect(domains)}")
    
    # Validate all domains first
    invalid_domains = Enum.reject(domains, &Types.domain_supported?/1)
    
    case invalid_domains do
      [] ->
        # Invalidate cache for all domains first
        invalidate_cache(domains)
        
        # Reload each domain
        results = 
          domains
          |> Enum.map(fn domain -> {domain, load_from_file(domain, bypass_cache: true)} end)
        
        # Separate successes and failures
        {successes, failures} = 
          results
          |> Enum.split_with(fn {_domain, result} -> match?({:ok, _}, result) end)
        
        # Update cache for successful reloads
        Enum.each(successes, fn {domain, {:ok, config}} ->
          put_in_cache(domain, config)
        end)
        
        case failures do
          [] ->
            success_map = 
              successes
              |> Enum.map(fn {domain, {:ok, config}} -> {domain, config} end)
              |> Enum.into(%{})
            
            Logger.info("Successfully reloaded #{length(domains)} domains")
            {:ok, success_map}
          
          _ ->
            failure_map = 
              failures
              |> Enum.map(fn {domain, {:error, reason}} -> {domain, reason} end)
              |> Enum.into(%{})
            
            Logger.error("Failed to reload some domains: #{inspect(failure_map)}")
            {:error, failure_map}
        end
      
      invalid ->
        Logger.error("Invalid domains for reload: #{inspect(invalid)}")
        {:error, Enum.map(invalid, fn domain -> {domain, :invalid_domain} end) |> Enum.into(%{})}
    end
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
  Invalidates the cache for a specific domain or multiple domains.
  
  Forces the next load of the specified domain(s) to read from file.
  This is more efficient than clearing the entire cache when only
  specific domains' configurations have changed.
  
  ## Parameters
  - domain: The domain atom to invalidate from cache
  - domains: List of domain atoms to invalidate from cache
  
  ## Returns
  - :ok always (operation is idempotent)
  
  ## Examples
      iex> DecisionEngine.RuleConfig.invalidate_cache(:power_platform)
      :ok
      
      iex> DecisionEngine.RuleConfig.invalidate_cache([:power_platform, :data_platform])
      :ok
  """
  @spec invalidate_cache(atom() | [atom()]) :: :ok
  def invalidate_cache(domains) when is_list(domains) do
    GenServer.call(__MODULE__, {:invalidate_multiple, domains})
  end
  def invalidate_cache(domain) when is_atom(domain) do
    GenServer.call(__MODULE__, {:invalidate, domain})
  end
  def invalidate_cache(domain) do
    Logger.warning("Invalid domain for cache invalidation: #{inspect(domain)}")
    :ok
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
  Gets cache statistics for monitoring and debugging.
  
  Returns information about the current state of the configuration cache
  including cached domains and memory usage.
  
  ## Returns
  - Map with cache statistics
  
  ## Examples
      iex> DecisionEngine.RuleConfig.cache_stats()
      %{
        cached_domains: [:power_platform, :data_platform],
        cache_size: 2,
        memory_usage: 1024
      }
  """
  @spec cache_stats() :: map()
  def cache_stats do
    GenServer.call(__MODULE__, :cache_stats)
  end

  @doc """
  Checks if a domain is currently cached.
  
  ## Parameters
  - domain: The domain atom to check
  
  ## Returns
  - true if domain is cached, false otherwise
  """
  @spec cached?(atom()) :: boolean()
  def cached?(domain) when is_atom(domain) do
    case get_from_cache(domain) do
      {:ok, _} -> true
      :not_found -> false
    end
  end
  def cached?(_), do: false

  @doc """
  Preloads configurations for multiple domains into cache.
  
  Efficiently loads multiple domain configurations into cache in a single
  operation. This is useful for warming the cache at application startup.
  
  ## Parameters
  - domains: List of domain atoms to preload
  
  ## Returns
  - {:ok, loaded_domains} on success
  - {:error, failed_domains} on failure
  
  ## Examples
      iex> DecisionEngine.RuleConfig.preload_cache([:power_platform, :data_platform])
      {:ok, [:power_platform, :data_platform]}
  """
  @spec preload_cache([atom()]) :: {:ok, [atom()]} | {:error, [{atom(), term()}]}
  def preload_cache(domains) when is_list(domains) do
    Logger.info("Preloading cache for domains: #{inspect(domains)}")
    
    results = 
      domains
      |> Enum.map(fn domain -> {domain, load(domain)} end)
    
    {successes, failures} = 
      results
      |> Enum.split_with(fn {_domain, result} -> match?({:ok, _}, result) end)
    
    success_domains = Enum.map(successes, fn {domain, _} -> domain end)
    failed_domains = Enum.map(failures, fn {domain, {:error, reason}} -> {domain, reason} end)
    
    case failed_domains do
      [] ->
        Logger.info("Successfully preloaded #{length(success_domains)} domains")
        {:ok, success_domains}
      
      failures ->
        Logger.error("Failed to preload some domains: #{inspect(failures)}")
        {:error, failures}
    end
  end

  @doc """
  Handles configuration file changes for dynamic reloading.
  
  This function can be called when configuration files are modified
  to automatically reload the affected domain configurations.
  
  ## Parameters
  - file_path: Path to the configuration file that changed
  
  ## Returns
  - {:ok, domain} if domain was successfully reloaded
  - {:error, reason} if reload failed
  - :ignored if file is not a domain configuration
  
  ## Examples
      iex> DecisionEngine.RuleConfig.handle_file_change("priv/rules/power_platform.json")
      {:ok, :power_platform}
  """
  @spec handle_file_change(String.t()) :: {:ok, atom()} | {:error, term()} | :ignored
  def handle_file_change(file_path) when is_binary(file_path) do
    case extract_domain_from_path(file_path) do
      {:ok, domain} ->
        Logger.info("Configuration file changed for domain: #{domain}")
        
        case reload(domain) do
          {:ok, _config} ->
            Logger.info("Successfully reloaded domain after file change: #{domain}")
            {:ok, domain}
          
          {:error, reason} = error ->
            Logger.error("Failed to reload domain after file change: #{domain}, reason: #{inspect(reason)}")
            error
        end
      
      :not_domain_config ->
        Logger.debug("Ignoring file change for non-domain configuration: #{file_path}")
        :ignored
    end
  end

  @doc """
  Validates cache consistency across all cached domains.
  
  Checks that all cached configurations are still valid and consistent
  with their corresponding files. This is useful for detecting cache
  corruption or file system changes.
  
  ## Returns
  - {:ok, valid_domains} if all cached domains are consistent
  - {:error, inconsistent_domains} if inconsistencies are found
  """
  @spec validate_cache_consistency() :: {:ok, [atom()]} | {:error, [{atom(), term()}]}
  def validate_cache_consistency do
    Logger.info("Validating cache consistency")
    
    stats = cache_stats()
    cached_domains = stats.cached_domains
    
    results = 
      cached_domains
      |> Enum.map(fn domain -> {domain, validate_domain_cache_consistency(domain)} end)
    
    {valid, invalid} = 
      results
      |> Enum.split_with(fn {_domain, result} -> result == :ok end)
    
    valid_domains = Enum.map(valid, fn {domain, _} -> domain end)
    invalid_domains = Enum.map(invalid, fn {domain, {:error, reason}} -> {domain, reason} end)
    
    case invalid_domains do
      [] ->
        Logger.info("Cache consistency validation passed for #{length(valid_domains)} domains")
        {:ok, valid_domains}
      
      inconsistencies ->
        Logger.warning("Cache consistency validation found issues: #{inspect(inconsistencies)}")
        {:error, inconsistencies}
    end
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

  defp extract_domain_from_path(file_path) do
    case Path.basename(file_path) do
      filename when is_binary(filename) ->
        case String.split(filename, ".") do
          [domain_name, "json"] ->
            domain_atom = String.to_atom(domain_name)
            
            # Verify this is actually a domain configuration file in the right directory
            expected_path = config_path(domain_atom)
            
            if Path.expand(file_path) == Path.expand(expected_path) do
              {:ok, domain_atom}
            else
              :not_domain_config
            end
          
          _ ->
            :not_domain_config
        end
      
      _ ->
        :not_domain_config
    end
  end

  defp validate_domain_cache_consistency(domain) do
    case get_from_cache(domain) do
      {:ok, cached_config} ->
        # Load from file and compare
        case load_from_file(domain, bypass_cache: true) do
          {:ok, file_config} ->
            if cached_config == file_config do
              :ok
            else
              {:error, :cache_file_mismatch}
            end
          
          {:error, reason} ->
            {:error, {:file_load_failed, reason}}
        end
      
      :not_found ->
        # This shouldn't happen if we're checking cached domains
        {:error, :not_in_cache}
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
  def handle_call({:invalidate, domain}, _from, state) do
    :ets.delete(@cache_table, domain)
    Logger.debug("Invalidated cache for domain: #{domain}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:invalidate_multiple, domains}, _from, state) do
    Enum.each(domains, fn domain ->
      :ets.delete(@cache_table, domain)
    end)
    Logger.debug("Invalidated cache for domains: #{inspect(domains)}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:cache_stats, _from, state) do
    cached_domains = :ets.tab2list(@cache_table) |> Enum.map(fn {domain, _} -> domain end)
    cache_size = length(cached_domains)
    
    # Get memory usage information
    memory_info = :ets.info(@cache_table, :memory)
    memory_usage = if memory_info, do: memory_info * :erlang.system_info(:wordsize), else: 0
    
    stats = %{
      cached_domains: cached_domains,
      cache_size: cache_size,
      memory_usage: memory_usage,
      table_info: :ets.info(@cache_table)
    }
    
    {:reply, stats, state}
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