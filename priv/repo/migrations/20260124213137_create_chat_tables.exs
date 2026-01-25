defmodule SocialScribe.Repo.Migrations.CreateChatTables do
  use Ecto.Migration

  def change do
    create table(:chat_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :title, :string

      timestamps()
    end

    create index(:chat_sessions, [:user_id])

    create table(:chat_messages) do
      add :chat_session_id, references(:chat_sessions, on_delete: :delete_all), null: false
      # "user" or "assistant"
      add :role, :string, null: false
      add :content, :text, null: false
      # For storing sources/attribution
      add :context_data, :map

      timestamps()
    end

    create index(:chat_messages, [:chat_session_id])
  end
end
