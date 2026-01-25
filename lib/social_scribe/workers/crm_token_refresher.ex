defmodule SocialScribe.Workers.CrmTokenRefresher do
  @moduledoc """
  Unified Oban worker that proactively refreshes OAuth tokens for all CRM providers.
  Runs every 5 minutes and refreshes tokens expiring within a threshold defined in Config.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias SocialScribe.Repo
  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.Crm.{Config, TokenManager}

  import Ecto.Query
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    provider = Map.get(args, "provider")

    providers = if provider, do: [provider], else: Config.provider_names()

    Enum.each(providers, fn p ->
      process_provider(p)
    end)

    :ok
  end

  defp process_provider(provider) do
    config = Config.get(provider)
    threshold_minutes = config.refresh_threshold_minutes || 10

    Logger.info("Running proactive #{config.label} token refresh check...")

    expiring_credentials = get_expiring_credentials(provider, threshold_minutes)

    case expiring_credentials do
      [] ->
        Logger.debug("No #{config.label} tokens expiring soon")
        :ok

      credentials ->
        Logger.info(
          "Found #{length(credentials)} #{config.label} token(s) expiring soon, refreshing..."
        )

        refresh_all(provider, credentials)
    end
  end

  defp get_expiring_credentials(provider, threshold_minutes) do
    threshold = DateTime.add(DateTime.utc_now(), threshold_minutes, :minute)

    from(c in UserCredential,
      where: c.provider == ^provider,
      where: c.expires_at < ^threshold,
      where: not is_nil(c.refresh_token)
    )
    |> Repo.all()
  end

  defp refresh_all(provider, credentials) do
    config = Config.get(provider)

    Enum.each(credentials, fn credential ->
      case TokenManager.refresh_credential(credential) do
        {:ok, _updated} ->
          Logger.info(
            "Proactively refreshed #{config.label} token for credential #{credential.id}"
          )

        {:error, reason} ->
          Logger.error(
            "Failed to proactively refresh #{config.label} token for credential #{credential.id}: #{inspect(reason)}"
          )
      end
    end)
  end
end
