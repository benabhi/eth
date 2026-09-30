defmodule EthWeb.Router do
  use EthWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EthWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => EthWeb.CSP.policy()}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", EthWeb do
    pipe_through :browser

    # El piloto activo se carga en todas las pantallas (RF-5.10, RF-6.1).
    live_session :default,
      on_mount: [EthWeb.PilotHook, EthWeb.RadarHook, EthWeb.AlertsHook, EthWeb.ViewersHook] do
      live "/", HunterLive
      live "/station", StationLive
      live "/orders", OrderLive
      live "/docs", DocsLive
      live "/docs/:page", DocsLive
      live "/run", RunLive
      live "/control", ControlLive
      live "/control/:tab", ControlLive
      live "/settings", SettingsLive, :characters
      live "/settings/ships", SettingsLive, :ships
      live "/settings/rules", SettingsLive, :rules
      live "/settings/engine", SettingsLive, :engine
      live "/settings/radar", SettingsLive, :radar
      live "/settings/markets", SettingsLive, :markets
      live "/settings/notifications", SettingsLive, :notifications
      live "/settings/setup", SettingsLive, :setup
      live "/settings/backup", SettingsLive, :backup
    end

    # Exportar la configuración (RF-9.7): descarga JSON sin secretos.
    get "/settings/export", ConfigController, :export
  end

  # EVE SSO (RF-5.1) y personaje activo (RF-5.10)
  scope "/auth", EthWeb do
    pipe_through :browser

    post "/logout", AuthController, :logout
    post "/characters/:id/activate", AuthController, :activate
    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end

  # Healthchecks (RNF-9.4)
  scope "/", EthWeb do
    pipe_through :api

    get "/health", HealthController, :health
    get "/ready", HealthController, :ready
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:eth, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: EthWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
