# lib/decision_engine/req_llm_production_optimizer.ex
defmodule DecisionEngine.ReqLLMProductionOptimizer do
  @moduledoc """
  Optimizes ReqLLM configuration for production workloads.

  This module provides functionality to fine-tune ReqLLM settings based on
  production requirements, system resources, and performance targets.
  """

  require Logger
  alias DecisionEngine.ReqLLMConfigManager
  alias DecisionEngine.ReqLLMPerformanceMonitor
  alias DecisionEngine.ReqLLMConnectionPool

  @doc """
  Optimizes ReqLLM configuration for production deployment.

  ## Parameters
  - environment: Production environment type (:production, :staging, :development)
  - system_resources: Map containing system resource information
  - performance_targets: Map containing performance targets

  ## Returns
  - {:ok, optimized_config} with production-optimized configuration
  - {:error, reason} if optimization fails
  """
  @spec optimize_for_production(atom(), map(), map()) :: {:ok, map()} | {:error, term()}
  def optimize_for_production(environment, system_resources, performance_targets) do
    Logger.info("Optimizing ReqLLM configuration for #{environment} environment")

    with {:ok, base_config} <- get_base_production_config(environment),
         {:ok, resource_optimized} <- optimize_for_resources(base_config, system_resources),
         {:ok, performance_optimized} <- optimize_for_performance(resource_optimized, performance_targets),
         {:ok, _validated_config} <- validate_production_config(performance_optimized) do

      Logger.info("Successfully optimized ReqLLM configuration for production")
      {:ok, performance_optimized}
    else
      {:error, reason} ->
        Logger.error("Failed to optimize ReqLLM configuration: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Optimizes connection pooling settings based on expected load.

  ## Parameters
  - current_config: Current ReqLLM configuration
  - expected_load: Map containing load expectations

  ## Returns
  - {:ok, optimized_config} with optimized connection pool settings
  """
  @spec optimize_connection_pooling(map(), map()) :: {:ok, map()}
  def optimize_connection_pooling(current_config, expected_load) do
    concurrent_users = Map.get(expected_load, :concurrent_users, 100)
    requests_per_second = Map.get(expected_load, :requests_per_second, 10)
    peak_multiplier = Map.get(expected_load, :peak_multiplier, 3)

    # Calculate optimal pool size based on expected load
    base_pool_size = min(concurrent_users, 50)  # Cap at 50 connections per provider
    peak_pool_size = min(base_pool_size * peak_multiplier, 100)

    # Calculate optimal timeouts based on request patterns
    checkout_timeout = calculate_checkout_timeout(requests_per_second)
    max_idle_time = calculate_max_idle_time(concurrent_users)

    optimized_pool_config = %{
      size: peak_pool_size,
      max_idle_time: max_idle_time,
      checkout_timeout: checkout_timeout,
      max_overflow: div(peak_pool_size, 4),  # 25% overflow capacity
      strategy: :lifo  # Last In, First Out for better connection reuse
    }

    updated_config = Map.put(current_config, :connection_pool, optimized_pool_config)

    Logger.info("Optimized connection pooling: pool_size=#{peak_pool_size}, checkout_timeout=#{checkout_timeout}ms")
    {:ok, updated_config}
  end

  @doc """
  Optimizes retry and error handling settings for production reliability.

  ## Parameters
  - current_config: Current ReqLLM configuration
  - reliability_targets: Map containing reliability requirements

  ## Returns
  - {:ok, optimized_config} with optimized error handling settings
  """
  @spec optimize_error_handling(map(), map()) :: {:ok, map()}
  def optimize_error_handling(current_config, reliability_targets) do
    target_uptime = Map.get(reliability_targets, :target_uptime, 0.999)  # 99.9%
    max_acceptable_latency = Map.get(reliability_targets, :max_acceptable_latency_ms, 10_000)
    error_budget = Map.get(reliability_targets, :error_budget, 0.001)  # 0.1%

    # Calculate retry strategy based on reliability targets
    max_retries = calculate_max_retries(target_uptime, error_budget)
    base_delay = calculate_base_delay(max_acceptable_latency, max_retries)
    max_delay = min(max_acceptable_latency / 2, 30_000)  # Cap at 30 seconds

    retry_strategy = %{
      max_retries: max_retries,
      base_delay: base_delay,
      max_delay: max_delay,
      backoff_type: :exponential,
      jitter: true  # Add jitter to prevent thundering herd
    }

    # Configure circuit breaker for production reliability
    circuit_breaker_config = %{
      enabled: true,
      failure_threshold: 5,  # Trip after 5 consecutive failures
      recovery_timeout: 30_000,  # 30 second recovery window
      half_open_max_calls: 3  # Test with 3 calls in half-open state
    }

    error_handling_config = %{
      retry_strategy: retry_strategy,
      circuit_breaker: circuit_breaker_config,
      rate_limit_handling: true,
      timeout_ms: max_acceptable_latency,
      fallback_enabled: true
    }

    updated_config = Map.put(current_config, :error_handling, error_handling_config)

    Logger.info("Optimized error handling: max_retries=#{max_retries}, base_delay=#{base_delay}ms")
    {:ok, updated_config}
  end

  @doc """
  Configures monitoring and alerting thresholds for production.

  ## Parameters
  - performance_targets: Map containing performance targets
  - alerting_config: Map containing alerting preferences

  ## Returns
  - {:ok, monitoring_config} with monitoring and alerting configuration
  """
  @spec configure_monitoring_thresholds(map(), map()) :: {:ok, map()}
  def configure_monitoring_thresholds(performance_targets, alerting_config) do
    # Extract performance targets
    max_latency_ms = Map.get(performance_targets, :max_latency_ms, 5000)
    min_success_rate = Map.get(performance_targets, :min_success_rate, 0.99)
    max_error_rate = Map.get(performance_targets, :max_error_rate, 0.01)

    # Extract alerting preferences
    alert_channels = Map.get(alerting_config, :channels, [:log, :email])
    escalation_delay = Map.get(alerting_config, :escalation_delay_minutes, 5)

    monitoring_config = %{
      performance_thresholds: %{
        latency: %{
          warning_ms: trunc(max_latency_ms * 0.8),  # 80% of max
          critical_ms: max_latency_ms,
          measurement_window_minutes: 5
        },
        success_rate: %{
          warning_threshold: min_success_rate + 0.005,  # 0.5% buffer
          critical_threshold: min_success_rate,
          measurement_window_minutes: 10
        },
        error_rate: %{
          warning_threshold: max_error_rate - 0.002,  # 0.2% buffer
          critical_threshold: max_error_rate,
          measurement_window_minutes: 5
        },
        throughput: %{
          min_requests_per_second: Map.get(performance_targets, :min_throughput, 1.0),
          measurement_window_minutes: 15
        }
      },
      alerting: %{
        channels: alert_channels,
        escalation_delay_minutes: escalation_delay,
        alert_frequency_minutes: 15,  # Don't spam alerts
        recovery_notification: true
      },
      metrics_collection: %{
        enabled: true,
        collection_interval_seconds: 30,
        retention_days: 30,
        detailed_logging: Map.get(alerting_config, :detailed_logging, false)
      }
    }

    Logger.info("Configured monitoring thresholds: latency_warning=#{monitoring_config.performance_thresholds.latency.warning_ms}ms")
    {:ok, monitoring_config}
  end

  @doc """
  Applies production optimizations to an existing ReqLLM configuration.

  ## Parameters
  - config: Current ReqLLM configuration
  - optimization_options: Map containing optimization preferences

  ## Returns
  - {:ok, optimized_config} with applied optimizations
  """
  @spec apply_production_optimizations(map(), map()) :: {:ok, map()}
  def apply_production_optimizations(config, optimization_options \\ %{}) do
    # Default optimization options
    default_options = %{
      optimize_connection_pooling: true,
      optimize_error_handling: true,
      optimize_timeouts: true,
      optimize_security: true,
      enable_detailed_logging: false
    }

    options = Map.merge(default_options, optimization_options)
    optimized_config = config

    # Apply connection pooling optimizations
    optimized_config = if options.optimize_connection_pooling do
      {:ok, config_with_pool} = optimize_connection_pooling(optimized_config, %{
        concurrent_users: 100,
        requests_per_second: 10,
        peak_multiplier: 2
      })
      config_with_pool
    else
      optimized_config
    end

    # Apply error handling optimizations
    optimized_config = if options.optimize_error_handling do
      {:ok, config_with_errors} = optimize_error_handling(optimized_config, %{
        target_uptime: 0.999,
        max_acceptable_latency_ms: 10_000,
        error_budget: 0.001
      })
      config_with_errors
    else
      optimized_config
    end

    # Apply timeout optimizations
    optimized_config = if options.optimize_timeouts do
      optimize_timeouts(optimized_config)
    else
      optimized_config
    end

    # Apply security optimizations
    optimized_config = if options.optimize_security do
      optimize_security_settings(optimized_config)
    else
      optimized_config
    end

    Logger.info("Applied production optimizations to ReqLLM configuration")
    {:ok, optimized_config}
  end

  # Private Functions

  defp get_base_production_config(:production) do
    {:ok, %{
      provider: :openai,
      base_url: "https://api.openai.com/v1/chat/completions",
      model: "gpt-4",
      temperature: 0.7,
      max_tokens: 2000,
      timeout: 30_000,
      # Production-specific defaults
      connection_pool: %{
        size: 20,
        max_idle_time: 300_000,  # 5 minutes
        checkout_timeout: 10_000  # 10 seconds
      },
      retry_strategy: %{
        max_retries: 3,
        base_delay: 1000,
        max_delay: 10_000,
        backoff_type: :exponential
      },
      error_handling: %{
        circuit_breaker: true,
        rate_limit_handling: true,
        timeout_ms: 30_000,
        fallback_enabled: true
      }
    }}
  end

  defp get_base_production_config(:staging) do
    {:ok, config} = get_base_production_config(:production)

    # Staging uses smaller pool sizes and shorter timeouts for faster feedback
    staging_config = %{config |
      connection_pool: %{config.connection_pool |
        size: 10,
        max_idle_time: 180_000  # 3 minutes
      },
      timeout: 20_000
    }

    {:ok, staging_config}
  end

  defp get_base_production_config(:development) do
    {:ok, %{
      provider: :openai,
      base_url: "https://api.openai.com/v1/chat/completions",
      model: "gpt-4",
      temperature: 0.7,
      max_tokens: 1000,
      timeout: 15_000,
      # Development-specific defaults (smaller, faster)
      connection_pool: %{
        size: 5,
        max_idle_time: 60_000,  # 1 minute
        checkout_timeout: 5_000  # 5 seconds
      },
      retry_strategy: %{
        max_retries: 2,
        base_delay: 500,
        max_delay: 5_000,
        backoff_type: :exponential
      }
    }}
  end

  defp optimize_for_resources(config, system_resources) do
    available_memory_mb = Map.get(system_resources, :available_memory_mb, 1024)
    cpu_cores = Map.get(system_resources, :cpu_cores, 4)
    network_bandwidth_mbps = Map.get(system_resources, :network_bandwidth_mbps, 100)

    # Adjust pool size based on available memory (rough estimate: 10MB per connection)
    max_pool_size_by_memory = div(available_memory_mb, 10)

    # Adjust pool size based on CPU cores (rough estimate: 5 connections per core)
    max_pool_size_by_cpu = cpu_cores * 5

    # Use the more conservative limit
    optimal_pool_size = min(max_pool_size_by_memory, max_pool_size_by_cpu)
    optimal_pool_size = max(optimal_pool_size, 5)  # Minimum of 5 connections

    # Adjust timeouts based on network bandwidth
    timeout_adjustment = case network_bandwidth_mbps do
      bw when bw >= 100 -> 1.0  # No adjustment for high bandwidth
      bw when bw >= 50 -> 1.2   # 20% longer timeouts for medium bandwidth
      bw when bw >= 10 -> 1.5   # 50% longer timeouts for low bandwidth
      _ -> 2.0                  # Double timeouts for very low bandwidth
    end

    base_timeout = Map.get(config, :timeout, 30_000)
    adjusted_timeout = trunc(base_timeout * timeout_adjustment)

    resource_optimized = %{config |
      connection_pool: %{config.connection_pool |
        size: optimal_pool_size
      },
      timeout: adjusted_timeout
    }

    Logger.info("Resource optimization: pool_size=#{optimal_pool_size}, timeout=#{adjusted_timeout}ms")
    {:ok, resource_optimized}
  end

  defp optimize_for_performance(config, performance_targets) do
    target_latency_ms = Map.get(performance_targets, :target_latency_ms, 5000)
    target_throughput_rps = Map.get(performance_targets, :target_throughput_rps, 10)
    target_success_rate = Map.get(performance_targets, :target_success_rate, 0.99)

    # Adjust connection pool for throughput targets
    min_pool_size = max(trunc(target_throughput_rps * 1.5), 5)
    current_pool_size = get_in(config, [:connection_pool, :size]) || 10
    optimal_pool_size = max(min_pool_size, current_pool_size)

    # Adjust timeouts for latency targets
    max_timeout = min(target_latency_ms, 60_000)  # Cap at 60 seconds

    # Adjust retry strategy for success rate targets
    {max_retries, base_delay} = case target_success_rate do
      rate when rate >= 0.999 -> {4, 500}   # High reliability: more retries, faster
      rate when rate >= 0.99 -> {3, 1000}   # Standard reliability
      rate when rate >= 0.95 -> {2, 1500}   # Lower reliability: fewer retries
      _ -> {1, 2000}                         # Minimal reliability
    end

    performance_optimized = %{config |
      connection_pool: %{config.connection_pool |
        size: optimal_pool_size
      },
      timeout: max_timeout,
      retry_strategy: %{config.retry_strategy |
        max_retries: max_retries,
        base_delay: base_delay
      }
    }

    Logger.info("Performance optimization: pool_size=#{optimal_pool_size}, max_retries=#{max_retries}")
    {:ok, performance_optimized}
  end

  defp validate_production_config(config) do
    # Validate required fields
    required_fields = [:provider, :base_url, :model, :connection_pool, :retry_strategy]

    missing_fields = Enum.filter(required_fields, fn field ->
      not Map.has_key?(config, field) or is_nil(Map.get(config, field))
    end)

    if Enum.empty?(missing_fields) do
      # Validate connection pool configuration
      pool_config = Map.get(config, :connection_pool)
      if is_map(pool_config) and Map.has_key?(pool_config, :size) and pool_config.size > 0 do
        {:ok, config}
      else
        {:error, "Invalid connection pool configuration"}
      end
    else
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  defp calculate_checkout_timeout(requests_per_second) do
    # Base timeout of 5 seconds, adjusted for request rate
    base_timeout = 5000

    case requests_per_second do
      rps when rps >= 50 -> base_timeout / 2    # 2.5 seconds for high load
      rps when rps >= 20 -> base_timeout        # 5 seconds for medium load
      rps when rps >= 5 -> base_timeout * 1.5   # 7.5 seconds for low load
      _ -> base_timeout * 2                     # 10 seconds for very low load
    end |> trunc()
  end

  defp calculate_max_idle_time(concurrent_users) do
    # Base idle time of 5 minutes, adjusted for user count
    base_idle_time = 300_000  # 5 minutes

    case concurrent_users do
      users when users >= 100 -> base_idle_time / 2    # 2.5 minutes for many users
      users when users >= 50 -> base_idle_time         # 5 minutes for medium users
      users when users >= 10 -> base_idle_time * 1.5   # 7.5 minutes for few users
      _ -> base_idle_time * 2                          # 10 minutes for very few users
    end |> trunc()
  end

  defp calculate_max_retries(target_uptime, error_budget) do
    # Calculate retries needed to achieve target uptime within error budget
    base_failure_rate = 1 - target_uptime
    acceptable_failure_rate = error_budget

    if base_failure_rate <= acceptable_failure_rate do
      2  # Minimal retries if already meeting targets
    else
      # Calculate retries needed (simplified model)
      retry_factor = base_failure_rate / acceptable_failure_rate
      min(trunc(:math.log(retry_factor) + 1), 5)  # Cap at 5 retries
    end
  end

  defp calculate_base_delay(max_acceptable_latency, max_retries) do
    # Calculate base delay that keeps total retry time under acceptable latency
    # Using exponential backoff: total_time ≈ base_delay * (2^max_retries - 1)
    if max_retries > 0 do
      max_retry_time = max_acceptable_latency / 2  # Use half of acceptable latency for retries
      exponential_factor = :math.pow(2, max_retries) - 1
      base_delay = max_retry_time / exponential_factor
      max(trunc(base_delay), 100)  # Minimum 100ms base delay
    else
      1000  # Default 1 second if no retries
    end
  end

  defp optimize_timeouts(config) do
    # Optimize various timeout settings for production
    base_timeout = Map.get(config, :timeout, 30_000)

    # Connection pool timeouts should be shorter than request timeouts
    checkout_timeout = min(base_timeout / 3, 10_000)

    # Idle timeout should be longer to maintain connections
    max_idle_time = base_timeout * 10

    # Ensure connection_pool exists before merging
    current_pool = Map.get(config, :connection_pool, %{})
    updated_pool = Map.merge(current_pool, %{
      checkout_timeout: trunc(checkout_timeout),
      max_idle_time: trunc(max_idle_time)
    })

    Map.put(config, :connection_pool, updated_pool)
  end

  defp optimize_security_settings(config) do
    # Add security-focused settings for production
    security_config = %{
      ssl_verify: true,
      ssl_cacerts: :public_key.cacerts_get(),
      headers: [
        {"user-agent", "DecisionEngine/1.0"},
        {"accept", "application/json"},
        {"connection", "keep-alive"}
      ],
      redact_sensitive_data: true,
      log_request_bodies: false,  # Don't log request bodies in production
      log_response_bodies: false  # Don't log response bodies in production
    }

    Map.merge(config, security_config)
  end
end
