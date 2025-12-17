# lib/decision_engine/pdf_processor.ex
defmodule DecisionEngine.PDFProcessor do
  @moduledoc """
  Processes PDF files to extract text content for LLM-based domain rule generation.

  This module handles PDF upload, text extraction, and integration with LLM services
  to generate domain configurations from reference documents.
  """

  require Logger

  @doc """
  Processes an uploaded PDF file and generates domain rules using LLM analysis with comprehensive error handling and retry mechanisms.

  ## Parameters
  - pdf_path: String path to the uploaded PDF file
  - domain_name: String name for the new domain
  - llm_config: Map containing LLM configuration (optional, uses default if not provided)

  ## Returns
  - {:ok, domain_config} with generated domain configuration
  - {:error, reason} on failure

  ## Error Handling
  - Implements retry mechanisms for transient failures
  - Provides fallback options for processing failures
  - Ensures graceful degradation when LLM services are unavailable
  """
  @spec process_pdf_for_domain(String.t(), String.t(), map() | nil) ::
    {:ok, map()} | {:error, term()}
  def process_pdf_for_domain(pdf_path, domain_name, llm_config \\ nil) do
    process_pdf_with_retry(pdf_path, domain_name, llm_config, 0, 3)
  end

  @doc """
  Processes PDF with retry logic and comprehensive error recovery.

  ## Parameters
  - pdf_path: String path to the uploaded PDF file
  - domain_name: String name for the new domain
  - llm_config: Map containing LLM configuration
  - retry_count: Current retry attempt
  - max_retries: Maximum number of retries allowed

  ## Returns
  - {:ok, domain_config} with generated domain configuration
  - {:error, reason} on failure
  """
  @spec process_pdf_with_retry(String.t(), String.t(), map() | nil, integer(), integer()) ::
    {:ok, map()} | {:error, term()}
  def process_pdf_with_retry(pdf_path, domain_name, llm_config, retry_count, max_retries) do
    with {:ok, text_content} <- extract_text_from_pdf_with_fallback(pdf_path),
         {:ok, config} <- get_llm_config_with_fallback(llm_config),
         {:ok, domain_config} <- generate_domain_from_text_with_retry(text_content, domain_name, config, retry_count, max_retries) do
      {:ok, domain_config}
    else
      {:error, reason} when retry_count < max_retries ->
        case should_retry_error?(reason) do
          {:retry, delay} ->
            Logger.warning("PDF processing failed, retrying in #{delay}ms (attempt #{retry_count + 1}/#{max_retries}): #{inspect(reason)}")
            Process.sleep(delay)
            process_pdf_with_retry(pdf_path, domain_name, llm_config, retry_count + 1, max_retries)

          :no_retry ->
            {:error, enhance_error_message(reason)}
        end

      {:error, reason} ->
        {:error, enhance_error_message(reason)}
    end
  end

  @doc """
  Processes an uploaded PDF file with streaming support for real-time feedback.

  ## Parameters
  - pdf_path: String path to the uploaded PDF file
  - domain_name: String name for the new domain
  - stream_pid: Process ID to receive streaming updates
  - llm_config: Map containing LLM configuration (optional, uses default if not provided)

  ## Returns
  - {:ok, domain_config} with generated domain configuration
  - {:error, reason} on failure

  ## Streaming Events
  The stream_pid will receive messages:
  - {:processing_step, step_name, progress_percent} - Processing progress updates
  - {:content_chunk, chunk} - Partial LLM response chunks
  - {:processing_complete, domain_config} - Final result
  - {:processing_error, reason} - Error occurred
  """
  @spec process_pdf_for_domain_streaming(String.t(), String.t(), pid(), map() | nil) ::
    {:ok, map()} | {:error, term()}
  def process_pdf_for_domain_streaming(pdf_path, domain_name, stream_pid, llm_config \\ nil) do
    try do
      # Step 0: Initialize processing
      send(stream_pid, {:processing_step, "Initializing PDF processing", 0, "Preparing to analyze your document..."})
      Process.sleep(200) # Brief pause for UI feedback

      # Step 1: Validate domain name first
      case validate_domain_name(domain_name) do
        :ok ->
          send(stream_pid, {:processing_step, "Validating PDF file", 5, "Checking file format and structure..."})

          # Step 2: Extract text from PDF
          send(stream_pid, {:processing_step, "Extracting text from PDF", 15, "Reading document content - this may take a moment for large files..."})

          case extract_text_from_pdf(pdf_path) do
            {:ok, text_content} ->
              content_length = String.length(text_content)
              send(stream_pid, {:processing_step, "Text extraction complete", 30, "Successfully extracted #{content_length} characters of text"})

              # Step 3: Validate content quality
              send(stream_pid, {:processing_step, "Analyzing content quality", 35, "Checking if content is suitable for domain generation..."})

              case validate_content_for_llm(text_content, domain_name) do
                :ok ->
                  # Step 4: Get LLM configuration
                  send(stream_pid, {:processing_step, "Connecting to AI service", 40, "Establishing connection with language model..."})

                  case get_llm_config(llm_config) do
                    {:ok, config} ->
                      send(stream_pid, {:processing_step, "Preparing AI analysis", 45, "Structuring content for intelligent analysis..."})

                      # Step 5: Generate domain configuration with streaming
                      case generate_domain_from_text_streaming(text_content, domain_name, config, stream_pid) do
                        {:ok, domain_config} ->
                          send(stream_pid, {:processing_step, "Finalizing domain configuration", 95, "Validating and formatting the generated domain..."})
                          Process.sleep(500) # Allow UI to show completion
                          send(stream_pid, {:processing_step, "Domain generation complete", 100, "Successfully created domain configuration!"})
                          send(stream_pid, {:processing_complete, domain_config})
                          {:ok, domain_config}

                        {:error, reason} ->
                          send(stream_pid, {:processing_error, reason})
                          {:error, reason}
                      end

                    {:error, reason} ->
                      send(stream_pid, {:processing_error, reason})
                      {:error, reason}
                  end

                {:error, reason} ->
                  send(stream_pid, {:processing_error, reason})
                  {:error, reason}
              end

            {:error, reason} ->
              send(stream_pid, {:processing_error, reason})
              {:error, reason}
          end

        {:error, reason} ->
          send(stream_pid, {:processing_error, reason})
          {:error, reason}
      end
    rescue
      error ->
        send(stream_pid, {:processing_error, "Processing exception: #{inspect(error)}"})
        {:error, "Processing exception: #{inspect(error)}"}
    end
  end

  defp validate_domain_name(domain_name) do
    cond do
      String.trim(domain_name) == "" ->
        {:error, "Domain name cannot be empty"}

      not String.match?(domain_name, ~r/^[a-zA-Z0-9\s_-]+$/) ->
        {:error, "Domain name contains invalid characters. Use only letters, numbers, spaces, hyphens, and underscores."}

      true ->
        :ok
    end
  end

  @doc """
  Processes an uploaded PDF file with concurrent reflection enhancement.

  This function provides non-blocking PDF processing by queuing the reflection
  enhancement for concurrent processing. The initial domain configuration is
  returned immediately, and reflection enhancement is processed asynchronously.

  ## Parameters
  - pdf_path: String path to the uploaded PDF file
  - domain_name: String name for the new domain
  - llm_config: Map containing LLM configuration (optional, uses default if not provided)
  - reflection_options: Map containing reflection configuration and callback settings

  ## Returns
  - {:ok, {domain_config, request_id}} with initial domain config and reflection request ID
  - {:error, reason} on failure

  ## Concurrent Processing Behavior
  - Returns initial domain configuration immediately
  - Queues reflection enhancement for background processing
  - Provides request_id for tracking reflection progress
  - Supports callback notifications for completion
  """
  @spec process_pdf_for_domain_with_concurrent_reflection(String.t(), String.t(), map() | nil, map() | nil) ::
    {:ok, {map(), String.t() | nil}} | {:error, term()}
  def process_pdf_for_domain_with_concurrent_reflection(pdf_path, domain_name, llm_config \\ nil, reflection_options \\ nil) do
    # First, perform standard PDF processing
    case process_pdf_for_domain(pdf_path, domain_name, llm_config) do
      {:ok, initial_domain_config} ->
        # Check if reflection is enabled and should be triggered
        if should_trigger_reflection?() do
          Logger.info("Reflection enabled, queuing concurrent reflection for domain: #{domain_name}")

          # Prepare reflection options for concurrent processing
          concurrent_options = prepare_concurrent_reflection_options(reflection_options, domain_name)

          case DecisionEngine.ReflectionCoordinator.start_reflection_async(initial_domain_config, concurrent_options) do
            {:ok, request_id} ->
              Logger.info("Queued reflection request #{request_id} for domain: #{domain_name}")
              {:ok, {initial_domain_config, request_id}}

            {:error, reason} ->
              Logger.warning("Failed to queue reflection for domain #{domain_name}: #{reason}")
              # Fallback to returning original config without reflection
              case Map.get(reflection_options || %{}, :fallback_on_queue_failure, true) do
                true ->
                  Logger.info("Falling back to original configuration for domain: #{domain_name}")
                  {:ok, {initial_domain_config, nil}}

                false ->
                  {:error, "Failed to queue reflection: #{reason}"}
              end
          end
        else
          Logger.debug("Reflection disabled, returning original domain configuration")
          {:ok, {initial_domain_config, nil}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Extracts text content from a PDF file with comprehensive validation and error handling.

  ## Parameters
  - pdf_path: String path to the PDF file

  ## Returns
  - {:ok, text_content} with extracted text
  - {:error, reason} on failure
  """
  @spec extract_text_from_pdf(String.t()) :: {:ok, String.t()} | {:error, term()}
  def extract_text_from_pdf(pdf_path) do
    with :ok <- validate_file_exists(pdf_path),
         :ok <- validate_file_size(pdf_path),
         :ok <- validate_pdf_format(pdf_path),
         {:ok, text} <- perform_text_extraction(pdf_path) do
      {:ok, text}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Extracts text content from a PDF file with enhanced fallback mechanisms and error recovery.

  ## Parameters
  - pdf_path: String path to the PDF file

  ## Returns
  - {:ok, text_content} with extracted text
  - {:error, reason} on failure with enhanced error messages
  """
  @spec extract_text_from_pdf_with_fallback(String.t()) :: {:ok, String.t()} | {:error, term()}
  def extract_text_from_pdf_with_fallback(pdf_path) do
    case extract_text_from_pdf(pdf_path) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        # Try alternative extraction methods for common issues
        cond do
          is_binary(reason) and String.contains?(reason, "PDF text extraction requires") and String.contains?(reason, "pdftotext") ->
            try_alternative_extraction_methods(pdf_path)

          reason == "Failed to extract text from PDF using all available methods" ->
            try_emergency_fallback(pdf_path)

          is_binary(reason) and String.contains?(reason, "PDF file appears to be corrupted") ->
            try_corrupted_pdf_recovery(pdf_path)

          true ->
            {:error, reason}
        end
    end
  end

  @doc """
  Validates that a file is a valid PDF with comprehensive format checking.

  ## Parameters
  - file_path: String path to the file

  ## Returns
  - :ok if file is a valid PDF
  - {:error, reason} if not valid
  """
  @spec validate_pdf(String.t()) :: :ok | {:error, String.t()}
  def validate_pdf(file_path) do
    with :ok <- validate_file_exists(file_path),
         :ok <- validate_file_size(file_path),
         :ok <- validate_pdf_format(file_path) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates file size to ensure it's within acceptable limits.

  ## Parameters
  - file_path: String path to the file

  ## Returns
  - :ok if file size is acceptable
  - {:error, reason} if file is too large
  """
  @spec validate_file_size(String.t()) :: :ok | {:error, String.t()}
  def validate_file_size(file_path) do
    max_size = Application.get_env(:decision_engine, :max_pdf_size, 50 * 1024 * 1024) # 50MB default

    case File.stat(file_path) do
      {:ok, %File.Stat{size: size}} when size <= max_size ->
        :ok
      {:ok, %File.Stat{size: size}} ->
        size_mb = Float.round(size / (1024 * 1024), 2)
        max_mb = Float.round(max_size / (1024 * 1024), 2)
        {:error, "File size #{size_mb}MB exceeds maximum allowed size of #{max_mb}MB"}
      {:error, reason} ->
        {:error, "Cannot read file stats: #{inspect(reason)}"}
    end
  end

  # Private Functions

  defp validate_file_exists(file_path) do
    if File.exists?(file_path) do
      :ok
    else
      {:error, "File does not exist: #{file_path}"}
    end
  end

  defp validate_pdf_format(file_path) do
    case File.open(file_path, [:read, :binary]) do
      {:ok, file} ->
        result = case IO.binread(file, 8) do
          <<"%PDF-", version::binary-size(3)>> ->
            # Check if version is valid (1.0 to 2.0)
            case version do
              v when v in ["1.0", "1.1", "1.2", "1.3", "1.4", "1.5", "1.6", "1.7", "2.0"] ->
                # Additional validation: check for EOF marker
                validate_pdf_structure(file)
              _ ->
                {:error, "Unsupported PDF version: #{version}"}
            end
          <<"%PDF">> ->
            # Fallback for PDFs without clear version
            validate_pdf_structure(file)
          _other ->
            {:error, "File is not a valid PDF format"}
        end
        File.close(file)
        result
      {:error, reason} ->
        {:error, "Cannot read file: #{inspect(reason)}"}
    end
  end

  defp validate_pdf_structure(file) do
    # Seek to end of file to check for proper PDF structure
    case :file.position(file, {:eof, -1024}) do
      {:ok, _pos} ->
        case IO.binread(file, 1024) do
          data when is_binary(data) ->
            if String.contains?(data, "%%EOF") do
              :ok
            else
              {:error, "PDF file appears to be corrupted or incomplete"}
            end
          _ ->
            {:error, "Cannot read PDF file structure"}
        end
      {:error, _reason} ->
        # File might be smaller than 1024 bytes, check from beginning
        :file.position(file, 0)
        case IO.binread(file, :eof) do
          data when is_binary(data) ->
            if String.contains?(data, "%%EOF") or byte_size(data) < 1024 do
              :ok
            else
              {:error, "PDF file appears to be corrupted"}
            end
          _ ->
            {:error, "Cannot read PDF file"}
        end
    end
  end

  defp perform_text_extraction(pdf_path) do
    try do
      # Check if pdftotext is available
      case System.cmd("pdftotext", ["-v"], stderr_to_stdout: true) do
        {output, _exit_code} when is_binary(output) and byte_size(output) > 0 ->
          # pdftotext -v returns version info regardless of exit code
          extract_with_pdftotext(pdf_path)
        {_error, _exit_code} ->
          {:error, "PDF text extraction requires 'pdftotext' command. Please install poppler-utils package."}
      end
    rescue
      error ->
        Logger.error("Exception during PDF processing: #{inspect(error)}")
        case error do
          %ErlangError{original: :enoent} ->
            {:error, "PDF text extraction requires 'pdftotext' command. Please install poppler-utils package."}
          _ ->
            {:error, "PDF processing exception: #{inspect(error)}"}
        end
    end
  end

  defp extract_with_pdftotext(pdf_path) do
    # Try different extraction methods for better compatibility
    extraction_methods = [
      # Standard extraction
      [pdf_path, "-"],
      # Layout preservation for complex documents
      ["-layout", pdf_path, "-"],
      # Raw text extraction for corrupted files
      ["-raw", pdf_path, "-"],
      # No page breaks between pages
      ["-nopgbrk", pdf_path, "-"]
    ]

    extract_with_fallback(extraction_methods, pdf_path)
  end

  defp extract_with_fallback([], pdf_path) do
    Logger.error("All PDF extraction methods failed for: #{pdf_path}")
    {:error, "Failed to extract text from PDF using all available methods"}
  end

  defp extract_with_fallback([method | remaining_methods], pdf_path) do
    Logger.info("Trying pdftotext with method: #{inspect(method)} for file: #{pdf_path}")
    Logger.info("File exists: #{File.exists?(pdf_path)}")
    case System.cmd("pdftotext", method, stderr_to_stdout: true) do
      {text_content, 0} when byte_size(text_content) > 0 ->
        cleaned_text = clean_extracted_text(text_content)
        if String.trim(cleaned_text) != "" do
          {:ok, cleaned_text}
        else
          # Text extraction succeeded but no meaningful content
          extract_with_fallback(remaining_methods, pdf_path)
        end

      {_text_content, 0} ->
        # Empty content, try next method
        Logger.warning("PDF extraction returned empty content, trying next method")
        extract_with_fallback(remaining_methods, pdf_path)

      {error_output, exit_code} ->
        Logger.warning("PDF extraction method failed (exit code #{exit_code}): #{error_output}")

        # Check if this is a specific error we can handle
        cond do
          String.contains?(error_output, "Couldn't open file") ->
            {:error, "Cannot open PDF file - file may be corrupted or password protected"}

          String.contains?(error_output, "Command Line Error") ->
            extract_with_fallback(remaining_methods, pdf_path)

          String.contains?(error_output, "Syntax Error") ->
            {:error, "PDF file has syntax errors and cannot be processed"}

          exit_code == 1 and remaining_methods != [] ->
            # Try next method for generic errors
            extract_with_fallback(remaining_methods, pdf_path)

          true ->
            {:error, "PDF text extraction failed: #{error_output}"}
        end
    end
  end

  defp get_llm_config(nil) do
    # Use LLMConfigManager for centralized configuration
    case DecisionEngine.LLMConfigManager.get_current_config() do
      {:ok, config} ->
        {:ok, config}
      {:error, :api_key_required} ->
        {:error, :no_api_key_configured}
      {:error, reason} ->
        Logger.warning("Failed to get LLM config from LLMConfigManager: #{inspect(reason)}")
        {:error, :no_llm_config_available}
    end
  end
  defp get_llm_config(config), do: {:ok, config}

  defp generate_domain_from_text(text_content, domain_name, config) do
    prompt = build_domain_generation_prompt(text_content, domain_name)

    case DecisionEngine.ReqLLMMigrationCoordinator.generate_text(prompt, config) do
      {:ok, response} ->
        parse_domain_config_response(response, domain_name)
      {:error, reason} ->
        {:error, {:llm_call_failed, reason}}
    end
  end

  defp generate_domain_from_text_streaming(text_content, domain_name, config, stream_pid) do
    # Content validation already done in main function
    send(stream_pid, {:processing_step, "Building AI prompt", 50, "Structuring your document content for analysis..."})

    prompt = build_enhanced_domain_generation_prompt(text_content, domain_name)

    send(stream_pid, {:processing_step, "Starting AI analysis", 55, "Sending content to AI for intelligent processing..."})

    # Start streaming LLM generation
    case start_streaming_generation(prompt, config, stream_pid) do
      {:ok, response} ->
        send(stream_pid, {:processing_step, "Processing AI response", 85, "Parsing and validating the generated domain configuration..."})

        case parse_domain_config_response(response, domain_name) do
          {:ok, domain_config} ->
            send(stream_pid, {:processing_step, "Validating configuration", 90, "Ensuring domain configuration meets quality standards..."})
            {:ok, domain_config}
          {:error, reason} ->
            {:error, {:config_parsing_failed, reason}}
        end
      {:error, reason} ->
        {:error, {:llm_call_failed, reason}}
    end
  end

  defp start_streaming_generation(prompt, config, stream_pid) do
    # Create a collector process to accumulate streaming chunks
    parent_pid = self()  # Capture the actual parent PID before spawning
    collector_pid = spawn_link(fn ->
      collect_streaming_response("", stream_pid, parent_pid, 60)  # Start at 60% progress
    end)

    send(stream_pid, {:processing_step, "AI is analyzing your document", 60, "The AI is reading and understanding your content..."})

    # Start LLM streaming with enhanced error handling and rate limiting
    case DecisionEngine.LLMClient.stream_justification(%{}, %{recommendation: prompt}, config, :domain_generation, collector_pid) do
      :ok ->
        # Wait for the collector to finish and return the result
        receive do
          {:streaming_complete, response} ->
            send(stream_pid, {:processing_step, "AI analysis complete", 80, "Successfully generated domain configuration from your document"})
            {:ok, response}
          {:streaming_error, reason} -> {:error, reason}
        after
          600_000 ->  # Increased to 10 minutes for local LLMs
            send(stream_pid, {:processing_step, "Processing timeout", 60, "AI analysis is taking longer than expected..."})
            {:error, :streaming_timeout}  # 10 minute timeout
        end

      {:error, reason} ->
        # Fallback to non-streaming if streaming fails
        Logger.warning("Streaming failed, falling back to non-streaming: #{inspect(reason)}")
        send(stream_pid, {:processing_step, "Switching to standard processing", 65, "Streaming unavailable, using standard AI processing..."})

        case DecisionEngine.ReqLLMMigrationCoordinator.generate_text(prompt, config) do
          {:ok, response} ->
            send(stream_pid, {:processing_step, "AI analysis complete", 80, "Successfully generated domain configuration"})
            {:ok, response}
          {:error, fallback_reason} ->
            {:error, fallback_reason}
        end
    end
  end

  defp collect_streaming_response(accumulated, stream_pid, parent_pid, base_progress) do
    receive do
      {:chunk, content} ->
        # Forward chunk to the main stream process
        send(stream_pid, {:content_chunk, content})

        # Update progress based on content length (rough estimation)
        new_length = String.length(accumulated <> content)
        estimated_progress = min(base_progress + trunc(new_length / 50), 78) # Cap at 78% during streaming

        # Send progress update every few chunks to avoid overwhelming the UI
        if rem(new_length, 200) < 50 do
          send(stream_pid, {:processing_step, "AI is generating domain rules", estimated_progress, "Creating intelligent patterns from your document..."})
        end

        collect_streaming_response(accumulated <> content, stream_pid, parent_pid, base_progress)

      {:complete} ->
        Logger.info("Streaming complete. Accumulated content length: #{String.length(accumulated)} characters")
        Logger.info("Accumulated content preview (first 200 chars): #{String.slice(accumulated, 0, 200)}")
        send(stream_pid, {:processing_step, "AI generation complete", 78, "Domain rules successfully generated"})
        send(parent_pid, {:streaming_complete, accumulated})

      {:error, reason} ->
        send(parent_pid, {:streaming_error, reason})
    after
      300_000 -> # 5 minute timeout for individual chunks (increased for local LLMs)
        send(stream_pid, {:processing_step, "Processing timeout", base_progress, "AI processing is taking longer than expected..."})
        send(parent_pid, {:streaming_error, :chunk_timeout})
    end
  end

  @doc """
  Extracts and structures business rules from PDF content for LLM analysis.

  ## Parameters
  - text_content: String containing extracted PDF text
  - domain_name: String name for the domain

  ## Returns
  - {:ok, structured_content} with organized business rules
  - {:error, reason} on failure
  """
  @spec extract_business_rules(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def extract_business_rules(text_content, domain_name) do
    try do
      structured_content = %{
        domain_name: domain_name,
        raw_content: text_content,
        business_rules: identify_business_rules(text_content),
        decision_points: identify_decision_points(text_content),
        process_descriptions: identify_process_descriptions(text_content),
        key_terms: extract_key_terms(text_content)
      }

      {:ok, structured_content}
    rescue
      error ->
        Logger.error("Failed to extract business rules: #{inspect(error)}")
        {:error, "Business rules extraction failed: #{inspect(error)}"}
    end
  end

  defp identify_business_rules(text) do
    # Look for common business rule patterns
    rule_patterns = [
      ~r/(?:if|when|where)\s+.+?(?:then|shall|must|should)\s+.+?(?:\.|;|\n)/i,
      ~r/(?:rule|policy|requirement)\s*\d*:?\s*.+?(?:\.|;|\n\n)/i,
      ~r/(?:must|shall|should|will)\s+(?:not\s+)?[^.]+\./i
    ]

    Enum.flat_map(rule_patterns, fn pattern ->
      Regex.scan(pattern, text)
      |> Enum.map(fn [match | _] -> match end)
    end)
    |> Enum.uniq()
    |> Enum.take(20) # Limit to most relevant rules
  end

  defp identify_decision_points(text) do
    # Look for decision-making language
    decision_patterns = [
      ~r/(?:decide|determine|choose|select|evaluate)\s+[^.]+\./i,
      ~r/(?:criteria|condition|requirement)\s+for\s+[^.]+\./i,
      ~r/(?:approve|reject|accept|deny)\s+[^.]+\./i
    ]

    Enum.flat_map(decision_patterns, fn pattern ->
      Regex.scan(pattern, text)
      |> Enum.map(fn [match | _] -> match end)
    end)
    |> Enum.uniq()
    |> Enum.take(15)
  end

  defp identify_process_descriptions(text) do
    # Look for process flow descriptions
    process_patterns = [
      ~r/(?:step|phase|stage)\s+\d+[^.]+\./i,
      ~r/(?:first|next|then|finally|lastly)[^.]+\./i,
      ~r/(?:process|procedure|workflow)\s+[^.]+\./i
    ]

    Enum.flat_map(process_patterns, fn pattern ->
      Regex.scan(pattern, text)
      |> Enum.map(fn [match | _] -> match end)
    end)
    |> Enum.uniq()
    |> Enum.take(10)
  end

  defp extract_key_terms(text) do
    # Extract important domain-specific terms
    # Look for capitalized terms, technical terms, and repeated important words
    words = String.split(text, ~r/\W+/)

    # Find capitalized terms (likely important concepts)
    capitalized_terms =
      words
      |> Enum.filter(&(String.match?(&1, ~r/^[A-Z][a-z]+$/)))
      |> Enum.frequencies()
      |> Enum.filter(fn {_term, count} -> count >= 2 end)
      |> Enum.sort_by(fn {_term, count} -> count end, :desc)
      |> Enum.take(20)
      |> Enum.map(fn {term, _count} -> term end)

    # Find technical terms (words with specific patterns)
    technical_terms =
      words
      |> Enum.filter(&(String.length(&1) > 4 and String.match?(&1, ~r/[A-Z]/)))
      |> Enum.frequencies()
      |> Enum.filter(fn {_term, count} -> count >= 2 end)
      |> Enum.sort_by(fn {_term, count} -> count end, :desc)
      |> Enum.take(15)
      |> Enum.map(fn {term, _count} -> term end)

    (capitalized_terms ++ technical_terms)
    |> Enum.uniq()
    |> Enum.take(25)
  end

  defp build_domain_generation_prompt(text_content, domain_name) do
    # Extract structured business rules first
    case extract_business_rules(text_content, domain_name) do
      {:ok, structured_content} ->
        build_enhanced_prompt(structured_content)
      {:error, _reason} ->
        # Fallback to basic prompt if business rules extraction fails
        build_basic_prompt(text_content, domain_name)
    end
  end

  defp build_enhanced_domain_generation_prompt(text_content, domain_name) do
    # Extract structured business rules with enhanced analysis
    case extract_business_rules(text_content, domain_name) do
      {:ok, structured_content} ->
        build_specialized_domain_prompt(structured_content)
      {:error, _reason} ->
        # Fallback to enhanced basic prompt
        build_enhanced_basic_prompt(text_content, domain_name)
    end
  end

  defp build_enhanced_prompt(structured_content) do
    %{
      domain_name: domain_name,
      business_rules: business_rules,
      decision_points: decision_points,
      process_descriptions: process_descriptions,
      key_terms: key_terms,
      raw_content: raw_content
    } = structured_content

    """
    Based on the following structured document analysis, generate a decision domain configuration for "#{domain_name}".

    ## Identified Business Rules:
    #{Enum.join(business_rules, "\n- ")}

    ## Decision Points:
    #{Enum.join(decision_points, "\n- ")}

    ## Process Descriptions:
    #{Enum.join(process_descriptions, "\n- ")}

    ## Key Terms:
    #{Enum.join(key_terms, ", ")}

    ## Raw Content (first 4000 chars):
    #{String.slice(raw_content, 0, 4000)}

    Please analyze this structured information and create a domain configuration with:

    1. **Signals Fields**: Extract 5-10 key data fields from the business rules and key terms that would be important for decision-making
    2. **Decision Patterns**: Create 3-5 decision patterns based on the identified business rules and decision points
    3. **Domain Description**: Write a 2-3 sentence description focusing on the decision-relevant aspects

    Return your response in the following JSON format:

    ```json
    {
      "name": "#{String.downcase(domain_name) |> String.replace(" ", "_")}",
      "display_name": "#{domain_name}",
      "description": "Description focusing on decision-making aspects from the document",
      "signals_fields": [
        "field1",
        "field2",
        "field3"
      ],
      "patterns": [
        {
          "id": "pattern_1",
          "outcome": "recommended_action_or_decision",
          "score": 0.8,
          "summary": "Pattern summary based on business rules",
          "use_when": [
            {
              "field": "field1",
              "op": "equals",
              "value": "some_value"
            }
          ],
          "avoid_when": [
            {
              "field": "field1",
              "op": "equals",
              "value": "negative_value"
            }
          ],
          "typical_use_cases": ["example_scenario_1", "example_scenario_2"]
        }
      ]
    }
    ```

    Focus on creating practical, actionable patterns based on the document's business rules and decision criteria.
    Use the key terms to create meaningful field names in snake_case format.
    Prioritize decision-relevant content over general information.
    """
  end

  defp build_specialized_domain_prompt(structured_content) do
    %{
      domain_name: domain_name,
      business_rules: business_rules,
      decision_points: decision_points,
      process_descriptions: process_descriptions,
      key_terms: key_terms,
      raw_content: raw_content
    } = structured_content

    """
    You are an expert business analyst specializing in decision automation systems.
    Analyze the following document and create a comprehensive decision domain configuration for "#{domain_name}".

    ## DOCUMENT ANALYSIS

    ### Business Rules Identified:
    #{format_analysis_section(business_rules, "No business rules identified")}

    ### Decision Points Found:
    #{format_analysis_section(decision_points, "No explicit decision points found")}

    ### Process Descriptions:
    #{format_analysis_section(process_descriptions, "No process descriptions found")}

    ### Key Domain Terms:
    #{format_key_terms(key_terms)}

    ### Content Sample (first 4000 characters):
    ```
    #{String.slice(raw_content, 0, 4000)}
    ```

    ## DOMAIN CONFIGURATION REQUIREMENTS

    Create a decision domain that captures the essence of this document's decision-making logic:

    ### 1. Signal Fields (5-10 fields)
    - Extract key data points that influence decisions in this domain
    - Use snake_case naming (e.g., request_type, complexity_level, user_role)
    - Focus on measurable or categorizable attributes
    - Include both contextual and outcome-relevant signals

    ### 2. Decision Patterns (3-7 patterns)
    - Each pattern should represent a distinct decision scenario
    - Base patterns on the identified business rules and decision points
    - Include confidence scores (0.1-1.0) based on rule clarity
    - Create meaningful pattern IDs that reflect the decision logic

    ### 3. Domain Description
    - 2-3 sentences explaining the domain's decision-making purpose
    - Focus on what types of decisions this domain helps make
    - Reference the source document's context

    ## OUTPUT FORMAT

    Return ONLY valid JSON in this exact structure:

    ```json
    {
      "name": "#{sanitize_domain_name(domain_name)}",
      "display_name": "#{domain_name}",
      "description": "Clear description of what decisions this domain handles, based on the analyzed document",
      "signals_fields": [
        "signal_field_1",
        "signal_field_2",
        "signal_field_3"
      ],
      "patterns": [
        {
          "id": "descriptive_pattern_id",
          "outcome": "recommended_action_or_decision",
          "score": 0.8,
          "summary": "When this pattern applies and what it recommends",
          "use_when": [
            {
              "field": "signal_field_name",
              "op": "in",
              "value": ["value1", "value2"]
            }
          ],
          "avoid_when": [
            {
              "field": "signal_field_name",
              "op": "equals",
              "value": "negative_value"
            }
          ],
          "typical_use_cases": ["example_scenario_1", "example_scenario_2"]
        }
      ],
      "metadata": {
        "source_document": "PDF analysis",
        "confidence": 0.85,
        "rules_extracted": #{length(business_rules)},
        "decision_points": #{length(decision_points)}
      }
    }
    ```

    ## QUALITY GUIDELINES

    - Ensure all field names use snake_case
    - Make pattern IDs descriptive and unique
    - Set realistic confidence scores based on rule clarity
    - Focus on actionable, decision-relevant content
    - Avoid generic or vague recommendations
    - Ensure patterns are mutually exclusive where possible

    Generate the domain configuration now:
    """
  end

  defp build_enhanced_basic_prompt(text_content, domain_name) do
    """
    You are an expert business analyst creating a decision automation domain from a document.

    ## TASK
    Analyze the following document content and create a decision domain configuration for "#{domain_name}".

    ## DOCUMENT CONTENT
    ```
    #{String.slice(text_content, 0, 8000)}
    ```

    ## ANALYSIS INSTRUCTIONS

    1. **Identify Decision Patterns**: Look for rules, conditions, and decision logic
    2. **Extract Key Signals**: Find data points that influence decisions
    3. **Understand Context**: Determine what types of decisions this domain should handle

    ## REQUIRED OUTPUT

    Generate a JSON configuration with:

    ### Signal Fields (5-8 fields)
    - Key data points that influence decisions
    - Use descriptive snake_case names
    - Include both input and contextual signals

    ### Decision Patterns (3-5 patterns)
    - Distinct decision scenarios from the document
    - Clear outcomes and conditions
    - Realistic confidence scores (0.1-1.0)

    ### Domain Description
    - 2-3 sentences about the domain's decision purpose
    - Reference the document's context

    ## JSON OUTPUT FORMAT

    ```json
    {
      "name": "#{sanitize_domain_name(domain_name)}",
      "display_name": "#{domain_name}",
      "description": "Description of what decisions this domain handles",
      "signals_fields": [
        "relevant_signal_1",
        "relevant_signal_2",
        "relevant_signal_3"
      ],
      "patterns": [
        {
          "id": "pattern_identifier",
          "outcome": "decision_outcome",
          "score": 0.7,
          "summary": "When this pattern applies and what it recommends",
          "use_when": [
            {
              "field": "signal_field_name",
              "op": "in",
              "value": ["value1", "value2"]
            }
          ],
          "avoid_when": [
            {
              "field": "signal_field_name",
              "op": "equals",
              "value": "negative_value"
            }
          ],
          "typical_use_cases": ["example_scenario"]
        }
      ],
      "metadata": {
        "source_document": "PDF analysis",
        "confidence": 0.75,
        "analysis_method": "basic_extraction"
      }
    }
    ```

    Focus on practical, actionable decision logic based on the document content.
    """
  end

  defp format_analysis_section(items, empty_message) when length(items) == 0, do: empty_message
  defp format_analysis_section(items, _empty_message) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {item, index} -> "#{index}. #{item}" end)
    |> Enum.join("\n")
  end

  defp format_key_terms(terms) when length(terms) == 0, do: "No key terms identified"
  defp format_key_terms(terms) do
    terms
    |> Enum.take(15)  # Limit to most relevant terms
    |> Enum.join(", ")
  end

  defp sanitize_domain_name(domain_name) do
    domain_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp build_basic_prompt(text_content, domain_name) do
    """
    Based on the following document content, generate a decision domain configuration for "#{domain_name}".

    Document Content:
    #{String.slice(text_content, 0, 6000)}

    Please analyze the document and create a domain configuration with:

    1. **Signals Fields**: Extract 5-10 key data fields that would be important for decision-making based on this document
    2. **Decision Patterns**: Create 3-5 decision patterns with rules based on the document's content
    3. **Domain Description**: Write a 2-3 sentence description of what this domain handles

    Return your response in the following JSON format:

    ```json
    {
      "name": "#{String.downcase(domain_name) |> String.replace(" ", "_")}",
      "display_name": "#{domain_name}",
      "description": "Description based on the document content",
      "signals_fields": [
        "field1",
        "field2",
        "field3"
      ],
      "patterns": [
        {
          "id": "pattern_1",
          "outcome": "recommended_action_or_decision",
          "score": 0.8,
          "summary": "Pattern summary describing when this applies",
          "use_when": [
            {
              "field": "field1",
              "op": "equals",
              "value": "some_value"
            }
          ],
          "avoid_when": [
            {
              "field": "field1",
              "op": "equals",
              "value": "negative_value"
            }
          ],
          "typical_use_cases": ["example_scenario_1", "example_scenario_2"]
        }
      ]
    }
    ```

    Focus on creating practical, actionable patterns based on the document's business rules, processes, or decision criteria.
    Make sure all field names use snake_case and are descriptive.
    """
  end

  defp parse_domain_config_response(response, domain_name) do
    try do
      Logger.info("Raw LLM response received (first 500 chars): #{String.slice(response, 0, 500)}")
      Logger.info("Full response length: #{String.length(response)} characters")

      # Extract JSON from the response (it might be wrapped in markdown code blocks)
      json_content = extract_json_from_response(response)
      Logger.info("Extracted JSON content (first 500 chars): #{String.slice(json_content, 0, 500)}")

      case Jason.decode(json_content) do
        {:ok, config} ->
          Logger.info("Successfully parsed JSON config: #{inspect(Map.keys(config))}")
          # Return the raw config for domain config builder to process
          {:ok, config}

        {:error, reason} ->
          Logger.error("Failed to parse domain config JSON: #{inspect(reason)}")
          Logger.error("JSON content that failed to parse: #{inspect(json_content)}")

          # Try to create a fallback domain configuration if JSON parsing fails
          Logger.info("Attempting to create fallback domain configuration due to JSON parsing failure")
          {:ok, fallback_config} = create_basic_domain_from_text("", domain_name)
          Logger.info("Successfully created fallback domain configuration")
          # Convert to string keys for domain config builder
          raw_fallback = convert_to_string_keys(fallback_config)
          {:ok, raw_fallback}
      end
    rescue
      error ->
        Logger.error("Exception parsing domain config: #{inspect(error)}")
        Logger.error("Response that caused exception: #{inspect(response)}")
        {:error, "Failed to parse domain configuration: #{inspect(error)}"}
    end
  end

  defp extract_json_from_response(response) do
    # First, try to extract JSON from markdown code blocks using regex
    case Regex.run(~r/```json\s*(.*?)\s*```/s, response, capture: :all_but_first) do
      [json_content] ->
        cleaned = String.trim(json_content)
        Logger.info("Extracted JSON from markdown code block (#{String.length(cleaned)} chars)")
        cleaned

      nil ->
        # No markdown code blocks found, try to extract JSON object directly
        Logger.info("No markdown code blocks found, trying direct JSON extraction")
        extract_json_object_from_text(response)
    end
  end

  defp extract_json_object_from_text(text) do
    # Simple approach: find first { and last } that makes valid JSON
    text = String.trim(text)

    # Find first opening brace
    start_pos = String.split(text, "", parts: :infinity) |> Enum.find_index(&(&1 == "{"))

    if start_pos do
      json_text = String.slice(text, start_pos..-1)

      # Try multiple patterns to find the end of JSON
      patterns = [
        # Pattern 1: JSON followed by ``` (markdown end)
        ~r/^(.+?})\s*```/s,
        # Pattern 2: JSON followed by ### (justification section)
        ~r/^(.+?})\s*\n\s*###/s,
        # Pattern 3: JSON followed by double newline and text
        ~r/^(.+?})\s*\n\n\w/s,
        # Pattern 4: Find balanced braces (more robust)
        ~r/^(\{(?:[^{}]|(?:\{(?:[^{}]|(?:\{[^{}]*\})*)*\})*)*\})/s
      ]

      # Try each pattern in order
      extracted_json = Enum.find_value(patterns, fn pattern ->
        case Regex.run(pattern, json_text, capture: :all_but_first) do
          [json_part] ->
            Logger.info("Extracted JSON using pattern (#{String.length(json_part)} chars)")
            json_part
          nil -> nil
        end
      end)

      case extracted_json do
        nil ->
          # Fallback: try to find the largest valid JSON object
          Logger.warning("Pattern matching failed, trying brace counting")
          extract_json_by_brace_counting(json_text)
        json_part ->
          json_part
      end
    else
      Logger.warning("No opening brace found in response")
      text
    end
  end



  defp extract_json_by_brace_counting(text) do
    # Count braces to find the complete JSON object
    chars = String.graphemes(text)

    {json_chars, _} = Enum.reduce_while(chars, {[], 0}, fn char, {acc, brace_count} ->
      new_acc = [char | acc]

      new_count = case char do
        "{" -> brace_count + 1
        "}" -> brace_count - 1
        _ -> brace_count
      end

      if new_count == 0 and brace_count > 0 do
        # Found complete JSON object
        {:halt, {new_acc, new_count}}
      else
        {:cont, {new_acc, new_count}}
      end
    end)

    json_string = json_chars |> Enum.reverse() |> Enum.join()
    Logger.info("Extracted JSON by brace counting (#{String.length(json_string)} chars)")
    json_string
  end



  defp clean_extracted_text(text) do
    text
    |> remove_control_characters()
    |> normalize_whitespace()
    |> remove_excessive_line_breaks()
    |> fix_word_breaks()
    |> String.trim()
  end

  defp remove_control_characters(text) do
    # Remove non-printable control characters except newlines and tabs
    String.replace(text, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end

  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/[ \t]+/, " ")  # Normalize spaces and tabs
    |> String.replace(~r/ +\n/, "\n")   # Remove trailing spaces before newlines
    |> String.replace(~r/\n +/, "\n")   # Remove leading spaces after newlines
  end

  defp remove_excessive_line_breaks(text) do
    text
    |> String.replace(~r/\n{3,}/, "\n\n")  # Limit consecutive newlines to 2
    |> String.replace(~r/^\n+/, "")        # Remove leading newlines
    |> String.replace(~r/\n+$/, "")        # Remove trailing newlines
  end

  defp fix_word_breaks(text) do
    # Fix common word breaks from PDF extraction
    text
    |> String.replace(~r/(\w)-\s*\n\s*(\w)/, "\\1\\2")  # Fix hyphenated words across lines
    |> String.replace(~r/(\w)\s*\n\s*(\w)/, "\\1 \\2")  # Fix words split across lines
  end

  @doc """
  Handles LLM API errors and implements rate limiting for domain generation.

  ## Parameters
  - error: The error returned from LLM API
  - retry_count: Current retry attempt number
  - max_retries: Maximum number of retries allowed

  ## Returns
  - {:retry, delay_ms} if should retry with delay
  - {:error, formatted_reason} if should not retry
  """
  @spec handle_llm_error(term(), integer(), integer()) :: {:retry, integer()} | {:error, String.t()}
  def handle_llm_error(error, retry_count, max_retries \\ 3) do
    case error do
      # Rate limiting errors - implement exponential backoff
      {:error, %{"error" => %{"type" => "rate_limit_exceeded"}}} when retry_count < max_retries ->
        delay = min(1000 * :math.pow(2, retry_count), 30_000) |> trunc()
        Logger.warning("Rate limit exceeded, retrying in #{delay}ms (attempt #{retry_count + 1})")
        {:retry, delay}

      # Temporary API errors - retry with shorter delay
      {:error, %{"error" => %{"type" => type}}} when type in ["server_error", "timeout"] and retry_count < max_retries ->
        delay = 2000 + (retry_count * 1000)
        Logger.warning("Temporary API error (#{type}), retrying in #{delay}ms")
        {:retry, delay}

      # Authentication errors - don't retry
      {:error, %{"error" => %{"type" => "invalid_api_key"}}} ->
        {:error, "Invalid API key. Please check your LLM configuration."}

      # Quota exceeded - don't retry immediately
      {:error, %{"error" => %{"type" => "quota_exceeded"}}} ->
        {:error, "API quota exceeded. Please try again later or check your billing."}

      # Content policy violations - don't retry
      {:error, %{"error" => %{"type" => "content_policy_violation"}}} ->
        {:error, "Content policy violation. The PDF content may contain restricted material."}

      # Generic errors after max retries
      _ when retry_count >= max_retries ->
        {:error, "Maximum retry attempts reached. Please try again later."}

      # Other errors - single retry
      _ when retry_count < 1 ->
        {:retry, 2000}

      # Unknown errors - don't retry
      _ ->
        {:error, "LLM processing failed: #{inspect(error)}"}
    end
  end

  @doc """
  Validates PDF content for LLM processing to avoid common issues.

  ## Parameters
  - text_content: Extracted text from PDF
  - domain_name: Proposed domain name

  ## Returns
  - :ok if content is suitable for processing
  - {:error, reason} if content has issues
  """
  @spec validate_content_for_llm(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_content_for_llm(text_content, domain_name) do
    cond do
      # Check domain name first
      String.trim(domain_name) == "" ->
        {:error, "Domain name cannot be empty"}

      not String.match?(domain_name, ~r/^[a-zA-Z0-9\s_-]+$/) ->
        {:error, "Domain name contains invalid characters. Use only letters, numbers, spaces, hyphens, and underscores."}

      # Then check content
      String.trim(text_content) == "" ->
        {:error, "PDF appears to be empty or contains no extractable text"}

      String.length(text_content) < 100 ->
        {:error, "PDF content is too short for meaningful analysis (minimum 100 characters)"}

      String.length(text_content) > 100_000 ->
        {:error, "PDF content is too large for processing (maximum 100,000 characters)"}

      # Check for potentially problematic content
      contains_mostly_numbers?(text_content) ->
        {:error, "PDF appears to contain mostly numerical data without sufficient context for domain generation"}

      contains_mostly_symbols?(text_content) ->
        {:error, "PDF appears to contain mostly symbols or formatting characters without readable text"}

      true ->
        :ok
    end
  end

  defp contains_mostly_numbers?(text) do
    # Check if more than 70% of non-whitespace characters are digits
    non_whitespace = String.replace(text, ~r/\s/, "")
    digits = String.replace(non_whitespace, ~r/[^0-9]/, "")

    if String.length(non_whitespace) > 0 do
      digit_ratio = String.length(digits) / String.length(non_whitespace)
      digit_ratio > 0.7
    else
      false
    end
  end

  defp contains_mostly_symbols?(text) do
    # Check if more than 50% of characters are symbols/punctuation
    letters_and_numbers = String.replace(text, ~r/[^a-zA-Z0-9\s]/, "")

    if String.length(text) > 0 do
      text_ratio = String.length(letters_and_numbers) / String.length(text)
      text_ratio < 0.5
    else
      false
    end
  end

  # Enhanced Error Handling and Recovery Functions

  @doc """
  Determines if an error should trigger a retry attempt.

  ## Parameters
  - reason: The error reason from a failed operation

  ## Returns
  - {:retry, delay_ms} if should retry with specified delay
  - :no_retry if should not retry
  """
  @spec should_retry_error?(term()) :: {:retry, integer()} | :no_retry
  def should_retry_error?(reason) do
    cond do
      # Network/API related errors - retry with exponential backoff
      match?({:llm_call_failed, _}, reason) -> {:retry, 2000}
      reason == :no_llm_config_available -> :no_retry
      reason == :no_api_key_configured -> :no_retry

      # File system errors - single retry
      is_binary(reason) and String.contains?(reason, "Cannot read PDF file") -> {:retry, 1000}
      is_binary(reason) and String.contains?(reason, "PDF text extraction requires") -> :no_retry

      # Content validation errors - no retry
      is_binary(reason) and String.contains?(reason, "PDF appears to be empty") -> :no_retry
      is_binary(reason) and String.contains?(reason, "PDF content is too short") -> :no_retry
      is_binary(reason) and String.contains?(reason, "PDF content is too large") -> :no_retry
      is_binary(reason) and String.contains?(reason, "Domain name contains invalid characters") -> :no_retry

      # Processing errors - retry once
      is_binary(reason) and String.contains?(reason, "Failed to extract text from PDF") -> {:retry, 1500}
      is_binary(reason) and String.contains?(reason, "Processing exception") -> {:retry, 2000}

      # Default: no retry for unknown errors
      true -> :no_retry
    end
  end

  @doc """
  Enhances error messages with user-friendly explanations and suggested actions.

  ## Parameters
  - reason: The original error reason

  ## Returns
  - Enhanced error message string with actionable guidance
  """
  @spec enhance_error_message(term()) :: String.t()
  def enhance_error_message(reason) do
    case reason do
      :no_api_key_configured ->
        "LLM API key not configured. Please set up your API key in the Settings page to enable PDF processing."

      :no_llm_config_available ->
        "LLM service not configured. Please configure your preferred LLM provider in the Settings page."

      {:llm_call_failed, details} ->
        "Failed to connect to LLM service: #{inspect(details)}. Please check your internet connection and API configuration."

      reason when is_binary(reason) ->
        cond do
          String.contains?(reason, "PDF text extraction requires") and String.contains?(reason, "pdftotext") ->
            "PDF text extraction tool (pdftotext) not available. On Windows, install poppler via Chocolatey: 'choco install poppler' or download from https://blog.alivate.com.au/poppler-windows/. On Linux/Mac: install poppler-utils package."

          String.contains?(reason, "File does not exist") ->
            "The uploaded file could not be found. Please try uploading the file again."

          String.contains?(reason, "File size") and String.contains?(reason, "exceeds maximum allowed size") ->
            "The PDF file is too large. Please upload a smaller file (maximum 50MB) or compress the PDF."

          String.contains?(reason, "PDF file appears to be corrupted") ->
            "The PDF file appears to be corrupted or incomplete. Please try uploading a different PDF file."

          String.contains?(reason, "PDF content is too short for meaningful analysis") ->
            "The PDF content is too brief for analysis. Please upload a document with more detailed content (minimum 100 characters)."

          String.contains?(reason, "PDF content is too large for processing") ->
            "The PDF content is too extensive for processing. Please upload a smaller document or split it into sections."

          String.contains?(reason, "Domain name contains invalid characters") ->
            "Domain name contains invalid characters. Please use only letters, numbers, spaces, hyphens, and underscores."

          String.contains?(reason, "PDF appears to contain mostly numerical data") ->
            "The PDF appears to contain mostly numerical data without sufficient context. Please upload a document with more descriptive text."

          String.contains?(reason, "PDF appears to contain mostly symbols") ->
            "The PDF appears to contain mostly symbols or formatting characters. Please upload a document with readable text content."

          String.contains?(reason, "Processing exception") ->
            "An unexpected error occurred during processing. Please try again or contact support if the problem persists."

          true ->
            "Processing failed: #{reason}. Please verify your file and try again."
        end

      "File is not a valid PDF format" ->
        "The uploaded file is not a valid PDF. Please ensure you're uploading a PDF document."

      "PDF appears to be empty or contains no extractable text" ->
        "The PDF file appears to be empty or contains only images/scanned content. Please upload a PDF with text content."

      "Domain name cannot be empty" ->
        "Please enter a domain name before processing the PDF."

      "Failed to extract text from PDF using all available methods" ->
        "Unable to extract text from the PDF using available methods. The file may be password-protected, corrupted, or contain only images."

      reason ->
        "An unexpected error occurred: #{inspect(reason)}. Please try again or contact support."
    end
  end

  @doc """
  Gets LLM configuration with fallback options and enhanced error handling.

  ## Parameters
  - llm_config: Optional LLM configuration map

  ## Returns
  - {:ok, config} with valid LLM configuration
  - {:error, reason} with enhanced error details
  """
  @spec get_llm_config_with_fallback(map() | nil) :: {:ok, map()} | {:error, term()}
  def get_llm_config_with_fallback(llm_config) do
    case get_llm_config(llm_config) do
      {:ok, config} ->
        {:ok, config}

      {:error, :no_api_key_configured} ->
        # Try to get a basic configuration for offline processing
        case try_offline_llm_config() do
          {:error, _} -> {:error, :no_api_key_configured}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates domain configuration from text with retry logic and fallback strategies.

  ## Parameters
  - text_content: Extracted PDF text
  - domain_name: Target domain name
  - config: LLM configuration
  - retry_count: Current retry attempt
  - max_retries: Maximum retries allowed

  ## Returns
  - {:ok, domain_config} on success
  - {:error, reason} on failure
  """
  @spec generate_domain_from_text_with_retry(String.t(), String.t(), map(), integer(), integer()) ::
    {:ok, map()} | {:error, term()}
  def generate_domain_from_text_with_retry(text_content, domain_name, config, retry_count, max_retries) do
    case generate_domain_from_text(text_content, domain_name, config) do
      {:ok, domain_config} ->
        {:ok, domain_config}

      {:error, {:llm_call_failed, reason}} when retry_count < max_retries ->
        case handle_llm_error({:error, reason}, retry_count, max_retries) do
          {:retry, delay} ->
            Logger.info("Retrying LLM call in #{delay}ms (attempt #{retry_count + 1})")
            Process.sleep(delay)
            generate_domain_from_text_with_retry(text_content, domain_name, config, retry_count + 1, max_retries)

          {:error, error_msg} ->
            # Try fallback generation if LLM fails
            try_fallback_domain_generation(text_content, domain_name, error_msg)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Alternative extraction methods for when pdftotext is not available
  defp try_alternative_extraction_methods(pdf_path) do
    Logger.info("Trying alternative PDF extraction methods for: #{pdf_path}")

    # Method 1: Try using Python's PyPDF2 if available
    case try_python_pdf_extraction(pdf_path) do
      {:ok, text} -> {:ok, text}
      {:error, _} ->
        # Method 2: Try basic file reading for simple PDFs
        try_basic_pdf_reading(pdf_path)
    end
  end

  defp try_python_pdf_extraction(pdf_path) do
    python_script = """
    import sys
    try:
        import PyPDF2
        with open(sys.argv[1], 'rb') as file:
            reader = PyPDF2.PdfReader(file)
            text = ''
            for page in reader.pages:
                text += page.extract_text()
            print(text)
    except Exception as e:
        sys.exit(1)
    """

    script_path = Path.join(System.tmp_dir!(), "pdf_extract_#{:rand.uniform(10000)}.py")

    try do
      File.write!(script_path, python_script)

      case System.cmd("python3", [script_path, pdf_path], stderr_to_stdout: true) do
        {text, 0} when byte_size(text) > 0 ->
          cleaned_text = clean_extracted_text(text)
          if String.trim(cleaned_text) != "" do
            {:ok, cleaned_text}
          else
            {:error, "No text extracted using Python method"}
          end

        {_error, _} ->
          {:error, "Python PDF extraction failed"}
      end
    rescue
      _ -> {:error, "Python extraction method unavailable"}
    after
      File.rm(script_path)
    end
  end

  defp try_basic_pdf_reading(pdf_path) do
    # Last resort: try to extract any readable text from the PDF file
    case File.read(pdf_path) do
      {:ok, binary_content} ->
        # Look for text streams in the PDF
        text_content = extract_text_from_pdf_binary(binary_content)
        if String.length(text_content) > 50 do
          {:ok, clean_extracted_text(text_content)}
        else
          {:error, "Insufficient text content found in PDF"}
        end

      {:error, reason} ->
        {:error, "Cannot read PDF file: #{inspect(reason)}"}
    end
  end

  defp extract_text_from_pdf_binary(binary_content) do
    # Extract text between stream markers (very basic approach)
    binary_content
    |> String.replace(~r/.*?stream\s*/, "", global: true)
    |> String.replace(~r/\s*endstream.*?/, "", global: true)
    |> String.replace(~r/[^\x20-\x7E\s]/, "")  # Keep only printable ASCII
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp try_emergency_fallback(pdf_path) do
    Logger.warning("Using emergency fallback for PDF extraction: #{pdf_path}")

    # Provide a minimal response that allows manual domain creation
    {:error, "Unable to extract text from PDF. You can create the domain manually using the form below."}
  end

  defp try_corrupted_pdf_recovery(pdf_path) do
    Logger.info("Attempting corrupted PDF recovery for: #{pdf_path}")

    # Try to read partial content from corrupted PDF
    case File.read(pdf_path) do
      {:ok, content} ->
        # Look for any readable text in the corrupted file
        readable_text =
          content
          |> String.replace(~r/[^\x20-\x7E\n\r\t]/, "")  # Remove non-printable characters
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        if String.length(readable_text) > 100 do
          {:ok, readable_text}
        else
          {:error, "PDF file is corrupted and contains insufficient readable content"}
        end

      {:error, _} ->
        {:error, "Cannot read corrupted PDF file"}
    end
  end

  defp try_offline_llm_config do
    # Attempt to create a basic configuration for offline processing
    # This would be used when no API key is available
    {:error, "Offline LLM processing not implemented"}
  end

  defp try_fallback_domain_generation(text_content, domain_name, _llm_error) do
    Logger.info("Attempting fallback domain generation for: #{domain_name}")

    # Create a basic domain configuration based on text analysis
    case create_basic_domain_from_text(text_content, domain_name) do
      {:ok, basic_config} ->
        Logger.info("Successfully created basic domain configuration")
        {:ok, basic_config}
    end
  end



  defp create_basic_domain_from_text(text_content, domain_name) do
    # Create a minimal domain configuration without LLM
    basic_signals = extract_basic_signals_from_text(text_content)
    basic_patterns = create_basic_patterns(domain_name)

    domain_config = %{
      name: sanitize_domain_name(domain_name),
      display_name: domain_name,
      description: "Basic domain configuration generated from PDF content analysis",
      signals_fields: basic_signals,
      patterns: basic_patterns,
      schema_module: "",
      metadata: %{
        source: "fallback_generation",
        generated_at: DateTime.utc_now(),
        method: "basic_text_analysis"
      }
    }

    {:ok, domain_config}
  end

  defp extract_basic_signals_from_text(text_content) do
    # Extract potential signal fields from text using simple heuristics
    words = String.split(text_content, ~r/\W+/)

    # Look for common business terms that could be signals
    business_terms = [
      "amount", "value", "price", "cost", "total", "sum",
      "type", "category", "status", "state", "level",
      "date", "time", "period", "duration",
      "user", "customer", "client", "account",
      "request", "application", "order", "transaction"
    ]

    found_terms =
      words
      |> Enum.map(&String.downcase/1)
      |> Enum.filter(&(&1 in business_terms))
      |> Enum.uniq()
      |> Enum.take(8)

    if length(found_terms) < 3 do
      ["request_type", "priority_level", "user_role", "status"]
    else
      found_terms
    end
  end

  defp convert_to_string_keys(config) when is_map(config) do
    config
    |> Enum.map(fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
    |> Map.new()
  end

  defp create_basic_patterns(domain_name) do
    [
      %{
        "id" => "basic_approval",
        "summary" => "Basic approval pattern for #{domain_name}",
        "conditions" => [
          %{
            "field" => "status",
            "operator" => "equals",
            "value" => "pending"
          }
        ],
        "actions" => ["Review and process request"],
        "priority" => 1
      }
    ]
  end

  # Helper functions for concurrent reflection processing

  # Checks if reflection should be triggered based on system configuration.
  @spec should_trigger_reflection?() :: boolean()
  defp should_trigger_reflection?() do
    try do
      # For PDF processing, we want to enable reflection even if it's disabled globally
      # because PDF-generated domains often need improvement
      case DecisionEngine.ReflectionConfig.reflection_enabled?() do
        true -> true
        false ->
          Logger.info("Reflection is disabled globally, but enabling for PDF-generated domain improvement")
          true  # Enable reflection for PDF processing regardless of global setting
      end
    rescue
      _ ->
        Logger.info("Reflection config unavailable, enabling reflection for PDF processing")
        true  # Default to true for PDF processing if reflection config is not available
    end
  end

  # Prepares reflection options for concurrent processing.
  @spec prepare_concurrent_reflection_options(map() | nil, String.t()) :: map()
  defp prepare_concurrent_reflection_options(reflection_options, domain_name) do
    base_options = reflection_options || %{}

    # Set default options for concurrent processing
    concurrent_defaults = %{
      priority: :normal,
      callback_pid: self(),
      session_id: "pdf_#{domain_name}_#{System.system_time(:microsecond)}",
      async: true,
      enable_progress_tracking: true,
      enable_cancellation: true,
      fallback_on_queue_failure: true
    }

    # Merge with provided options, giving precedence to user-provided values
    Map.merge(concurrent_defaults, base_options)
  end

end
