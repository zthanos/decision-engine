# lib/decision_engine_web/components/core_components.ex
defmodule DecisionEngineWeb.CoreComponents do
  use Phoenix.Component
  # alias Phoenix.LiveView.JS
  # import DecisionEngineWeb.Gettext

  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  attr :replace, :boolean, default: false
  attr :method, :string, default: nil
  attr :csrf_token, :any, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(download hreflang referrerpolicy rel target type)
  slot :inner_block, required: true

  def nav_link(%{navigate: to} = assigns) when is_binary(to) do
    ~H"""
    <a href={@navigate} data-phx-link="redirect" data-phx-link-state="push" class={@class} {@rest}>
      <%= render_slot(@inner_block) %>
    </a>
    """
  end

  def nav_link(%{patch: to} = assigns) when is_binary(to) do
    ~H"""
    <a href={@patch} data-phx-link="patch" data-phx-link-state="push" class={@class} {@rest}>
      <%= render_slot(@inner_block) %>
    </a>
    """
  end

  def nav_link(%{} = assigns) do
    ~H"""
    <a href={@href} class={@class} {@rest}>
      <%= render_slot(@inner_block) %>
    </a>
    """
  end

  def page_title(assigns) do
    ~H"""
    <title><%= @suffix %></title>
    """
  end
end
