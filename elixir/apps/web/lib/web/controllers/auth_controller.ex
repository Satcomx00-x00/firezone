defmodule Web.AuthController do
  use Web, :controller
  alias Web.Auth
  alias Domain.Auth.Adapters.OpenIDConnect

  # This is the cookie which will store recent account ids
  # that the user has signed in to.
  @remember_me_cookie_name "fz_recent_account_ids"
  @remember_me_cookie_options [
    sign: true,
    max_age: 365 * 24 * 60 * 60,
    same_site: "Lax",
    secure: true,
    http_only: true
  ]

  # This is the cookie which will be used to store the
  # state and code verifier for OpenID Connect IdP's
  @state_cookie_key_prefix "fz_auth_state_"
  @state_cookie_options [
    sign: true,
    max_age: 300,
    same_site: "Lax",
    secure: true,
    http_only: true
  ]

  action_fallback Web.FallbackController

  @doc """
  This is a callback for the UserPass provider which checks login and password to authenticate the user.
  """
  def verify_credentials(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "provider_id" => provider_id,
          "userpass" => %{
            "provider_identifier" => provider_identifier,
            "secret" => secret
          }
        } = params
      ) do
    redirect_params =
      Map.take(params, ["client_platform", "client_csrf_token"])

    with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
         {:ok, subject} <-
           Domain.Auth.sign_in(
             provider,
             provider_identifier,
             secret,
             conn.assigns.user_agent,
             conn.remote_ip
           ) do
      client_platform = params["client_platform"]
      client_csrf_token = params["client_csrf_token"]

      conn
      |> persist_recent_account(subject.account)
      |> Web.Auth.signed_in_redirect(subject, client_platform, client_csrf_token)
    else
      {:error, :not_found} ->
        conn
        |> put_flash(:userpass_provider_identifier, String.slice(provider_identifier, 0, 160))
        |> put_flash(:error, "You may not use this method to sign in.")
        |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")

      {:error, _reason} ->
        conn
        |> put_flash(:userpass_provider_identifier, String.slice(provider_identifier, 0, 160))
        |> put_flash(:error, "Invalid username or password.")
        |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")
    end
  end

  @doc """
  This is a callback for the Email provider which sends login link.
  """
  def request_magic_link(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "provider_id" => provider_id,
          "email" => %{
            "provider_identifier" => provider_identifier
          }
        } = params
      ) do
    conn =
      with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
           {:ok, identity} <-
             Domain.Auth.fetch_identity_by_provider_and_identifier(provider, provider_identifier,
               preload: :account
             ),
           {:ok, identity} <- Domain.Auth.Adapters.Email.request_sign_in_token(identity) do
        sign_in_link_params = Map.take(params, ["client_platform", "client_csrf_token"])

        <<email_secret::binary-size(5), nonce::binary>> =
          identity.provider_virtual_state.sign_in_token

        {:ok, _} =
          Web.Mailer.AuthEmail.sign_in_link_email(
            identity,
            email_secret,
            conn.assigns.user_agent,
            conn.remote_ip,
            sign_in_link_params
          )
          |> Web.Mailer.deliver()

        put_session(conn, :sign_in_nonce, nonce)
      else
        _ -> conn
      end

    redirect_params =
      Map.take(params, ["client_platform", "client_csrf_token"])
      |> Map.put("provider_identifier", provider_identifier)

    conn
    |> maybe_put_resent_flash(params)
    |> put_session(:client_platform, params["client_platform"])
    |> put_session(:client_csrf_token, params["client_csrf_token"])
    |> redirect(
      to: ~p"/#{account_id_or_slug}/sign_in/providers/email/#{provider_id}?#{redirect_params}"
    )
  end

  defp maybe_put_resent_flash(conn, %{"resend" => "true"}),
    do: put_flash(conn, :info, "Email was resent.")

  defp maybe_put_resent_flash(conn, _params),
    do: conn

  @doc """
  This is a callback for the Email provider which handles both form submission and redirect login link
  to authenticate a user.
  """
  def verify_sign_in_token(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "provider_id" => provider_id,
          "identity_id" => identity_id,
          "secret" => email_secret
        } = params
      ) do
    client_platform = get_session(conn, :client_platform) || params["client_platform"]
    client_csrf_token = get_session(conn, :client_csrf_token) || params["client_csrf_token"]

    redirect_params =
      put_if_not_nil(:client_platform, client_platform)
      |> put_if_not_nil(:client_csrf_token, client_csrf_token)

    with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
         nonce = get_session(conn, :sign_in_nonce) || "=",
         {:ok, subject} <-
           Domain.Auth.sign_in(
             provider,
             identity_id,
             String.downcase(email_secret) <> nonce,
             conn.assigns.user_agent,
             conn.remote_ip
           ) do
      conn
      |> delete_session(:client_platform)
      |> delete_session(:client_csrf_token)
      |> delete_session(:sign_in_nonce)
      |> persist_recent_account(subject.account)
      |> Web.Auth.signed_in_redirect(subject, client_platform, client_csrf_token)
    else
      {:error, :not_found} ->
        conn
        |> put_flash(:error, "You may not use this method to sign in.")
        |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")

      {:error, _reason} ->
        redirect_params = put_if_not_nil(redirect_params, "provider_identifier", identity_id)

        conn
        |> put_flash(:error, "The sign in link is invalid or expired.")
        |> redirect(
          to: ~p"/#{account_id_or_slug}/sign_in/providers/email/#{provider_id}?#{redirect_params}"
        )
    end
  end

  @doc """
  This controller redirects user to IdP during sign in for authentication while persisting
  verification state to prevent various attacks on OpenID Connect.
  """
  def redirect_to_idp(
        conn,
        %{
          "account_id_or_slug" => account_id_or_slug,
          "provider_id" => provider_id
        } = params
      ) do
    with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id) do
      conn = put_session(conn, :client_platform, params["client_platform"])
      conn = put_session(conn, :client_csrf_token, params["client_csrf_token"])

      redirect_url =
        url(~p"/#{account_id_or_slug}/sign_in/providers/#{provider.id}/handle_callback")

      redirect_to_idp(conn, redirect_url, provider)
    else
      {:error, :not_found} ->
        redirect_params = Map.take(params, ["client_platform", "client_csrf_token"])

        conn
        |> put_flash(:error, "You may not use this method to sign in.")
        |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")
    end
  end

  def redirect_to_idp(%Plug.Conn{} = conn, redirect_url, %Domain.Auth.Provider{} = provider) do
    {:ok, authorization_url, {state, code_verifier}} =
      OpenIDConnect.authorization_uri(provider, redirect_url)

    key = state_cookie_key(provider.id)
    value = :erlang.term_to_binary({state, code_verifier})

    conn
    |> put_resp_cookie(key, value, @state_cookie_options)
    |> redirect(external: authorization_url)
  end

  @doc """
  This controller handles IdP redirect back to the Firezone when user signs in.
  """
  def handle_idp_callback(conn, %{
        "account_id_or_slug" => account_id_or_slug,
        "provider_id" => provider_id,
        "state" => state,
        "code" => code
      }) do
    client_platform = get_session(conn, :client_platform)
    client_csrf_token = get_session(conn, :client_csrf_token)

    redirect_params =
      put_if_not_nil(:client_platform, client_platform)
      |> put_if_not_nil(:client_csrf_token, client_csrf_token)

    with {:ok, code_verifier, conn} <- verify_state_and_fetch_verifier(conn, provider_id, state) do
      payload = {
        url(~p"/#{account_id_or_slug}/sign_in/providers/#{provider_id}/handle_callback"),
        code_verifier,
        code
      }

      with {:ok, provider} <- Domain.Auth.fetch_active_provider_by_id(provider_id),
           {:ok, subject} <-
             Domain.Auth.sign_in(provider, payload, conn.assigns.user_agent, conn.remote_ip) do
        conn
        |> delete_session(:client_platform)
        |> delete_session(:client_csrf_token)
        |> delete_session(:sign_in_nonce)
        |> persist_recent_account(subject.account)
        |> Web.Auth.signed_in_redirect(subject, client_platform, client_csrf_token)
      else
        {:error, :not_found} ->
          conn
          |> put_flash(:error, "You may not use this method to sign in.")
          |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")

        {:error, _reason} ->
          conn
          |> put_flash(:error, "You may not authenticate to this account.")
          |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")
      end
    else
      {:error, :invalid_state, conn} ->
        conn
        |> put_flash(:error, "Your session has expired, please try again.")
        |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")
    end
  end

  def verify_state_and_fetch_verifier(conn, provider_id, state) do
    key = state_cookie_key(provider_id)
    conn = fetch_cookies(conn, signed: [key])

    with {:ok, encoded_state} <- Map.fetch(conn.cookies, key),
         {persisted_state, persisted_verifier} <- :erlang.binary_to_term(encoded_state, [:safe]),
         :ok <- OpenIDConnect.ensure_states_equal(state, persisted_state) do
      {:ok, persisted_verifier, delete_resp_cookie(conn, key, @state_cookie_options)}
    else
      _ -> {:error, :invalid_state, delete_resp_cookie(conn, key, @state_cookie_options)}
    end
  end

  defp state_cookie_key(provider_id) do
    @state_cookie_key_prefix <> provider_id
  end

  def sign_out(%{assigns: %{subject: subject}} = conn, %{
        "account_id_or_slug" => account_id_or_slug
      }) do
    redirect_params = Map.take(conn.params, ["client_platform"])

    {:ok, _identity, redirect_url} =
      Domain.Auth.sign_out(subject.identity, url(~p"/#{account_id_or_slug}?#{redirect_params}"))

    conn
    |> delete_recent_account()
    |> Auth.sign_out()
    |> redirect(external: redirect_url)
  end

  def sign_out(conn, %{"account_id_or_slug" => account_id_or_slug}) do
    redirect_params = Map.take(conn.params, ["client_platform"])

    conn
    |> Auth.sign_out()
    |> redirect(to: ~p"/#{account_id_or_slug}?#{redirect_params}")
  end

  defp delete_recent_account(%{assigns: %{subject: subject}} = conn) do
    update_recent_accounts(conn, fn recent_account_ids ->
      recent_account_ids -- [subject.account.id]
    end)
  end

  defp persist_recent_account(conn, %Domain.Accounts.Account{} = account) do
    update_recent_accounts(conn, fn recent_account_ids ->
      [account.id] ++ recent_account_ids
    end)
  end

  defp update_recent_accounts(conn, callback) when is_function(callback, 1) do
    conn = fetch_cookies(conn, signed: [@remember_me_cookie_name])

    recent_account_ids =
      if recent_account_ids = Map.get(conn.cookies, @remember_me_cookie_name) do
        :erlang.binary_to_term(recent_account_ids, [:safe])
      else
        []
      end

    recent_account_ids =
      recent_account_ids
      |> callback.()
      |> Enum.take(5)
      |> :erlang.term_to_binary()

    put_resp_cookie(
      conn,
      @remember_me_cookie_name,
      recent_account_ids,
      @remember_me_cookie_options
    )
  end

  defp put_if_not_nil(map \\ %{}, key, value)
  defp put_if_not_nil(map, _key, nil), do: map
  defp put_if_not_nil(map, key, value), do: Map.put(map, key, value)
end
