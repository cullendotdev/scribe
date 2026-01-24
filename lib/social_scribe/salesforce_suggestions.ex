defmodule SocialScribe.SalesforceSuggestions do
  @moduledoc """
  Generates and formats Salesforce contact update suggestions by combining
  AI-extracted data with existing Salesforce contact information.
  """

  alias SocialScribe.AIContentGeneratorApi
  alias SocialScribe.SalesforceApi
  alias SocialScribe.Accounts.UserCredential

  @field_labels %{
    "FirstName" => "First Name",
    "LastName" => "Last Name",
    "Email" => "Email",
    "Phone" => "Phone",
    "MobilePhone" => "Mobile Phone",
    "Title" => "Job Title",
    "Department" => "Department",
    "MailingStreet" => "Mailing Street",
    "MailingCity" => "Mailing City",
    "MailingState" => "Mailing State",
    "MailingPostalCode" => "Mailing Zip",
    "MailingCountry" => "Mailing Country"
  }

  @doc """
  Generates suggested updates for a Salesforce contact based on a meeting transcript.
  """
  def generate_suggestions(%UserCredential{} = credential, contact_id, meeting) do
    with {:ok, contact} <- SalesforceApi.get_contact(credential, contact_id),
         {:ok, ai_suggestions} <- AIContentGeneratorApi.generate_salesforce_suggestions(meeting) do
      suggestions =
        ai_suggestions
        |> Enum.map(fn suggestion ->
          field = suggestion.field
          current_value = get_contact_field(contact, field)

          %{
            field: field,
            label: Map.get(@field_labels, field, field),
            current_value: current_value,
            new_value: suggestion.value,
            context: suggestion.context,
            apply: true,
            has_change: current_value != suggestion.value
          }
        end)
        |> Enum.filter(fn s -> s.has_change end)

      {:ok, %{contact: contact, suggestions: suggestions}}
    end
  end

  @doc """
  Generates suggestions without fetching contact data.
  """
  def generate_suggestions_from_meeting(meeting) do
    case AIContentGeneratorApi.generate_salesforce_suggestions(meeting) do
      {:ok, ai_suggestions} ->
        suggestions =
          ai_suggestions
          |> Enum.map(fn suggestion ->
            %{
              field: suggestion.field,
              label: Map.get(@field_labels, suggestion.field, suggestion.field),
              current_value: nil,
              new_value: suggestion.value,
              context: Map.get(suggestion, :context),
              timestamp: Map.get(suggestion, :timestamp),
              apply: true,
              has_change: true
            }
          end)

        {:ok, suggestions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Merges AI suggestions with contact data to show current vs suggested values.
  """
  def merge_with_contact(suggestions, contact) when is_list(suggestions) do
    Enum.map(suggestions, fn suggestion ->
      current_value = get_contact_field(contact, suggestion.field)

      %{suggestion | current_value: current_value, has_change: current_value != suggestion.new_value, apply: true}
    end)
    |> Enum.filter(fn s -> s.has_change end)
  end

  defp get_contact_field(contact, field) do
    # Map API field names (TitleCase) to our internal atom keys (lowercase)
    key =
      case field do
        "FirstName" -> :firstname
        "LastName" -> :lastname
        "Email" -> :email
        "Phone" -> :phone
        "MobilePhone" -> :mobilephone
        "Title" -> :jobtitle
        "Department" -> :department
        "MailingStreet" -> :address
        "MailingCity" -> :city
        "MailingState" -> :state
        "MailingPostalCode" -> :zip
        "MailingCountry" -> :country
        _ -> nil
      end

    if key do
      Map.get(contact, key)
    else
      nil
    end
  end
end
