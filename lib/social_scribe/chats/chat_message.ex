defmodule SocialScribe.Chats.ChatMessage do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_messages" do
    field :role, :string
    field :content, :string
    field :context_data, :map

    belongs_to :chat_session, SocialScribe.Chats.ChatSession

    timestamps()
  end

  def changeset(chat_message, attrs) do
    chat_message
    |> cast(attrs, [:role, :content, :context_data, :chat_session_id])
    |> validate_required([:role, :content, :chat_session_id])
  end
end
