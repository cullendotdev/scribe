defmodule SocialScribe.Chats do
  @moduledoc """
  The Chats context.
  """

  import Ecto.Query, warn: false
  alias SocialScribe.Repo

  alias SocialScribe.Chats.{ChatSession, ChatMessage}

  def list_user_chat_sessions(user_id) do
    ChatSession
    |> where([c], c.user_id == ^user_id)
    |> order_by([c], desc: c.updated_at)
    |> Repo.all()
  end

  def get_chat_session!(id), do: Repo.get!(ChatSession, id)

  def get_chat_session(id) do
    Repo.get(ChatSession, id)
    |> Repo.preload(messages: from(m in ChatMessage, order_by: m.inserted_at))
  end

  def create_chat_session(attrs \\ %{}) do
    %ChatSession{}
    |> ChatSession.changeset(attrs)
    |> Repo.insert()
  end

  def update_chat_session(%ChatSession{} = chat_session, attrs) do
    chat_session
    |> ChatSession.changeset(attrs)
    |> Repo.update()
  end

  def delete_chat_session(%ChatSession{} = chat_session) do
    Repo.delete(chat_session)
  end

  def add_message_to_session(session_id, attrs) do
    # Sanitize context_data to ensure it's JSON-serializable (removes Ecto structs)
    sanitized_attrs =
      if Map.has_key?(attrs, :context_data) do
        Map.update!(attrs, :context_data, &sanitize_for_json/1)
      else
        attrs
      end

    %ChatMessage{}
    |> ChatMessage.changeset(Map.put(sanitized_attrs, :chat_session_id, session_id))
    |> Repo.insert()
    |> case do
      {:ok, message} ->
        # Touch the session updated_at
        Repo.update_all(
          from(c in ChatSession, where: c.id == ^session_id),
          set: [updated_at: DateTime.utc_now()]
        )

        {:ok, message}

      error ->
        error
    end
  end

  @doc """
  Merge new contacts into the session's accumulated sources.
  Each contact is keyed by "provider:id" to allow the same contact from different providers.
  """
  def update_session_sources(session_id, contacts) when is_list(contacts) do
    session = get_chat_session!(session_id)
    current_sources = session.sources || %{}

    new_sources =
      contacts
      |> Enum.reduce(current_sources, fn contact, acc ->
        provider = contact[:provider] || contact["provider"] || "unknown"
        id = contact[:id] || contact["id"]
        key = "#{provider}:#{id}"

        # Sanitize contact data to be JSON-serializable (remove Ecto structs)
        sanitized_contact = sanitize_for_json(contact)

        Map.put(acc, key, %{
          "provider" => provider,
          "data" => sanitized_contact,
          "fetched_at" => DateTime.to_iso8601(DateTime.utc_now())
        })
      end)

    update_chat_session(session, %{sources: new_sources})
  end

  # Sanitizes data to be JSON-serializable by converting structs to plain maps
  # and removing non-serializable fields like Ecto associations.
  defp sanitize_for_json(data) when is_struct(data) do
    # For Ecto structs, just store essential identifying info
    case data do
      %SocialScribe.Meetings.Meeting{} = meeting ->
        %{
          "id" => meeting.id,
          "title" => meeting.title,
          "recorded_at" => DateTime.to_iso8601(meeting.recorded_at),
          "duration_seconds" => meeting.duration_seconds
        }

      _ ->
        # For other structs, convert to map and sanitize recursively
        data
        |> Map.from_struct()
        |> Map.drop([:__meta__, :__struct__])
        |> sanitize_for_json()
    end
  end

  defp sanitize_for_json(data) when is_map(data) do
    data
    |> Enum.reject(fn {_k, v} -> match?(%Ecto.Association.NotLoaded{}, v) end)
    |> Enum.map(fn {k, v} -> {to_string(k), sanitize_for_json(v)} end)
    |> Enum.into(%{})
  end

  defp sanitize_for_json(data) when is_list(data) do
    Enum.map(data, &sanitize_for_json/1)
  end

  defp sanitize_for_json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp sanitize_for_json(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp sanitize_for_json(%Date{} = d), do: Date.to_iso8601(d)
  defp sanitize_for_json(data), do: data

  @doc """
  Get all accumulated sources for a session as a list of contact maps.
  """
  def get_session_sources(session_id) do
    session = get_chat_session!(session_id)
    sources = session.sources || %{}

    sources
    |> Map.values()
    |> Enum.map(fn source -> source["data"] end)
  end

  @doc """
  Get session sources as a map with metadata (for staleness checking).
  """
  def get_session_sources_with_metadata(session_id) do
    session = get_chat_session!(session_id)
    session.sources || %{}
  end
end
