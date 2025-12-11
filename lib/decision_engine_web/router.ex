# lib/decision_engine_web/router.ex
defmodule DecisionEngineWeb.Router do
  use DecisionEngineWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DecisionEngineWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", DecisionEngineWeb do
    pipe_through :browser

    live "/", DecisionLive.Index, :index
    live "/history", DecisionLive.History, :index
    live "/settings", DecisionLive.Settings, :index
  end
end
