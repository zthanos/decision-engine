defmodule DecisionEngine.DescriptionGenerator do
  @moduledoc """
  Generates domain descriptions using LLM analysis of rule configurations.

  Provides AI-powered description generation for domains based on their
  rule JSON configurations, with caching and error handling.
  """

  use GenServer
  require Logger

  @cache_table :description_cache
  @descriptions_file "priv/descriptions/domain_descriptions.json"

  # Client API

  @doc """
  Starts the DescriptionGenerator GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generates a description for a domain using LLM analysis.

  ## Parameters
  - domain: Atom representing the domain to generate description for
  - llm_config: Map containing LLM configuration (optional, uses default if not provided)

  ## Returns
  - {:ok, String.t()} with generated description
  - {:error, term()} on failure
  """
  @spec generate_description(atom(), map() | nil) :: {:ok, String.t()} | {:error, term()}
  def generate_description(domain, llm_config \\ nil) do
    GenServer.call(__MODULE__, {:generate_description, domain, llm_config}, 30_000)
  end

  @doc """
  Updates a domain's description in the configuration.

  ## Parameters
  - domain: Atom representing the domain
  - description: String description to save

  ## Returns
  - :ok on success
  - {:error, term()} on failure
  """
  @spec update_domain_description(atom(), String.t()) :: :ok | {:error, term()}
  def update_domain_description(domain, description) do
    GenServer.call(__MODULE__, {:update_description, domain, description})
  end

  @doc """
  Gets a cached description for a domain.

  ## Parameters
  - domain: Atom representing the domain

  ## Returns
  - {:ok, String.t()} with cached description
  - {:error, :not_found} if no cached description exists
  """
  @spec get_cached_description(atom()) :: {:ok, String.t()} | {:error, :not_found}
  def get_cached_description(domain) do
    GenServer.call(__MODULE__, {:get_cached_description, domain})
  end

  @doc """
  Gets all cached descriptions.

  ## Returns
  - {:ok, map()} with domain -> description mappings
  """
  @spec get_all_descriptions() :: {:ok, map()}
  def get_all_descriptions do
    GenServer.call(__MODULE__, :get_all_descriptions)
  end

  @doc """
  Clears the description cache.

  ## Returns
  - :ok
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    GenServer.call(__MODULE__, :clear_cache)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting DescriptionGenerator")

    # Create ETS table for caching
    :ets.new(@cache_table, [:named_table, :set, :protected])

    # Ensure descriptions directory exists
    ensure_descriptions_directory()

    # Load existing descriptions into cache
    case load_descriptions_from_file() do
      {:ok, descriptions} ->
        populate_cache(descriptions)
        Logger.info("DescriptionGenerator started with #{map_size(descriptions)} cached descriptions")
        {:ok, %{descriptions: descriptions, file_available: true}}

      {:error, :enoent} ->
        Logger.info("DescriptionGenerator started with empty cache")
        {:ok, %{descriptions: %{}, file_available: true}}

      {:error, reason} ->
        Logger.warning("Failed to load descriptions file, using in-memory only: #{inspect(reason)}")
        {:ok, %{descriptions: %{}, file_available: false}}
    end
  end

  @impl true
  def handle_call({:generate_description, domain, llm_config}, _from, state) do
    Logger.info("Generating description for domain: #{domain}")

    case generate_domain_description(domain, llm_config) do
      {:ok, description} ->
        # Cache the generated description
        :ets.insert(@cache_table, {domain, description})

        # Update state
        new_descriptions = Map.put(state.descriptions, domain, description)
        new_state = %{state | descriptions: new_descriptions}

        # Persist to file if available
        case state.file_available do
          true ->
            case persist_descriptions_to_file(new_descriptions) do
              :ok ->
                {:reply, {:ok, description}, new_state}
              {:error, reason} ->
                Logger.warning("Failed to persist descriptions to file: #{inspect(reason)}")
                {:reply, {:ok, description}, %{new_state | file_available: false}}
            end

          false ->
            {:reply, {:ok, description}, new_state}
        end

      {:error, reason} ->
        Logger.error("Failed to generate description for domain #{domain}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:update_description, domain, description}, _from, state) do
    # Cache the description
    :ets.insert(@cache_table, {domain, description})

    # Update state
    new_descriptions = Map.put(state.descriptions, domain, description)
    new_state = %{state | descriptions: new_descriptions}

    # Persist to file if available
    case state.file_available do
      true ->
        case persist_descriptions_to_file(new_descriptions) do
          :ok ->
            {:reply, :ok, new_state}
          {:error, reason} ->
            Logger.warning("Failed to persist descriptions to file: #{inspect(reason)}")
            {:reply, :ok, %{new_state | file_available: false}}
        end

      false ->
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:get_cached_description, domain}, _from, state) do
    case :ets.lookup(@cache_table, domain) do
      [{^domain, description}] ->
        {:reply, {:ok, description}, state}
      [] ->
        # Fallback to state descriptions
        case Map.get(state.descriptions, domain) do
          nil -> {:reply, {:error, :not_found}, state}
          description -> {:reply, {:ok, description}, state}
        end
    end
  end

  @impl true
  def handle_call(:get_all_descriptions, _from, state) do
    {:reply, {:ok, state.descriptions}, state}
  end

  @impl true
  def handle_call(:clear_cache, _from, state) do
    :ets.delete_all_objects(@cache_table)

    new_state = %{state | descriptions: %{}}

    # Clear file if available
    case state.file_available do
      true ->
        case persist_descriptions_to_file(%{}) do
          :ok ->
            {:reply, :ok, new_state}
          {:error, reason} ->
            Logger.warning("Failed to clear descriptions file: #{inspect(reason)}")
            {:reply, :ok, %{new_state | file_available: false}}
        end

      false ->
        {:reply, :ok, new_state}
    end
  end

  # Private Functions

  defp ensure_descriptions_directory do
    descriptions_dir = Path.dirname(@descriptions_file)
    File.mkdir_p!(descriptions_dir)
  end

  defp generate_domain_description(domain, llm_config) do
    with {:ok, rule_config} <- DecisionEngine.RuleConfig.load(domain),
         {:ok, config} <- get_llm_config(llm_config),
         prompt <- build_description_prompt(domain, rule_config),
         {:ok, description} <- call_llm_for_description(prompt, config) do

      cleaned_description = clean_description_response(description)
      {:ok, cleaned_description}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_llm_config(nil) do
    # Use default configuration - this would typically come from application config
    default_config = %{
      provider: :openai,
      api_url: "https://api.openai.com/v1/chat/completions",
      api_key: System.get_env("OPENAI_API_KEY"),
      model: "gpt-4",
      temperature: 0.3,
      max_tokens: 500
    }

    case default_config.api_key do
      nil -> {:error, :no_api_key_configured}
      _ -> {:ok, default_config}
    end
  end
  defp get_llm_config(config), do: {:ok, config}

  defp build_description_prompt(domain, rule_config) do
    domain_name = domain |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

    signals_fields = rule_config["signals_fields"] || []
    patterns = rule_config["patterns"] || []

    pattern_summaries =
      patterns
      |> Enum.map(fn pattern ->
        "- #{pattern["summary"]} (#{pattern["id"]})"
      end)
      |> Enum.join("\n")

    signals_list =
      signals_fields
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    """
    Generate a concise, professional description for the "#{domain_name}" decision domain based on its configuration.

    Domain: #{domain_name}

    Signal Fields:
    #{signals_list}

    Available Decision Patterns:
    #{pattern_summaries}

    Requirements:
    1. Write 2-3 sentences describing what this domain is for
    2. Explain the types of scenarios it handles
    3. Mention key decision factors it considers
    4. Keep it professional and user-friendly
    5. Focus on the domain's purpose and capabilities
    6. Do not include technical implementation details

    Return only the description text, no additional formatting or explanations.
    """
  end

  defp call_llm_for_description(prompt, config) do
    case DecisionEngine.LLMClient.generate_text(prompt, config) do
      {:ok, response} ->
        {:ok, response}
      {:error, reason} ->
        {:error, {:llm_call_failed, reason}}
    end
  end

  defp clean_description_response(response) do
    response
    |> String.trim()
    |> String.replace(~r/^["']/, "")
    |> String.replace(~r/["']$/, "")
    |> String.trim()
  end

  defp load_descriptions_from_file do
    case File.read(@descriptions_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"descriptions" => descriptions}} ->
            # Convert string keys to atoms
            atom_descriptions =
              descriptions
              |> Enum.map(fn {domain_str, desc} -> {String.to_atom(domain_str), desc} end)
              |> Enum.into(%{})

            {:ok, atom_descriptions}

          {:ok, %{}} ->
            {:ok, %{}}

          {:error, reason} ->
            {:error, {:json_parse_error, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp populate_cache(descriptions) do
    Enum.each(descriptions, fn {domain, description} ->
      :ets.insert(@cache_table, {domain, description})
    end)
  end

  defp persist_descriptions_to_file(descriptions) do
    # Convert atom keys to strings for JSON serialization
    string_descriptions =
      descriptions
      |> Enum.map(fn {domain, desc} -> {Atom.to_string(domain), desc} end)
      |> Enum.into(%{})

    descriptions_data = %{
      version: "1.0",
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      descriptions: string_descriptions
    }

    case Jason.encode(descriptions_data, pretty: true) do
      {:ok, json} ->
        File.write(@descriptions_file, json)

      {:error, reason} ->
        {:error, {:json_encode_error, reason}}
    end
  end
end
