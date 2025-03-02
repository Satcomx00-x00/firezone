defmodule Web.Live.Groups.ShowTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()
    actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
    identity = Fixtures.Auth.create_identity(account: account, actor: actor)
    subject = Fixtures.Auth.create_subject(account: account, actor: actor, identity: identity)
    group = Fixtures.Actors.create_group(account: account, subject: subject)

    %{
      account: account,
      actor: actor,
      identity: identity,
      group: group
    }
  end

  test "redirects to sign in page for unauthorized user", %{
    account: account,
    group: group,
    conn: conn
  } do
    assert live(conn, ~p"/#{account}/groups/#{group}") ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}",
                 flash: %{"error" => "You must log in to access this page."}
               }}}
  end

  test "renders not found error when group is deleted", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    group = Fixtures.Actors.delete_group(group)

    assert_raise Web.LiveErrors.NotFoundError, fn ->
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")
    end
  end

  test "renders breadcrumbs item", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, _lv, html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    assert item = Floki.find(html, "[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "Groups"
    assert breadcrumbs =~ group.name
  end

  test "renders group details", %{
    account: account,
    group: group,
    actor: actor,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    table =
      lv
      |> element("#group")
      |> render()
      |> vertical_table_to_map()

    assert table["name"] == group.name
    assert around_now?(table["source"])
    assert table["source"] =~ "by #{actor.name}"
  end

  test "renders name of actor that created group", %{
    account: account,
    actor: actor,
    group: group,
    identity: identity,
    conn: conn
  } do
    group
    |> Ecto.Changeset.change(
      created_by: :identity,
      created_by_identity_id: identity.id
    )
    |> Repo.update!()

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    assert lv
           |> element("#group")
           |> render()
           |> vertical_table_to_map()
           |> Map.fetch!("source") =~ "by #{actor.name}"
  end

  test "renders provider that synced group", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {provider, _bypass} =
      Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

    group
    |> Ecto.Changeset.change(
      created_by: :provider,
      provider_id: provider.id,
      provider_identifier: Ecto.UUID.generate()
    )
    |> Repo.update!()

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    assert lv
           |> element("#group")
           |> render()
           |> vertical_table_to_map()
           |> Map.fetch!("source") =~ "Synced from #{provider.name} never"
  end

  test "renders group actors", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    user_actor = Fixtures.Actors.create_actor(type: :account_user, account: account)
    Fixtures.Actors.create_membership(group: group, actor: user_actor)

    service_account = Fixtures.Actors.create_actor(type: :service_account, account: account)
    Fixtures.Actors.create_membership(group: group, actor: service_account)

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    lv
    |> element("#actors")
    |> render()
    |> table_to_map()
    |> with_table_row("actor", user_actor.name, fn row ->
      user_actor = Repo.preload(user_actor, identities: [:provider])

      for identity <- user_actor.identities do
        assert row["identities"] =~ identity.provider.name
        assert row["identities"] =~ identity.provider_identifier
      end
    end)
    |> with_table_row("actor", "#{service_account.name} (service account)", fn row ->
      service_account = Repo.preload(service_account, identities: [:provider])

      for identity <- service_account.identities do
        assert row["identities"] =~ identity.provider.name
        assert row["identities"] =~ identity.provider_identifier
      end
    end)
  end

  test "allows editing groups", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    assert lv
           |> element("a:first-child", "Edit Group")
           |> render_click() ==
             {:error, {:live_redirect, %{to: ~p"/#{account}/groups/#{group}/edit", kind: :push}}}
  end

  test "does not allow editing synced groups", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {provider, _bypass} =
      Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

    group
    |> Ecto.Changeset.change(
      created_by: :provider,
      provider_id: provider.id,
      provider_identifier: Ecto.UUID.generate()
    )
    |> Repo.update!()

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    refute has_element?(lv, "a", "Edit Group")
  end

  test "allows editing actors", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    assert lv
           |> element("a", "Edit Actors")
           |> render_click() ==
             {:error,
              {:live_redirect, %{to: ~p"/#{account}/groups/#{group}/edit_actors", kind: :push}}}
  end

  test "does not allow editing synced actors", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {provider, _bypass} =
      Fixtures.Auth.start_and_create_google_workspace_provider(account: account)

    group
    |> Ecto.Changeset.change(
      created_by: :provider,
      provider_id: provider.id,
      provider_identifier: Ecto.UUID.generate()
    )
    |> Repo.update!()

    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    refute has_element?(lv, "a", "Edit Actors")
  end

  test "allows deleting groups", %{
    account: account,
    group: group,
    identity: identity,
    conn: conn
  } do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(identity)
      |> live(~p"/#{account}/groups/#{group}")

    assert lv
           |> element("button", "Delete Group")
           |> render_click() ==
             {:error, {:redirect, %{to: ~p"/#{account}/groups"}}}

    assert Repo.get(Domain.Actors.Group, group.id).deleted_at
  end
end
