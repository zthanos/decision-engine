# lib/decision_engine_web/live/decision_live/history.ex
defmodule DecisionEngineWeb.DecisionLive.History do
  use DecisionEngineWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:history_data, [])
     |> assign(:search_query, "")
     |> assign(:current_page, 1)
     |> assign(:per_page, 20)
     |> assign(:total_count, 0)
     |> assign(:total_pages, 1)
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = String.to_integer(params["page"] || "1")
    per_page = String.to_integer(params["per_page"] || "20")
    search_query = params["search"] || ""

    {history_data, total_count} = load_history_paginated(page, per_page, search_query)

    {:noreply,
     socket
     |> assign(:history_data, history_data)
     |> assign(:search_query, search_query)
     |> assign(:current_page, page)
     |> assign(:per_page, per_page)
     |> assign(:total_count, total_count)
     |> assign(:total_pages, calculate_total_pages(total_count, per_page))
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("delete", %{"entry_id" => entry_id}, socket) do
    case DecisionEngine.HistoryManager.delete_entry(entry_id) do
      :ok ->
        # Reload current page after deletion
        {history_data, total_count} = load_history_paginated(
          socket.assigns.current_page,
          socket.assigns.per_page,
          socket.assigns.search_query
        )

        # If current page is empty and not the first page, go to previous page
        {new_page, new_history_data, new_total_count} =
          if length(history_data) == 0 and socket.assigns.current_page > 1 do
            new_page = socket.assigns.current_page - 1
            {new_history_data, new_total_count} = load_history_paginated(new_page, socket.assigns.per_page, socket.assigns.search_query)
            {new_page, new_history_data, new_total_count}
          else
            {socket.assigns.current_page, history_data, total_count}
          end

        {:noreply,
         socket
         |> assign(:history_data, new_history_data)
         |> assign(:current_page, new_page)
         |> assign(:total_count, new_total_count)
         |> assign(:total_pages, calculate_total_pages(new_total_count, socket.assigns.per_page))
         |> put_flash(:info, "Entry deleted successfully")}
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete entry")}
    end
  end

  @impl true
  def handle_event("clear_all", _, socket) do
    case DecisionEngine.HistoryManager.clear_history() do
      :ok ->
        {:noreply,
         socket
         |> assign(:history_data, [])
         |> assign(:current_page, 1)
         |> assign(:total_count, 0)
         |> assign(:total_pages, 1)
         |> put_flash(:info, "History cleared successfully")}
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to clear history")}
    end
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    # Reset to first page when searching
    {history_data, total_count} = load_history_paginated(1, socket.assigns.per_page, query)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:history_data, history_data)
     |> assign(:current_page, 1)
     |> assign(:total_count, total_count)
     |> assign(:total_pages, calculate_total_pages(total_count, socket.assigns.per_page))
     |> push_patch(to: build_history_path(1, socket.assigns.per_page, query))}
  end

  @impl true
  def handle_event("export", %{"format" => format}, socket) do
    format_atom = String.to_atom(format)
    case DecisionEngine.HistoryManager.export_history(format_atom) do
      {:ok, %{data: data, metadata: metadata}} ->
        filename = "history_export_#{Date.utc_today()}.#{format}"
        {:noreply,
         socket
         |> push_event("download", %{filename: filename, data: data, mime_type: get_mime_type(format_atom)})
         |> put_flash(:info, "Export ready: #{metadata.entry_count} entries (#{format_bytes(metadata.data_size)}) in #{metadata.processing_time_ms}ms")}
      {:ok, data} when is_binary(data) ->
        # Fallback for old format without metadata
        filename = "history_export_#{Date.utc_today()}.#{format}"
        {:noreply,
         socket
         |> push_event("download", %{filename: filename, data: data, mime_type: get_mime_type(format_atom)})
         |> put_flash(:info, "Export ready for download")}
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to export history")}
    end
  end

  @impl true
  def handle_event("goto_page", %{"page" => page_str}, socket) do
    page = String.to_integer(page_str)
    {history_data, total_count} = load_history_paginated(page, socket.assigns.per_page, socket.assigns.search_query)

    {:noreply,
     socket
     |> assign(:history_data, history_data)
     |> assign(:current_page, page)
     |> assign(:total_count, total_count)
     |> assign(:total_pages, calculate_total_pages(total_count, socket.assigns.per_page))
     |> push_patch(to: build_history_path(page, socket.assigns.per_page, socket.assigns.search_query))}
  end

  @impl true
  def handle_event("change_per_page", %{"per_page" => per_page_str}, socket) do
    per_page = String.to_integer(per_page_str)
    # Reset to first page when changing per_page
    {history_data, total_count} = load_history_paginated(1, per_page, socket.assigns.search_query)

    {:noreply,
     socket
     |> assign(:history_data, history_data)
     |> assign(:current_page, 1)
     |> assign(:per_page, per_page)
     |> assign(:total_count, total_count)
     |> assign(:total_pages, calculate_total_pages(total_count, per_page))
     |> push_patch(to: build_history_path(1, per_page, socket.assigns.search_query))}
  end

  defp load_history_paginated(page, per_page, "") do
    case DecisionEngine.HistoryManager.load_history_paginated(page, per_page) do
      {:ok, %{entries: entries, total: total}} -> {entries, total}
      {:error, _} -> {[], 0}
    end
  end

  defp load_history_paginated(page, per_page, query) do
    case DecisionEngine.HistoryManager.search_history_paginated(query, page, per_page) do
      {:ok, %{entries: entries, total: total}} -> {entries, total}
      {:error, _} -> {[], 0}
    end
  end

  defp calculate_total_pages(total_count, per_page) do
    max(ceil(total_count / per_page), 1)
  end

  defp build_history_path(page, per_page, search_query) do
    query_params = []
    query_params = if page > 1, do: [{"page", page} | query_params], else: query_params
    query_params = if per_page != 20, do: [{"per_page", per_page} | query_params], else: query_params
    query_params = if search_query != "", do: [{"search", search_query} | query_params], else: query_params

    case query_params do
      [] -> "/history"
      params -> "/history?" <> URI.encode_query(params)
    end
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp pagination_range(current_page, total_pages) do
    # Show up to 7 page numbers with current page in the middle when possible
    max_visible = 7

    cond do
      total_pages <= max_visible ->
        1..total_pages

      current_page <= 4 ->
        1..max_visible

      current_page >= total_pages - 3 ->
        (total_pages - max_visible + 1)..total_pages

      true ->
        (current_page - 3)..(current_page + 3)
    end
  end

  defp get_mime_type(:json), do: "application/json"
  defp get_mime_type(:csv), do: "text/csv"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <nav class="navbar bg-primary text-primary-content shadow-lg" role="navigation" aria-label="Main navigation">
        <div class="flex-1">
          <.logo_with_text
            class="btn btn-ghost text-xl"
            size="h-6 w-auto"
            text="Decision Engine"
            href="/"
            aria_label="Decision Engine home"
          />
        </div>
        <div class="flex-none gap-2" role="menubar">
          <.nav_link
            navigate="/"
            class="btn btn-ghost btn-sm"
            aria_label="Go to home page"
            role="menuitem"
          >
            <span class="hero-home w-5 h-5" aria-hidden="true"></span>
            Home
          </.nav_link>
          <.nav_link
            navigate="/domains"
            class="btn btn-ghost btn-sm"
            aria_label="Go to domain management"
            role="menuitem"
          >
            <span class="hero-building-office w-5 h-5" aria-hidden="true"></span>
            Domains
          </.nav_link>
          <.nav_link
            navigate="/history"
            class="btn btn-ghost btn-sm"
            aria_current="page"
            aria_label="Current page: Decision history"
            role="menuitem"
          >
            <span class="hero-clock w-5 h-5" aria-hidden="true"></span>
            History
          </.nav_link>
          <.nav_link
            navigate="/settings"
            class="btn btn-ghost btn-sm"
            aria_label="Go to settings"
            role="menuitem"
          >
            <span class="hero-cog-6-tooth w-5 h-5" aria-hidden="true"></span>
            Settings
          </.nav_link>
        </div>
      </nav>

      <div class="container mx-auto p-6 max-w-6xl">
        <header class="flex justify-between items-center mb-6">
          <div>
            <h1 class="text-3xl font-bold" id="page-title">
              <span class="hero-clock w-8 h-8 inline" aria-hidden="true"></span>
              Decision History
            </h1>
            <p class="text-base-content/60 mt-2" aria-describedby="page-title">
              View and manage your analysis history
              <%= if @total_count > 0 do %>
                (<%= @total_count %> <%= if @total_count == 1, do: "entry", else: "entries" %>)
                <%= if @search_query != "" do %>
                  - showing <%= length(@history_data) %> matches
                <% end %>
              <% end %>
            </p>
          </div>
          <%= if @total_count > 0 do %>
            <div class="flex gap-2" role="toolbar" aria-label="History actions">
              <!-- Export Dropdown -->
              <div class="dropdown dropdown-end">
                <div
                  tabindex="0"
                  role="button"
                  class="btn btn-outline btn-sm"
                  aria-label="Export history options"
                  aria-haspopup="true"
                  aria-expanded="false"
                >
                  <span class="hero-arrow-down-tray w-5 h-5" aria-hidden="true"></span>
                  Export
                </div>
                <ul
                  tabindex="0"
                  class="dropdown-content menu bg-base-100 rounded-box z-[1] w-52 p-2 shadow"
                  role="menu"
                  aria-label="Export format options"
                >
                  <li role="none">
                    <a
                      phx-click="export"
                      phx-value-format="json"
                      role="menuitem"
                      aria-label="Export history as JSON file"
                    >
                      Export as JSON
                    </a>
                  </li>
                  <li role="none">
                    <a
                      phx-click="export"
                      phx-value-format="csv"
                      role="menuitem"
                      aria-label="Export history as CSV file"
                    >
                      Export as CSV
                    </a>
                  </li>
                </ul>
              </div>

              <button
                phx-click="clear_all"
                class="btn btn-error btn-sm"
                aria-label="Clear all history entries"
                aria-describedby="clear-all-warning"
              >
                <span class="hero-trash w-5 h-5" aria-hidden="true"></span>
                Clear All
              </button>
              <div id="clear-all-warning" class="sr-only">
                This action will permanently delete all history entries and cannot be undone
              </div>
            </div>
          <% end %>
        </header>

        <!-- Search Bar and Pagination Controls -->
        <%= if @total_count > 0 do %>
          <section class="card bg-base-100 shadow-lg mb-6" aria-label="Search and pagination controls">
            <div class="card-body">
              <div class="flex flex-col lg:flex-row gap-4 items-start lg:items-center justify-between">
                <!-- Search Form -->
                <form phx-change="search" phx-submit="search" role="search" class="flex-1 max-w-md">
                  <div class="form-control">
                    <label for="history-search" class="label">
                      <span class="label-text font-semibold">Search History</span>
                    </label>
                    <div class="input-group">
                      <input
                        id="history-search"
                        type="text"
                        name="search[query]"
                        value={@search_query}
                        placeholder="Search history by scenario text..."
                        class="input input-bordered flex-1"
                        aria-label="Search history entries"
                        aria-describedby="search-help"
                      />
                      <button
                        type="submit"
                        class="btn btn-square"
                        aria-label="Execute search"
                      >
                        <span class="hero-magnifying-glass w-5 h-5" aria-hidden="true"></span>
                      </button>
                    </div>
                    <div id="search-help" class="label">
                      <span class="label-text-alt">Search through scenario descriptions and outcomes</span>
                    </div>
                  </div>
                </form>

                <!-- Per Page Selector -->
                <div class="form-control">
                  <label for="per-page-select" class="label">
                    <span class="label-text font-semibold">Entries per page</span>
                  </label>
                  <select
                    id="per-page-select"
                    phx-change="change_per_page"
                    name="per_page"
                    class="select select-bordered select-sm"
                    aria-label="Number of entries per page"
                  >
                    <option value="10" selected={@per_page == 10}>10</option>
                    <option value="20" selected={@per_page == 20}>20</option>
                    <option value="50" selected={@per_page == 50}>50</option>
                    <option value="100" selected={@per_page == 100}>100</option>
                  </select>
                </div>
              </div>

              <%= if @search_query != "" do %>
                <div
                  class="text-sm text-base-content/60 mt-2"
                  role="status"
                  aria-live="polite"
                  aria-label="Search results"
                >
                  Showing <%= length(@history_data) %> of <%= @total_count %> entries
                  <%= if length(@history_data) == 0 do %>
                    - no matches found
                  <% end %>
                </div>
              <% end %>
            </div>
          </section>
        <% end %>

        <%= if @loading do %>
          <section class="card bg-base-100 shadow-xl" role="status" aria-live="polite">
            <div class="card-body items-center text-center">
              <span class="loading loading-spinner loading-lg text-primary" aria-hidden="true"></span>
              <h2 class="card-title text-xl mb-3">Loading History...</h2>
              <p class="text-base-content/70">Please wait while we fetch your analysis history.</p>
            </div>
          </section>
        <% else %>
          <%= if @total_count == 0 do %>
            <section class="card bg-base-100 shadow-xl" role="status" aria-live="polite">
              <div class="card-body items-center text-center">
                <span class="hero-inbox w-16 h-16 text-base-300 mb-4" aria-hidden="true"></span>
                <h2 class="card-title text-xl mb-3">No History Yet</h2>
                <p class="text-base-content/70 mb-4 max-w-md">
                  Your decision history will appear here after you analyze scenarios.
                  Start by describing an automation or integration scenario to get personalized recommendations.
                </p>
                <.nav_link
                  navigate="/"
                  class="btn btn-primary mt-4"
                  aria_label="Go to home page to start analyzing scenarios"
                >
                  <span class="hero-play w-5 h-5" aria-hidden="true"></span>
                  Start Analyzing
                </.nav_link>
                <div class="mt-6 text-sm text-base-content/50">
                  <p>💡 Tip: Try describing scenarios like:</p>
                  <ul class="list-disc list-inside mt-2 space-y-1 text-left">
                    <li>"Automate approval workflows in SharePoint"</li>
                    <li>"Sync data between systems in real-time"</li>
                    <li>"Process documents with AI and notifications"</li>
                  </ul>
                </div>
              </div>
            </section>
          <% else %>
            <%= if length(@history_data) == 0 and @search_query != "" do %>
              <section class="card bg-base-100 shadow-xl" role="status" aria-live="polite">
                <div class="card-body items-center text-center">
                  <span class="hero-magnifying-glass w-16 h-16 text-base-300 mb-4" aria-hidden="true"></span>
                  <h2 class="card-title text-xl mb-3">No Results Found</h2>
                  <p class="text-base-content/70 mb-4">
                    No history entries match your search query: "<strong><%= @search_query %></strong>"
                  </p>
                  <div class="space-y-3">
                    <button
                      phx-click="search"
                      phx-value-search[query]=""
                      class="btn btn-outline"
                      aria-label="Clear search and show all history entries"
                    >
                      <span class="hero-x-mark w-5 h-5" aria-hidden="true"></span>
                      Clear Search
                    </button>
                    <div class="text-sm text-base-content/50">
                      <p>💡 Search tips:</p>
                      <ul class="list-disc list-inside mt-1 space-y-1">
                        <li>Try broader terms like "SharePoint" or "automation"</li>
                        <li>Search by outcome like "Power Automate" or "Logic Apps"</li>
                        <li>Use partial words or phrases from your scenarios</li>
                      </ul>
                    </div>
                  </div>
                </div>
              </section>
            <% else %>
              <!-- Pagination Controls -->
              <%= if @total_pages > 1 do %>
                <section class="flex justify-center mb-6" aria-label="Pagination">
                  <div class="join">
                    <!-- Previous Button -->
                    <%= if @current_page > 1 do %>
                      <button
                        phx-click="goto_page"
                        phx-value-page={@current_page - 1}
                        class="join-item btn btn-sm"
                        aria-label="Go to previous page"
                      >
                        <span class="hero-chevron-left w-4 h-4" aria-hidden="true"></span>
                        Previous
                      </button>
                    <% else %>
                      <button class="join-item btn btn-sm btn-disabled" disabled aria-label="Previous page (disabled)">
                        <span class="hero-chevron-left w-4 h-4" aria-hidden="true"></span>
                        Previous
                      </button>
                    <% end %>

                    <!-- Page Numbers -->
                    <%= for page_num <- pagination_range(@current_page, @total_pages) do %>
                      <%= if page_num == @current_page do %>
                        <button class="join-item btn btn-sm btn-active" aria-current="page" aria-label={"Current page: #{page_num}"}>
                          <%= page_num %>
                        </button>
                      <% else %>
                        <button
                          phx-click="goto_page"
                          phx-value-page={page_num}
                          class="join-item btn btn-sm"
                          aria-label={"Go to page #{page_num}"}
                        >
                          <%= page_num %>
                        </button>
                      <% end %>
                    <% end %>

                    <!-- Next Button -->
                    <%= if @current_page < @total_pages do %>
                      <button
                        phx-click="goto_page"
                        phx-value-page={@current_page + 1}
                        class="join-item btn btn-sm"
                        aria-label="Go to next page"
                      >
                        Next
                        <span class="hero-chevron-right w-4 h-4" aria-hidden="true"></span>
                      </button>
                    <% else %>
                      <button class="join-item btn btn-sm btn-disabled" disabled aria-label="Next page (disabled)">
                        Next
                        <span class="hero-chevron-right w-4 h-4" aria-hidden="true"></span>
                      </button>
                    <% end %>
                  </div>
                </section>
              <% end %>

              <main class="space-y-4" role="main" aria-label="History entries">
                <%= for {result, index} <- Enum.with_index(@history_data) do %>
                  <article
                    class="card bg-base-100 shadow-lg hover:shadow-xl transition-all duration-300 focus-within:ring-2 focus-within:ring-primary/50"
                    tabindex="0"
                    role="article"
                    aria-label={"History entry #{(@current_page - 1) * @per_page + index + 1}: #{get_decision_summary(result.decision)}"}
                    aria-describedby={"entry-#{result.id}-details"}
                  >
                    <div class="card-body">
                      <div class="flex justify-between items-start">
                        <div class="flex-1">
                          <div class="flex items-center gap-2 mb-2" role="group" aria-label="Entry metadata">
                            <div class={[
                              "badge",
                              get_outcome_badge_class(get_decision_outcome(result.decision))
                            ]}
                            role="status"
                            aria-label={"Outcome: #{get_decision_outcome(result.decision)}"}
                            >
                              <%= get_decision_outcome(result.decision) %>
                            </div>
                            <div class="badge badge-ghost" role="status" aria-label={"Confidence score: #{trunc(get_decision_score(result.decision) * 100)} percent"}>
                              Score: <%= trunc(get_decision_score(result.decision) * 100) %>%
                            </div>
                            <div class="badge badge-info badge-sm" role="status" aria-label={"Entry #{(@current_page - 1) * @per_page + index + 1} of #{@total_count}"}>
                              #<%= (@current_page - 1) * @per_page + index + 1 %>
                            </div>
                          </div>
                          <h3 class="font-bold text-lg mb-2" id={"entry-#{result.id}-title"}>
                            <%= get_decision_summary(result.decision) %>
                          </h3>
                          <div class="flex items-center gap-3 text-sm text-base-content/60">
                            <time
                              datetime={DateTime.to_iso8601(result.timestamp)}
                              aria-label={"Created on #{format_timestamp(result.timestamp)}"}
                            >
                              <span class="hero-clock w-4 h-4 inline" aria-hidden="true"></span>
                              <%= format_timestamp(result.timestamp) %>
                            </time>
                            <%= if result.domain do %>
                              <div class="badge badge-outline badge-sm" aria-label={"Domain: #{format_domain_name(result.domain)}"}>
                                <span class="hero-building-office w-3 h-3" aria-hidden="true"></span>
                                <%= format_domain_name(result.domain) %>
                              </div>
                            <% end %>
                          </div>
                        </div>
                        <button
                          phx-click="delete"
                          phx-value-entry_id={result.id}
                          class="btn btn-ghost btn-sm btn-square"
                          aria-label={"Delete history entry: #{get_decision_summary(result.decision)}"}
                          title="Delete this entry"
                        >
                          <span class="hero-trash w-5 h-5" aria-hidden="true"></span>
                        </button>
                      </div>

                      <div class="divider my-3" aria-hidden="true"></div>

                      <details class="collapse collapse-arrow bg-base-200" id={"entry-#{result.id}-details"}>
                        <summary class="collapse-title font-medium cursor-pointer" aria-expanded="false">
                          <span class="flex items-center gap-2">
                            <span class="hero-eye w-4 h-4" aria-hidden="true"></span>
                            View Details
                          </span>
                        </summary>
                        <div class="collapse-content space-y-4" role="region" aria-label="Entry details">
                          <div>
                            <h4 class="font-semibold mb-2 flex items-center gap-2">
                              <span class="hero-signal w-4 h-4 text-info" aria-hidden="true"></span>
                              Extracted Signals
                            </h4>
                            <div class="flex flex-wrap gap-2" role="list" aria-label="Signal values">
                              <%= for {key, value} <- result.signals do %>
                                <div
                                  class="badge badge-outline badge-sm"
                                  role="listitem"
                                  aria-label={"Signal: #{key} equals #{format_value(value)}"}
                                >
                                  <strong><%= key %></strong>: <%= format_value(value) %>
                                </div>
                              <% end %>
                            </div>
                          </div>

                          <%= if result.justification do %>
                            <div>
                              <h4 class="font-semibold mb-2 flex items-center gap-2">
                                <span class="hero-document-text w-4 h-4 text-warning" aria-hidden="true"></span>
                                Justification
                              </h4>
                              <div
                                class="text-sm prose prose-sm max-w-none bg-base-50 p-4 rounded-lg border"
                                role="region"
                                aria-label="Decision justification"
                              >
                                <%= raw(get_rendered_justification(result.justification)) %>
                              </div>
                            </div>
                          <% end %>
                        </div>
                      </details>
                    </div>
                  </article>
                <% end %>
              </main>

              <!-- Bottom Pagination Controls -->
              <%= if @total_pages > 1 do %>
                <section class="flex justify-center mt-8" aria-label="Bottom pagination">
                  <div class="join">
                    <!-- Previous Button -->
                    <%= if @current_page > 1 do %>
                      <button
                        phx-click="goto_page"
                        phx-value-page={@current_page - 1}
                        class="join-item btn btn-sm"
                        aria-label="Go to previous page"
                      >
                        <span class="hero-chevron-left w-4 h-4" aria-hidden="true"></span>
                        Previous
                      </button>
                    <% else %>
                      <button class="join-item btn btn-sm btn-disabled" disabled aria-label="Previous page (disabled)">
                        <span class="hero-chevron-left w-4 h-4" aria-hidden="true"></span>
                        Previous
                      </button>
                    <% end %>

                    <!-- Page Numbers -->
                    <%= for page_num <- pagination_range(@current_page, @total_pages) do %>
                      <%= if page_num == @current_page do %>
                        <button class="join-item btn btn-sm btn-active" aria-current="page" aria-label={"Current page: #{page_num}"}>
                          <%= page_num %>
                        </button>
                      <% else %>
                        <button
                          phx-click="goto_page"
                          phx-value-page={page_num}
                          class="join-item btn btn-sm"
                          aria-label={"Go to page #{page_num}"}
                        >
                          <%= page_num %>
                        </button>
                      <% end %>
                    <% end %>

                    <!-- Next Button -->
                    <%= if @current_page < @total_pages do %>
                      <button
                        phx-click="goto_page"
                        phx-value-page={@current_page + 1}
                        class="join-item btn btn-sm"
                        aria-label="Go to next page"
                      >
                        Next
                        <span class="hero-chevron-right w-4 h-4" aria-hidden="true"></span>
                      </button>
                    <% else %>
                      <button class="join-item btn btn-sm btn-disabled" disabled aria-label="Next page (disabled)">
                        Next
                        <span class="hero-chevron-right w-4 h-4" aria-hidden="true"></span>
                      </button>
                    <% end %>
                  </div>

                  <!-- Page Info -->
                  <div class="ml-4 flex items-center text-sm text-base-content/60">
                    Page <%= @current_page %> of <%= @total_pages %>
                    (<%= @total_count %> total <%= if @total_count == 1, do: "entry", else: "entries" %>)
                  </div>
                </section>
              <% end %>
            <% end %>
          <% end %>
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
  defp get_rendered_justification(%{"rendered_html" => html}), do: html
  defp get_rendered_justification(%{raw_markdown: markdown}) do
    DecisionEngine.MarkdownRenderer.render_to_html!(markdown)
  end
  defp get_rendered_justification(%{"raw_markdown" => markdown}) do
    DecisionEngine.MarkdownRenderer.render_to_html!(markdown)
  end
  defp get_rendered_justification(justification) when is_binary(justification) do
    DecisionEngine.MarkdownRenderer.render_to_html!(justification)
  end
  defp get_rendered_justification(_), do: "<p>No justification available</p>"

  defp get_outcome_badge_class(outcome) do
    case outcome do
      "prefer_power_automate" -> "badge-success"
      "power_automate_possible_with_caveats" -> "badge-warning"
      "avoid_power_automate_use_logic_apps_or_integration_platform" -> "badge-error"
      "use_power_automate_desktop" -> "badge-info"
      _ -> "badge-ghost"
    end
  end

  defp format_timestamp(timestamp) do
    Calendar.strftime(timestamp, "%B %d, %Y at %H:%M:%S")
  end

  defp format_domain_name(domain) do
    case domain do
      :power_platform -> "Power Platform"
      :data_platform -> "Data Platform"
      :integration_platform -> "Integration Platform"
      _ -> domain |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
    end
  end

  # Safe accessors for decision fields
  defp get_decision_summary(%{"summary" => summary}), do: summary
  defp get_decision_summary(%{summary: summary}), do: summary
  defp get_decision_summary(_), do: "Decision Analysis"

  defp get_decision_outcome(%{"outcome" => outcome}), do: outcome
  defp get_decision_outcome(%{outcome: outcome}), do: outcome
  defp get_decision_outcome(_), do: "unknown"

  defp get_decision_score(%{"score" => score}), do: score
  defp get_decision_score(%{score: score}), do: score
  defp get_decision_score(_), do: 0.0
end
