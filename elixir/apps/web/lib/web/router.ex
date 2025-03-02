defmodule Web.Router do
  use Web, :router
  import Web.Auth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :fetch_live_flash
    plug :put_root_layout, {Web.Layouts, :root}
    plug :fetch_user_agent
    plug :fetch_subject_and_account
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :ensure_authenticated
    plug :ensure_authenticated_actor_type, :service_account
  end

  pipeline :public do
    plug :accepts, ["html", "xml"]
  end

  pipeline :ensure_authenticated_admin do
    plug :ensure_authenticated
    plug :ensure_authenticated_actor_type, :account_admin_user
  end

  scope "/browser", Web do
    pipe_through :public

    get "/config.xml", BrowserController, :config
  end

  scope "/", Web do
    pipe_through :public

    get "/", RedirectController, :home
    get "/healthz", HealthController, :healthz
  end

  if Mix.env() in [:dev, :test] do
    scope "/dev" do
      pipe_through [:public]
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  scope "/sign_up", Web do
    pipe_through :browser

    live "/", SignUp
  end

  scope "/:account_id_or_slug", Web do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    live_session :redirect_if_user_is_authenticated,
      on_mount: [
        Web.Sandbox,
        {Web.Auth, :redirect_if_user_is_authenticated}
      ] do
      live "/", Auth.SignIn

      # Adapter-specific routes
      ## Email
      live "/sign_in/providers/email/:provider_id", Auth.Email
    end

    scope "/sign_in/providers/:provider_id" do
      # UserPass
      post "/verify_credentials", AuthController, :verify_credentials

      # Email
      post "/request_magic_link", AuthController, :request_magic_link
      get "/verify_sign_in_token", AuthController, :verify_sign_in_token

      # IdP
      get "/redirect", AuthController, :redirect_to_idp
      get "/handle_callback", AuthController, :handle_idp_callback
    end
  end

  scope "/:account_id_or_slug", Web do
    pipe_through [:browser]

    get "/sign_out", AuthController, :sign_out
  end

  scope "/:account_id_or_slug", Web do
    pipe_through [:browser, :ensure_authenticated_admin]

    live_session :ensure_authenticated,
      on_mount: [
        Web.Sandbox,
        {Web.Auth, :ensure_authenticated},
        {Web.Auth, :ensure_account_admin_user_actor},
        {Web.Auth, :mount_account},
        {Web.Nav, :set_active_sidebar_item}
      ] do
      scope "/actors", Actors do
        live "/", Index
        live "/new", New
        live "/:id", Show

        scope "/users", Users do
          live "/new", New
          live "/:id/new_identity", NewIdentity
        end

        scope "/service_accounts", ServiceAccounts do
          live "/new", New
          live "/:id/new_identity", NewIdentity
        end

        live "/:id/edit", Edit
        # TODO: REMOVEME it's just another identity
        live "/:id/new_token", NewToken
      end

      scope "/groups", Groups do
        live "/", Index
        live "/new", New
        live "/:id/edit", Edit
        live "/:id/edit_actors", EditActors
        live "/:id", Show
      end

      scope "/clients", Clients do
        live "/", Index
        live "/:id", Show
        live "/:id/edit", Edit
      end

      scope "/relay_groups", RelayGroups do
        live "/", Index
        live "/new", New
        live "/:id/edit", Edit
        live "/:id", Show
      end

      scope "/relays", Relays do
        live "/:id", Show
      end

      scope "/sites", Sites do
        live "/", Index
        live "/new", New
        live "/:id/new_token", NewToken
        live "/:id/edit", Edit
        live "/:id", Show
      end

      scope "/gateways", Gateways do
        live "/:id", Show
      end

      scope "/resources", Resources do
        live "/", Index
        live "/new", New
        live "/:id/edit", Edit
        live "/:id", Show
      end

      scope "/policies", Policies do
        live "/", Index
        live "/new", New
        live "/:id/edit", Edit
        live "/:id", Show
      end

      scope "/flows", Flows do
        live "/:id", Show
        get "/:id/activities.csv", DownloadActivities, :download
      end

      scope "/settings", Settings do
        live "/account", Account

        scope "/identity_providers", IdentityProviders do
          live "/", Index
          live "/new", New

          scope "/saml", SAML do
            live "/new", New
            live "/:provider_id", Show
            live "/:provider_id/edit", Edit
          end

          scope "/openid_connect", OpenIDConnect do
            live "/new", New
            live "/:provider_id", Show
            live "/:provider_id/edit", Edit

            # OpenID Connection
            get "/:provider_id/redirect", Connect, :redirect_to_idp
            get "/:provider_id/handle_callback", Connect, :handle_idp_callback
          end

          scope "/google_workspace", GoogleWorkspace do
            live "/new", New
            live "/:provider_id", Show
            live "/:provider_id/edit", Edit

            # OpenID Connection
            get "/:provider_id/redirect", Connect, :redirect_to_idp
            get "/:provider_id/handle_callback", Connect, :handle_idp_callback
          end

          scope "/system", System do
            live "/:provider_id", Show
          end
        end

        live "/dns", DNS
      end
    end
  end
end
