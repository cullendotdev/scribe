defmodule SocialScribe.Crm.Suggestions do
  @moduledoc """
  Unified service for generating and formatting CRM contact update suggestions.
  """
  alias SocialScribe.AIContentGeneratorApi
  alias SocialScribe.Crm.Config
  alias SocialScribe.Accounts.UserCredential

  @doc """
  Generates suggested updates for a CRM contact based on a meeting transcript.
  """
  def generate_suggestions(%UserCredential{provider: provider} = credential, contact_id, meeting) do
    config = Config.get(provider)
    api_module = Config.api_impl(provider)

    # Dynamic function call to AI generator based on provider
    ai_gen_fn = get_ai_gen_fn(provider)

    with {:ok, contact} <- api_module.get_contact(credential, contact_id),
         {:ok, ai_suggestions} <- apply(AIContentGeneratorApi, ai_gen_fn, [meeting]) do
      suggestions =
        ai_suggestions
        |> Enum.map(fn suggestion ->
          field = suggestion.field
          current_value = get_contact_field(contact, field, config)

          %{
            field: field,
            label: get_field_label(field, config),
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
  def generate_suggestions_from_meeting(provider, meeting) do
    ai_gen_fn = get_ai_gen_fn(provider)
    config = Config.get(provider)

    case apply(AIContentGeneratorApi, ai_gen_fn, [meeting]) do
      {:ok, ai_suggestions} ->
        suggestions =
          ai_suggestions
          |> Enum.map(fn suggestion ->
            %{
              field: suggestion.field,
              label: get_field_label(suggestion.field, config),
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
  def merge_with_contact(provider, suggestions, contact) when is_list(suggestions) do
    config = Config.get(provider)

    Enum.map(suggestions, fn suggestion ->
      current_value = get_contact_field(contact, suggestion.field, config)

      suggestion
      |> Map.put(:current_value, current_value)
      |> Map.put(:has_change, current_value != suggestion.new_value)
      |> Map.put(:apply, true)
    end)
    |> Enum.filter(fn s -> s.has_change end)
  end

  defp get_field_label(field, config) do
    get_in(config.fields, [field, :label]) || field
  end

  defp get_contact_field(contact, field, config) when is_map(contact) do
    internal_key = get_in(config.fields, [field, :internal_key])

    if internal_key do
      Map.get(contact, internal_key)
    else
      nil
    end
  end

  defp get_contact_field(_, _, _), do: nil

  defp get_ai_gen_fn("hubspot"), do: :generate_hubspot_suggestions
  defp get_ai_gen_fn("salesforce"), do: :generate_salesforce_suggestions

  defp get_ai_gen_fn(provider) do
    raise "Suggestions not supported for CRM provider: #{provider}"
  end
end
