defmodule Web.Live.Resources.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)

    group = Fixtures.Gateways.create_group(account: account, subject: subject)
    gateway = Fixtures.Gateways.create_gateway(account: account, group: group)
    gateway = Repo.preload(gateway, :group)

    resource =
      Fixtures.Resources.create_resource(
        account: account,
        subject: subject,
        connections: [%{gateway_group_id: group.id}]
      )

    %{
      account: account,
      actor: actor,
      identity: identity,
      subject: subject,
      group: group,
      gateway: gateway,
      resource: resource
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    resource: resource,
    conn: conn
  } do
    assert live(conn, ~p"/#{account}/resources/#{resource}") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders not found error when resource is deleted", %{
    account: account,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    resource = Fixtures.Resources.delete_resource(resource)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Resources"
    assert breadcrumbs =~ resource.name
  end

  test "allows editing resource", %{
    account: account,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert lv
           |> element("a", "Edit Resource")
           |> render_click() ==
             {:error,
              {:live_redirect, %{to: ~p"/#{account}/resources/#{resource}/edit", kind: :push}}}
  end

  test "renders resource details", %{
    account: account,
    actor: actor,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    table =
      lv
      |> element("#resource")
      |> render()
      |> vertical_table_to_map()

    assert table["name"] =~ resource.name
    assert table["address"] =~ resource.address
    assert table["created"] =~ actor.name

    for filter <- resource.filters do
      assert String.downcase(table["traffic filtering rules"]) =~ Atom.to_string(filter.protocol)
    end
  end

  test "renders gateways table", %{
    account: account,
    identity: identity,
    group: group,
    resource: resource,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    gateway_groups =
      lv
      |> element("#gateway_instance_groups")
      |> render()
      |> table_to_map()

    for gateway_group <- gateway_groups do
      assert gateway_group["name"] =~ group.name_prefix
      # TODO: check that status is being rendered
    end
  end

  test "renders logs table", %{
    account: account,
    identity: identity,
    resource: resource,
    conn: conn
  } do
    flow =
      Fixtures.Flows.create_flow(
        account: account,
        resource: resource
      )

    flow =
      Repo.preload(flow, client: [:actor], gateway: [:group], policy: [:actor_group, :resource])

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    [row] =
      lv
      |> element("#flows")
      |> render()
      |> table_to_map()

    assert row["authorized at"]
    assert row["expires at"]
    assert row["policy"] =~ flow.policy.actor_group.name
    assert row["policy"] =~ flow.policy.resource.name

    assert row["gateway (ip)"] ==
             "#{flow.gateway.group.name_prefix}-#{flow.gateway.name_suffix} (189.172.73.153)"

    assert row["client, actor (ip)"] =~ flow.client.name
    assert row["client, actor (ip)"] =~ "owned by #{flow.client.actor.name}"
    assert row["client, actor (ip)"] =~ to_string(flow.client_remote_ip)
  end

  test "allows deleting resource", %{
    account: account,
    resource: resource,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/resources/#{resource}")

    assert lv
           |> element("button", "Delete Resource")
           |> render_click() ==
             {:error, {:live_redirect, %{to: ~p"/#{account}/resources", kind: :push}}}

    assert Repo.get(Domain.Resources.Resource, resource.id).deleted_at
  end
end
