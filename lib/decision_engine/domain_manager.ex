defmodule DecisionEngine.DomainManager do
  @moduledoc """
  Manages domain configurations including CRUD operations for domains.
  Handles persistence to configuration files and dynamic reloading.
  """

  require Logger
  alias DecisionEngine.{Types, RuleConfig, SignalsSchema}

  @type domain_config :: %{
    name: String.t(),
    display_name: String.t(),
    description: String.t(),
    signals_fields: [String.t()],
    patterns: [Types.pattern()],
    schema_module: String.t()
  }

  @doc """
  Lists all available domains in the system.

  Returns domains that have both valid configuration files and schema modules.
  This provides a complete view of domains ready for use.

  ## Returns
  - List of domain atoms that are fully operational

  ## Examples
      iex> DecisionEngine.DomainManager.list_available_domains()
      [:power_platform, :data_platform, :integration_platform]
  """
  @spec list_available_domains() :: [atom()]
  def list_available_domains do
    SignalsSchema.discover_available_domains()
  end

  @doc """
  Lists all domain configurations for management interface.

  Returns detailed domain configuration information suitable for display
  in management interfaces.

  ## Returns
  - {:ok, [domain_config()]} on success
  - {:error, term()} on failure

  ## Examples
      iex> DecisionEngine.DomainManager.list_domains()
      {:ok, [%{name: "power_platform", display_name: "Power Platform", ...}]}
  """
  @spec list_domains() :: {:ok, [domain_config()]} | {:error, term()}
  def list_domains do
    case File.ls("priv/rules") do
      {:ok, files} ->
        domains =
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(&Path.rootname/1)
          |> Enum.map(&String.to_atom/1)
          |> Enum.map(&load_domain_config/1)
          |> Enum.filter(fn
            {:ok, _} -> true
            {:error, _} -> false
          end)
          |> Enum.map(fn {:ok, config} -> config end)

        {:ok, domains}

      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets a specific domain configuration.

  ## Parameters
  - domain: The domain atom to retrieve

  ## Returns
  - {:ok, domain_config()} on success
  - {:error, term()} on failure
  """
  @spec get_domain(Types.domain()) :: {:ok, domain_config()} | {:error, term()}
  def get_domain(domain) do
    load_domain_config(domain)
  end

  @doc """
  Creates a new domain configuration.

  ## Parameters
  - domain_config: The domain configuration to create

  ## Returns
  - {:ok, domain_config()} on success
  - {:error, term()} on failure
  """
  @spec create_domain(domain_config()) :: {:ok, domain_config()} | {:error, term()}
  def create_domain(domain_config) do
    domain_atom = String.to_atom(domain_config.name)

    # Check if domain already exists
    case get_domain(domain_atom) do
      {:ok, _} -> {:error, :domain_already_exists}
      {:error, :enoent} ->
        # Create configuration file
        config_data = %{
          "domain" => domain_config.name,
          "display_name" => domain_config.display_name,
          "description" => domain_config.description,
          "signals_fields" => domain_config.signals_fields,
          "patterns" => domain_config.patterns,
          "schema_module" => domain_config.schema_module
        }

        case save_domain_config(domain_atom, config_data) do
          :ok ->
            # Invalidate cache and reload
            invalidate_cache(domain_atom)
            # Broadcast domain addition
            broadcast_domain_change(:domain_added, domain_atom)
            {:ok, domain_config}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates an existing domain configuration.

  ## Parameters
  - domain: The domain atom to update
  - domain_config: The updated domain configuration

  ## Returns
  - {:ok, domain_config()} on success
  - {:error, term()} on failure
  """
  @spec update_domain(Types.domain(), domain_config()) :: {:ok, domain_config()} | {:error, term()}
  def update_domain(domain, domain_config) do
    # Verify domain exists
    case get_domain(domain) do
      {:ok, _existing} ->
        config_data = %{
          "domain" => domain_config.name,
          "display_name" => domain_config.display_name,
          "description" => domain_config.description,
          "signals_fields" => domain_config.signals_fields,
          "patterns" => domain_config.patterns,
          "schema_module" => domain_config.schema_module
        }

        case save_domain_config(domain, config_data) do
          :ok ->
            # Invalidate cache and reload
            invalidate_cache(domain)
            # Broadcast domain change
            broadcast_domain_change(:domain_changed, domain)
            {:ok, domain_config}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a domain configuration.

  ## Parameters
  - domain: The domain atom to delete

  ## Returns
  - :ok on success
  - {:error, term()} on failure
  """
  @spec delete_domain(Types.domain()) :: :ok | {:error, term()}
  def delete_domain(domain) do
    path = "priv/rules/#{domain}.json"

    case File.rm(path) do
      :ok ->
        # Invalidate cache
        invalidate_cache(domain)
        # Broadcast domain removal
        broadcast_domain_change(:domain_removed, domain)
        :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates a domain configuration structure.

  ## Parameters
  - domain_config: The domain configuration to validate

  ## Returns
  - :ok if valid
  - {:error, [String.t()]} with list of validation errors
  """
  @spec validate_domain_config(domain_config()) :: :ok | {:error, [String.t()]}
  def validate_domain_config(domain_config) do
    errors = []

    errors = if String.trim(domain_config.name) == "", do: ["Domain name cannot be empty" | errors], else: errors
    errors = if String.trim(domain_config.display_name) == "", do: ["Display name cannot be empty" | errors], else: errors
    errors = if length(domain_config.signals_fields) == 0, do: ["At least one signal field is required" | errors], else: errors

    # Validate patterns
    pattern_errors =
      domain_config.patterns
      |> Enum.with_index()
      |> Enum.flat_map(fn {pattern, index} ->
        validate_pattern(pattern, index)
      end)

    errors = errors ++ pattern_errors

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  ## Private Functions

  defp validate_pattern(pattern, index) do
    errors = []

    errors = if not Map.has_key?(pattern, "id") or String.trim(pattern["id"]) == "",
      do: ["Pattern #{index + 1}: ID is required" | errors], else: errors

    errors = if not Map.has_key?(pattern, "outcome") or String.trim(pattern["outcome"]) == "",
      do: ["Pattern #{index + 1}: Outcome is required" | errors], else: errors

    errors = if not Map.has_key?(pattern, "score") or not is_number(pattern["score"]),
      do: ["Pattern #{index + 1}: Score must be a number" | errors], else: errors

    errors = if not Map.has_key?(pattern, "summary") or String.trim(pattern["summary"]) == "",
      do: ["Pattern #{index + 1}: Summary is required" | errors], else: errors

    errors
  end

  defp load_domain_config(domain) do
    case RuleConfig.load(domain) do
      {:ok, config} ->
        domain_config = %{
          name: config["domain"],
          display_name: config["display_name"] || String.replace(to_string(domain), "_", " ") |> String.capitalize(),
          description: config["description"] || "No description provided",
          signals_fields: config["signals_fields"],
          patterns: config["patterns"],
          schema_module: config["schema_module"] || "DecisionEngine.SignalsSchema.#{Macro.camelize(to_string(domain))}"
        }
        {:ok, domain_config}

      {:error, reason} -> {:error, reason}
    end
  end

  defp save_domain_config(domain, config_data) do
    path = "priv/rules/#{domain}.json"

    case Jason.encode(config_data, pretty: true) do
      {:ok, json} ->
        File.write(path, json)
      {:error, reason} -> {:error, reason}
    end
  end

  defp invalidate_cache(domain) do
    # Invalidate cache for the specific domain
    RuleConfig.invalidate_cache(domain)
  end

  defp broadcast_domain_change(event_type, domain) do
    Phoenix.PubSub.broadcast(DecisionEngine.PubSub, "domain_changes", {event_type, domain})
  end

  @doc """
  Gets detailed information about a specific domain.

  Returns comprehensive information including configuration status,
  schema module availability, and basic configuration metadata.

  ## Parameters
  - domain: The domain atom to inspect

  ## Returns
  - {:ok, domain_info} on success
  - {:error, reason} if domain is not available

  ## Examples
      iex> DecisionEngine.DomainManager.get_domain_info(:power_platform)
      {:ok, %{
        domain: :power_platform,
        config_available: true,
        schema_module: DecisionEngine.SignalsSchema.PowerPlatform,
        signals_fields: ["workload_type", "primary_users", ...],
        pattern_count: 3
      }}
  """
  @spec get_domain_info(atom()) :: {:ok, map()} | {:error, term()}
  def get_domain_info(domain) do
    case RuleConfig.load(domain) do
      {:ok, config} ->
        schema_module = SignalsSchema.module_for(domain)
        schema_available = SignalsSchema.schema_module_exists?(domain)

        info = %{
          domain: domain,
          config_available: true,
          schema_module: schema_module,
          schema_available: schema_available,
          signals_fields: config["signals_fields"],
          pattern_count: length(config["patterns"]),
          config_path: RuleConfig.config_path(domain)
        }

        {:ok, info}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Adds a new domain to the system with comprehensive validation.

  Creates a new domain configuration file and validates that all required
  components are in place. The domain becomes immediately available after
  successful addition.

  ## Parameters
  - domain_name: String name for the new domain
  - signals_fields: List of signal field names
  - patterns: List of decision patterns for the domain
  - options: Optional configuration (e.g., validation_level)

  ## Returns
  - {:ok, domain_atom} on success
  - {:error, reason} on failure

  ## Examples
      iex> patterns = [%{"id" => "basic", "outcome" => "recommend", ...}]
      iex> DecisionEngine.DomainManager.add_domain("ai_platform", ["model_type"], patterns)
      {:ok, :ai_platform}
  """
  @spec add_domain(String.t(), [String.t()], [map()], keyword()) :: {:ok, atom()} | {:error, term()}
  def add_domain(domain_name, signals_fields, patterns, options \\ []) do
    Logger.info("Adding new domain: #{domain_name}")

    validation_level = Keyword.get(options, :validation_level, :strict)

    with :ok <- validate_domain_prerequisites(domain_name),
         config <- Types.create_domain_template(domain_name, signals_fields, patterns),
         :ok <- validate_domain_config_for_addition(config, domain_name, validation_level),
         {:ok, domain_atom} <- RuleConfig.add_domain(domain_name, config),
         :ok <- post_addition_validation(domain_atom) do

      Logger.info("Successfully added domain: #{domain_name}")
      {:ok, domain_atom}
    else
      {:error, reason} = error ->
        Logger.error("Failed to add domain #{domain_name}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Removes a domain from the system.

  Removes the configuration file and clears cached data. The domain
  becomes unavailable immediately after removal.

  ## Parameters
  - domain: The domain atom to remove
  - options: Optional configuration (e.g., force: true)

  ## Returns
  - :ok on success
  - {:error, reason} on failure
  """
  @spec remove_domain(atom(), keyword()) :: :ok | {:error, term()}
  def remove_domain(domain, options \\ []) do
    force = Keyword.get(options, :force, false)

    Logger.info("Removing domain: #{domain}")

    with :ok <- validate_removal_safety(domain, force),
         :ok <- RuleConfig.remove_domain(domain) do

      Logger.info("Successfully removed domain: #{domain}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to remove domain #{domain}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Reloads all domain configurations from files.

  Clears the configuration cache and forces reload of all domain
  configurations. Useful for applying configuration changes without
  application restart.

  ## Returns
  - {:ok, reloaded_domains} on success
  - {:error, failed_domains} on partial failure
  """
  @spec reload_all_domains() :: {:ok, [atom()]} | {:error, [{atom(), term()}]}
  def reload_all_domains do
    Logger.info("Reloading all domain configurations")

    RuleConfig.clear_cache()
    domains = list_available_domains()

    {successes, failures} =
      domains
      |> Enum.map(&{&1, RuleConfig.reload(&1)})
      |> Enum.split_with(fn {_domain, result} -> match?({:ok, _}, result) end)

    success_domains = Enum.map(successes, fn {domain, _} -> domain end)
    failed_domains = Enum.map(failures, fn {domain, {:error, reason}} -> {domain, reason} end)

    case failed_domains do
      [] ->
        Logger.info("Successfully reloaded #{length(success_domains)} domains")
        {:ok, success_domains}

      failures ->
        Logger.error("Failed to reload #{length(failures)} domains: #{inspect(failures)}")
        {:error, failures}
    end
  end

  @doc """
  Reloads a specific domain configuration without application restart.

  Forces reload of a single domain's configuration from file, bypassing
  cache. This enables dynamic configuration updates for individual domains.

  ## Parameters
  - domain: The domain atom to reload

  ## Returns
  - {:ok, config} on success with the reloaded configuration
  - {:error, reason} on failure
  """
  @spec reload_domain(atom()) :: {:ok, map()} | {:error, term()}
  def reload_domain(domain) do
    Logger.info("Reloading configuration for domain: #{domain}")

    case RuleConfig.reload(domain) do
      {:ok, config} ->
        Logger.info("Successfully reloaded domain: #{domain}")
        {:ok, config}

      {:error, reason} = error ->
        Logger.error("Failed to reload domain #{domain}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Tests configuration reloading functionality for all domains.

  Validates that all domain configurations can be reloaded without
  application restart. This is useful for verifying system extensibility.

  ## Returns
  - {:ok, test_results} if all domains pass reloading tests
  - {:error, test_failures} if any domains fail reloading tests
  """
  @spec test_configuration_reloading() :: {:ok, map()} | {:error, map()}
  def test_configuration_reloading do
    Logger.info("Testing configuration reloading for all domains")

    domains = list_available_domains()

    test_results =
      domains
      |> Enum.map(&test_domain_reloading/1)
      |> Enum.into(%{})

    successful_tests =
      test_results
      |> Enum.filter(fn {_domain, result} -> match?({:ok, _}, result) end)
      |> Enum.map(fn {domain, _} -> domain end)

    failed_tests =
      test_results
      |> Enum.filter(fn {_domain, result} -> match?({:error, _}, result) end)
      |> Enum.into(%{})

    case failed_tests do
      empty when map_size(empty) == 0 ->
        report = %{
          status: :all_passed,
          successful_domains: successful_tests,
          total_tested: length(domains),
          timestamp: DateTime.utc_now()
        }
        {:ok, report}

      failures ->
        report = %{
          status: :some_failed,
          successful_domains: successful_tests,
          failed_domains: failures,
          total_tested: length(domains),
          timestamp: DateTime.utc_now()
        }
        {:error, report}
    end
  end

  @doc """
  Validates the health of all domains in the system.

  Performs comprehensive health checks on all available domains including
  configuration validation, schema module availability, and basic functionality.

  ## Returns
  - {:ok, health_report} if all domains are healthy
  - {:error, health_issues} if problems are found
  """
  @spec validate_system_health() :: {:ok, map()} | {:error, map()}
  def validate_system_health do
    Logger.info("Validating system health for all domains")

    domains = list_available_domains()

    health_results =
      domains
      |> Enum.map(fn domain -> {domain, validate_domain_health(domain)} end)

    healthy_domains =
      health_results
      |> Enum.filter(fn {_domain, result} -> match?({:ok, _}, result) end)
      |> Enum.map(fn {domain, _} -> domain end)

    unhealthy_domains =
      health_results
      |> Enum.filter(fn {_domain, result} -> match?({:error, _}, result) end)
      |> Enum.into(%{})

    case unhealthy_domains do
      empty when map_size(empty) == 0 ->
        report = %{
          status: :healthy,
          healthy_domains: healthy_domains,
          total_domains: length(domains),
          timestamp: DateTime.utc_now()
        }
        {:ok, report}

      issues ->
        report = %{
          status: :unhealthy,
          healthy_domains: healthy_domains,
          unhealthy_domains: issues,
          total_domains: length(domains),
          timestamp: DateTime.utc_now()
        }
        {:error, report}
    end
  end

  ## Additional Private Functions

  defp validate_domain_prerequisites(domain_name) do
    cond do
      domain_name in ["power_platform", "data_platform", "integration_platform"] ->
        {:error, {:reserved_domain_name, domain_name}}

      String.to_atom(domain_name) in list_available_domains() ->
        {:error, {:domain_already_exists, domain_name}}

      true ->
        :ok
    end
  end

  defp validate_domain_config_for_addition(config, domain_name, validation_level) do
    case validation_level do
      :strict -> Types.validate_new_domain_config(config, domain_name)
      :basic -> Types.validate_rule_config(config)
      :none -> :ok
    end
  end

  defp post_addition_validation(domain_atom) do
    # For extensibility, we only validate that the configuration can be loaded
    # Schema module validation is optional for new domains
    case RuleConfig.load(domain_atom) do
      {:ok, _config} -> :ok
      {:error, reason} -> {:error, {:post_addition_validation_failed, reason}}
    end
  end

  defp validate_removal_safety(domain, force) do
    if force do
      :ok
    else
      # Check if domain is a core domain that shouldn't be removed
      core_domains = [:power_platform, :data_platform, :integration_platform]

      if domain in core_domains do
        {:error, {:cannot_remove_core_domain, domain}}
      else
        :ok
      end
    end
  end

  defp validate_domain_health(domain) do
    case RuleConfig.load(domain) do
      {:ok, config} ->
        case validate_config_integrity(config) do
          :ok ->
            schema_available = SignalsSchema.schema_module_exists?(domain)

            health_info = %{
              config_valid: true,
              schema_available: schema_available,
              pattern_count: length(config["patterns"]),
              signals_field_count: length(config["signals_fields"])
            }

            {:ok, health_info}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_config_integrity(config) do
    # Additional integrity checks beyond basic validation
    patterns = config["patterns"]

    cond do
      length(patterns) == 0 ->
        {:error, :no_patterns_defined}

      Enum.any?(patterns, fn p -> p["score"] < 0 or p["score"] > 1 end) ->
        {:error, :invalid_pattern_scores}

      true ->
        :ok
    end
  end

  defp test_domain_reloading(domain) do
    # Test that domain configuration can be reloaded successfully
    case RuleConfig.reload(domain) do
      {:ok, config} ->
        # Validate that reloaded config is structurally sound
        case validate_config_integrity(config) do
          :ok -> {:ok, :reload_successful}
          {:error, reason} -> {:error, {:integrity_check_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:reload_failed, reason}}
    end
  end
end
