# lib/decision_engine.ex
defmodule DecisionEngine do
  @moduledoc """
  Main module that orchestrates the decision engine workflow.
  Supports multi-domain processing with automatic configuration loading.
  """

  require Logger
  alias DecisionEngine.Types

  @default_domain :power_platform

  @doc """
  Process a user scenario with domain-specific configuration and return a decision with justification.

  ## Parameters
  - scenario: The user's natural language description of their automation need
  - domain: The decision domain (:power_platform, :data_platform, :integration_platform)
  - config: LLM provider configuration map (see DecisionEngine.LLMClient for details)

  ## Returns
  {:ok, result} with the decision and justification including domain information, or {:error, reason}
  """
  @spec process(String.t(), Types.domain(), map()) :: {:ok, map()} | {:error, term()}
  def process(scenario, domain, config) when is_atom(domain) do
    Logger.info("Processing scenario for domain #{domain}: #{scenario}")

    with :ok <- validate_domain(domain),
         {:ok, rule_config} <- load_domain_configuration(domain),
         schema_module <- get_schema_module(domain),
         {:ok, signals} <- extract_domain_signals(scenario, config, domain, schema_module, rule_config),
         decision_result <- evaluate_domain_rules(signals, rule_config, domain),
         {:ok, justification} <- generate_domain_justification(signals, decision_result, config, domain) do

      # Render markdown justification to HTML
      rendered_html = DecisionEngine.MarkdownRenderer.render_to_html!(justification)
      
      result = %{
        domain: domain,
        signals: signals,
        decision: decision_result,
        justification: %{
          raw_markdown: justification,
          rendered_html: rendered_html
        },
        timestamp: DateTime.utc_now()
      }

      Logger.info("Decision made for domain #{domain}: #{decision_result.pattern_id}")
      {:ok, result}
    else
      {:error, reason} ->
        Logger.error("Processing failed for domain #{domain}: #{inspect(reason)}")
        {:error, format_domain_error(domain, reason)}
    end
  end

  @doc """
  Process a user scenario using the default domain for backward compatibility.

  ## Parameters
  - scenario: The user's natural language description of their automation need
  - config: LLM provider configuration map (see DecisionEngine.LLMClient for details)

  ## Returns
  {:ok, result} with the decision and justification, or {:error, reason}
  """
  @spec process(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def process(scenario, config) do
    Logger.info("Processing scenario with default domain (#{@default_domain}): #{scenario}")
    process(scenario, @default_domain, config)
  end

  @doc """
  Process a user scenario with streaming LLM justification generation.

  This function initiates streaming processing where the LLM justification is
  delivered progressively through Server-Sent Events (SSE). The function returns
  immediately with session information while the streaming continues in the background.

  ## Parameters
  - scenario: The user's natural language description of their automation need
  - domain: The decision domain (:power_platform, :data_platform, :integration_platform)
  - config: LLM provider configuration map (must support streaming)
  - session_id: Unique identifier for the streaming session

  ## Returns
  {:ok, result} with immediate processing results and streaming session info, or {:error, reason}

  The result includes:
  - domain: The domain used for processing
  - signals: Extracted signals from the scenario
  - decision: Rule engine evaluation result
  - streaming: true to indicate streaming mode
  - session_id: Session identifier for tracking the stream
  - timestamp: Processing start time

  ## Streaming Protocol
  The actual justification content is delivered through SSE events to the session.
  If streaming fails, the function will automatically fall back to traditional processing.

  ## Examples
      {:ok, result} = DecisionEngine.process_streaming(scenario, :power_platform, config, "session-123")
      # result.streaming == true
      # Justification content delivered via SSE to session "session-123"
  """
  @spec process_streaming(String.t(), Types.domain(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def process_streaming(scenario, domain, config, session_id) when is_atom(domain) and is_binary(session_id) do
    Logger.info("Processing scenario with streaming for domain #{domain}, session #{session_id}: #{scenario}")

    with :ok <- validate_domain(domain),
         :ok <- validate_session_id(session_id),
         {:ok, rule_config} <- load_domain_configuration(domain),
         schema_module <- get_schema_module(domain),
         {:ok, signals} <- extract_domain_signals(scenario, config, domain, schema_module, rule_config),
         decision_result <- evaluate_domain_rules(signals, rule_config, domain) do

      # Check if StreamManager is available for this session
      case DecisionEngine.StreamManager.get_stream_status(session_id) do
        {:ok, _status} ->
          # StreamManager exists, initiate streaming
          case DecisionEngine.StreamManager.stream_processing(session_id, signals, decision_result, config, domain) do
            :ok ->
              result = %{
                domain: domain,
                signals: signals,
                decision: decision_result,
                streaming: true,
                session_id: session_id,
                timestamp: DateTime.utc_now()
              }

              Logger.info("Streaming initiated for domain #{domain}, session #{session_id}")
              {:ok, result}

            {:error, stream_reason} ->
              Logger.warning("Streaming failed for session #{session_id}: #{inspect(stream_reason)}, falling back to traditional processing")
              fallback_to_traditional_processing(domain, config, signals, decision_result)
          end

        {:error, :not_found} ->
          Logger.warning("StreamManager not found for session #{session_id}, falling back to traditional processing")
          fallback_to_traditional_processing(domain, config, signals, decision_result)
      end
    else
      {:error, reason} ->
        Logger.error("Streaming processing failed for domain #{domain}, session #{session_id}: #{inspect(reason)}")
        {:error, format_domain_error(domain, reason)}
    end
  end

  @doc """
  Process a user scenario with streaming using the default domain.

  ## Parameters
  - scenario: The user's natural language description of their automation need
  - config: LLM provider configuration map (must support streaming)
  - session_id: Unique identifier for the streaming session

  ## Returns
  {:ok, result} with streaming session info, or {:error, reason}
  """
  @spec process_streaming(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def process_streaming(scenario, config, session_id) do
    Logger.info("Processing scenario with streaming using default domain (#{@default_domain}), session #{session_id}: #{scenario}")
    process_streaming(scenario, @default_domain, config, session_id)
  end

  # Private helper functions for domain-specific processing

  defp validate_domain(domain) do
    # Use dynamic domain discovery instead of hardcoded list
    available_domains = DecisionEngine.DomainManager.list_available_domains()
    
    if domain in available_domains do
      :ok
    else
      {:error, {:invalid_domain, domain, available_domains}}
    end
  end

  defp load_domain_configuration(domain) do
    case DecisionEngine.RuleConfig.load(domain) do
      {:ok, rule_config} ->
        Logger.debug("Successfully loaded configuration for domain #{domain}")
        {:ok, rule_config}
      
      {:error, reason} ->
        Logger.error("Failed to load configuration for domain #{domain}: #{inspect(reason)}")
        {:error, {:configuration_load_failed, domain, reason}}
    end
  end

  defp get_schema_module(domain) do
    schema_module = DecisionEngine.SignalsSchema.module_for(domain)
    Logger.debug("Using schema module #{schema_module} for domain #{domain}")
    schema_module
  end

  defp extract_domain_signals(scenario, config, domain, schema_module, rule_config) do
    case DecisionEngine.LLMClient.extract_signals(scenario, config, domain, schema_module, rule_config) do
      {:ok, signals} ->
        Logger.debug("Successfully extracted signals for domain #{domain}: #{inspect(Map.keys(signals))}")
        {:ok, signals}
      
      {:error, reason} ->
        Logger.error("Signal extraction failed for domain #{domain}: #{inspect(reason)}")
        {:error, {:signal_extraction_failed, domain, reason}}
    end
  end

  defp evaluate_domain_rules(signals, rule_config, domain) do
    Logger.debug("Evaluating rules for domain #{domain}")
    decision_result = DecisionEngine.RuleEngine.evaluate(signals, rule_config)
    Logger.debug("Rule evaluation completed for domain #{domain}: #{decision_result.pattern_id}")
    decision_result
  end

  defp generate_domain_justification(signals, decision_result, config, domain) do
    case DecisionEngine.LLMClient.generate_justification(signals, decision_result, config, domain) do
      {:ok, justification} ->
        Logger.debug("Successfully generated justification for domain #{domain}")
        {:ok, justification}
      
      {:error, reason} ->
        Logger.error("Justification generation failed for domain #{domain}: #{inspect(reason)}")
        {:error, {:justification_failed, domain, reason}}
    end
  end

  defp format_domain_error(domain, reason) do
    domain_name = domain |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
    
    case reason do
      {:invalid_domain, invalid_domain, supported_domains} ->
        "Invalid domain '#{invalid_domain}'. Supported domains: #{inspect(supported_domains)}"
      
      {:invalid_session_id, msg} ->
        "Invalid session ID: #{msg}"
      
      {:configuration_load_failed, ^domain, config_reason} ->
        "Failed to load configuration for #{domain_name}: #{format_config_error(config_reason)}"
      
      {:signal_extraction_failed, ^domain, extraction_reason} ->
        "Signal extraction failed for #{domain_name}: #{format_extraction_error(extraction_reason)}"
      
      {:justification_failed, ^domain, justification_reason} ->
        "Justification generation failed for #{domain_name}: #{format_justification_error(justification_reason)}"
      
      other ->
        "Processing failed for #{domain_name}: #{inspect(other)}"
    end
  end

  defp format_config_error(reason) do
    case reason do
      :enoent -> "Configuration file not found. Ensure the domain configuration exists in priv/rules/"
      {:invalid_json, _} -> "Configuration file contains invalid JSON"
      {:validation_failed, msg} -> "Configuration validation failed: #{msg}"
      other -> inspect(other)
    end
  end

  defp format_extraction_error(reason) do
    case reason do
      "Failed to call LLM API: " <> api_error -> "LLM API error: #{api_error}"
      "Failed to parse LLM response" <> _ -> "LLM response parsing failed - invalid JSON format"
      other -> inspect(other)
    end
  end

  defp format_justification_error(reason) do
    case reason do
      "Failed to generate justification for domain " <> _ -> "LLM justification generation failed"
      other -> inspect(other)
    end
  end

  # Validates that the session ID is properly formatted
  defp validate_session_id(session_id) when is_binary(session_id) do
    if String.length(session_id) > 0 and String.length(session_id) <= 255 do
      :ok
    else
      {:error, {:invalid_session_id, "Session ID must be between 1 and 255 characters"}}
    end
  end
  defp validate_session_id(_), do: {:error, {:invalid_session_id, "Session ID must be a string"}}

  # Fallback mechanism when streaming is not available or fails
  defp fallback_to_traditional_processing(domain, config, signals, decision_result) do
    Logger.info("Falling back to traditional processing for domain #{domain}")
    
    case generate_domain_justification(signals, decision_result, config, domain) do
      {:ok, justification} ->
        # Render markdown justification to HTML
        rendered_html = DecisionEngine.MarkdownRenderer.render_to_html!(justification)
        
        result = %{
          domain: domain,
          signals: signals,
          decision: decision_result,
          justification: %{
            raw_markdown: justification,
            rendered_html: rendered_html
          },
          streaming: false,
          fallback_reason: "streaming_unavailable",
          timestamp: DateTime.utc_now()
        }

        Logger.info("Fallback processing completed for domain #{domain}")
        {:ok, result}
      
      {:error, reason} ->
        Logger.error("Fallback processing failed for domain #{domain}: #{inspect(reason)}")
        {:error, {:justification_failed, domain, reason}}
    end
  end

  @doc """
  Pretty print the decision result with domain information.
  """
  def print_result({:ok, result}) do
    domain_name = if Map.has_key?(result, :domain) do
      result.domain |> Atom.to_string() |> String.replace("_", " ") |> String.upcase()
    else
      "POWER PLATFORM"  # Backward compatibility
    end

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("#{domain_name} ARCHITECTURE DECISION RECOMMENDATION")
    IO.puts(String.duplicate("=", 80))

    if Map.has_key?(result, :domain) do
      IO.puts("\n🏢 DOMAIN: #{domain_name}")
    end

    # Handle streaming vs traditional results
    if Map.get(result, :streaming, false) do
      IO.puts("\n🔄 STREAMING MODE: Active")
      IO.puts("📡 SESSION ID: #{result.session_id}")
      IO.puts("⏰ STARTED: #{result.timestamp}")
      IO.puts("\n📊 EXTRACTED SIGNALS:")
      IO.puts(Jason.encode!(result.signals, pretty: true))

      IO.puts("\n🎯 DECISION:")
      IO.puts("  Pattern: #{result.decision.pattern_id}")
      IO.puts("  Outcome: #{result.decision.outcome}")
      IO.puts("  Score: #{result.decision.score}")
      IO.puts("  Summary: #{result.decision.summary}")

      IO.puts("\n💡 JUSTIFICATION: Streaming in progress...")
      IO.puts("   Connect to SSE endpoint to receive real-time justification")
    else
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

      # Handle both old and new justification formats
      justification_content = case result[:justification] do
        %{raw_markdown: markdown} -> markdown
        %{"raw_markdown" => markdown} -> markdown
        text when is_binary(text) -> text
        _ -> "No justification available"
      end

      IO.puts("\n💡 JUSTIFICATION:")
      IO.puts(justification_content)

      # Show fallback information if applicable
      if Map.has_key?(result, :fallback_reason) do
        IO.puts("\n⚠️  FALLBACK: Streaming was unavailable (#{result.fallback_reason})")
      end
    end

    IO.puts("\n" <> String.duplicate("=", 80) <> "\n")
  end

  def print_result({:error, reason}) do
    IO.puts("\n❌ ERROR: #{reason}\n")
  end
end
