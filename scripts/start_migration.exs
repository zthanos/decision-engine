#!/usr/bin/env elixir

# scripts/start_migration.exs
# Script to start the ReqLLM migration process

IO.puts("🚀 Starting ReqLLM Migration Process...")
IO.puts("This script will initiate the phased migration from legacy LLM to ReqLLM.")
IO.puts("")

# Start the application if not already running
case Application.ensure_all_started(:decision_engine) do
  {:ok, _} ->
    IO.puts("✅ Application started successfully")
  {:error, reason} ->
    IO.puts("❌ Failed to start application: #{inspect(reason)}")
    System.halt(1)
end

# Wait a moment for all processes to initialize
Process.sleep(2000)

# Check current migration status
IO.puts("\n📊 Checking current migration status...")
status = DecisionEngine.ReqLLMMigrationManager.get_migration_status()
IO.puts("Current phase: #{status.current_phase}")

case status.current_phase do
  :not_started ->
    IO.puts("\n🎯 Starting migration from phase :not_started to :phase_1")
    IO.puts("This will enable ReqLLM for 10% of non-streaming requests.")

    IO.write("Continue? (y/N): ")
    response = IO.read(:line) |> String.trim() |> String.downcase()

    if response in ["y", "yes"] do
      case DecisionEngine.ReqLLMMigrationManager.start_migration() do
        :ok ->
          IO.puts("✅ Migration started successfully!")
          IO.puts("\n📈 Migration Status:")
          DecisionEngine.ReqLLMMigrationCLI.show_migration_status()

          IO.puts("\n💡 Next Steps:")
          IO.puts("1. Monitor performance metrics with: DecisionEngine.ReqLLMMigrationCLI.show_performance_metrics()")
          IO.puts("2. Check migration status with: DecisionEngine.ReqLLMMigrationCLI.show_migration_status()")
          IO.puts("3. Enable auto-advance with: DecisionEngine.ReqLLMMigrationCLI.enable_auto_advance()")
          IO.puts("4. Manually advance when ready with: DecisionEngine.ReqLLMMigrationCLI.advance_phase()")

        {:error, reason} ->
          IO.puts("❌ Failed to start migration: #{reason}")
          System.halt(1)
      end
    else
      IO.puts("❌ Migration cancelled by user")
    end

  phase ->
    IO.puts("⚠️  Migration already in progress at phase: #{phase}")
    IO.puts("Use DecisionEngine.ReqLLMMigrationCLI.show_migration_status() for details")
end

IO.puts("\n🎉 Migration script completed!")
