#!/usr/bin/env elixir

# scripts/monitor_migration.exs
# Script to continuously monitor migration progress

IO.puts("📊 ReqLLM Migration Monitor")
IO.puts("Monitoring migration progress and system health...")
IO.puts("Press Ctrl+C to stop monitoring")
IO.puts("")

# Start the application if not already running
case Application.ensure_all_started(:decision_engine) do
  {:ok, _} ->
    IO.puts("✅ Application started successfully")
  {:error, reason} ->
    IO.puts("❌ Failed to start application: #{inspect(reason)}")
    System.halt(1)
end

# Wait for processes to initialize
Process.sleep(2000)

defmodule MigrationMonitor do
  def monitor_loop() do
    clear_screen()

    IO.puts("🚀 ReqLLM Migration Monitor - #{DateTime.utc_now() |> DateTime.to_string()}")
    IO.puts(String.duplicate("=", 80))

    # Show migration status
    show_migration_status()

    # Show performance metrics
    show_performance_metrics()

    # Show monitoring status
    show_monitoring_status()

    # Show recent alerts
    show_recent_alerts()

    IO.puts(String.duplicate("=", 80))
    IO.puts("🔄 Refreshing in 30 seconds... (Press Ctrl+C to stop)")

    # Wait 30 seconds before next update
    Process.sleep(30_000)

    monitor_loop()
  end

  defp clear_screen() do
    IO.write("\e[2J\e[H")  # ANSI escape codes to clear screen and move cursor to top
  end

  defp show_migration_status() do
    status = DecisionEngine.ReqLLMMigrationManager.get_migration_status()

    IO.puts("📋 Migration Status:")
    IO.puts("   Phase: #{status.current_phase}")
    IO.puts("   Description: #{status.phase_description}")

    if status.phase_start_time do
      start_time = DateTime.from_unix!(status.phase_start_time)
      elapsed = DateTime.diff(DateTime.utc_now(), start_time, :second)
      hours = div(elapsed, 3600)
      minutes = div(rem(elapsed, 3600), 60)
      IO.puts("   Duration: #{hours}h #{minutes}m")
    end

    IO.puts("   Auto-advance: #{if status.auto_advance_enabled, do: "✅", else: "❌"}")
    IO.puts("   Can Advance: #{if status.can_advance, do: "✅", else: "❌"}")

    if status.phase_config[:rollout_percentage] do
      IO.puts("   Rollout: #{status.phase_config.rollout_percentage}%")
    end

    IO.puts("")
  end

  defp show_performance_metrics() do
    case DecisionEngine.ReqLLMPerformanceMonitor.get_current_metrics() do
      {:ok, metrics} ->
        IO.puts("📈 Performance Metrics (Last 60 minutes):")
        IO.puts("   Total Requests: #{metrics.total_requests}")
        IO.puts("   Error Rate: #{format_percentage(metrics.error_rate)}")
        IO.puts("   Latency Ratio: #{Float.round(metrics.latency_ratio, 2)}x")
        IO.puts("   Streaming Success: #{format_percentage(metrics.streaming_success_rate)}")
        IO.puts("   Pool Efficiency: #{format_percentage(metrics.connection_pool_efficiency)}")
        IO.puts("   Performance Improvement: #{Float.round(metrics.performance_improvement, 2)}x")

        # Show health indicator
        health_indicator = cond do
          metrics.error_rate > 0.05 -> "🔴 CRITICAL"
          metrics.latency_ratio > 2.0 -> "🟡 WARNING"
          metrics.performance_improvement > 1.1 -> "🟢 EXCELLENT"
          true -> "🟢 HEALTHY"
        end

        IO.puts("   Health: #{health_indicator}")

      {:error, reason} ->
        IO.puts("📈 Performance Metrics: ❌ Error - #{reason}")
    end

    IO.puts("")
  end

  defp show_monitoring_status() do
    monitor_status = DecisionEngine.ReqLLMMigrationMonitor.get_monitoring_status()

    IO.puts("🔍 Monitoring Status:")
    IO.puts("   Auto-rollback: #{if monitor_status.auto_rollback_enabled, do: "✅", else: "❌"}")
    IO.puts("   Monitoring Active: #{if monitor_status.monitoring_active, do: "✅", else: "❌"}")
    IO.puts("   Consecutive Warnings: #{monitor_status.consecutive_warnings}")
    IO.puts("   Consecutive Criticals: #{monitor_status.consecutive_criticals}")
    IO.puts("   Rollback Triggered: #{if monitor_status.rollback_triggered, do: "🚨 YES", else: "✅ No"}")
    IO.puts("   Health Checks: #{monitor_status.health_checks_count}")

    if monitor_status.last_check_time do
      last_check = DateTime.from_unix!(monitor_status.last_check_time)
      seconds_ago = DateTime.diff(DateTime.utc_now(), last_check, :second)
      IO.puts("   Last Check: #{seconds_ago}s ago")
    end

    IO.puts("")
  end

  defp show_recent_alerts() do
    monitor_status = DecisionEngine.ReqLLMMigrationMonitor.get_monitoring_status()

    if not Enum.empty?(monitor_status.recent_alerts) do
      IO.puts("🚨 Recent Alerts:")

      Enum.take(monitor_status.recent_alerts, 5)
      |> Enum.each(fn alert ->
        timestamp = DateTime.from_unix!(alert.timestamp)
        severity_icon = case alert.severity do
          :critical -> "🔴"
          :warning -> "🟡"
          _ -> "🔵"
        end

        IO.puts("   #{severity_icon} #{alert.message} (#{DateTime.to_time(timestamp)})")
      end)
    else
      IO.puts("🚨 Recent Alerts: None")
    end

    IO.puts("")
  end

  defp format_percentage(value) do
    "#{Float.round(value * 100, 2)}%"
  end
end

# Start monitoring loop
try do
  MigrationMonitor.monitor_loop()
rescue
  e ->
    IO.puts("\n❌ Monitoring stopped: #{inspect(e)}")
catch
  :exit, _ ->
    IO.puts("\n👋 Monitoring stopped by user")
end
