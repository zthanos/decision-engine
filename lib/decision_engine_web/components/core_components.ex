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
  attr :aria_label, :string, default: nil
  attr :aria_current, :string, default: nil
  attr :rest, :global, include: ~w(download hreflang referrerpolicy rel target type)
  slot :inner_block, required: true

  def nav_link(%{navigate: to} = assigns) when is_binary(to) do
    ~H"""
    <a
      href={@navigate}
      data-phx-link="redirect"
      data-phx-link-state="push"
      class={@class}
      aria-label={@aria_label}
      aria-current={@aria_current}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </a>
    """
  end

  def nav_link(%{patch: to} = assigns) when is_binary(to) do
    ~H"""
    <a
      href={@patch}
      data-phx-link="patch"
      data-phx-link-state="push"
      class={@class}
      aria-label={@aria_label}
      aria-current={@aria_current}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </a>
    """
  end

  def nav_link(%{} = assigns) do
    ~H"""
    <a
      href={@href}
      class={@class}
      aria-label={@aria_label}
      aria-current={@aria_current}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </a>
    """
  end

  def page_title(assigns) do
    ~H"""
    <title><%= @suffix %></title>
    """
  end

  @doc """
  Renders a decision table component for domain patterns.
  """
  attr :patterns, :list, required: true
  attr :max_patterns, :integer, default: 5
  attr :class, :string, default: ""

  def decision_table(assigns) do
    ~H"""
    <div class={"decision-table-wrapper #{@class}"} role="region" aria-label="Decision patterns table">
      <%= if length(@patterns) > 0 do %>
        <div class="space-y-4" role="list" aria-label="Decision patterns">
          <%= for {pattern, index} <- Enum.with_index(Enum.take(@patterns, @max_patterns)) do %>
            <div
              class="decision-pattern-card bg-base-50 rounded-lg p-4 border border-base-200 hover:border-primary/30 transition-all duration-300 focus-within:ring-2 focus-within:ring-primary/50"
              role="listitem"
              tabindex="0"
              aria-label={"Pattern #{index + 1}: #{pattern["outcome"]} with #{trunc((pattern["score"] || 0.5) * 100)}% confidence"}
            >
              <!-- Pattern Header -->
              <div class="flex items-center justify-between mb-3">
                <div class="flex items-center gap-3">
                  <div class="badge badge-primary badge-lg font-mono" aria-label={"Pattern ID: #{pattern["id"] || "pattern_#{index + 1}"}"}>
                    <%= pattern["id"] || "pattern_#{index + 1}" %>
                  </div>
                  <div class="flex items-center gap-2">
                    <span class="text-sm font-semibold text-base-content/80" aria-hidden="true">→</span>
                    <span class="font-semibold text-base-content" aria-label="Outcome"><%= pattern["outcome"] %></span>
                  </div>
                </div>
                <div class="flex items-center gap-2">
                  <div class="radial-progress text-sm font-bold"
                       style={"--value:#{trunc((pattern["score"] || 0.5) * 100)}; --size:3rem; --thickness:4px;"}
                       role="progressbar"
                       aria-valuenow={trunc((pattern["score"] || 0.5) * 100)}
                       aria-valuemin="0"
                       aria-valuemax="100"
                       aria-label={"Confidence score: #{trunc((pattern["score"] || 0.5) * 100)} percent"}>
                    <%= trunc((pattern["score"] || 0.5) * 100) %>%
                  </div>
                </div>
              </div>

              <!-- Pattern Summary -->
              <%= if pattern["summary"] do %>
                <div class="mb-3">
                  <p class="text-sm text-base-content/70 italic" aria-label="Pattern description">
                    <%= pattern["summary"] %>
                  </p>
                </div>
              <% end %>

              <!-- Conditions Grid -->
              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4" role="group" aria-label="Pattern conditions">
                <!-- Use When Conditions -->
                <%= if pattern["use_when"] && length(pattern["use_when"]) > 0 do %>
                  <div class="condition-group" role="group" aria-label="Use when conditions">
                    <div class="flex items-center gap-2 mb-2">
                      <span class="badge badge-success badge-sm font-semibold" role="status">USE WHEN</span>
                      <span class="text-xs text-base-content/60" aria-label={"#{length(pattern["use_when"])} conditions"}>
                        <%= length(pattern["use_when"]) %> condition<%= if length(pattern["use_when"]) > 1, do: "s" %>
                      </span>
                    </div>
                    <div class="space-y-2" role="list">
                      <%= for condition <- pattern["use_when"] do %>
                        <div
                          class="condition-item bg-success/10 border border-success/20 rounded-md p-2"
                          role="listitem"
                          aria-label={"Condition: #{condition["field"]} #{format_operator(condition["op"])} #{format_value_display(condition["value"])}"}
                        >
                          <div class="text-xs font-mono text-success">
                            <span class="font-semibold"><%= condition["field"] %></span>
                            <span class="mx-1 opacity-70" aria-hidden="true"><%= format_operator(condition["op"]) %></span>
                            <span class="font-medium"><%= format_value_display(condition["value"]) %></span>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <!-- Avoid When Conditions -->
                <%= if pattern["avoid_when"] && length(pattern["avoid_when"]) > 0 do %>
                  <div class="condition-group" role="group" aria-label="Avoid when conditions">
                    <div class="flex items-center gap-2 mb-2">
                      <span class="badge badge-error badge-sm font-semibold" role="status">AVOID WHEN</span>
                      <span class="text-xs text-base-content/60" aria-label={"#{length(pattern["avoid_when"])} conditions"}>
                        <%= length(pattern["avoid_when"]) %> condition<%= if length(pattern["avoid_when"]) > 1, do: "s" %>
                      </span>
                    </div>
                    <div class="space-y-2" role="list">
                      <%= for condition <- pattern["avoid_when"] do %>
                        <div
                          class="condition-item bg-error/10 border border-error/20 rounded-md p-2"
                          role="listitem"
                          aria-label={"Condition: #{condition["field"]} #{format_operator(condition["op"])} #{format_value_display(condition["value"])}"}
                        >
                          <div class="text-xs font-mono text-error">
                            <span class="font-semibold"><%= condition["field"] %></span>
                            <span class="mx-1 opacity-70" aria-hidden="true"><%= format_operator(condition["op"]) %></span>
                            <span class="font-medium"><%= format_value_display(condition["value"]) %></span>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <!-- No Conditions Message -->
                <%= if (!pattern["use_when"] || length(pattern["use_when"]) == 0) &&
                       (!pattern["avoid_when"] || length(pattern["avoid_when"]) == 0) do %>
                  <div class="col-span-full text-center py-4" role="status" aria-live="polite">
                    <span class="text-base-content/40 text-sm italic">No conditions configured for this pattern</span>
                  </div>
                <% end %>
              </div>

              <!-- Typical Use Cases -->
              <%= if pattern["typical_use_cases"] && length(pattern["typical_use_cases"]) > 0 do %>
                <div class="mt-4 pt-3 border-t border-base-200" role="group" aria-label="Typical use cases">
                  <div class="flex items-center gap-2 mb-2">
                    <span class="hero-light-bulb w-4 h-4 text-warning" aria-hidden="true"></span>
                    <span class="text-xs font-semibold text-base-content/70">Typical Use Cases</span>
                  </div>
                  <div class="flex flex-wrap gap-1" role="list" aria-label="Use case examples">
                    <%= for use_case <- Enum.take(pattern["typical_use_cases"], 4) do %>
                      <span class="badge badge-outline badge-xs" role="listitem"><%= use_case %></span>
                    <% end %>
                    <%= if length(pattern["typical_use_cases"]) > 4 do %>
                      <span class="badge badge-ghost badge-xs" role="listitem" aria-label={"#{length(pattern["typical_use_cases"]) - 4} additional use cases"}>
                        +<%= length(pattern["typical_use_cases"]) - 4 %> more
                      </span>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <%= if length(@patterns) > @max_patterns do %>
          <div class="text-center mt-4 pt-4 border-t border-base-200" role="status" aria-live="polite">
            <span class="text-sm text-base-content/60">
              Showing <%= @max_patterns %> of <%= length(@patterns) %> patterns
            </span>
            <div class="text-xs text-base-content/40 mt-1">
              Edit domain to view all patterns
            </div>
          </div>
        <% end %>
      <% else %>
        <div class="text-center py-12 text-base-content/60" role="status" aria-live="polite">
          <span class="hero-table-cells w-16 h-16 mx-auto mb-4 opacity-30" aria-hidden="true"></span>
          <h3 class="text-lg font-semibold mb-2">No Decision Patterns</h3>
          <p class="text-sm">This domain doesn't have any decision patterns configured yet.</p>
          <p class="text-xs mt-1 opacity-70">Edit the domain to add patterns.</p>
        </div>
      <% end %>
    </div>
    """
  end



  # Helper functions for the enhanced decision table
  defp format_operator(op) do
    case op do
      "in" -> "IN"
      "intersects" -> "∩"
      "not_intersects" -> "∉"
      "equals" -> "="
      "not_equals" -> "≠"
      "contains" -> "⊃"
      "not_contains" -> "⊅"
      _ -> String.upcase(op)
    end
  end

  defp format_value_display(value) when is_list(value) do
    case length(value) do
      0 -> "[]"
      1 -> "[#{hd(value)}]"
      2 -> "[#{Enum.join(value, ", ")}]"
      n when n <= 4 -> "[#{Enum.join(value, ", ")}]"
      n -> "[#{Enum.take(value, 3) |> Enum.join(", ")}, +#{n - 3} more]"
    end
  end

  defp format_value_display(value) when is_binary(value) do
    if String.length(value) > 20 do
      "\"#{String.slice(value, 0, 17)}...\""
    else
      "\"#{value}\""
    end
  end

  defp format_value_display(value), do: to_string(value)
end
