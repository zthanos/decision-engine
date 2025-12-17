# lib/decision_engine/req_llm_request_batcher.ex
defmodule DecisionEngine.ReqLLMRequestBatcher do
  @moduledoc """
  Request batching and prioritization for ReqLLM integration.

  This module provides intelligent request queuing, batching, and prioritization
  to optimize performance for supported LLM providers. It implements request
  aggregation, priority-based scheduling, and batch processing optimization.
  """

  use GenServer
  require Logger

  @default_batch_config %{
    max_batch_size: 10,
    batch_timeout: 1000,  # 1 second
    max_queue_size: 100,
    priority_levels: [:high, :normal, :low],
    batch_processing_interval: 500  # 500ms
  }

  @request_priorities %{
    streaming: :high,
    interactive: :high,
    background: :normal,
    bulk: :low,
    analytics: :low
  }

  # Client API

  @doc """
  Starts the ReqLLM Request Batcher.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Configures request batching for a specific provider.

  ## Parameters
  - provider: Provider atom (:openai, :anthropic, etc.)
  - batch_config: Map containing batching configuration options

  ## Returns
  - :ok on successful configuration
  - {:error, reason} if configuration fails
  """
  @spec configure_batching(atom(), map()) :: :ok | {:error, term()}
  def configure_batching(provider, batch_config \\ %{}) do
    GenServer.call(__MODULE__, {:configure_batching, provider, batch_config})
  end

  @doc """
  Submits a request for batching and prioritization.

  ## Parameters
  - provider: Provider atom
  - request: Request map containing the LLM request details
  - priority: Priority level (:high, :normal, :low) or request type atom
  - callback: Function to call when request is processed

  ## Returns
  - {:ok, request_id} with unique request identifier
  - {:error, reason} if submission fails
  """
  @spec submit_request(atom(), map(), atom(), function()) :: {:ok, String.t()} | {:error, term()}
  def submit_request(provider, request, priority, callback) do
    GenServer.call(__MODULE__, {:submit_request, provider, request, priority, callback})
  end

  @doc """
  Submits a request with automatic priority detection.

  ## Parameters
  - provider: Provider atom
  - request: Request map containing the LLM request details
  - request_type: Type of request (:streaming, :interactive, :background, etc.)
  - callback: Function to call when request is processed

  ## Returns
  - {:ok, request_id} with unique request identifier
  - {:error, reason} if submission fails
  """
  @spec submit_request_with_type(atom(), map(), atom(), function()) :: {:ok, String.t()} | {:error, term()}
  def submit_request_with_type(provider, request, request_type, callback) do
    priority = Map.get(@request_priorities, request_type, :normal)
    submit_request(provider, request, priority, callback)
  end

  @doc """
  Gets batching statistics for a provider.

  ## Parameters
  - provider: Provider atom

  ## Returns
  - {:ok, stats} with current batching statistics
  - {:error, reason} if provider not configured
  """
  @spec get_batch_stats(atom()) :: {:ok, map()} | {:error, term()}
  def get_batch_stats(provider) do
    GenServer.call(__MODULE__, {:get_batch_stats, provider})
  end

  @doc """
  Gets batching statistics for all configured providers.

  ## Returns
  - Map with provider atoms as keys and statistics as values
  """
  @spec get_all_batch_stats() :: map()
  def get_all_batch_stats do
    GenServer.call(__MODULE__, :get_all_batch_stats)
  end

  @doc """
  Cancels a pending request.

  ## Parameters
  - request_id: Unique request identifier

  ## Returns
  - :ok if request was cancelled
  - {:error, reason} if cancellation fails
  """
  @spec cancel_request(String.t()) :: :ok | {:error, term()}
  def cancel_request(request_id) do
    GenServer.call(__MODULE__, {:cancel_request, request_id})
  end

  @doc """
  Forces immediate processing of pending batches for a provider.

  ## Parameters
  - provider: Provider atom

  ## Returns
  - :ok if batches were processed
  - {:error, reason} if processing fails
  """
  @spec flush_batches(atom()) :: :ok | {:error, term()}
  def flush_batches(provider) do
    GenServer.call(__MODULE__, {:flush_batches, provider})
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting ReqLLM Request Batcher")

    # Schedule periodic batch processing
    Process.send_after(self(), :process_batches, @default_batch_config.batch_processing_interval)

    state = %{
      providers: %{},
      request_queues: %{},
      active_batches: %{},
      request_registry: %{},
      stats: %{},
      processing_timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:configure_batching, provider, batch_config}, _from, state) do
    try do
      # Merge with defaults
      config = Map.merge(@default_batch_config, batch_config)

      # Validate configuration
      case validate_batch_config(config) do
        :ok ->
          # Initialize provider state
          provider_state = %{
            config: config,
            created_at: System.monotonic_time(:millisecond)
          }

          # Initialize queues for each priority level
          priority_queues = Enum.map(config.priority_levels, fn priority ->
            {priority, :queue.new()}
          end)
          |> Map.new()

          new_providers = Map.put(state.providers, provider, provider_state)
          new_queues = Map.put(state.request_queues, provider, priority_queues)
          new_stats = Map.put(state.stats, provider, initialize_stats())

          Logger.info("Configured request batching for provider #{provider}: #{inspect(config)}")

          {:reply, :ok, %{state |
            providers: new_providers,
            request_queues: new_queues,
            stats: new_stats
          }}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    rescue
      error ->
        Logger.error("Error configuring batching for #{provider}: #{inspect(error)}")
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:submit_request, provider, request, priority, callback}, _from, state) do
    case Map.get(state.providers, provider) do
      nil ->
        {:reply, {:error, :provider_not_configured}, state}

      provider_state ->
        case submit_request_internal(provider, request, priority, callback, state) do
          {:ok, request_id, updated_state} ->
            {:reply, {:ok, request_id}, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_batch_stats, provider}, _from, state) do
    case Map.get(state.stats, provider) do
      nil ->
        {:reply, {:error, :provider_not_configured}, state}
      stats ->
        # Calculate current queue sizes
        queue_stats = calculate_queue_stats(provider, state)
        updated_stats = Map.merge(stats, queue_stats)
        {:reply, {:ok, updated_stats}, state}
    end
  end

  @impl true
  def handle_call(:get_all_batch_stats, _from, state) do
    all_stats = Enum.map(state.stats, fn {provider, stats} ->
      queue_stats = calculate_queue_stats(provider, state)
      updated_stats = Map.merge(stats, queue_stats)
      {provider, updated_stats}
    end)
    |> Map.new()

    {:reply, all_stats, state}
  end

  @impl true
  def handle_call({:cancel_request, request_id}, _from, state) do
    case Map.get(state.request_registry, request_id) do
      nil ->
        {:reply, {:error, :request_not_found}, state}

      request_info ->
        case cancel_request_internal(request_id, request_info, state) do
          {:ok, updated_state} ->
            {:reply, :ok, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:flush_batches, provider}, _from, state) do
    case Map.get(state.providers, provider) do
      nil ->
        {:reply, {:error, :provider_not_configured}, state}

      _provider_state ->
        updated_state = process_provider_batches(provider, state)
        {:reply, :ok, updated_state}
    end
  end

  @impl true
  def handle_info(:process_batches, state) do
    # Process batches for all configured providers
    updated_state = process_all_provider_batches(state)

    # Schedule next processing cycle
    Process.send_after(self(), :process_batches, @default_batch_config.batch_processing_interval)

    {:noreply, updated_state}
  end

  @impl true
  def handle_info({:batch_timeout, provider, batch_id}, state) do
    # Handle batch timeout - force processing of the batch
    updated_state = process_timed_out_batch(provider, batch_id, state)
    {:noreply, updated_state}
  end

  # Private Functions

  defp validate_batch_config(config) do
    required_fields = [:max_batch_size, :batch_timeout, :max_queue_size]

    missing_fields = Enum.filter(required_fields, fn field ->
      not Map.has_key?(config, field) or is_nil(Map.get(config, field))
    end)

    if Enum.empty?(missing_fields) do
      cond do
        config.max_batch_size <= 0 ->
          {:error, "Max batch size must be positive"}
        config.batch_timeout <= 0 ->
          {:error, "Batch timeout must be positive"}
        config.max_queue_size <= 0 ->
          {:error, "Max queue size must be positive"}
        true ->
          :ok
      end
    else
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  defp submit_request_internal(provider, request, priority, callback, state) do
    try do
      # Generate unique request ID
      request_id = generate_request_id()

      # Validate priority
      provider_state = Map.get(state.providers, provider)
      valid_priorities = provider_state.config.priority_levels

      unless priority in valid_priorities do
        raise ArgumentError, "Invalid priority #{priority}. Valid priorities: #{inspect(valid_priorities)}"
      end

      # Check queue size limits
      provider_queues = Map.get(state.request_queues, provider)
      current_queue_size = calculate_total_queue_size(provider_queues)
      max_queue_size = provider_state.config.max_queue_size

      if current_queue_size >= max_queue_size do
        {:error, :queue_full}
      else
        # Create request entry
        request_entry = %{
          id: request_id,
          provider: provider,
          request: request,
          priority: priority,
          callback: callback,
          submitted_at: System.monotonic_time(:millisecond),
          status: :queued
        }

        # Add to appropriate priority queue
        priority_queue = Map.get(provider_queues, priority)
        updated_queue = :queue.in(request_entry, priority_queue)
        updated_provider_queues = Map.put(provider_queues, priority, updated_queue)

        # Update state
        new_request_queues = Map.put(state.request_queues, provider, updated_provider_queues)
        new_request_registry = Map.put(state.request_registry, request_id, request_entry)
        new_stats = update_submission_stats(state.stats, provider)

        updated_state = %{state |
          request_queues: new_request_queues,
          request_registry: new_request_registry,
          stats: new_stats
        }

        Logger.debug("Submitted request #{request_id} for provider #{provider} with priority #{priority}")

        {:ok, request_id, updated_state}
      end
    rescue
      error ->
        Logger.error("Error submitting request for #{provider}: #{inspect(error)}")
        {:error, error}
    end
  end

  defp cancel_request_internal(request_id, request_info, state) do
    try do
      provider = request_info.provider
      priority = request_info.priority

      # Remove from priority queue
      provider_queues = Map.get(state.request_queues, provider)
      priority_queue = Map.get(provider_queues, priority)

      updated_queue = :queue.filter(fn entry ->
        entry.id != request_id
      end, priority_queue)

      updated_provider_queues = Map.put(provider_queues, priority, updated_queue)
      new_request_queues = Map.put(state.request_queues, provider, updated_provider_queues)

      # Remove from registry
      new_request_registry = Map.delete(state.request_registry, request_id)

      # Update stats
      new_stats = update_cancellation_stats(state.stats, provider)

      updated_state = %{state |
        request_queues: new_request_queues,
        request_registry: new_request_registry,
        stats: new_stats
      }

      Logger.debug("Cancelled request #{request_id} for provider #{provider}")

      {:ok, updated_state}
    rescue
      error ->
        Logger.error("Error cancelling request #{request_id}: #{inspect(error)}")
        {:error, error}
    end
  end

  defp process_all_provider_batches(state) do
    Enum.reduce(Map.keys(state.providers), state, fn provider, acc_state ->
      process_provider_batches(provider, acc_state)
    end)
  end

  defp process_provider_batches(provider, state) do
    provider_state = Map.get(state.providers, provider)
    provider_queues = Map.get(state.request_queues, provider)

    if provider_state && provider_queues do
      # Process batches in priority order (high to low)
      priority_levels = provider_state.config.priority_levels

      Enum.reduce(priority_levels, state, fn priority, acc_state ->
        process_priority_queue(provider, priority, acc_state)
      end)
    else
      state
    end
  end

  defp process_priority_queue(provider, priority, state) do
    provider_state = Map.get(state.providers, provider)
    provider_queues = Map.get(state.request_queues, provider)
    priority_queue = Map.get(provider_queues, priority)

    max_batch_size = provider_state.config.max_batch_size

    # Extract requests for batch processing
    {batch_requests, remaining_queue} = extract_batch_from_queue(priority_queue, max_batch_size)

    if length(batch_requests) > 0 do
      # Process the batch
      batch_id = generate_batch_id()

      # Check if provider supports batching
      if supports_batching?(provider) do
        process_batch_requests(provider, batch_id, batch_requests, state)
      else
        # Process requests individually for providers that don't support batching
        process_individual_requests(provider, batch_requests, state)
      end

      # Update queue state
      updated_provider_queues = Map.put(provider_queues, priority, remaining_queue)
      new_request_queues = Map.put(state.request_queues, provider, updated_provider_queues)

      # Update stats
      new_stats = update_batch_processing_stats(state.stats, provider, length(batch_requests))

      %{state |
        request_queues: new_request_queues,
        stats: new_stats
      }
    else
      state
    end
  end

  defp extract_batch_from_queue(queue, max_size) do
    extract_batch_from_queue(queue, max_size, [])
  end

  defp extract_batch_from_queue(queue, max_size, acc) when length(acc) >= max_size do
    {Enum.reverse(acc), queue}
  end

  defp extract_batch_from_queue(queue, max_size, acc) do
    case :queue.out(queue) do
      {{:value, request}, remaining_queue} ->
        extract_batch_from_queue(remaining_queue, max_size, [request | acc])

      {:empty, _} ->
        {Enum.reverse(acc), queue}
    end
  end

  defp supports_batching?(provider) do
    # Currently, most LLM providers don't support true request batching
    # This could be extended in the future as providers add batch APIs
    case provider do
      :openai -> false  # OpenAI has batch API but it's for offline processing
      :anthropic -> false
      :ollama -> false
      :openrouter -> false
      :custom -> false
      _ -> false
    end
  end

  defp process_batch_requests(provider, batch_id, batch_requests, state) do
    # For providers that support batching (future implementation)
    Logger.debug("Processing batch #{batch_id} for provider #{provider} with #{length(batch_requests)} requests")

    # This would implement actual batch API calls
    # For now, we'll process individually
    process_individual_requests(provider, batch_requests, state)
  end

  defp process_individual_requests(provider, requests, state) do
    # Process each request individually but in an optimized manner
    Enum.each(requests, fn request ->
      spawn(fn ->
        process_single_request(provider, request)
      end)
    end)

    state
  end

  defp process_single_request(provider, request) do
    try do
      Logger.debug("Processing individual request #{request.id} for provider #{provider}")

      # Execute the actual LLM request
      case DecisionEngine.ReqLLMClient.call_llm(request.request.prompt, request.request.config) do
        {:ok, response} ->
          # Call the callback with success
          request.callback.({:ok, response})

        {:error, reason} ->
          # Call the callback with error
          request.callback.({:error, reason})
      end
    rescue
      error ->
        Logger.error("Error processing request #{request.id}: #{inspect(error)}")
        request.callback.({:error, error})
    end
  end

  defp process_timed_out_batch(provider, batch_id, state) do
    # Handle batch timeout by forcing processing
    Logger.debug("Processing timed out batch #{batch_id} for provider #{provider}")

    # This would find and process the specific batch
    # For now, we'll just process all pending batches for the provider
    process_provider_batches(provider, state)
  end

  defp calculate_queue_stats(provider, state) do
    case Map.get(state.request_queues, provider) do
      nil ->
        %{current_queue_size: 0, queue_sizes_by_priority: %{}}

      provider_queues ->
        queue_sizes = Enum.map(provider_queues, fn {priority, queue} ->
          {priority, :queue.len(queue)}
        end)
        |> Map.new()

        total_size = Enum.sum(Map.values(queue_sizes))

        %{
          current_queue_size: total_size,
          queue_sizes_by_priority: queue_sizes
        }
    end
  end

  defp calculate_total_queue_size(provider_queues) do
    Enum.reduce(provider_queues, 0, fn {_priority, queue}, acc ->
      acc + :queue.len(queue)
    end)
  end

  defp initialize_stats do
    %{
      total_submitted: 0,
      total_processed: 0,
      total_cancelled: 0,
      total_batches_processed: 0,
      average_batch_size: 0.0,
      current_queue_size: 0,
      queue_sizes_by_priority: %{},
      last_updated: System.monotonic_time(:millisecond)
    }
  end

  defp update_submission_stats(stats, provider) do
    current_stats = Map.get(stats, provider)
    updated_stats = %{current_stats |
      total_submitted: current_stats.total_submitted + 1,
      last_updated: System.monotonic_time(:millisecond)
    }
    Map.put(stats, provider, updated_stats)
  end

  defp update_cancellation_stats(stats, provider) do
    current_stats = Map.get(stats, provider)
    updated_stats = %{current_stats |
      total_cancelled: current_stats.total_cancelled + 1,
      last_updated: System.monotonic_time(:millisecond)
    }
    Map.put(stats, provider, updated_stats)
  end

  defp update_batch_processing_stats(stats, provider, batch_size) do
    current_stats = Map.get(stats, provider)

    new_total_batches = current_stats.total_batches_processed + 1
    new_total_processed = current_stats.total_processed + batch_size

    new_average_batch_size = if new_total_batches > 0 do
      new_total_processed / new_total_batches
    else
      0.0
    end

    updated_stats = %{current_stats |
      total_processed: new_total_processed,
      total_batches_processed: new_total_batches,
      average_batch_size: new_average_batch_size,
      last_updated: System.monotonic_time(:millisecond)
    }

    Map.put(stats, provider, updated_stats)
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
  end

  defp generate_batch_id do
    :crypto.strong_rand_bytes(8) |> Base.encode64(padding: false)
  end
end
