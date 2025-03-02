defmodule Web.Auth do
  use Web, :verified_routes
  alias Domain.Auth

  def signed_in_path(%Auth.Subject{actor: %{type: :account_admin_user}} = subject) do
    ~p"/#{subject.account.slug || subject.account}/actors"
  end

  def put_subject_in_session(conn, %Auth.Subject{} = subject) do
    {:ok, session_token} = Auth.create_session_token_from_subject(subject)

    conn
    |> Plug.Conn.put_session(:signed_in_at, DateTime.utc_now())
    |> Plug.Conn.put_session(:session_token, session_token)
    |> Plug.Conn.put_session(:live_socket_id, "actors_sessions:#{subject.actor.id}")
  end

  @doc """
  Redirects the signed in user depending on the actor type.

  The account admin users are sent to authenticated home or a return path if it's stored in session.

  The account users are only expected to authenticate using client apps.
  If the platform is known, we direct them to the application through a deep link or an app link;
  if not, we guide them to the install instructions accompanied by an error message.
  """
  def signed_in_redirect(
        conn,
        %Auth.Subject{} = subject,
        client_platform,
        client_csrf_token
      )
      when not is_nil(client_platform) do
    platform_redirects =
      Domain.Config.fetch_env!(:web, __MODULE__)
      |> Keyword.fetch!(:platform_redirects)

    if redirects = Map.get(platform_redirects, client_platform) do
      {:ok, client_token} = Auth.create_client_token_from_subject(subject)

      query =
        %{
          client_auth_token: client_token,
          client_csrf_token: client_csrf_token,
          actor_name: subject.actor.name,
          identity_provider_identifier: subject.identity.provider_identifier
        }
        |> Enum.reject(&is_nil(elem(&1, 1)))
        |> URI.encode_query()

      redirect_method = Keyword.fetch!(redirects, :method)
      redirect_dest = "#{Keyword.fetch!(redirects, :dest)}?#{query}"

      conn
      |> Phoenix.Controller.redirect([{redirect_method, redirect_dest}])
    else
      conn
      |> Phoenix.Controller.put_flash(
        :info,
        "Please use a client application to access Firezone."
      )
      |> Phoenix.Controller.redirect(to: ~p"/#{conn.path_params["account_id_or_slug"]}")
    end
  end

  def signed_in_redirect(
        conn,
        %Auth.Subject{actor: %{type: :account_admin_user}} = subject,
        _client_platform,
        _client_csrf_token
      ) do
    redirect_to = Plug.Conn.get_session(conn, :user_return_to) || signed_in_path(subject)

    conn
    |> Web.Auth.renew_session()
    |> Web.Auth.put_subject_in_session(subject)
    |> Plug.Conn.delete_session(:user_return_to)
    |> Phoenix.Controller.redirect(to: redirect_to)
  end

  def signed_in_redirect(conn, %Auth.Subject{} = _subject, _client_platform, _client_csrf_token) do
    conn
    |> Phoenix.Controller.put_flash(
      :info,
      "Please use a client application to access Firezone."
    )
    |> Phoenix.Controller.redirect(to: ~p"/#{conn.path_params["account_id_or_slug"]}")
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See `renew_session/1`.
  """
  def sign_out(%Plug.Conn{} = conn) do
    # token = Plug.Conn.get_session(conn, :session_token)
    # subject && Accounts.delete_user_session_token(subject)

    if live_socket_id = Plug.Conn.get_session(conn, :live_socket_id) do
      conn.private.phoenix_endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
  end

  @doc """
  This function renews the session ID and erases the whole
  session to avoid fixation attacks.
  """
  def renew_session(%Plug.Conn{} = conn) do
    preferred_locale = Plug.Conn.get_session(conn, :preferred_locale)

    conn
    |> Plug.Conn.configure_session(renew: true)
    |> Plug.Conn.clear_session()
    |> Plug.Conn.put_session(:preferred_locale, preferred_locale)
  end

  ###########################
  ## Plugs
  ###########################

  @doc """
  Fetches the user agent value from headers and assigns it the connection.
  """
  def fetch_user_agent(%Plug.Conn{} = conn, _opts) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [user_agent | _] -> Plug.Conn.assign(conn, :user_agent, user_agent)
      _ -> conn
    end
  end

  @doc """
  Fetches the session token from the session and assigns the subject to the connection.
  """
  def fetch_subject_and_account(%Plug.Conn{} = conn, _opts) do
    {location_region, location_city, {location_lat, location_lon}} =
      get_load_balancer_ip_location(conn)

    context = %Auth.Context{
      user_agent: conn.assigns.user_agent,
      remote_ip: conn.remote_ip,
      remote_ip_location_region: location_region,
      remote_ip_location_city: location_city,
      remote_ip_location_lat: location_lat,
      remote_ip_location_lon: location_lon
    }

    with token when not is_nil(token) <- Plug.Conn.get_session(conn, :session_token),
         {:ok, subject} <-
           Domain.Auth.sign_in(token, context),
         {:ok, account} <-
           Domain.Accounts.fetch_account_by_id_or_slug(
             conn.path_params["account_id_or_slug"],
             subject
           ) do
      conn
      |> Plug.Conn.assign(:account, account)
      |> Plug.Conn.assign(:subject, subject)
    else
      _ -> conn
    end
  end

  defp get_load_balancer_ip_location(%Plug.Conn{} = conn) do
    location_region =
      case Plug.Conn.get_req_header(conn, "x-geo-location-region") do
        ["" | _] -> nil
        [location_region | _] -> location_region
        [] -> nil
      end

    location_city =
      case Plug.Conn.get_req_header(conn, "x-geo-location-city") do
        ["" | _] -> nil
        [location_city | _] -> location_city
        [] -> nil
      end

    {location_lat, location_lon} =
      case Plug.Conn.get_req_header(conn, "x-geo-location-coordinates") do
        ["" | _] ->
          {nil, nil}

        ["," | _] ->
          {nil, nil}

        [coordinates | _] ->
          [lat, lon] = String.split(coordinates, ",", parts: 2)
          lat = String.to_float(lat)
          lon = String.to_float(lon)
          {lat, lon}

        [] ->
          {nil, nil}
      end

    {location_lat, location_lon} =
      Domain.Geo.maybe_put_default_coordinates(location_region, {location_lat, location_lon})

    {location_region, location_city, {location_lat, location_lon}}
  end

  defp get_load_balancer_ip_location(x_headers) do
    location_region =
      case get_socket_header(x_headers, "x-geo-location-region") do
        {"x-geo-location-region", ""} -> nil
        {"x-geo-location-region", location_region} -> location_region
        _other -> nil
      end

    location_city =
      case get_socket_header(x_headers, "x-geo-location-city") do
        {"x-geo-location-city", ""} -> nil
        {"x-geo-location-city", location_city} -> location_city
        _other -> nil
      end

    {location_lat, location_lon} =
      case get_socket_header(x_headers, "x-geo-location-coordinates") do
        {"x-geo-location-coordinates", ""} ->
          {nil, nil}

        {"x-geo-location-coordinates", coordinates} ->
          [lat, lon] = String.split(coordinates, ",", parts: 2)
          lat = String.to_float(lat)
          lon = String.to_float(lon)
          {lat, lon}

        _other ->
          {nil, nil}
      end

    {location_lat, location_lon} =
      Domain.Geo.maybe_put_default_coordinates(location_region, {location_lat, location_lon})

    {location_region, location_city, {location_lat, location_lon}}
  end

  defp get_socket_header(x_headers, key) do
    List.keyfind(x_headers, key, 0)
  end

  @doc """
  Used for routes that require the user to not be authenticated.
  """
  def redirect_if_user_is_authenticated(%Plug.Conn{} = conn, _opts) do
    if conn.assigns[:subject] do
      client_platform =
        Plug.Conn.get_session(conn, :client_platform) || conn.query_params["client_platform"]

      client_csrf_token =
        Plug.Conn.get_session(conn, :client_csrf_token) || conn.query_params["client_csrf_token"]

      conn
      |> signed_in_redirect(conn.assigns[:subject], client_platform, client_csrf_token)
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  @doc """
  Used for routes that require the user to be authenticated.

  This plug will only work if there is an `account_id` in the path params.
  """
  def ensure_authenticated(%Plug.Conn{} = conn, _opts) do
    if conn.assigns[:subject] do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> Phoenix.Controller.redirect(to: ~p"/#{conn.path_params["account_id_or_slug"]}")
      |> Plug.Conn.halt()
    end
  end

  @doc """
  Used for routes that require the user to be authenticated as a specific kind of actor.

  This plug will only work if there is an `account_id` in the path params.
  """
  def ensure_authenticated_actor_type(%Plug.Conn{} = conn, type) do
    if not is_nil(conn.assigns[:subject]) and conn.assigns[:subject].actor.type == type do
      conn
    else
      conn
      |> Web.FallbackController.call({:error, :not_found})
      |> Plug.Conn.halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    Plug.Conn.put_session(conn, :user_return_to, Phoenix.Controller.current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  ###########################
  ## LiveView
  ###########################

  @doc """
  Handles mounting and authenticating the actor in LiveViews.

  Notice: every protected route should have `account_id` in the path params.

  ## `on_mount` arguments

    * `:mount_subject` - assigns user_agent and subject to the socket assigns based on
      session_token, or nil if there's no session_token or no matching user.

    * `:ensure_authenticated` - authenticates the user from the session,
      and assigns the subject to socket assigns based on session_token.
      Redirects to login page if there's no logged user.

    * `:redirect_if_user_is_authenticated` - authenticates the user from the session.
      Redirects to signed_in_path if there's a logged user.

    * `:mount_account` - takes `account_id` from path params and loads the given account
      into the socket assigns using the `subject` mounted via `:mount_subject`. This is useful
      because some actions can be performed by superadmin users on behalf of other accounts
      so we can't really rely on `subject.account` in a lot of places.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the subject:

      defmodule Web.Page do
        use Web, :live_view

        on_mount {Web.UserAuth, :mount_subject}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{Web.UserAuth, :ensure_authenticated}] do
        live "/:account_id/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_subject, params, session, socket) do
    {:cont, mount_subject(socket, params, session)}
  end

  def on_mount(:mount_account, params, session, socket) do
    {:cont, mount_account(socket, params, session)}
  end

  def on_mount(:ensure_authenticated, params, session, socket) do
    socket = mount_subject(socket, params, session)

    if socket.assigns[:subject] do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/#{params["account_id_or_slug"]}")

      {:halt, socket}
    end
  end

  def on_mount(:ensure_account_admin_user_actor, params, session, socket) do
    socket = mount_subject(socket, params, session)

    if socket.assigns[:subject].actor.type == :account_admin_user do
      {:cont, socket}
    else
      raise Web.LiveErrors.NotFoundError
    end
  end

  def on_mount(:redirect_if_user_is_authenticated, params, session, socket) do
    socket = mount_subject(socket, params, session)

    if socket.assigns[:subject] do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket.assigns[:subject]))}
    else
      {:cont, socket}
    end
  end

  defp mount_subject(socket, _params, session) do
    Phoenix.Component.assign_new(socket, :subject, fn ->
      user_agent = Phoenix.LiveView.get_connect_info(socket, :user_agent)
      real_ip = real_ip(socket)
      x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []

      {location_region, location_city, {location_lat, location_lon}} =
        get_load_balancer_ip_location(x_headers)

      context = %Domain.Auth.Context{
        user_agent: user_agent,
        remote_ip: real_ip,
        remote_ip_location_region: location_region,
        remote_ip_location_city: location_city,
        remote_ip_location_lat: location_lat,
        remote_ip_location_lon: location_lon
      }

      with token when not is_nil(token) <- session["session_token"],
           {:ok, subject} <- Domain.Auth.sign_in(token, context) do
        subject
      else
        _ -> nil
      end
    end)
  end

  defp mount_account(
         %{assigns: %{subject: subject}} = socket,
         %{"account_id_or_slug" => account_id_or_slug},
         _session
       ) do
    Phoenix.Component.assign_new(socket, :account, fn ->
      with {:ok, account} <-
             Domain.Accounts.fetch_account_by_id_or_slug(account_id_or_slug, subject) do
        account
      else
        _ -> nil
      end
    end)
  end

  defp real_ip(socket) do
    peer_data = Phoenix.LiveView.get_connect_info(socket, :peer_data)
    x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers)

    real_ip =
      if is_list(x_headers) and length(x_headers) > 0 do
        RemoteIp.from(x_headers, Web.Endpoint.real_ip_opts())
      end

    real_ip || peer_data.address
  end
end
