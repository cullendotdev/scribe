defmodule SocialScribe.Crm.Config do
  @moduledoc """
  Central configuration and registry for supported CRM integrations.
  """

  @providers %{
    "hubspot" => %{
      label: "HubSpot",
      initial: "H",
      color: "bg-orange-500",
      button_class: "bg-orange-500 hover:bg-orange-600",
      icon_path:
        "M18.72 14.76c.35-.85.54-1.76.54-2.76 0-.72-.11-1.41-.3-2.05-.65.15-1.33.23-2.04.23A9.07 9.07 0 0112 9.9a8.963 8.963 0 01-4.92.28c-.2.64-.3 1.33-.3 2.05 0 1 .19 1.91.54 2.76 1.34-.5 2.75-.79 4.18-.79s2.84.29 4.22.79M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2m0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8m0-14c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3",
      api_module: SocialScribe.HubspotApi,
      suggestions_module: SocialScribe.Crm.Suggestions,
      modal_component: SocialScribeWeb.MeetingLive.HubspotModalComponent,
      modal_id: "hubspot-modal",
      # Token refresh config
      token_url: Ueberauth.Strategy.Hubspot.OAuth.token_url(),
      oauth_strategy: Ueberauth.Strategy.Hubspot.OAuth,
      token_expiry_buffer_seconds: 300,
      refresh_threshold_minutes: 10,
      fields: %{
        "firstname" => %{label: "First Name", internal_key: :firstname},
        "lastname" => %{label: "Last Name", internal_key: :lastname},
        "email" => %{label: "Email", internal_key: :email},
        "phone" => %{label: "Phone", internal_key: :phone},
        "mobilephone" => %{label: "Mobile Phone", internal_key: :mobilephone},
        "company" => %{label: "Company", internal_key: :company},
        "jobtitle" => %{label: "Job Title", internal_key: :jobtitle},
        "address" => %{label: "Address", internal_key: :address},
        "city" => %{label: "City", internal_key: :city},
        "state" => %{label: "State", internal_key: :state},
        "zip" => %{label: "ZIP Code", internal_key: :zip},
        "country" => %{label: "Country", internal_key: :country},
        "website" => %{label: "Website", internal_key: :website},
        "linkedin_url" => %{label: "LinkedIn", internal_key: :linkedin_url},
        "twitter_handle" => %{label: "Twitter", internal_key: :twitter_handle}
      }
    },
    "salesforce" => %{
      label: "Salesforce",
      initial: "S",
      color: "bg-[#00A1E0]",
      button_class: "bg-[#00A1E0] hover:bg-[#008CC2]",
      icon_path:
        "M17.65 6.84C17.26 4.12 14.85 2 12.02 2 9.17 2 6.78 4.12 6.38 6.83 2.94 7.28 0 10.15 0 13.5c0 3.75 3.33 6.64 7.28 6.5h8.95c3.55 0 6.77-2.6 6.77-6.57 0-3.32-2.78-6.13-5.35-6.59z",
      api_module: SocialScribe.SalesforceApi,
      suggestions_module: SocialScribe.Crm.Suggestions,
      modal_component: SocialScribeWeb.MeetingLive.SalesforceModalComponent,
      modal_id: "salesforce-modal",
      # Token refresh config
      token_url: Ueberauth.Strategy.Salesforce.OAuth.token_url(),
      oauth_strategy: Ueberauth.Strategy.Salesforce.OAuth,
      token_expiry_buffer_seconds: 300,
      refresh_threshold_minutes: 10,
      fields: %{
        "FirstName" => %{label: "First Name", internal_key: :firstname},
        "LastName" => %{label: "Last Name", internal_key: :lastname},
        "Email" => %{label: "Email", internal_key: :email},
        "Phone" => %{label: "Phone", internal_key: :phone},
        "MobilePhone" => %{label: "Mobile Phone", internal_key: :mobilephone},
        "Title" => %{label: "Job Title", internal_key: :jobtitle},
        "Department" => %{label: "Department", internal_key: :department},
        "MailingStreet" => %{label: "Mailing Street", internal_key: :address},
        "MailingCity" => %{label: "Mailing City", internal_key: :city},
        "MailingState" => %{label: "Mailing State", internal_key: :state},
        "MailingPostalCode" => %{label: "Mailing Zip", internal_key: :zip},
        "MailingCountry" => %{label: "Mailing Country", internal_key: :country}
      }
    },
    "google_meet" => %{
      label: "Meeting",
      initial: "M",
      color: "bg-blue-600",
      button_class: "bg-blue-600 hover:bg-blue-700",
      # Not used for meeting integration card
      icon_path: ""
    }
  }

  @doc """
  Returns all configured providers.
  """
  def providers, do: @providers

  @doc """
  Returns config for a specific provider.
  """
  def get(provider) when is_binary(provider), do: Map.get(@providers, provider)
  def get(provider) when is_atom(provider), do: get(Atom.to_string(provider))

  @doc """
  Returns a list of all provider names.
  """
  def provider_names, do: Map.keys(@providers)

  @doc """
  Gets the API implementation for a provider, allowing for environment overrides (mocks).
  """
  def api_impl(provider) do
    config = get(provider)
    env_key = String.to_atom("#{provider}_api")
    Application.get_env(:social_scribe, env_key, config.api_module)
  end
end
