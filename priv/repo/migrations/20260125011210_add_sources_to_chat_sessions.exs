defmodule SocialScribe.Repo.Migrations.AddSourcesToChatSessions do
  use Ecto.Migration

  def change do
    alter table(:chat_sessions) do
      # Stores accumulated contact sources for the session
      # Format: %{"contact_id" => %{provider: "salesforce", data: %{...}, fetched_at: timestamp}}
      add :sources, :map, default: %{}
    end
  end
end
