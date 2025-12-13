# lib/decision_engine_web/components/logo.ex
defmodule DecisionEngineWeb.Components.Logo do
  @moduledoc """
  Logo component with proper asset handling and fallback mechanisms.

  Provides responsive logo display with graceful fallbacks for missing assets.
  Validates Requirements 1.1, 1.2, 1.3, 1.4, 1.5.
  """

  use Phoenix.Component

  # Import verified routes for ~p sigil
  use Phoenix.VerifiedRoutes,
    endpoint: DecisionEngineWeb.Endpoint,
    router: DecisionEngineWeb.Router,
    statics: DecisionEngineWeb.static_paths()

  @doc """
  Renders the application logo with fallback handling.

  ## Attributes

    * `size` - Size class for the logo (default: "h-8 w-auto")
    * `class` - Additional CSS classes
    * `show_text` - Whether to show text alongside logo (default: true)
    * `text` - Text to display (default: "Decision Engine")
    * `link` - Whether logo should be a link (default: true)
    * `href` - Link destination (default: "/")

  ## Examples

      <.logo />
      <.logo size="h-12 w-auto" />
      <.logo show_text={false} />
      <.logo class="mr-4" text="Custom Text" />
  """
  attr :size, :string, default: "h-8 w-auto"
  attr :class, :string, default: ""
  attr :show_text, :boolean, default: true
  attr :text, :string, default: "Decision Engine"
  attr :link, :boolean, default: true
  attr :href, :string, default: "/"
  attr :aria_label, :string, default: nil
  attr :rest, :global

  def logo(assigns) do
    ~H"""
    <%= if @link do %>
      <a
        href={@href}
        class={["flex items-center gap-2", @class]}
        aria-label={@aria_label}
        {@rest}
      >
        <.logo_image size={@size} />
        <%= if @show_text do %>
          <span class="text-xl font-semibold hidden sm:inline"><%= @text %></span>
        <% end %>
      </a>
    <% else %>
      <div
        class={["flex items-center gap-2", @class]}
        aria-label={@aria_label}
        {@rest}
      >
        <.logo_image size={@size} />
        <%= if @show_text do %>
          <span class="text-xl font-semibold hidden sm:inline"><%= @text %></span>
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders just the logo image with fallback handling.

  ## Attributes

    * `size` - Size class for the logo (default: "h-8 w-auto")
    * `class` - Additional CSS classes
    * `alt` - Alt text for accessibility (default: "Decision Engine Logo")
  """
  attr :size, :string, default: "h-8 w-auto"
  attr :class, :string, default: ""
  attr :alt, :string, default: "Decision Engine Logo"
  attr :rest, :global

  def logo_image(assigns) do
    ~H"""
    <div class={["logo-container relative", @class]} {@rest}>
      <!-- Primary logo image -->
      <img
        src={~p"/images/logo.png"}
        alt={@alt}
        class={["logo-image transition-opacity duration-200", @size]}
        onerror="this.style.display='none'; this.nextElementSibling.style.display='flex';"
      />

      <!-- Fallback icon when logo fails to load -->
      <div class={[
        "logo-fallback hidden items-center justify-center rounded-lg bg-primary text-primary-content font-bold text-lg",
        @size
      ]} style="display: none;">
        <span class="hero-sparkles w-6 h-6"></span>
      </div>
    </div>
    """
  end

  @doc """
  Renders logo with text for use in headers and navigation.

  This is a convenience function that always shows text and is optimized for navigation use.

  ## Attributes

    * `size` - Size class for the logo (default: "h-8 w-auto")
    * `class` - Additional CSS classes
    * `text` - Text to display (default: "Decision Engine")
    * `href` - Link destination (default: "/")
    * `aria_label` - ARIA label for accessibility
  """
  attr :size, :string, default: "h-8 w-auto"
  attr :class, :string, default: ""
  attr :text, :string, default: "Decision Engine"
  attr :href, :string, default: "/"
  attr :aria_label, :string, default: nil
  attr :rest, :global

  def logo_with_text(assigns) do
    # Set default aria_label if not provided
    assigns = assign_new(assigns, :aria_label, fn -> assigns.text end)

    ~H"""
    <.logo
      size={@size}
      class={@class}
      text={@text}
      href={@href}
      show_text={true}
      link={true}
      aria-label={@aria_label}
      {@rest}
    />
    """
  end

  @doc """
  Renders a compact logo for mobile or small spaces.

  ## Attributes

    * `class` - Additional CSS classes
    * `href` - Link destination (default: "/")
  """
  attr :class, :string, default: ""
  attr :href, :string, default: "/"
  attr :rest, :global

  def logo_compact(assigns) do
    ~H"""
    <.logo
      size="h-6 w-auto"
      class={@class}
      href={@href}
      show_text={false}
      link={true}
      {@rest}
    />
    """
  end
end
