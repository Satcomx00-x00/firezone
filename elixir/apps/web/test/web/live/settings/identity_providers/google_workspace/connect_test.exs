defmodule Web.Live.Settings.IdentityProviders.GoogleWorkspace.Connect do
  use Web.ConnCase, async: true

  describe "redirect_to_idp/2" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        bypass: bypass,
        account: account,
        provider: provider,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "redirects to login page when user is not signed in", %{conn: conn} do
      account_id = Ecto.UUID.generate()
      provider_id = Ecto.UUID.generate()

      conn =
        conn
        |> get(
          ~p"/#{account_id}/settings/identity_providers/google_workspace/#{provider_id}/redirect"
        )

      assert redirected_to(conn) == "/#{account_id}/sign_in"
      assert flash(conn, :error) == "You must log in to access this page."
    end

    test "redirects with an error when provider does not exist", %{identity: identity, conn: conn} do
      account = Fixtures.Accounts.create_account()
      provider_id = Ecto.UUID.generate()

      conn =
        conn
        |> authorize_conn(identity)
        |> assign(:account, account)
        |> get(
          ~p"/#{account.id}/settings/identity_providers/google_workspace/#{provider_id}/redirect"
        )

      assert redirected_to(conn) == "/#{account.id}/settings/identity_providers"
      assert flash(conn, :error) == "Provider does not exist."
    end

    test "redirects to IdP when provider exists", %{
      account: account,
      provider: provider,
      identity: identity,
      conn: conn
    } do
      conn =
        conn
        |> authorize_conn(identity)
        |> assign(:account, account)
        |> get(
          ~p"/#{account.id}/settings/identity_providers/google_workspace/#{provider.id}/redirect",
          %{}
        )

      assert to = redirected_to(conn)
      uri = URI.parse(to)
      assert uri.host == "localhost"
      assert uri.path == "/authorize"

      callback_url =
        url(
          ~p"/#{account.id}/settings/identity_providers/google_workspace/#{provider.id}/handle_callback"
        )

      {state, verifier} = conn.cookies["fz_auth_state_#{provider.id}"] |> :erlang.binary_to_term()
      code_challenge = Domain.Auth.Adapters.OpenIDConnect.PKCE.code_challenge(verifier)

      assert URI.decode_query(uri.query) == %{
               "access_type" => "offline",
               "client_id" => provider.adapter_config["client_id"],
               "code_challenge" => code_challenge,
               "code_challenge_method" => "S256",
               "redirect_uri" => callback_url,
               "response_type" => "code",
               "scope" => "openid email profile",
               "state" => state
             }
    end
  end

  describe "handle_idp_callback/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      %{account: account}
    end

    test "redirects to login page when user is not signed in", %{conn: conn} do
      account_id = Ecto.UUID.generate()
      provider_id = Ecto.UUID.generate()

      conn =
        conn
        |> get(~p"/#{account_id}/sign_in/providers/#{provider_id}/handle_callback", %{
          "state" => "foo",
          "code" => "bar"
        })

      assert redirected_to(conn) == "/#{account_id}/sign_in"
      assert flash(conn, :error) == "Your session has expired, please try again."
    end

    test "redirects with an error when state cookie does not exist", %{
      account: account,
      conn: conn
    } do
      {provider, _bypass} =
        Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)

      conn =
        conn
        |> authorize_conn(identity)
        |> assign(:account, account)
        |> get(
          ~p"/#{account}/settings/identity_providers/google_workspace/#{provider}/handle_callback",
          %{
            "state" => "XOXOX",
            "code" => "bar"
          }
        )

      assert redirected_to(conn) ==
               ~p"/#{account}/settings/identity_providers/google_workspace/#{provider}"

      assert flash(conn, :error) == "Your session has expired, please try again."
    end

    test "redirects to the dashboard when credentials are valid and return path is empty", %{
      account: account,
      conn: conn
    } do
      {provider, bypass} =
        Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor, provider: provider)

      redirected_conn =
        conn
        |> authorize_conn(identity)
        |> assign(:account, account)
        |> get(
          ~p"/#{account}/settings/identity_providers/google_workspace/#{provider}/redirect",
          %{}
        )

      {token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)
      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{"id_token" => token})
      Mocks.OpenIDConnect.expect_userinfo(bypass)

      cookie_key = "fz_auth_state_#{provider.id}"
      redirected_conn = fetch_cookies(redirected_conn)
      {state, _verifier} = redirected_conn.cookies[cookie_key] |> :erlang.binary_to_term([:safe])
      %{value: signed_state} = redirected_conn.resp_cookies[cookie_key]

      conn =
        conn
        |> authorize_conn(identity)
        |> assign(:account, account)
        |> put_req_cookie(cookie_key, signed_state)
        |> put_session(:foo, "bar")
        |> put_session(:preferred_locale, "en_US")
        |> get(
          ~p"/#{account.id}/settings/identity_providers/google_workspace/#{provider.id}/handle_callback",
          %{
            "state" => state,
            "code" => "MyFakeCode"
          }
        )

      assert redirected_to(conn) ==
               ~p"/#{account}/settings/identity_providers/google_workspace/#{provider}"

      assert %{
               "live_socket_id" => "actors_sessions:" <> socket_id,
               "preferred_locale" => "en_US",
               "session_token" => session_token
             } = conn.private.plug_session

      assert socket_id == identity.actor_id
      assert {:ok, subject} = Domain.Auth.sign_in(session_token, "testing", conn.remote_ip)
      assert subject.identity.id == identity.id
      assert subject.identity.last_seen_user_agent == "testing"
      assert subject.identity.last_seen_remote_ip.address == {127, 0, 0, 1}
      assert subject.identity.last_seen_at

      assert provider = Repo.get(Domain.Auth.Provider, provider.id)

      assert %{
               "access_token" => _,
               "claims" => %{},
               "expires_at" => _,
               "refresh_token" => _,
               "userinfo" => %{}
             } = provider.adapter_state

      assert is_nil(provider.disabled_at)
    end
  end
end
