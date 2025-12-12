defmodule DecisionEngine.SignalsSchema.Behaviour do
  @moduledoc """
  Behaviour for domain-specific signal schema modules.
  
  Each domain schema module must implement this behaviour to provide
  consistent schema access and signal processing capabilities.
  """

  @doc """
  Returns the JSON schema definition for the domain.
  """
  @callback schema() :: map()

  @doc """
  Applies domain-specific default values to signals.
  """
  @callback apply_defaults(map()) :: map()
end