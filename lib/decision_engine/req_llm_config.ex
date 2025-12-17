# lib/decision_engine/req_llm_config.ex
defmodule DecisionEngine.ReqLLMConfig do
  @moduledoc """
  Basic ReqLLM configuration module for the LLM integration refactor.

  This module provides basic configuration setup for ReqLLM integration,
  preparing the foundation for the gradual migration from direct HTTP calls.
  """

  require Logger

  @doc """
  Initializes basic ReqLLM configuration.

  Sets up the basic configuration structure needed for ReqLLM integration.
  This is the foundation for the gradual migration from direct HTTP calls.
  """
  def init_config do
    Logger.info("Initializing ReqLLM configuration")

    # Basic configuration setup - will be expanded in later tasks
    config = %{
      initialized: true,
      version: "1.0.0",
      migration_ready: false
    }

    # Store basic config in application environment for now
    Application.put_env(:decision_engine, :req_llm_config, config)

    Logger.info("ReqLLM configuration initialized")
    :ok
  end

  @doc """
  Gets the current ReqLLM configuration.
  """
  def get_config do
    case Application.get_env(:decision_engine, :req_llm_config) do
      nil -> {:error, :not_initialized}
      config -> {:ok, config}
    end
  end

  @doc """
  Checks if ReqLLM is initialized and ready for use.
  """
  def ready? do
    case get_config() do
      {:ok, %{initialized: true}} -> true
      _ -> false
    end
  end
end
