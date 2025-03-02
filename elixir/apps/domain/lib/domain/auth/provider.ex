defmodule Domain.Auth.Provider do
  use Domain, :schema

  schema "auth_providers" do
    field :name, :string

    field :adapter, Ecto.Enum, values: ~w[email openid_connect google_workspace userpass token]a
    field :provisioner, Ecto.Enum, values: ~w[manual just_in_time custom]a
    field :adapter_config, :map
    field :adapter_state, :map

    belongs_to :account, Domain.Accounts.Account

    has_many :actor_groups, Domain.Actors.Group, where: [deleted_at: nil]
    has_many :identities, Domain.Auth.Identity, where: [deleted_at: nil]

    field :created_by, Ecto.Enum, values: ~w[system identity]a
    belongs_to :created_by_identity, Domain.Auth.Identity

    field :last_synced_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
