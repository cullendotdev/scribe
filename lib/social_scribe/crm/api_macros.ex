defmodule SocialScribe.Crm.ApiMacros do
  @moduledoc """
  Shared macros for CRM API implementations.
  Injects common behavior and reduces boilerplate across provider-specific APIs.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote do
      @behaviour SocialScribe.CrmApiBehaviour

      alias SocialScribe.Accounts.UserCredential
      alias SocialScribe.Crm.{BaseApi, Config, ContactFormatter}

      require Logger

      @provider unquote(provider)

      @impl SocialScribe.CrmApiBehaviour
      def display_properties do
        Config.get(@provider)
      end

      @doc """
      Batch updates multiple properties on a contact.
      Filters to only apply updates marked with `apply: true`.
      """
      @impl SocialScribe.CrmApiBehaviour
      def apply_updates(%UserCredential{} = credential, contact_id, updates_list)
          when is_list(updates_list) do
        BaseApi.apply_updates(__MODULE__, credential, contact_id, updates_list)
      end

      # Allow modules to override specific functions
      defoverridable display_properties: 0, apply_updates: 3
    end
  end
end
