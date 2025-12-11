# lib/decision_engine.ex
defmodule DecisionEngine do
  @moduledoc """
  Main module that orchestrates the decision engine workflow.
  """

  require Logger

  @doc """
  Process a user scenario and return a decision with justification.

  ## Parameters
  - scenario: The user's natural language description of their automation need
  - config: LLM provider configuration map (see DecisionEngine.LLMClient for details)

  ## Returns
  {:ok, result} with the decision and justification, or {:error, reason}
  """
  def process(scenario, config) do
    Logger.info("Processing scenario: #{scenario}")

    with {:ok, signals} <- DecisionEngine.LLMClient.extract_signals(scenario, config),
         decision_result <- DecisionEngine.RuleEngine.evaluate(signals),
         {:ok, justification} <- DecisionEngine.LLMClient.generate_justification(signals, decision_result, config) do

      result = %{
        signals: signals,
        decision: decision_result,
        justification: justification,
        timestamp: DateTime.utc_now()
      }

      Logger.info("Decision made: #{decision_result.pattern_id}")
      {:ok, result}
    else
      {:error, reason} = error ->
        Logger.error("Processing failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Pretty print the decision result.
  """
  def print_result({:ok, result}) do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("ARCHITECTURE DECISION RECOMMENDATION")
    IO.puts(String.duplicate("=", 80))

    IO.puts("\n📊 EXTRACTED SIGNALS:")
    IO.puts(Jason.encode!(result.signals, pretty: true))

    IO.puts("\n🎯 DECISION:")
    IO.puts("  Pattern: #{result.decision.pattern_id}")
    IO.puts("  Outcome: #{result.decision.outcome}")
    IO.puts("  Score: #{result.decision.score}")
    IO.puts("  Summary: #{result.decision.summary}")

    if result.decision[:details] do
      IO.puts("\n📝 DETAILS:")
      Enum.each(result.decision.details, fn {key, value} ->
        if value do
          IO.puts("  #{key}:")
          Enum.each(List.wrap(value), fn item ->
            IO.puts("    • #{item}")
          end)
        end
      end)
    end

    IO.puts("\n💡 JUSTIFICATION:")
    IO.puts(result.justification)

    IO.puts("\n" <> String.duplicate("=", 80) <> "\n")
  end

  def print_result({:error, reason}) do
    IO.puts("\n❌ ERROR: #{inspect(reason)}\n")
  end
end
