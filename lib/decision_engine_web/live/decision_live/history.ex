# lib/decision_engine_web/live/decision_live/history.ex
defmodule DecisionEngineWeb.DecisionLive.History do
  use DecisionEngineWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, history: load_history())}
  end

  @impl true
  def handle_event("delete", %{"timestamp" => timestamp}, socket) do
    timestamp_int = String.to_integer(timestamp)
    :ets.delete(:decision_history, timestamp_int)
    {:noreply, assign(socket, history: load_history())}
  end

  @impl true
  def handle_event("clear_all", _, socket) do
    :ets.delete_all_objects(:decision_history)
    {:noreply, assign(socket, history: [])}
  end

  defp load_history do
    case :ets.whereis(:decision_history) do
      :undefined -> []
      _table ->
        :ets.tab2list(:decision_history)
        |> Enum.sort_by(fn {timestamp, _} -> timestamp end, :desc)
        |> Enum.map(fn {timestamp, result} -> Map.put(result, :_timestamp, timestamp) end)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <div class="navbar bg-primary text-primary-content shadow-lg">
        <div class="flex-1">
          <a href="/" class="btn btn-ghost text-xl">
            <span class="hero-sparkles w-6 h-6 mr-2"></span>
            Decision Engine
          </a>
        </div>
        <div class="flex-none gap-2">
          <.nav_link navigate="/" class="btn btn-ghost btn-sm">
            <span class="hero-home w-5 h-5"></span>
            Home
          </.nav_link>
          <.nav_link navigate="/domains" class="btn btn-ghost btn-sm">
            <span class="hero-building-office w-5 h-5"></span>
            Domains
          </.nav_link>
          <.nav_link navigate="/settings" class="btn btn-ghost btn-sm">
            <span class="hero-cog-6-tooth w-5 h-5"></span>
            Settings
          </.nav_link>
        </div>
      </div>

      <div class="container mx-auto p-6 max-w-6xl">
        <div class="flex justify-between items-center mb-6">
          <h1 class="text-3xl font-bold">
            <span class="hero-clock w-8 h-8 inline"></span>
            Decision History
          </h1>
          <%= if length(@history) > 0 do %>
            <button phx-click="clear_all" class="btn btn-error btn-sm">
              <span class="hero-trash w-5 h-5"></span>
              Clear All
            </button>
          <% end %>
        </div>

        <%= if length(@history) == 0 do %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body items-center text-center">
              <span class="hero-inbox w-16 h-16 text-base-300 mb-4"></span>
              <h2 class="card-title">No History Yet</h2>
              <p>Your decision history will appear here after you analyze scenarios.</p>
              <.nav_link navigate="/" class="btn btn-primary mt-4">
                Start Analyzing
              </.nav_link>
            </div>
          </div>
        <% else %>
          <div class="space-y-4">
            <%= for result <- @history do %>
              <div class="card bg-base-100 shadow-lg hover:shadow-xl transition-shadow">
                <div class="card-body">
                  <div class="flex justify-between items-start">
                    <div class="flex-1">
                      <div class="flex items-center gap-2 mb-2">
                        <div class={[
                          "badge",
                          get_outcome_badge_class(result.decision.outcome)
                        ]}>
                          <%= result.decision.outcome %>
                        </div>
                        <div class="badge badge-ghost">
                          Score: <%= trunc(result.decision.score * 100) %>%
                        </div>
                      </div>
                      <h3 class="font-bold text-lg"><%= result.decision.summary %></h3>
                      <p class="text-sm text-base-content/60 mt-1">
                        <%= Calendar.strftime(result.timestamp, "%B %d, %Y at %H:%M:%S") %>
                      </p>
                    </div>
                    <button
                      phx-click="delete"
                      phx-value-timestamp={result._timestamp}
                      class="btn btn-ghost btn-sm"
                    >
                      <span class="hero-trash w-5 h-5"></span>
                    </button>
                  </div>

                  <div class="divider my-2"></div>

                  <div class="collapse collapse-arrow bg-base-200">
                    <input type="checkbox" />
                    <div class="collapse-title font-medium">View Details</div>
                    <div class="collapse-content space-y-4">
                      <div>
                        <h4 class="font-semibold mb-2">Signals</h4>
                        <div class="flex flex-wrap gap-2">
                          <%= for {key, value} <- result.signals do %>
                            <div class="badge badge-outline badge-sm">
                              <%= key %>: <%= format_value(value) %>
                            </div>
                          <% end %>
                        </div>
                      </div>

                      <%= if result.justification do %>
                        <div>
                          <h4 class="font-semibold mb-2">Justification</h4>
                          <div class="text-sm prose prose-sm max-w-none">
                            <%= raw(get_rendered_justification(result.justification)) %>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_value(value) when is_list(value) do
    value
    |> Enum.map(&format_single_value/1)
    |> Enum.join(", ")
  end
  defp format_value(value) when is_map(value), do: inspect(value)
  defp format_value(value), do: to_string(value)

  defp format_single_value(value) when is_map(value), do: inspect(value)
  defp format_single_value(value), do: to_string(value)

  # Handle both new structured justification and legacy string justification
  defp get_rendered_justification(%{rendered_html: html}), do: html
  defp get_rendered_justification(justification) when is_binary(justification) do
    DecisionEngine.MarkdownRenderer.render_to_html!(justification)
  end

  defp get_outcome_badge_class(outcome) do
    case outcome do
      "prefer_power_automate" -> "badge-success"
      "power_automate_possible_with_caveats" -> "badge-warning"
      "avoid_power_automate_use_logic_apps_or_integration_platform" -> "badge-error"
      "use_power_automate_desktop" -> "badge-info"
      _ -> "badge-ghost"
    end
  end
end
