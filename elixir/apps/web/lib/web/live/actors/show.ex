defmodule Web.Actors.Show do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.Auth
  alias Domain.Actors

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject,
             preload: [
               identities: [:provider, created_by_identity: [:actor]],
               groups: [:provider]
             ]
           ) do
      {:ok, assign(socket, actor: actor), temporary_assigns: [page_title: actor.name]}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor}"}>
        <%= @actor.name %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        <%= actor_type(@actor.type) %>: <span class="font-bold"><%= @actor.name %></span>
      </:title>
      <:action>
        <.edit_button navigate={~p"/#{@account}/actors/#{@actor}/edit"}>
          Edit <%= actor_type(@actor.type) %>
        </.edit_button>
      </:action>
      <:content flash={@flash}>
        <.vertical_table id="actor">
          <.vertical_table_row label_class="w-1/5">
            <:label>Name</:label>
            <:value><%= @actor.name %>
              <.actor_status actor={@actor} /></:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>Role</:label>
            <:value>
              <%= actor_role(@actor.type) %>
            </:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>Groups</:label>
            <:value>
              <div class="flex flex-wrap gap-y-2">
                <span :if={Enum.empty?(@actor.groups)}>none</span>
                <span :for={group <- @actor.groups}>
                  <.group account={@account} group={group} />
                </span>
              </div>
            </:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>Last Signed In</:label>
            <:value><.relative_datetime datetime={last_seen_at(@actor.identities)} /></:value>
          </.vertical_table_row>

          <.vertical_table_row :if={Actors.actor_synced?(@actor)}>
            <:label>Last Synced At</:label>
            <:value><.relative_datetime datetime={@actor.last_synced_at} /></:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>Authentication Identities</:title>
      <:action>
        <.add_button
          :if={@actor.type == :service_account}
          navigate={~p"/#{@account}/actors/service_accounts/#{@actor}/new_identity"}
        >
          Create Token
        </.add_button>
      </:action>
      <:action>
        <.add_button
          :if={@actor.type != :service_account}
          navigate={~p"/#{@account}/actors/users/#{@actor}/new_identity"}
        >
          Create Identity
        </.add_button>
      </:action>

      <:content>
        <.table id="actors" rows={@actor.identities} row_id={&"identity-#{&1.id}"}>
          <:col :let={identity} label="IDENTITY" sortable="false">
            <.identity_identifier account={@account} identity={identity} />
          </:col>

          <:col :let={identity} label="CREATED" sortable="false">
            <.created_by account={@account} schema={identity} />
          </:col>
          <:col :let={identity} label="LAST SIGNED IN" sortable="false">
            <.relative_datetime datetime={identity.last_seen_at} />
          </:col>
          <:action :let={identity}>
            <button
              :if={identity.created_by != :provider}
              phx-click="delete_identity"
              data-confirm="Are you sure want to delete this identity?"
              phx-value-id={identity.id}
              class={[
                "block w-full py-2 px-4 hover:bg-gray-100"
              ]}
            >
              Delete
            </button>
          </:action>
          <:empty>
            <div class="flex justify-center text-center text-slate-500 p-4">
              <div class="w-auto">
                <div class="pb-4">
                  No authentication identities to display
                </div>
                <.add_button
                  :if={@actor.type == :service_account}
                  navigate={~p"/#{@account}/actors/service_accounts/#{@actor}/new_identity"}
                >
                  Create Token
                </.add_button>
                <.add_button
                  :if={@actor.type != :service_account}
                  navigate={~p"/#{@account}/actors/users/#{@actor}/new_identity"}
                >
                  Create Identity
                </.add_button>
              </div>
            </div>
          </:empty>
        </.table>
      </:content>
    </.section>

    <.danger_zone>
      <:action>
        <.delete_button
          :if={not Actors.actor_synced?(@actor)}
          phx-click="delete"
          data-confirm="Are you sure want to delete this actor and all it's identities?"
        >
          Delete <%= actor_type(@actor.type) %>
        </.delete_button>
      </:action>
      <:action>
        <.button
          :if={Actors.actor_disabled?(@actor)}
          style="danger"
          icon="hero-lock-open"
          phx-click="enable"
          data-confirm="Are you sure want to enable this actor?"
        >
          Enable <%= actor_type(@actor.type) %>
        </.button>
      </:action>
      <:action>
        <.button
          :if={not Actors.actor_disabled?(@actor)}
          style="danger"
          icon="hero-lock-closed"
          phx-click="disable"
          data-confirm="Are you sure want to disable this actor?"
        >
          Disable <%= actor_type(@actor.type) %>
        </.button>
      </:action>
      <:content></:content>
    </.danger_zone>
    """
  end

  def handle_event("delete", _params, socket) do
    with {:ok, _actor} <- Actors.delete_actor(socket.assigns.actor, socket.assigns.subject) do
      {:noreply, redirect(socket, to: ~p"/#{socket.assigns.account}/actors")}
    else
      {:error, :cant_delete_the_last_admin} ->
        {:noreply, put_flash(socket, :error, "You can't delete the last admin of an account.")}
    end
  end

  def handle_event("disable", _params, socket) do
    with {:ok, actor} <- Actors.disable_actor(socket.assigns.actor, socket.assigns.subject) do
      actor = %{
        actor
        | identities: socket.assigns.actor.identities,
          groups: socket.assigns.actor.groups
      }

      socket =
        socket
        |> put_flash(:info, "Actor was disabled.")
        |> assign(actor: actor)

      {:noreply, socket}
    else
      {:error, :cant_disable_the_last_admin} ->
        {:noreply, put_flash(socket, :error, "You can't disable the last admin of an account.")}
    end
  end

  def handle_event("enable", _params, socket) do
    {:ok, actor} = Actors.enable_actor(socket.assigns.actor, socket.assigns.subject)

    actor = %{
      actor
      | identities: socket.assigns.actor.identities,
        groups: socket.assigns.actor.groups
    }

    socket =
      socket
      |> put_flash(:info, "Actor was enabled.")
      |> assign(actor: actor)

    {:noreply, socket}
  end

  def handle_event("delete_identity", %{"id" => id}, socket) do
    {:ok, identity} = Auth.fetch_identity_by_id(id, socket.assigns.subject)
    {:ok, _identity} = Auth.delete_identity(identity, socket.assigns.subject)

    {:ok, actor} =
      Actors.fetch_actor_by_id(socket.assigns.actor.id, socket.assigns.subject,
        preload: [
          identities: [:provider, created_by_identity: [:actor]],
          groups: []
        ]
      )

    socket =
      socket
      |> put_flash(:info, "Identity was deleted.")
      |> assign(actor: actor)

    {:noreply, socket}
  end

  defp last_seen_at(identities) do
    identities
    |> Enum.reject(&is_nil(&1.last_seen_at))
    |> Enum.max_by(& &1.last_seen_at, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      identity -> identity.last_seen_at
    end
  end
end
