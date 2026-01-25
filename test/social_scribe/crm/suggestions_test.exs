defmodule SocialScribe.Crm.SuggestionsTest do
  use SocialScribe.DataCase

  alias SocialScribe.Crm.Suggestions

  describe "merge_with_contact/3 for hubspot" do
    test "merges suggestions with contact data and filters unchanged values" do
      suggestions = [
        %{
          field: "phone",
          new_value: "555-1234",
          apply: false,
          has_change: true
        },
        %{
          field: "company",
          new_value: "Acme Corp",
          apply: false,
          has_change: true
        }
      ]

      contact = %{
        id: "123",
        phone: nil,
        company: "Acme Corp",
        email: "test@example.com"
      }

      result = Suggestions.merge_with_contact("hubspot", suggestions, contact)

      # Only phone should remain since company already matches
      assert length(result) == 1
      assert hd(result).field == "phone"
      assert hd(result).new_value == "555-1234"
      assert hd(result).current_value == nil
    end
  end

  describe "merge_with_contact/3 for salesforce" do
    test "merges suggestions using internal key mapping" do
      suggestions = [
        %{
          field: "FirstName",
          new_value: "John",
          apply: false,
          has_change: true
        },
        %{
          field: "Title",
          new_value: "CEO",
          apply: false,
          has_change: true
        }
      ]

      contact = %{
        id: "123",
        # Already matches
        firstname: "John",
        # Different
        jobtitle: "Manager"
      }

      result = Suggestions.merge_with_contact("salesforce", suggestions, contact)

      assert length(result) == 1
      assert hd(result).field == "Title"
      assert hd(result).new_value == "CEO"
      assert hd(result).current_value == "Manager"
    end
  end

  describe "generate_suggestions_from_meeting/2" do
    import Mox
    setup :verify_on_exit!

    test "generates suggestions with correct labels for hubspot" do
      meeting = %{id: "m1"}

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_hubspot_suggestions, fn _ ->
        {:ok, [%{field: "firstname", value: "Jane", context: "...", timestamp: "00:01"}]}
      end)

      {:ok, suggestions} = Suggestions.generate_suggestions_from_meeting("hubspot", meeting)

      assert length(suggestions) == 1
      suggestion = hd(suggestions)
      assert suggestion.field == "firstname"
      assert suggestion.label == "First Name"
      assert suggestion.new_value == "Jane"
    end

    test "generates suggestions with correct labels for salesforce" do
      meeting = %{id: "m1"}

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _ ->
        {:ok, [%{field: "FirstName", value: "Jane", context: "...", timestamp: "00:01"}]}
      end)

      {:ok, suggestions} = Suggestions.generate_suggestions_from_meeting("salesforce", meeting)

      assert length(suggestions) == 1
      suggestion = hd(suggestions)
      assert suggestion.field == "FirstName"
      assert suggestion.label == "First Name"
      assert suggestion.new_value == "Jane"
    end
  end
end
