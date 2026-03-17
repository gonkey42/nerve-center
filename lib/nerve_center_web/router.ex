defmodule NerveCenterWeb.Router do
  use NerveCenterWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NerveCenterWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", NerveCenterWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/devices/:id", DeviceLive, :show
    live "/sources", SourcesLive, :index
    live "/sources/:device_id/:source", SourceLive, :show
  end

  scope "/", NerveCenterWeb do
    pipe_through :api

    get "/healthz", HealthController, :show
  end
end
