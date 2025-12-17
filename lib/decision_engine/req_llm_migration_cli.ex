# lib/decision_engine/req_llm_migration_cli.ex
defmodule DecisionEngine.ReqLLMMigrationCLI do
  @moduledoc """
  Command-line interface for managing ReqLLM migration.

  Provides commands to start, monitor, and control the phased migration
  from legacy LLM implementation to ReqLLM.
  """

  require Logger

  alias DecisionEngine.ReqLLMMigrationManager
  alias DecisionEngine.ReqLLMFeatureFlags
  alias DecisionEngine.ReqLLMPerformanceMonitor

  @doc """
  Starts the migration process.
  """
  def start_migration() do
    IO.puts("🚀 Starting ReqLLM Migration...")

    case ReqLLMMigrationManager.start_migration() do
      :ok ->
        IO.puts("✅ Migration started successfully!")
        show_migration_status()

      {:error, reason} ->
        IO.puts("❌ Failed to start migration: #{reason}")
    end
  end

  @doc """
  Shows current migration status.
  """
  def show_migration_status() do
    status = ReqLLMMigrationManager.get_migration_status()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("📊 REQLLM MIGRATION STATUS")
    IO.puts(String.duplicate("=", 60))

    IO.puts("🔄 Current Phase: #{status.current_phase}")
    IO.puts("📝 Description: #{status.phase_description}")

    if status.phase_start_time do
      start_time = DateTime.from_unix!(status.phase_start_time)
      elapsed = DateTime.diff(DateTime.utc_now(), start_time, :second)
      hours = div(elapsed, 3600)
      minutes = div(rem(elapsed, 3600), 60)
      IO.puts("⏱️  Phase Duration: #{hours}h #{minutes}m")
    end

    IO.puts("🎯 Auto-advance: #{if status.auto_advance_enabled, do: "Enabled", else: "Disabled"}")
    IO.puts("📈 Can Advance: #{if status.can_advance, do: "Yes", else: "No"}")

    if status.next_phase do
      IO.puts("➡️  Next Phase: #{status.next_phase}")
    end

    # Show phase configuration
    if not Enum.empty?(status.phase_config) do
      IO.puts("\n📋 Phase Configuration:")
      IO.puts("   Rollout: #{status.phase_config[:rollout_percentage] || 0}%")
      IO.puts("   Duration: #{status.phase_config[:duration_hours] || 0} hours")

      if status.phase_config[:success_criteria] do
        IO.puts("   Success Criteria:")
        Enum.each(status.phase_config.success_criteria, fn {key, value} ->
          IO.puts("     • #{format_criterion(key)}: #{value}")
        end)
      end
    end

    # Show rollback history if any
    if not Enum.empty?(status.rollback_history) do
      IO.puts("\n🔄 Recent Rollbacks:")
      Enum.take(status.rollback_history, 3)
      |> Enum.each(fn rollback ->
        timestamp = DateTime.from_unix!(rollback.timestamp)
        IO.puts("   • #{rollback.from_phase} → #{rollback.to_phase} at #{DateTime.to_string(timestamp)}")
      end)
    end

    IO.puts(String.duplicate("=", 60))
  end

  @doc """
  Shows performance metrics.
  """
  def show_performance_metrics() do
    case ReqLLMPerformanceMonitor.get_current_metrics() do
      {:ok, metrics} ->
        IO.puts("\n" <> String.duplicate("=", 60))
        IO.puts("📈 PERFORMANCE METRICS")
        IO.puts(String.duplicate("=", 60))

        IO.puts("🔄 ReqLLM Metrics:")
        show_implementation_metrics(metrics.reqllm, "  ")

        IO.puts("\n🏛️  Legacy Metrics:")
        show_implementation_metrics(metrics.legacy, "  ")

        IO.puts("\n📊 Comparison:")
        show_comparison_metrics(metrics.comparison, "  ")

        IO.puts("\n🎯 Key Migration Metrics:")
        IO.puts("  Error Rate: #{Float.round(metrics.error_rate * 100, 2)}%")
        IO.puts("  Latency Ratio: #{Float.round(metrics.latency_ratio, 2)}x")
        IO.puts("  Streaming Success: #{Float.round(metrics.streaming_success_rate * 100, 2)}%")
        IO.puts("  Total Requests: #{metrics.total_requests}")
        IO.puts("  Pool Efficiency: #{Float.round(metrics.connection_pool_efficiency * 100, 2)}%")
        IO.puts("  Performance Improvement: #{Float.round(metrics.performance_improvement, 2)}x")

        IO.puts(String.duplicate("=", 60))

      {:error, reason} ->
        IO.puts("❌ Failed to get performance metrics: #{reason}")
    end
  end

  @doc """
  Advances to the next migration phase.
  """
  def advance_phase() do
    IO.puts("⏭️  Advancing to next migration phase...")

    case ReqLLMMigrationManager.advance_phase() do
      :ok ->
        IO.puts("✅ Successfully advanced to next phase!")
        show_migration_status()

      {:error, reason} ->
        IO.puts("❌ Cannot advance phase: #{reason}")
        IO.puts("\n💡 Try checking performance metrics or waiting longer for criteria to be met.")
    end
  end

  @doc """
  Rolls back to the previous migration phase.
  """
  def rollback_phase() do
    IO.puts("⏪ Rolling back to previous migration phase...")

    case ReqLLMMigrationManager.rollback_phase() do
      :ok ->
        IO.puts("✅ Successfully rolled back to previous phase!")
        show_migration_status()

      {:error, reason} ->
        IO.puts("❌ Cannot rollback phase: #{reason}")
    end
  end

  @doc """
  Forces migration to a specific phase.
  """
  def force_phase(phase_name) when is_binary(phase_name) do
    phase = String.to_existing_atom(phase_name)
    force_phase(phase)
  rescue
    ArgumentError ->
      IO.puts("❌ Invalid phase name: #{phase_name}")
      IO.puts("Valid phases: not_started, phase_1, phase_2, phase_3, completed")
  end

  def force_phase(phase) when is_atom(phase) do
    IO.puts("⚠️  Force transitioning to phase: #{phase}")
    IO.puts("This bypasses safety checks and should only be used for testing!")

    IO.write("Are you sure? (y/N): ")
    response = IO.read(:line) |> String.trim() |> String.downcase()

    if response in ["y", "yes"] do
      case ReqLLMMigrationManager.force_phase(phase) do
        :ok ->
          IO.puts("✅ Successfully forced transition to #{phase}!")
          show_migration_status()

        {:error, reason} ->
          IO.puts("❌ Failed to force phase transition: #{reason}")
      end
    else
      IO.puts("❌ Phase transition cancelled.")
    end
  end

  @doc """
  Enables automatic phase advancement.
  """
  def enable_auto_advance() do
    IO.puts("🤖 Enabling automatic phase advancement...")

    case ReqLLMMigrationManager.enable_auto_advance() do
      :ok ->
        IO.puts("✅ Auto-advance enabled! Migration will progress automatically when criteria are met.")

      {:error, reason} ->
        IO.puts("❌ Failed to enable auto-advance: #{reason}")
    end
  end

  @doc """
  Disables automatic phase advancement.
  """
  def disable_auto_advance() do
    IO.puts("✋ Disabling automatic phase advancement...")

    case ReqLLMMigrationManager.disable_auto_advance() do
      :ok ->
        IO.puts("✅ Auto-advance disabled! Manual control required for phase transitions.")

      {:error, reason} ->
        IO.puts("❌ Failed to disable auto-advance: #{reason}")
    end
  end

  @doc """
  Shows feature flag status.
  """
  def show_feature_flags() do
    flags = ReqLLMFeatureFlags.get_all_flags()

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("🚩 REQLLM FEATURE FLAGS")
    IO.puts(String.duplicate("=", 60))

    IO.puts("🔧 Core Flags:")
    IO.puts("  ReqLLM Enabled: #{flags.reqllm_enabled}")
    IO.puts("  Streaming Enabled: #{flags.reqllm_streaming_enabled}")
    IO.puts("  Non-streaming Enabled: #{flags.reqllm_non_streaming_enabled}")

    IO.puts("\n🏢 Provider Flags:")
    IO.puts("  OpenAI: #{flags.reqllm_openai_enabled}")
    IO.puts("  Anthropic: #{flags.reqllm_anthropic_enabled}")
    IO.puts("  Ollama: #{flags.reqllm_ollama_enabled}")
    IO.puts("  OpenRouter: #{flags.reqllm_openrouter_enabled}")
    IO.puts("  Custom: #{flags.reqllm_custom_enabled}")

    IO.puts("\n⚙️  Feature Flags:")
    IO.puts("  Connection Pooling: #{flags.reqllm_connection_pooling_enabled}")
    IO.puts("  Retry Logic: #{flags.reqllm_retry_logic_enabled}")
    IO.puts("  Circuit Breaker: #{flags.reqllm_circuit_breaker_enabled}")
    IO.puts("  Rate Limiting: #{flags.reqllm_rate_limiting_enabled}")

    IO.puts("\n🔄 Migration Control:")
    IO.puts("  Migration Phase: #{flags.migration_phase}")
    IO.puts("  Fallback Enabled: #{flags.fallback_enabled}")
    IO.puts("  Legacy Monitoring: #{flags.legacy_monitoring_enabled}")
    IO.puts("  Rollout Percentage: #{flags.rollout_percentage}%")

    IO.puts(String.duplicate("=", 60))
  end

  @doc """
  Sets rollout percentage.
  """
  def set_rollout_percentage(percentage) when is_integer(percentage) do
    IO.puts("📊 Setting rollout percentage to #{percentage}%...")

    case ReqLLMFeatureFlags.set_rollout_percentage(percentage) do
      :ok ->
        IO.puts("✅ Rollout percentage updated successfully!")

      {:error, reason} ->
        IO.puts("❌ Failed to set rollout percentage: #{reason}")
    end
  end

  def set_rollout_percentage(percentage_str) when is_binary(percentage_str) do
    case Integer.parse(percentage_str) do
      {percentage, ""} ->
        set_rollout_percentage(percentage)

      _ ->
        IO.puts("❌ Invalid percentage: #{percentage_str}. Must be an integer between 0 and 100.")
    end
  end

  @doc """
  Resets all performance metrics.
  """
  def reset_metrics() do
    IO.puts("🔄 Resetting all performance metrics...")

    IO.write("This will clear all collected performance data. Are you sure? (y/N): ")
    response = IO.read(:line) |> String.trim() |> String.downcase()

    if response in ["y", "yes"] do
      case ReqLLMPerformanceMonitor.reset_metrics() do
        :ok ->
          IO.puts("✅ All performance metrics have been reset!")

        {:error, reason} ->
          IO.puts("❌ Failed to reset metrics: #{reason}")
      end
    else
      IO.puts("❌ Metrics reset cancelled.")
    end
  end

  @doc """
  Shows help information.
  """
  def show_help() do
    IO.puts("""

    🚀 ReqLLM Migration CLI Commands:

    Migration Control:
      start_migration()           - Start the migration process
      show_migration_status()     - Show current migration status
      advance_phase()             - Advance to next phase
      rollback_phase()            - Rollback to previous phase
      force_phase("phase_name")   - Force transition to specific phase

    Automation:
      enable_auto_advance()       - Enable automatic phase advancement
      disable_auto_advance()      - Disable automatic phase advancement

    Monitoring:
      show_performance_metrics()  - Show performance comparison
      show_feature_flags()        - Show current feature flag status
      reset_metrics()             - Reset all performance metrics

    Configuration:
      set_rollout_percentage(50)  - Set rollout percentage (0-100)

    Examples:
      # Start migration
      DecisionEngine.ReqLLMMigrationCLI.start_migration()

      # Check status
      DecisionEngine.ReqLLMMigrationCLI.show_migration_status()

      # Enable auto-advance and monitor
      DecisionEngine.ReqLLMMigrationCLI.enable_auto_advance()

      # Force to specific phase (testing only)
      DecisionEngine.ReqLLMMigrationCLI.force_phase("phase_2")

    """)
  end

  # Private helper functions

  defp show_implementation_metrics(metrics, indent) do
    IO.puts("#{indent}Total Requests: #{metrics.total_requests}")
    IO.puts("#{indent}Successful: #{metrics.successful_requests}")
    IO.puts("#{indent}Failed: #{metrics.failed_requests}")
    IO.puts("#{indent}Error Rate: #{Float.round(metrics.error_rate * 100, 2)}%")

    if metrics.latency_stats do
      IO.puts("#{indent}Latency (avg): #{Float.round(metrics.latency_stats.avg, 1)}ms")
      IO.puts("#{indent}Latency (p95): #{metrics.latency_stats.p95}ms")
    end

    IO.puts("#{indent}Streaming Success: #{Float.round(metrics.streaming_success_rate * 100, 2)}%")
    IO.puts("#{indent}Pool Efficiency: #{Float.round(metrics.connection_pool_efficiency * 100, 2)}%")
  end

  defp show_comparison_metrics(comparison, indent) do
    IO.puts("#{indent}Latency Improvement: #{Float.round(comparison.latency_improvement * 100, 2)}%")
    IO.puts("#{indent}Error Rate Improvement: #{Float.round(comparison.error_rate_improvement * 100, 2)}%")
    IO.puts("#{indent}Throughput Improvement: #{Float.round(comparison.throughput_improvement * 100, 2)}%")
  end

  defp format_criterion(:error_rate_threshold), do: "Max Error Rate"
  defp format_criterion(:latency_increase_threshold), do: "Max Latency Increase"
  defp format_criterion(:latency_decrease_threshold), do: "Min Latency Decrease"
  defp format_criterion(:streaming_success_rate), do: "Min Streaming Success"
  defp format_criterion(:min_requests), do: "Min Requests"
  defp format_criterion(:connection_pool_efficiency), do: "Min Pool Efficiency"
  defp format_criterion(:performance_improvement), do: "Min Performance Improvement"
  defp format_criterion(other), do: to_string(other)
end
