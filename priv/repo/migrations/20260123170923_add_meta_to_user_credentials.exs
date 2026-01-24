defmodule SocialScribe.Repo.Migrations.AddMetaToUserCredentials do
  use Ecto.Migration

  def change do
    alter table(:user_credentials) do
      add :meta, :map, default: %{}
    end
  end
end