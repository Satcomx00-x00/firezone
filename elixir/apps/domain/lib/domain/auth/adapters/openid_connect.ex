defmodule Domain.Auth.Adapters.OpenIDConnect do
  use Supervisor
  alias Domain.Repo
  alias Domain.Actors
  alias Domain.Auth.{Identity, Provider, Adapter}
  alias Domain.Auth.Adapters.OpenIDConnect.{Settings, State, PKCE}
  require Logger

  @behaviour Adapter
  @behaviour Adapter.IdP

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = []

    Supervisor.init(children, strategy: :one_for_one)
  end

  @impl true
  def capabilities do
    [
      provisioners: [:just_in_time],
      default_provisioner: :just_in_time,
      parent_adapter: :openid_connect
    ]
  end

  @impl true
  def identity_changeset(%Provider{} = _provider, %Ecto.Changeset{} = changeset) do
    changeset
    |> Domain.Validator.trim_change(:provider_identifier)
    |> Ecto.Changeset.put_change(:provider_state, %{})
    |> Ecto.Changeset.put_change(:provider_virtual_state, %{})
  end

  @impl true
  def provider_changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> Domain.Changeset.cast_polymorphic_embed(:adapter_config,
      required: true,
      with: fn current_attrs, attrs ->
        Ecto.embedded_load(Settings, current_attrs, :json)
        |> Settings.Changeset.changeset(attrs)
      end
    )
  end

  @impl true
  def ensure_provisioned(%Provider{} = provider) do
    {:ok, provider}
  end

  @impl true
  def ensure_deprovisioned(%Provider{} = provider) do
    {:ok, provider}
  end

  def authorization_uri(%Provider{} = provider, redirect_uri) when is_binary(redirect_uri) do
    config = config_for_provider(provider)

    verifier = PKCE.code_verifier()
    state = State.new()

    params = %{
      access_type: :offline,
      state: state,
      code_challenge_method: PKCE.code_challenge_method(),
      code_challenge: PKCE.code_challenge(verifier)
    }

    with {:ok, uri} <- OpenIDConnect.authorization_uri(config, redirect_uri, params) do
      {:ok, uri, {state, verifier}}
    end
  end

  def ensure_states_equal(state1, state2) do
    if State.equal?(state1, state2) do
      :ok
    else
      {:error, :invalid_state}
    end
  end

  @impl true
  def sign_out(%Provider{} = provider, %Identity{} = identity, redirect_url) do
    config = config_for_provider(provider)

    case OpenIDConnect.end_session_uri(config, %{
           id_token_hint: identity.provider_state["id_token"],
           post_logout_redirect_uri: redirect_url
         }) do
      {:ok, end_session_uri} ->
        {:ok, identity, end_session_uri}

      {:error, _reason} ->
        {:ok, identity, redirect_url}
    end
  end

  @impl true
  def verify_and_update_identity(%Provider{} = provider, {redirect_uri, code_verifier, code}) do
    token_params = %{
      grant_type: "authorization_code",
      redirect_uri: redirect_uri,
      code: code,
      code_verifier: code_verifier
    }

    with {:ok, provider_identifier, identity_state} <-
           fetch_state(provider, token_params) do
      Identity.Query.not_disabled()
      |> Identity.Query.by_provider_id(provider.id)
      |> Identity.Query.by_provider_identifier(provider_identifier)
      |> Repo.fetch_and_update(
        with: fn identity ->
          Identity.Changeset.update_identity_provider_state(identity, identity_state)
        end
      )
      |> case do
        {:ok, identity} -> {:ok, identity, identity_state["expires_at"]}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :expired_token} -> {:error, :expired}
      {:error, :invalid_token} -> {:error, :invalid}
      {:error, :internal_error} -> {:error, :internal_error}
    end
  end

  def verify_and_upsert_identity(
        %Actors.Actor{} = actor,
        %Provider{} = provider,
        {redirect_uri, code_verifier, code}
      ) do
    token_params = %{
      grant_type: "authorization_code",
      redirect_uri: redirect_uri,
      code: code,
      code_verifier: code_verifier
    }

    with {:ok, provider_identifier, identity_state} <-
           fetch_state(provider, token_params) do
      Domain.Auth.upsert_identity(actor, provider, %{
        provider_identifier: provider_identifier,
        provider_virtual_state: identity_state
      })
    end
  end

  def refresh_access_token(%Provider{} = provider) do
    token_params = %{
      grant_type: "refresh_token",
      refresh_token: provider.adapter_state["refresh_token"]
    }

    with {:ok, _provider_identifier, adapter_state} <-
           fetch_state(provider, token_params) do
      Provider.Query.by_id(provider.id)
      |> Repo.fetch_and_update(
        with: fn provider ->
          adapter_state_updates =
            Map.take(adapter_state, ["expires_at", "access_token", "userinfo", "claims"])

          adapter_state =
            Map.merge(provider.adapter_state, adapter_state_updates)

          Provider.Changeset.update(provider, %{adapter_state: adapter_state})
        end
      )
    else
      {:error, :expired_token} -> {:error, :expired}
      {:error, :invalid_token} -> {:error, :invalid}
      {:error, :internal_error} -> {:error, :internal_error}
    end
  end

  defp fetch_state(%Provider{} = provider, token_params) do
    config = config_for_provider(provider)

    with {:ok, tokens} <- OpenIDConnect.fetch_tokens(config, token_params),
         {:ok, claims} <- OpenIDConnect.verify(config, tokens["id_token"]),
         {:ok, userinfo} <- OpenIDConnect.fetch_userinfo(config, tokens["access_token"]) do
      expires_at =
        cond do
          not is_nil(tokens["expires_in"]) ->
            DateTime.add(DateTime.utc_now(), tokens["expires_in"], :second)

          not is_nil(claims["exp"]) ->
            DateTime.from_unix!(claims["exp"])

          true ->
            nil
        end

      provider_identifier = claims["sub"]

      {:ok, provider_identifier,
       %{
         "access_token" => tokens["access_token"],
         "refresh_token" => tokens["refresh_token"],
         "expires_at" => expires_at,
         "userinfo" => userinfo,
         "claims" => claims
       }}
    else
      {:error, {:invalid_jwt, "invalid exp claim: token has expired"}} ->
        {:error, :expired_token}

      {:error, {:invalid_jwt, _reason}} ->
        {:error, :invalid_token}

      {:error, other} ->
        Logger.error("Failed to connect OpenID Connect provider",
          provider_id: provider.id,
          reason: inspect(other)
        )

        {:error, :internal_error}
    end
  end

  defp config_for_provider(%Provider{} = provider) do
    Ecto.embedded_load(Settings, provider.adapter_config, :json)
    |> Map.from_struct()
  end
end
