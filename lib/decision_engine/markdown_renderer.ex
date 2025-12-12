defmodule DecisionEngine.MarkdownRenderer do
  @moduledoc """
  Handles conversion of markdown text to safe HTML for display in the interface.
  Provides XSS protection while preserving formatting elements.
  """

  @doc """
  Converts markdown content to safe HTML.
  
  Returns {:ok, html} on success or {:error, reason} on failure.
  """
  @spec render_to_html(String.t()) :: {:ok, String.t()} | {:error, term()}
  def render_to_html(markdown_content) when is_binary(markdown_content) do
    if markdown_content == "" do
      {:ok, ""}
    else
      try do
        html = 
          markdown_content
          |> Earmark.as_html!()
          |> sanitize_html()
          |> clean_html()
        
        {:ok, html}
      rescue
        error ->
          {:error, error}
      end
    end
  end

  def render_to_html(_), do: {:error, :invalid_input}

  @doc """
  Converts markdown content to safe HTML with graceful fallback.
  
  Returns safe HTML on success, or escaped raw text on failure.
  """
  @spec render_to_html!(String.t()) :: String.t()
  def render_to_html!(markdown_content) when is_binary(markdown_content) do
    if markdown_content == "" do
      ""
    else
      case render_to_html(markdown_content) do
        {:ok, html} -> html
        {:error, _} -> escape_html(markdown_content)
      end
    end
  end

  def render_to_html!(_), do: ""

  # Sanitizes HTML content to prevent XSS attacks while preserving safe formatting elements.
  defp sanitize_html(html) do
    # Use HtmlSanitizeEx to remove dangerous elements while preserving formatting
    HtmlSanitizeEx.markdown_html(html)
  end

  # Cleans up HTML by removing unnecessary whitespace and newlines
  defp clean_html(html) do
    html
    |> String.replace(~r/>\s+</, "><")     # Remove whitespace between tags
    |> String.replace(~r/\n\s*/, "")       # Remove newlines and leading whitespace
    |> String.replace(~r/\s+<\//, "</")    # Remove trailing whitespace before closing tags
    |> String.replace(~r/>\s+/, ">")       # Remove whitespace after opening tags
    |> String.trim()                       # Remove leading/trailing whitespace
  end

  # Escapes HTML content for safe display as plain text.
  defp escape_html(text) do
    Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()
  end
end