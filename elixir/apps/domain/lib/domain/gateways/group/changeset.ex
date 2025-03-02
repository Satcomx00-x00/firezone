defmodule Domain.Gateways.Group.Changeset do
  use Domain, :changeset
  alias Domain.{Auth, Accounts}
  alias Domain.Gateways

  @fields ~w[name_prefix]a

  def create(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    %Gateways.Group{account: account}
    |> changeset(attrs)
    |> put_change(:account_id, account.id)
    |> put_change(:created_by, :identity)
    |> put_change(:created_by_identity_id, subject.identity.id)
    |> cast_assoc(:tokens,
      with: fn _token, _attrs ->
        Gateways.Token.Changeset.create(account, subject)
      end,
      required: true
    )
  end

  def update(%Gateways.Group{} = group, attrs, %Auth.Subject{} = subject) do
    changeset(group, attrs)
    |> cast_assoc(:tokens,
      with: fn _token, _attrs ->
        Gateways.Token.Changeset.create(group.account, subject)
      end
    )
  end

  def update(%Gateways.Group{} = group, attrs) do
    changeset(group, attrs)
  end

  defp changeset(%Gateways.Group{} = group, attrs) do
    group
    |> cast(attrs, @fields)
    |> trim_change(:name_prefix)
    |> put_default_value(:name_prefix, &Domain.NameGenerator.generate/0)
    |> validate_required(@fields)
    |> validate_length(:name_prefix, min: 1, max: 64)
    |> unique_constraint(:name_prefix, name: :gateway_groups_account_id_name_prefix_index)
  end

  def delete(%Gateways.Group{} = group) do
    group
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
