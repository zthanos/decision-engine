# lib/decision_engine/req_llm_connection_pool.ex
defmodule DecisionEngine.ReqLLMConnectionPool do
  @moduledoc """
  Connection pool management for ReqLLM integration.

  This module provides connection pooling configuration and management for each
  LLM provider, implementing connection reuse, lifecycle management, and monitoring
  to optimize performance and resource utilization.
  """

  use GenServer
  require Logger

  @default_pool_config %{
    size: 10,
    max_idle_time: 60_000,  # 60 seconds
    checkout_timeout: 5_000,  # 5 seconds
    max_overflow: 5,
    idle_interval: 30_000,  # 30 seconds cleanup interval
    connection_ttl: 300_000  # 5 minutes connection TTL
  }

  @pool_metrics %{
    active_connections: 0,
    idle_connections: 0,
    total_checkouts: 0,
    checkout_timeouts: 0,
    connection_errors: 0,
    pool_utilization: 0.0
  }

  # Client API

  @doc """
  Starts the ReqLLM Connection Pool Manager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Configures connection pool for a specific provider.

  ## Parameters
  - provider: Provider atom (:openai, :anthropic, etc.)
  - pool_config: Map containing pool configuration options

  ## Returns
  - :ok on successful configuration
  - {:error, reason} if configuration fails
  """
  @spec configure_pool(atom(), map()) :: :ok | {:error, term()}
  def configure_pool(provider, pool_config \\ %{}) do
    GenServer.call(__MODULE__, {:configure_pool, provider, pool_config})
  end

  @doc """
  Gets connection pool configuration for a provider.

  ## Parameters
  - provider: Provider atom

  ## Returns
  - {:ok, config} with current pool configuration
  - {:error, reason} if provider not configured
  """
  @spec get_pool_config(atom()) :: {:ok, map()} | {:error, term()}
  def get_pool_config(provider) do
    GenServer.call(__MODULE__, {:get_pool_config, provider})
  end

  @doc """
  Checks out a connection from the pool for a provider.

  ## Parameters
  - provider: Provider atom
  - timeout: Checkout timeout in milliseconds (optional)

  ## Returns
  - {:ok, connection} on successful checkout
  - {:error, reason} if checkout fails
  """
  @spec checkout_connection(atom(), integer()) :: {:ok, term()} | {:error, term()}
  def checkout_connection(provider, timeout \\ 5000) do
    GenServer.call(__MODULE__, {:checkout_connection, provider, timeout}, timeout + 1000)
  end

  @doc """
  Checks in a connection back to the pool.

  ## Parameters
  - provider: Provider atom
  - connection: Connection to return to pool

  ## Returns
  - :ok on successful checkin
  - {:error, reason} if checkin fails
  """
  @spec checkin_connection(atom(), term()) :: :ok | {:error, term()}
  def checkin_connection(provider, connection) do
    GenServer.call(__MODULE__, {:checkin_connection, provider, connection})
  end

  @doc """
  Gets connection pool metrics for a provider.

  ## Parameters
  - provider: Provider atom

  ## Returns
  - {:ok, metrics} with current pool metrics
  - {:error, reason} if provider not configured
  """
  @spec get_pool_metrics(atom()) :: {:ok, map()} | {:error, term()}
  def get_pool_metrics(provider) do
    GenServer.call(__MODULE__, {:get_pool_metrics, provider})
  end

  @doc """
  Gets metrics for all configured pools.

  ## Returns
  - Map with provider atoms as keys and metrics as values
  """
  @spec get_all_metrics() :: map()
  def get_all_metrics do
    GenServer.call(__MODULE__, :get_all_metrics)
  end

  @doc """
  Closes all connections for a provider and removes the pool.

  ## Parameters
  - provider: Provider atom

  ## Returns
  - :ok on successful cleanup
  - {:error, reason} if cleanup fails
  """
  @spec close_pool(atom()) :: :ok | {:error, term()}
  def close_pool(provider) do
    GenServer.call(__MODULE__, {:close_pool, provider})
  end

  @doc """
  Creates a ReqLLM request with connection pooling enabled.

  ## Parameters
  - provider: Provider atom
  - base_config: Base ReqLLM configuration

  ## Returns
  - {:ok, req_with_pool} configured Req client with pooling
  - {:error, reason} if configuration fails
  """
  @spec create_pooled_request(atom(), map()) :: {:ok, Req.Request.t()} | {:error, term()}
  def create_pooled_request(provider, base_config) do
    GenServer.call(__MODULE__, {:create_pooled_request, provider, base_config})
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting ReqLLM Connection Pool Manager")

    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup_idle_connections, @default_pool_config.idle_interval)

    state = %{
      pools: %{},
      metrics: %{},
      cleanup_timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:configure_pool, provider, pool_config}, _from, state) do
    try do
      # Merge with defaults
      config = Map.merge(@default_pool_config, pool_config)

      # Validate configuration
      case validate_pool_config(config) do
        :ok ->
          # Initialize pool for provider
          pool_state = %{
            config: config,
            connections: %{},
            active: MapSet.new(),
            idle: [],
            checkout_queue: :queue.new(),
            created_at: System.monotonic_time(:millisecond)
          }

          new_pools = Map.put(state.pools, provider, pool_state)
          new_metrics = Map.put(state.metrics, provider, @pool_metrics)

          Logger.info("Configured connection pool for provider #{provider}: #{inspect(config)}")

          {:reply, :ok, %{state | pools: new_pools, metrics: new_metrics}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    rescue
      error ->
        Logger.error("Error configuring pool for #{provider}: #{inspect(error)}")
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:get_pool_config, provider}, _from, state) do
    case Map.get(state.pools, provider) do
      nil ->
        {:reply, {:error, :pool_not_configured}, state}
      pool_state ->
        {:reply, {:ok, pool_state.config}, state}
    end
  end

  @impl true
  def handle_call({:checkout_connection, provider, timeout}, from, state) do
    case Map.get(state.pools, provider) do
      nil ->
        {:reply, {:error, :pool_not_configured}, state}

      pool_state ->
        case checkout_connection_internal(pool_state, from, timeout) do
          {:ok, connection, updated_pool} ->
            new_pools = Map.put(state.pools, provider, updated_pool)
            new_metrics = update_checkout_metrics(state.metrics, provider, :success)

            {:reply, {:ok, connection}, %{state | pools: new_pools, metrics: new_metrics}}

          {:error, reason, updated_pool} ->
            new_pools = Map.put(state.pools, provider, updated_pool)
            new_metrics = update_checkout_metrics(state.metrics, provider, :error)

            {:reply, {:error, reason}, %{state | pools: new_pools, metrics: new_metrics}}

          {:queue, updated_pool} ->
            # Connection will be provided asynchronously
            new_pools = Map.put(state.pools, provider, updated_pool)
            {:noreply, %{state | pools: new_pools}}
        end
    end
  end

  @impl true
  def handle_call({:checkin_connection, provider, connection}, _from, state) do
    case Map.get(state.pools, provider) do
      nil ->
        {:reply, {:error, :pool_not_configured}, state}

      pool_state ->
        case checkin_connection_internal(pool_state, connection) do
          {:ok, updated_pool} ->
            new_pools = Map.put(state.pools, provider, updated_pool)
            new_metrics = update_checkin_metrics(state.metrics, provider)

            {:reply, :ok, %{state | pools: new_pools, metrics: new_metrics}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_pool_metrics, provider}, _from, state) do
    case Map.get(state.metrics, provider) do
      nil ->
        {:reply, {:error, :pool_not_configured}, state}
      metrics ->
        # Calculate current utilization
        pool_state = Map.get(state.pools, provider)
        updated_metrics = calculate_pool_utilization(metrics, pool_state)
        {:reply, {:ok, updated_metrics}, state}
    end
  end

  @impl true
  def handle_call(:get_all_metrics, _from, state) do
    all_metrics = Enum.map(state.metrics, fn {provider, metrics} ->
      pool_state = Map.get(state.pools, provider)
      updated_metrics = calculate_pool_utilization(metrics, pool_state)
      {provider, updated_metrics}
    end)
    |> Map.new()

    {:reply, all_metrics, state}
  end

  @impl true
  def handle_call({:close_pool, provider}, _from, state) do
    case Map.get(state.pools, provider) do
      nil ->
        {:reply, {:error, :pool_not_configured}, state}

      pool_state ->
        # Close all connections
        close_all_connections(pool_state)

        new_pools = Map.delete(state.pools, provider)
        new_metrics = Map.delete(state.metrics, provider)

        Logger.info("Closed connection pool for provider #{provider}")

        {:reply, :ok, %{state | pools: new_pools, metrics: new_metrics}}
    end
  end

  @impl true
  def handle_call({:create_pooled_request, provider, base_config}, _from, state) do
    case Map.get(state.pools, provider) do
      nil ->
        {:reply, {:error, :pool_not_configured}, state}

      pool_state ->
        case create_req_with_pooling(provider, base_config, pool_state.config) do
          {:ok, req} ->
            {:reply, {:ok, req}, state}
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_info(:cleanup_idle_connections, state) do
    # Clean up idle connections across all pools
    new_state = cleanup_idle_connections_all_pools(state)

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_idle_connections, @default_pool_config.idle_interval)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:connection_timeout, provider, from_pid}, state) do
    # Handle connection checkout timeout
    case Map.get(state.pools, provider) do
      nil ->
        {:noreply, state}

      pool_state ->
        updated_pool = remove_from_checkout_queue(pool_state, from_pid)
        new_pools = Map.put(state.pools, provider, updated_pool)
        new_metrics = update_checkout_metrics(state.metrics, provider, :timeout)

        GenServer.reply(from_pid, {:error, :checkout_timeout})

        {:noreply, %{state | pools: new_pools, metrics: new_metrics}}
    end
  end

  # Private Functions

  defp validate_pool_config(config) do
    required_fields = [:size, :max_idle_time, :checkout_timeout]

    missing_fields = Enum.filter(required_fields, fn field ->
      not Map.has_key?(config, field) or is_nil(Map.get(config, field))
    end)

    if Enum.empty?(missing_fields) do
      # Validate field values
      cond do
        config.size <= 0 ->
          {:error, "Pool size must be positive"}
        config.max_idle_time <= 0 ->
          {:error, "Max idle time must be positive"}
        config.checkout_timeout <= 0 ->
          {:error, "Checkout timeout must be positive"}
        true ->
          :ok
      end
    else
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  defp checkout_connection_internal(pool_state, from, timeout) do
    cond do
      # Check if we have idle connections
      length(pool_state.idle) > 0 ->
        [connection | remaining_idle] = pool_state.idle
        updated_pool = %{pool_state |
          idle: remaining_idle,
          active: MapSet.put(pool_state.active, connection)
        }
        {:ok, connection, updated_pool}

      # Check if we can create new connection
      MapSet.size(pool_state.active) + length(pool_state.idle) < pool_state.config.size ->
        case create_new_connection(pool_state.config) do
          {:ok, connection} ->
            updated_pool = %{pool_state |
              active: MapSet.put(pool_state.active, connection),
              connections: Map.put(pool_state.connections, connection, %{
                created_at: System.monotonic_time(:millisecond),
                last_used: System.monotonic_time(:millisecond)
              })
            }
            {:ok, connection, updated_pool}

          {:error, reason} ->
            {:error, reason, pool_state}
        end

      # Queue the request if pool is full
      true ->
        # Set up timeout for queued request
        timer_ref = Process.send_after(self(), {:connection_timeout, :provider, from}, timeout)

        queue_entry = {from, timer_ref, System.monotonic_time(:millisecond)}
        updated_queue = :queue.in(queue_entry, pool_state.checkout_queue)
        updated_pool = %{pool_state | checkout_queue: updated_queue}

        {:queue, updated_pool}
    end
  end

  defp checkin_connection_internal(pool_state, connection) do
    if MapSet.member?(pool_state.active, connection) do
      # Update connection metadata
      connection_meta = Map.get(pool_state.connections, connection, %{})
      updated_meta = Map.put(connection_meta, :last_used, System.monotonic_time(:millisecond))

      updated_connections = Map.put(pool_state.connections, connection, updated_meta)
      updated_active = MapSet.delete(pool_state.active, connection)

      # Check if there are queued requests
      case :queue.out(pool_state.checkout_queue) do
        {{:value, {from, timer_ref, _queued_at}}, remaining_queue} ->
          # Cancel timeout timer and provide connection to queued request
          Process.cancel_timer(timer_ref)
          GenServer.reply(from, {:ok, connection})

          updated_pool = %{pool_state |
            active: MapSet.put(updated_active, connection),
            connections: updated_connections,
            checkout_queue: remaining_queue
          }
          {:ok, updated_pool}

        {:empty, _} ->
          # No queued requests, add to idle pool
          updated_pool = %{pool_state |
            active: updated_active,
            idle: [connection | pool_state.idle],
            connections: updated_connections
          }
          {:ok, updated_pool}
      end
    else
      {:error, :connection_not_active}
    end
  end

  defp create_new_connection(config) do
    try do
      # Create a connection identifier (in real implementation, this would be actual connection)
      connection_id = :crypto.strong_rand_bytes(16) |> Base.encode64()

      # In a real implementation, you would establish actual HTTP connection here
      # For now, we'll use a connection identifier
      connection = %{
        id: connection_id,
        created_at: System.monotonic_time(:millisecond),
        config: config
      }

      Logger.debug("Created new connection: #{connection_id}")
      {:ok, connection}
    rescue
      error ->
        Logger.error("Failed to create connection: #{inspect(error)}")
        {:error, error}
    end
  end

  defp close_all_connections(pool_state) do
    # Close active connections
    Enum.each(pool_state.active, fn connection ->
      close_connection(connection)
    end)

    # Close idle connections
    Enum.each(pool_state.idle, fn connection ->
      close_connection(connection)
    end)

    # Reply to any queued requests with error
    :queue.to_list(pool_state.checkout_queue)
    |> Enum.each(fn {from, timer_ref, _queued_at} ->
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, {:error, :pool_closed})
    end)
  end

  defp close_connection(connection) do
    # In a real implementation, this would close the actual HTTP connection
    Logger.debug("Closing connection: #{inspect(connection.id)}")
    :ok
  end

  defp cleanup_idle_connections_all_pools(state) do
    current_time = System.monotonic_time(:millisecond)

    new_pools = Enum.map(state.pools, fn {provider, pool_state} ->
      updated_pool = cleanup_idle_connections_for_pool(pool_state, current_time)
      {provider, updated_pool}
    end)
    |> Map.new()

    %{state | pools: new_pools}
  end

  defp cleanup_idle_connections_for_pool(pool_state, current_time) do
    max_idle_time = pool_state.config.max_idle_time
    connection_ttl = Map.get(pool_state.config, :connection_ttl, 300_000)

    {valid_idle, expired_idle} = Enum.split_with(pool_state.idle, fn connection ->
      connection_meta = Map.get(pool_state.connections, connection, %{})
      last_used = Map.get(connection_meta, :last_used, 0)
      created_at = Map.get(connection_meta, :created_at, 0)

      # Keep connection if it's within idle time and TTL limits
      (current_time - last_used) < max_idle_time and
      (current_time - created_at) < connection_ttl
    end)

    # Close expired connections
    Enum.each(expired_idle, fn connection ->
      close_connection(connection)
    end)

    # Remove expired connections from metadata
    updated_connections = Enum.reduce(expired_idle, pool_state.connections, fn connection, acc ->
      Map.delete(acc, connection)
    end)

    if length(expired_idle) > 0 do
      Logger.debug("Cleaned up #{length(expired_idle)} expired idle connections")
    end

    %{pool_state |
      idle: valid_idle,
      connections: updated_connections
    }
  end

  defp remove_from_checkout_queue(pool_state, from_pid) do
    updated_queue = :queue.filter(fn {queued_from, _timer_ref, _queued_at} ->
      queued_from != from_pid
    end, pool_state.checkout_queue)

    %{pool_state | checkout_queue: updated_queue}
  end

  defp update_checkout_metrics(metrics, provider, result) do
    current_metrics = Map.get(metrics, provider, @pool_metrics)

    updated_metrics = case result do
      :success ->
        %{current_metrics |
          total_checkouts: current_metrics.total_checkouts + 1
        }
      :error ->
        %{current_metrics |
          connection_errors: current_metrics.connection_errors + 1
        }
      :timeout ->
        %{current_metrics |
          checkout_timeouts: current_metrics.checkout_timeouts + 1
        }
    end

    Map.put(metrics, provider, updated_metrics)
  end

  defp update_checkin_metrics(metrics, provider) do
    # Checkin doesn't need specific metric updates beyond utilization
    # which is calculated dynamically
    metrics
  end

  defp calculate_pool_utilization(metrics, pool_state) do
    if pool_state do
      total_capacity = pool_state.config.size
      active_count = MapSet.size(pool_state.active)
      idle_count = length(pool_state.idle)

      utilization = if total_capacity > 0 do
        active_count / total_capacity
      else
        0.0
      end

      %{metrics |
        active_connections: active_count,
        idle_connections: idle_count,
        pool_utilization: utilization
      }
    else
      metrics
    end
  end

  defp create_req_with_pooling(provider, base_config, pool_config) do
    try do
      # Configure Req with connection pooling options
      req_options = [
        base_url: Map.get(base_config, :base_url),
        headers: Map.get(base_config, :headers, []),
        receive_timeout: Map.get(base_config, :timeout, 30_000),
        # Connection pooling configuration
        pool_timeout: pool_config.checkout_timeout,
        pool_size: pool_config.size,
        pool_max_overflow: Map.get(pool_config, :max_overflow, 5),
        # HTTP/2 connection reuse
        http_2: true,
        # Keep-alive settings
        connect_options: [
          keepalive: true,
          keepalive_timeout: pool_config.max_idle_time
        ]
      ]

      req = Req.new(req_options)

      Logger.debug("Created pooled Req client for provider #{provider}")
      {:ok, req}
    rescue
      error ->
        Logger.error("Failed to create pooled request for #{provider}: #{inspect(error)}")
        {:error, error}
    end
  end
end
