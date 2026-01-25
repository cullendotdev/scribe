defmodule SocialScribe.Chats.ChatSession do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_sessions" do
    field :title, :string
    # Accumulated sources from all contacts mentioned in this session
    # Format: %{"provider:contact_id" => %{provider: "...", data: %{...}, fetched_at: "..."}}
    field :sources, :map, default: %{}
    belongs_to :user, SocialScribe.Accounts.User
    has_many :messages, SocialScribe.Chats.ChatMessage, foreign_key: :chat_session_id

    timestamps()
  end

  def changeset(chat_session, attrs) do
    chat_session
    |> cast(attrs, [:title, :user_id, :sources])
    |> validate_required([:user_id])
  end
end
