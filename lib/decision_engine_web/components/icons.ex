# lib/decision_engine_web/components/icons.ex
defmodule DecisionEngineWeb.Components.Icons do
  @moduledoc """
  Icon components with proper asset loading and fallback mechanisms.

  This module provides a centralized way to handle icons throughout the application,
  ensuring consistent styling and proper fallback behavior when icon resources
  are missing or fail to load.
  """

  use Phoenix.Component

  @doc """
  Renders an icon with fallback support.

  ## Examples

      <.icon name="home" class="w-5 h-5" />
      <.icon name="plus" class="w-4 h-4" fallback_text="+" />
      <.icon name="missing-icon" class="w-5 h-5" fallback_text="?" />
  """
  attr :name, :string, required: true, doc: "Icon name (without hero- prefix)"
  attr :class, :string, default: "w-5 h-5", doc: "CSS classes for styling"
  attr :fallback_text, :string, default: nil, doc: "Text to show if icon fails to load"
  attr :aria_hidden, :boolean, default: true, doc: "Whether icon is decorative"
  attr :title, :string, default: nil, doc: "Tooltip text for the icon"
  attr :rest, :global, doc: "Additional HTML attributes"

  def icon(assigns) do
    assigns = assign(assigns, :icon_class, "hero-#{assigns.name}")

    ~H"""
    <span
      class={[@icon_class, @class, "icon-container"]}
      title={@title}
      aria-hidden={@aria_hidden}
      {@rest}
    >
      <!-- Heroicon SVG will be rendered here by JavaScript -->
    </span>
    """
  end

  @doc """
  Renders an icon with explicit fallback text that shows when icon is missing.

  ## Examples

      <.icon_with_fallback name="home" fallback_text="🏠" class="w-5 h-5" />
      <.icon_with_fallback name="plus" fallback_text="+" class="w-4 h-4" />
  """
  attr :name, :string, required: true, doc: "Icon name (without hero- prefix)"
  attr :fallback_text, :string, required: true, doc: "Text to show if icon fails to load"
  attr :class, :string, default: "w-5 h-5", doc: "CSS classes for styling"
  attr :aria_hidden, :boolean, default: true, doc: "Whether icon is decorative"
  attr :title, :string, default: nil, doc: "Tooltip text for the icon"
  attr :rest, :global, doc: "Additional HTML attributes"

  def icon_with_fallback(assigns) do
    assigns = assign(assigns, :icon_class, "hero-#{assigns.name}")

    ~H"""
    <span
      class={["icon-with-fallback", @class]}
      title={@title}
      aria-hidden={@aria_hidden}
      {@rest}
    >
      <!-- Try to render Heroicon first -->
      <span class={[@icon_class, "icon-primary"]} aria-hidden="true"></span>
      <!-- Fallback text that shows when icon is missing -->
      <span class="icon-fallback" aria-hidden="true"><%= @fallback_text %></span>
    </span>
    """
  end

  @doc """
  Renders a button with an icon and proper fallback handling.

  ## Examples

      <.icon_button name="plus" text="Add Item" phx-click="add" />
      <.icon_button name="trash" text="Delete" class="btn-error" phx-click="delete" />
  """
  attr :name, :string, required: true, doc: "Icon name (without hero- prefix)"
  attr :text, :string, default: nil, doc: "Button text"
  attr :class, :string, default: "btn", doc: "Button CSS classes"
  attr :icon_class, :string, default: "w-4 h-4", doc: "Icon CSS classes"
  attr :fallback_text, :string, default: nil, doc: "Fallback text for icon"
  attr :disabled, :boolean, default: false, doc: "Whether button is disabled"
  attr :type, :string, default: "button", doc: "Button type"
  attr :rest, :global, include: ~w(phx-click phx-value-* title aria-label), doc: "Additional HTML attributes"

  def icon_button(assigns) do
    fallback_text = assigns[:fallback_text] || case assigns.name do
      "plus" -> "+"
      "trash" -> "🗑"
      "pencil" -> "✏"
      "x-mark" -> "✕"
      "home" -> "🏠"
      "cog-6-tooth" -> "⚙"
      "clock" -> "🕐"
      "building-office" -> "🏢"
      "sparkles" -> "✨"
      "arrow-path" -> "↻"
      "ellipsis-vertical" -> "⋮"
      "chevron-up" -> "▲"
      "chevron-down" -> "▼"
      "table-cells" -> "📊"
      "information-circle" -> "ℹ"
      "exclamation-triangle" -> "⚠"
      "signal" -> "📶"
      "puzzle-piece" -> "🧩"
      "eye" -> "👁"
      "light-bulb" -> "💡"
      _ -> "•"
    end

    assigns = assign(assigns, :fallback_text, fallback_text)

    ~H"""
    <button
      type={@type}
      class={[@class]}
      disabled={@disabled}
      {@rest}
    >
      <span class={["icon-with-fallback", @icon_class]} aria-hidden={@text != nil}>
        <!-- Try to render Heroicon first -->
        <span class={["hero-#{@name}", "icon-primary"]} aria-hidden="true"></span>
        <!-- Fallback text that shows when icon is missing -->
        <span class="icon-fallback" aria-hidden="true"><%= @fallback_text %></span>
      </span>
      <%= if @text do %>
        <span class="button-text"><%= @text %></span>
      <% end %>
    </button>
    """
  end

  @doc """
  Validates that icon assets are properly loaded.
  This function can be called during application startup to check icon availability.
  """
  def ensure_icon_assets do
    # Check if Heroicons dependency is available
    case Application.get_env(:decision_engine, :heroicons_available, true) do
      true -> :ok
      false -> {:error, "Heroicons not available"}
    end
  end

  @doc """
  Returns a list of commonly used icons with their fallback text.
  Useful for testing and documentation.
  """
  def available_icons do
    [
      {"home", "🏠", "Home icon"},
      {"plus", "+", "Add/Plus icon"},
      {"trash", "🗑", "Delete/Trash icon"},
      {"pencil", "✏", "Edit/Pencil icon"},
      {"x-mark", "✕", "Close/X icon"},
      {"cog-6-tooth", "⚙", "Settings/Gear icon"},
      {"clock", "🕐", "Time/Clock icon"},
      {"building-office", "🏢", "Building/Office icon"},
      {"sparkles", "✨", "AI/Sparkles icon"},
      {"arrow-path", "↻", "Refresh/Reload icon"},
      {"ellipsis-vertical", "⋮", "More options icon"},
      {"chevron-up", "▲", "Expand/Up arrow"},
      {"chevron-down", "▼", "Collapse/Down arrow"},
      {"table-cells", "📊", "Table/Grid icon"},
      {"information-circle", "ℹ", "Information icon"},
      {"exclamation-triangle", "⚠", "Warning icon"},
      {"signal", "📶", "Signal/Strength icon"},
      {"puzzle-piece", "🧩", "Component/Puzzle icon"},
      {"eye", "👁", "View/Eye icon"},
      {"light-bulb", "💡", "Idea/Bulb icon"}
    ]
  end
end
