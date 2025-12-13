# lib/decision_engine/pdf_processor.ex
defmodule DecisionEngine.PDFProcessor do
  @moduledoc """
  Processes PDF files to extract text content for LLM-based domain rule generation.

  This module handles PDF upload, text extraction, and integration with LLM services
  to generate domain configurations from reference documents.
  """

  require Logger

  @doc """
  Processes an uploaded PDF file and generates domain rules using LLM analysis.

  ## Parameters
  - pdf_path: String path to the uploaded PDF file
  - domain_name: String name for the new domain
  - llm_config: Map containing LLM configuration (optional, uses default if not provided)

  ## Returns
  - {:ok, domain_config} with generated domain configuration
  - {:error, reason} on failure
  """
  @spec process_pdf_for_domain(String.t(), String.t(), map() | nil) ::
    {:ok, map()} | {:error, term()}
  def process_pdf_for_domain(pdf_path, domain_name, llm_config \\ nil) do
    with {:ok, text_content} <- extract_text_from_pdf(pdf_path),
         {:ok, config} <- get_llm_config(llm_config),
         {:ok, domain_config} <- generate_domain_from_text(text_content, domain_name, config) do
      {:ok, domain_config}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Extracts text content from a PDF file.

  ## Parameters
  - pdf_path: String path to the PDF file

  ## Returns
  - {:ok, text_content} with extracted text
  - {:error, reason} on failure
  """
  @spec extract_text_from_pdf(String.t()) :: {:ok, String.t()} | {:error, term()}
  def extract_text_from_pdf(pdf_path) do
    try do
      # Check if pdftotext is available
      case System.cmd("pdftotext", ["-v"], stderr_to_stdout: true) do
        {_output, 0} ->
          # pdftotext is available, use it
          case System.cmd("pdftotext", [pdf_path, "-"], stderr_to_stdout: true) do
            {text_content, 0} ->
              cleaned_text = clean_extracted_text(text_content)
              {:ok, cleaned_text}

            {error_output, _exit_code} ->
              Logger.error("PDF text extraction failed: #{error_output}")
              {:error, "Failed to extract text from PDF: #{error_output}"}
          end

        {_error, _exit_code} ->
          # pdftotext not available
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

  @doc """
  Validates that a file is a valid PDF.

  ## Parameters
  - file_path: String path to the file

  ## Returns
  - :ok if file is a valid PDF
  - {:error, reason} if not valid
  """
  @spec validate_pdf(String.t()) :: :ok | {:error, String.t()}
  def validate_pdf(file_path) do
    case File.open(file_path, [:read, :binary]) do
      {:ok, file} ->
        case IO.binread(file, 4) do
          <<"%PDF">> ->
            File.close(file)
            :ok
          _other ->
            File.close(file)
            {:error, "File is not a valid PDF"}
        end
      {:error, reason} ->
        {:error, "Cannot read file: #{inspect(reason)}"}
    end
  end

  # Private Functions

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

    case DecisionEngine.LLMClient.generate_text(prompt, config) do
      {:ok, response} ->
        parse_domain_config_response(response, domain_name)
      {:error, reason} ->
        {:error, {:llm_call_failed, reason}}
    end
  end

  defp build_domain_generation_prompt(text_content, domain_name) do
    """
    Based on the following document content, generate a decision domain configuration for "#{domain_name}".

    Document Content:
    #{String.slice(text_content, 0, 8000)}  # Limit content to avoid token limits

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
          "summary": "Pattern summary",
          "conditions": [
            {
              "field": "field1",
              "operator": "equals",
              "value": "some_value"
            }
          ],
          "actions": [
            "Action to take when conditions are met"
          ],
          "priority": 1
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
      # Extract JSON from the response (it might be wrapped in markdown code blocks)
      json_content = extract_json_from_response(response)

      case Jason.decode(json_content) do
        {:ok, config} ->
          # Validate and normalize the configuration
          normalized_config = normalize_domain_config(config, domain_name)
          {:ok, normalized_config}

        {:error, reason} ->
          Logger.error("Failed to parse domain config JSON: #{inspect(reason)}")
          {:error, "Invalid JSON response from LLM: #{inspect(reason)}"}
      end
    rescue
      error ->
        Logger.error("Exception parsing domain config: #{inspect(error)}")
        {:error, "Failed to parse domain configuration: #{inspect(error)}"}
    end
  end

  defp extract_json_from_response(response) do
    # Remove markdown code block markers if present
    response
    |> String.replace(~r/```json\s*/, "")
    |> String.replace(~r/```\s*$/, "")
    |> String.trim()
  end

  defp normalize_domain_config(config, domain_name) do
    %{
      name: config["name"] || String.downcase(domain_name) |> String.replace(" ", "_"),
      display_name: config["display_name"] || domain_name,
      description: config["description"] || "Generated from PDF document",
      signals_fields: config["signals_fields"] || [],
      patterns: normalize_patterns(config["patterns"] || []),
      schema_module: ""  # Will be set by domain manager
    }
  end

  defp normalize_patterns(patterns) when is_list(patterns) do
    patterns
    |> Enum.with_index(1)
    |> Enum.map(fn {pattern, index} ->
      %{
        "id" => pattern["id"] || "pattern_#{index}",
        "summary" => pattern["summary"] || "Generated pattern #{index}",
        "conditions" => normalize_conditions(pattern["conditions"] || []),
        "actions" => pattern["actions"] || [],
        "priority" => pattern["priority"] || index
      }
    end)
  end

  defp normalize_conditions(conditions) when is_list(conditions) do
    Enum.map(conditions, fn condition ->
      %{
        "field" => condition["field"] || "unknown_field",
        "operator" => condition["operator"] || "equals",
        "value" => condition["value"] || ""
      }
    end)
  end

  defp clean_extracted_text(text) do
    text
    |> String.replace(~r/\s+/, " ")  # Normalize whitespace
    |> String.replace(~r/\n+/, "\n") # Normalize line breaks
    |> String.trim()
  end
end
