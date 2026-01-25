defmodule SocialScribe.AIContentGenerator do
  @moduledoc "Generates content using Google Gemini."

  @behaviour SocialScribe.AIContentGeneratorApi

  alias SocialScribe.Meetings
  alias SocialScribe.Automations

  @gemini_model "gemini-2.5-flash-lite"
  @gemini_api_base_url "https://generativelanguage.googleapis.com/v1beta/models"

  @impl SocialScribe.AIContentGeneratorApi
  def generate_follow_up_email(meeting) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        prompt = """
        Based on the following meeting transcript, please draft a concise and professional follow-up email.
        The email should summarize the key discussion points and clearly list any action items assigned, including who is responsible if mentioned.
        Keep the tone friendly and action-oriented.

        #{meeting_prompt}
        """

        call_gemini(prompt)
    end
  end

  @impl SocialScribe.AIContentGeneratorApi
  def generate_automation(automation, meeting) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        prompt = """
        #{Automations.generate_prompt_for_automation(automation)}

        #{meeting_prompt}
        """

        call_gemini(prompt)
    end
  end

  @impl SocialScribe.AIContentGeneratorApi
  def generate_hubspot_suggestions(meeting) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        prompt = """
        You are an AI assistant that extracts contact information updates from meeting transcripts.

        Analyze the following meeting transcript and extract any information that could be used to update a CRM contact record.

        Look for mentions of:
        - Phone numbers (phone, mobilephone)
        - Email addresses (email)
        - Company name (company)
        - Job title/role (jobtitle)
        - Physical address details (address, city, state, zip, country)
        - Website URLs (website)
        - LinkedIn profile (linkedin_url)
        - Twitter handle (twitter_handle)

        IMPORTANT: Only extract information that is EXPLICITLY mentioned in the transcript. Do not infer or guess.

        The transcript includes timestamps in [MM:SS] format at the start of each line.

        Return your response as a JSON array of objects. Each object should have:
        - "field": the CRM field name (use exactly: firstname, lastname, email, phone, mobilephone, company, jobtitle, address, city, state, zip, country, website, linkedin_url, twitter_handle)
        - "value": the extracted value
        - "context": a brief quote of where this was mentioned
        - "timestamp": the timestamp in MM:SS format where this was mentioned

        If no contact information updates are found, return an empty array: []

        Example response format:
        [
          {"field": "phone", "value": "555-123-4567", "context": "John mentioned 'you can reach me at 555-123-4567'", "timestamp": "01:23"},
          {"field": "company", "value": "Acme Corp", "context": "Sarah said she just joined Acme Corp", "timestamp": "05:47"}
        ]

        ONLY return valid JSON, no other text.

        Meeting transcript:
        #{meeting_prompt}
        """

        case call_gemini(prompt) do
          {:ok, response} ->
            parse_suggestions(response)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl SocialScribe.AIContentGeneratorApi
  def generate_salesforce_suggestions(meeting) do
    case Meetings.generate_prompt_for_meeting(meeting) do
      {:error, reason} ->
        {:error, reason}

      {:ok, meeting_prompt} ->
        prompt = """
        You are an AI assistant that extracts contact information updates from meeting transcripts for Salesforce.

        Analyze the following meeting transcript and extract any information that could be used to update a Salesforce Contact record.

        Look for mentions of:
        - First Name (FirstName)
        - Last Name (LastName)
        - Email (Email)
        - Phone number (Phone)
        - Mobile Phone (MobilePhone)
        - Job Title (Title)
        - Department (Department)
        - Mailing Address (MailingStreet, MailingCity, MailingState, MailingPostalCode, MailingCountry)

        IMPORTANT: Only extract information that is EXPLICITLY mentioned in the transcript. Do not infer or guess.

        The transcript includes timestamps in [MM:SS] format at the start of each line.

        Return your response as a JSON array of objects. Each object should have:
        - "field": the Salesforce API field name (use exactly: FirstName, LastName, Email, Phone, MobilePhone, Title, Department, MailingStreet, MailingCity, MailingState, MailingPostalCode, MailingCountry)
        - "value": the extracted value
        - "context": a brief quote of where this was mentioned
        - "timestamp": the timestamp in MM:SS format where this was mentioned

        If no contact information updates are found, return an empty array: []

        Example response format:
        [
          {"field": "Phone", "value": "555-123-4567", "context": "John mentioned 'you can reach me at 555-123-4567'", "timestamp": "01:23"},
          {"field": "Title", "value": "VP of Sales", "context": "Sarah said she was promoted to VP of Sales", "timestamp": "05:47"}
        ]

        ONLY return valid JSON, no other text.

        Meeting transcript:
        #{meeting_prompt}
        """

        case call_gemini(prompt) do
          {:ok, response} ->
            parse_suggestions(response)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl SocialScribe.AIContentGeneratorApi
  def answer_crm_question(question, conversation_history, contacts_data, model \\ nil) do
    selected_model = model || @gemini_model
    conversation = format_conversation_history(conversation_history)
    sources_info = format_multi_source_contacts(contacts_data)

    system_context =
      if sources_info != "" do
        """
        You are a helpful CRM assistant with access to contact information from one or more CRM sources.
        You can answer questions about contacts, compare information across different sources, and provide insights.

        IMPORTANT - Mention Formatting:
        When you want to show a contact or meeting as a styled inline mention (with avatar/icon), use these token formats:
        - For contacts: [[contact:PROVIDER:ID:Full Name]]
        - For meetings: [[meeting:ID:Title]]

        Examples:
        - "I found information about [[contact:salesforce:123:John Rabbit]]"
        - "In the [[meeting:456:Weekly Standup]], Tim discussed..."

        Use plain text (no tokens) for:
        - Headings and section titles
        - Bullet point labels (e.g., "Name:", "Email:")
        - When the name appears multiple times in quick succession

        Available Contact Sources:
        #{sources_info}
        """
      else
        """
        You are a helpful CRM assistant. The user hasn't tagged any specific contacts yet.
        Suggest they tag a contact using @Name to get specific information.
        """
      end

    prompt =
      if conversation != "" do
        """
        #{system_context}

        Conversation History:
        #{conversation}

        Current User Question:
        #{question}

        Please answer based on the available contact data and conversation context.
        If comparing contacts, clearly reference each source.
        If information is not available, say so politely.
        """
      else
        """
        #{system_context}

        User Question:
        #{question}

        Please answer based on the available contact data.
        If information is not available, say so politely.
        """
      end

    call_gemini(prompt, selected_model)
  end

  defp format_conversation_history(history) when is_list(history) do
    history
    |> Enum.map(fn msg ->
      role = if msg[:role] == :user or msg[:role] == "user", do: "User", else: "Assistant"
      "#{role}: #{msg[:content]}"
    end)
    |> Enum.join("\n")
  end

  defp format_conversation_history(_), do: ""

  defp format_multi_source_contacts(contacts) when is_list(contacts) and length(contacts) > 0 do
    contacts
    |> Enum.with_index(1)
    |> Enum.map(fn {contact, idx} ->
      provider = contact[:provider] || contact["provider"] || "unknown"
      id = contact[:id] || contact["id"]

      if provider == "google_meet" do
        meeting_data = contact[:meeting] || contact["meeting"]
        title = contact[:lastname] || contact["lastname"] || "Meeting"

        prompt =
          case meeting_data do
            %SocialScribe.Meetings.Meeting{} = m ->
              case SocialScribe.Meetings.generate_prompt_for_meeting(m) do
                {:ok, p} -> p
                _ -> "Meeting transcript unavailable."
              end

            _ ->
              "Meeting data unavailable."
          end

        """
        [Source #{idx}: Google Meet Transcript]
        Token to use: [[meeting:#{id}:#{title}]]
        #{prompt}
        """
      else
        name =
          "#{contact[:firstname] || contact["firstname"]} #{contact[:lastname] || contact["lastname"]}"

        """
        [Source #{idx}: #{String.capitalize(provider)} - #{name}]
        Token to use: [[contact:#{provider}:#{id}:#{name}]]
        #{Jason.encode!(contact, pretty: true)}
        """
      end
    end)
    |> Enum.join("\n")
  end

  defp format_multi_source_contacts(_), do: ""

  defp parse_suggestions(response) do
    # Clean up the response - remove markdown code blocks if present
    cleaned =
      response
      |> String.trim()
      |> String.replace(~r/^```json\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, suggestions} when is_list(suggestions) ->
        formatted =
          suggestions
          |> Enum.filter(&is_map/1)
          |> Enum.map(fn s ->
            %{
              field: s["field"],
              value: s["value"],
              context: s["context"],
              timestamp: s["timestamp"]
            }
          end)
          |> Enum.filter(fn s -> s.field != nil and s.value != nil end)

        {:ok, formatted}

      {:ok, _} ->
        {:ok, []}

      {:error, _} ->
        # If JSON parsing fails, return empty suggestions
        {:ok, []}
    end
  end

  defp call_gemini(prompt_text, model \\ @gemini_model) do
    api_key = Application.get_env(:social_scribe, :gemini_api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, {:config_error, "Gemini API key is missing - set GEMINI_API_KEY env var"}}
    else
      path = "/#{model}:generateContent?key=#{api_key}"

      payload = %{
        contents: [
          %{
            parts: [%{text: prompt_text}]
          }
        ]
      }

      case Tesla.post(client(), path, payload) do
        {:ok, %Tesla.Env{status: 200, body: body}} ->
          text_path = [
            "candidates",
            Access.at(0),
            "content",
            "parts",
            Access.at(0),
            "text"
          ]

          case get_in(body, text_path) do
            nil -> {:error, {:parsing_error, "No text content found in Gemini response", body}}
            text_content -> {:ok, text_content}
          end

        {:ok, %Tesla.Env{status: status, body: error_body}} ->
          {:error, {:api_error, status, error_body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

  defp client do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, @gemini_api_base_url},
      Tesla.Middleware.JSON
    ])
  end
end
