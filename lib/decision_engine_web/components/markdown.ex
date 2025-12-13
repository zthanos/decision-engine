# lib/decision_engine_web/components/markdown.ex
defmodule DecisionEngineWeb.Components.Markdown do
  @moduledoc """
  Markdown rendering components for displaying formatted text content.
  """

  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]
  alias DecisionEngine.MarkdownRenderer

  @doc """
  Renders markdown content as HTML with proper styling.

  ## Examples

      <.markdown content={@description} class="prose prose-sm" />

      <.markdown content={@content} class="text-base-content/80" />
  """
  attr :content, :string, required: true, doc: "The markdown content to render"
  attr :class, :string, default: "prose prose-sm max-w-none", doc: "CSS classes for styling"
  attr :fallback, :string, default: nil, doc: "Fallback text if content is empty"

  def markdown(assigns) do
    ~H"""
    <div class={@class}>
      <%= if @content && String.trim(@content) != "" do %>
        <%= raw(render_markdown(@content)) %>
      <% else %>
        <%= @fallback || "No content available" %>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders inline markdown content without block-level styling.

  ## Examples

      <.inline_markdown content={@short_description} />
  """
  attr :content, :string, required: true, doc: "The markdown content to render"
  attr :class, :string, default: "", doc: "CSS classes for styling"
  attr :fallback, :string, default: nil, doc: "Fallback text if content is empty"

  def inline_markdown(assigns) do
    ~H"""
    <span class={@class}>
      <%= if @content && String.trim(@content) != "" do %>
        <%= raw(render_inline_markdown(@content)) %>
      <% else %>
        <%= @fallback || "No content available" %>
      <% end %>
    </span>
    """
  end

  # Private helper functions

  defp render_markdown(content) do
    case MarkdownRenderer.render_to_html(content) do
      {:ok, html} -> html
      {:error, _reason} -> Phoenix.HTML.html_escape(content) |> Phoenix.HTML.safe_to_string()
    end
  end

  defp render_inline_markdown(content) do
    # For inline content, we strip block elements and keep only inline formatting
    case MarkdownRenderer.render_to_html(content) do
      {:ok, html} ->
        html
        |> String.replace(~r/<\/?p[^>]*>/, "")  # Remove paragraph tags
        |> String.replace(~r/<\/?div[^>]*>/, "") # Remove div tags
        |> String.trim()
      {:error, _reason} ->
        Phoenix.HTML.html_escape(content) |> Phoenix.HTML.safe_to_string()
    end
  end
end
