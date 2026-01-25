defmodule SocialScribe.ChatsTest do
  use SocialScribe.DataCase

  alias SocialScribe.Chats
  alias SocialScribe.Chats.{ChatSession, ChatMessage}

  import SocialScribe.AccountsFixtures

  describe "chat sessions" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "list_user_chat_sessions/1 returns sessions ordered by updated_at desc", %{user: user} do
      {:ok, session1} = Chats.create_chat_session(%{user_id: user.id, title: "First"})
      # Ensure time difference between sessions (DB uses second precision)
      Process.sleep(1001)
      {:ok, session2} = Chats.create_chat_session(%{user_id: user.id, title: "Second"})

      # session2 is now the most recently created
      sessions = Chats.list_user_chat_sessions(user.id)
      assert length(sessions) == 2
      # Most recent first (session2 was created after session1)
      assert hd(sessions).id == session2.id
      assert List.last(sessions).id == session1.id
    end

    test "list_user_chat_sessions/1 only returns sessions for specified user", %{user: user} do
      other_user = user_fixture()
      {:ok, _} = Chats.create_chat_session(%{user_id: user.id, title: "My Session"})
      {:ok, _} = Chats.create_chat_session(%{user_id: other_user.id, title: "Other Session"})

      sessions = Chats.list_user_chat_sessions(user.id)
      assert length(sessions) == 1
      assert hd(sessions).title == "My Session"
    end

    test "create_chat_session/1 creates session with valid attributes", %{user: user} do
      attrs = %{user_id: user.id, title: "Test Session"}
      assert {:ok, %ChatSession{} = session} = Chats.create_chat_session(attrs)
      assert session.title == "Test Session"
      assert session.user_id == user.id
      assert session.sources == %{}
    end

    test "create_chat_session/1 fails without user_id" do
      assert {:error, changeset} = Chats.create_chat_session(%{title: "No User"})
      assert %{user_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "get_chat_session!/1 returns session with id", %{user: user} do
      {:ok, session} = Chats.create_chat_session(%{user_id: user.id, title: "Test"})
      fetched = Chats.get_chat_session!(session.id)
      assert fetched.id == session.id
    end

    test "get_chat_session!/1 raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Chats.get_chat_session!(999_999)
      end
    end

    test "get_chat_session/1 returns session with preloaded messages", %{user: user} do
      {:ok, session} = Chats.create_chat_session(%{user_id: user.id, title: "Test"})
      Chats.add_message_to_session(session.id, %{role: "user", content: "Hello"})
      Chats.add_message_to_session(session.id, %{role: "assistant", content: "Hi"})

      fetched = Chats.get_chat_session(session.id)
      assert fetched.id == session.id
      assert length(fetched.messages) == 2
      assert Enum.map(fetched.messages, & &1.role) == ["user", "assistant"]
    end

    test "get_chat_session/1 returns nil for non-existent id" do
      assert Chats.get_chat_session(999_999) == nil
    end

    test "update_chat_session/2 updates title", %{user: user} do
      {:ok, session} = Chats.create_chat_session(%{user_id: user.id, title: "Old Title"})
      {:ok, updated} = Chats.update_chat_session(session, %{title: "New Title"})
      assert updated.title == "New Title"
    end

    test "update_chat_session/2 updates sources", %{user: user} do
      {:ok, session} = Chats.create_chat_session(%{user_id: user.id, title: "Test"})
      sources = %{"salesforce:123" => %{"provider" => "salesforce", "data" => %{"id" => "123"}}}
      {:ok, updated} = Chats.update_chat_session(session, %{sources: sources})
      assert updated.sources == sources
    end

    test "delete_chat_session/1 deletes session and its messages", %{user: user} do
      {:ok, session} = Chats.create_chat_session(%{user_id: user.id, title: "To Delete"})
      Chats.add_message_to_session(session.id, %{role: "user", content: "Hello"})

      {:ok, _} = Chats.delete_chat_session(session)

      assert_raise Ecto.NoResultsError, fn ->
        Chats.get_chat_session!(session.id)
      end

      # Verify messages are also deleted (cascade)
      import Ecto.Query

      messages =
        SocialScribe.Repo.all(from m in ChatMessage, where: m.chat_session_id == ^session.id)

      assert messages == []
    end
  end

  describe "chat messages" do
    setup do
      user = user_fixture()
      {:ok, session} = Chats.create_chat_session(%{user_id: user.id, title: "Test Session"})
      %{user: user, session: session}
    end

    test "add_message_to_session/2 creates message with valid attributes", %{session: session} do
      attrs = %{role: "user", content: "Hello AI"}
      {:ok, %ChatMessage{} = message} = Chats.add_message_to_session(session.id, attrs)
      assert message.role == "user"
      assert message.content == "Hello AI"
      assert message.chat_session_id == session.id
    end

    test "add_message_to_session/2 updates session updated_at", %{session: session} do
      original_updated_at = session.updated_at

      # DB uses second-level precision, so we need to wait at least 1 second
      Process.sleep(1001)

      Chats.add_message_to_session(session.id, %{role: "user", content: "Hello"})

      refreshed = Chats.get_chat_session!(session.id)
      # Use NaiveDateTime since Ecto timestamps are NaiveDateTime
      assert NaiveDateTime.compare(refreshed.updated_at, original_updated_at) == :gt
    end

    test "add_message_to_session/2 stores context_data", %{session: session} do
      context = %{"sources" => ["salesforce"], "contacts" => [%{"id" => "1", "name" => "John"}]}
      attrs = %{role: "user", content: "Hello", context_data: context}

      {:ok, message} = Chats.add_message_to_session(session.id, attrs)
      assert message.context_data["sources"] == ["salesforce"]
      assert message.context_data["contacts"] == [%{"id" => "1", "name" => "John"}]
    end

    test "add_message_to_session/2 fails without required fields", %{session: session} do
      assert {:error, changeset} = Chats.add_message_to_session(session.id, %{role: "user"})
      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "session sources" do
    setup do
      user = user_fixture()
      {:ok, session} = Chats.create_chat_session(%{user_id: user.id, title: "Test"})
      %{user: user, session: session}
    end

    test "update_session_sources/2 adds new sources keyed by provider:id", %{session: session} do
      contacts = [
        %{provider: "salesforce", id: "123", firstname: "John", lastname: "Doe"},
        %{provider: "hubspot", id: "456", firstname: "Jane", lastname: "Smith"}
      ]

      {:ok, updated} = Chats.update_session_sources(session.id, contacts)

      assert Map.has_key?(updated.sources, "salesforce:123")
      assert Map.has_key?(updated.sources, "hubspot:456")
      assert updated.sources["salesforce:123"]["provider"] == "salesforce"
    end

    test "update_session_sources/2 merges with existing sources", %{session: session} do
      contact1 = [%{provider: "salesforce", id: "123", firstname: "John", lastname: "Doe"}]
      {:ok, _} = Chats.update_session_sources(session.id, contact1)

      contact2 = [%{provider: "hubspot", id: "456", firstname: "Jane", lastname: "Smith"}]
      {:ok, updated} = Chats.update_session_sources(session.id, contact2)

      assert Map.has_key?(updated.sources, "salesforce:123")
      assert Map.has_key?(updated.sources, "hubspot:456")
    end

    test "update_session_sources/2 overwrites duplicate keys", %{session: session} do
      contact = [%{provider: "salesforce", id: "123", firstname: "John", lastname: "Doe"}]
      {:ok, _} = Chats.update_session_sources(session.id, contact)

      updated_contact = [
        %{provider: "salesforce", id: "123", firstname: "Johnny", lastname: "Doe"}
      ]

      {:ok, updated} = Chats.update_session_sources(session.id, updated_contact)

      assert updated.sources["salesforce:123"]["data"]["firstname"] == "Johnny"
    end

    test "get_session_sources/1 returns list of source data", %{session: session} do
      contacts = [
        %{provider: "salesforce", id: "123", firstname: "John", lastname: "Doe"},
        %{provider: "hubspot", id: "456", firstname: "Jane", lastname: "Smith"}
      ]

      Chats.update_session_sources(session.id, contacts)
      sources = Chats.get_session_sources(session.id)

      assert length(sources) == 2
      assert Enum.any?(sources, fn s -> s["id"] == "123" end)
      assert Enum.any?(sources, fn s -> s["id"] == "456" end)
    end

    test "get_session_sources/1 returns empty list for session without sources", %{
      session: session
    } do
      sources = Chats.get_session_sources(session.id)
      assert sources == []
    end

    test "get_session_sources_with_metadata/1 returns full sources map", %{session: session} do
      contacts = [%{provider: "salesforce", id: "123", firstname: "John", lastname: "Doe"}]
      Chats.update_session_sources(session.id, contacts)

      sources = Chats.get_session_sources_with_metadata(session.id)

      assert Map.has_key?(sources, "salesforce:123")
      assert Map.has_key?(sources["salesforce:123"], "fetched_at")
      assert Map.has_key?(sources["salesforce:123"], "provider")
      assert Map.has_key?(sources["salesforce:123"], "data")
    end
  end
end
