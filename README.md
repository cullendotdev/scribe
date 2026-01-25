# Social Scribe

Social Scribe connects your Google Calendar with Recall.ai and Google Gemini to automate your post-meeting workflow. It attends your meetings, summarizes them, suggests automated CRM updates, drafts content for LinkedIn, Facebook, and email, and provides an AI assistant to chat with your meeting transcripts and CRM data.

---

## Key Features

- ** Automated Workflow:** Syncs with Google Calendar, joins meetings via Recall.ai, and auto-generates summaries.
- ** AI Power:** Uses Google Gemini to draft follow-up emails and social media posts based on your custom prompts.
- ** Social Integration:** Post directly to LinkedIn and Facebook Pages from the dashboard.
- ** Unified CRM:** Deep integration with **HubSpot** and **Salesforce** (see below).
- ** AI Assistant:** Context-aware chat sidebar to query meeting insights and CRM data.

---

## Tech Stack

- **Backend:** Elixir, Phoenix LiveView, Oban
- **Database:** PostgreSQL
- **Frontend:** Tailwind CSS, Heroicons, Topbar.js
- **AI & Transcription:** Google Gemini (Flash), Recall.ai
- **Authentication:** Ueberauth (Google, LinkedIn, Facebook, HubSpot, Salesforce)

---

## Getting Started

### Prerequisites

- Elixir & Erlang/OTP
- PostgreSQL
- Node.js

### Setup Instructions

1.  **Clone & Install:**

    ```bash
    git clone https://github.com/cullendotdev/scribe.git
    cd social_scribe
    mix setup
    ```

2.  **Configure Environment:**
    Copy `.env.example` to `.env` and populate the following:

    ```bash
    # Google (Auth & Calendar)
    GOOGLE_CLIENT_ID=...
    GOOGLE_CLIENT_SECRET=...
    GOOGLE_REDIRECT_URI="http://localhost:4000/auth/google/callback"

    # AI & Transcription
    GEMINI_API_KEY=...
    RECALL_API_KEY=...

    # Social Platforms
    # LinkedIn (optional)
    LINKEDIN_CLIENT_ID=...
    LINKEDIN_CLIENT_SECRET=...
    LINKEDIN_REDIRECT_URI="http://localhost:4000/auth/linkedin/callback"

    # Facebook (optional)
    FACEBOOK_APP_ID=...
    FACEBOOK_APP_SECRET=...
    FACEBOOK_REDIRECT_URI="http://localhost:4000/auth/facebook/callback"

    # CRM Integrations
    # HubSpot (optional)
    HUBSPOT_CLIENT_ID=...
    HUBSPOT_CLIENT_SECRET=...
    HUBSPOT_REDIRECT_URI="http://localhost:4000/auth/hubspot/callback"

    # Salesforce (optional)
    SALESFORCE_CLIENT_ID=...
    SALESFORCE_CLIENT_SECRET=...
    SALESFORCE_REDIRECT_URI="http://localhost:4000/auth/salesforce/callback"
    ```

3.  **Run:**
    ```bash
    mix phx.server
    ```
    Visit [`localhost:4000`](http://localhost:4000).

---

## Core Workflow

- **Connect:** Sync Google Calendar and authenticate social/CRM platforms.
- **Capture:** Recall.ai bots join meetings to generate transcripts and participant logs.
- **Analyze:** Google Gemini drafts follow-up emails and social content via background workers.
- **Execute:** Post directly to social media or trigger CRM updates from the dashboard.

---

## 🤝 Unified CRM Integration

Social Scribe features a robust, extensible CRM integration layer designed to sync meeting insights directly into external systems like HubSpot and Salesforce.

### Architecture

- **Config-Driven Registry:** The `SocialScribe.Crm.Config` module serves as a central registry, defining provider metadata (colors, icons), API modules, and field mappings. This allows for easy addition of new CRM providers.
- **Shared API Logic:** `SocialScribe.Crm.BaseApi` abstracts common HTTP client setup and handles **automatic token refreshing**. If an API call fails due to an expired token, the system transparently refreshes the credential and retries the request.
- **Unified UI Components:** A single `CrmModalComponent` dynamically adapts its appearance and behavior based on the active provider, rendering the appropriate fields, icons, and search interfaces.

### Supported Providers

#### HubSpot

- **Status:** Fully Supported
- **Authentication:** Custom Ueberauth strategy (`lib/ueberauth/strategy/hubspot.ex`) handling OAuth 2.0 authorization code flow.
- **Key Features:** Contact search, batch property updates, and automated token management.

#### Salesforce

- **Status:** Fully Supported
- **Authentication:** Custom Ueberauth strategy for Salesforce (`lib/ueberauth/strategy/salesforce.ex`).
- **API:** specific implementation using SOSL (Salesforce Object Search Language) for high-performance contact searching and REST API for record updates.
- **Instance Management:** Dynamically handles tenant-specific instance URLs derived from OAuth metadata.

### 🧠 AI-Powered Contact Updates

The system leverages Google Gemini to automatically keep your CRM data clean:

1.  **Analysis:** After a meeting, the AI analyzes the transcript to identify contact details (titles, phone numbers, addresses).
2.  **Suggestion Engine:** It compares these details against the current data in your connected CRM.
3.  **Smart Review:** The UI presents a "diff" card, showing the current value (strikethrough) and the suggested new value. Users can review and apply these updates selectively with a single click.

---

## 💬 AI CRM Assistant

The **CRM Chat Assistant** is a persistent, context-aware sidebar that allows users to query their CRM data and meeting insights using natural language. It serves as a bridge between unstructured data (conversations, transcripts) and structured records (CRM contacts).

### 🌟 Key Features

- **Multimodal Context Awareness:**
  - **@Mentions:** Integrating a sophisticated mention system, users can type `@` to search across all connected CRMs (HubSpot & Salesforce) simultaneously.
  - **Meeting Transcripts:** Users can feed full meeting transcripts into the context window, allowing the AI to answer questions like _"What did we promise John in last week's meeting?"_.
- **Persistent & Accumulative Sessions:**
  - Chat sessions are saved to the database.
  - **Context Accumulation:** As you mention more contacts or meetings, they are added to the session's "Accumulated Sources". The AI retains knowledge of these entities throughout the conversation, even if not explicitly referenced in every message.
- **Rich UI/UX:**
  - **Markdown & Chips:** AI responses are rendered with Markdown. References to contacts or meetings are automatically converted into interactive "Chips" (inline or block style) displaying the provider's icon.
  - **Resizable Sidebar:** A custom JS hook enables a fully draggable sidebar for optimal workspace management.
  - **Model Selection:** Users can toggle between `Gemini 2.5 Flash` (for speed) and `Gemini 2.5 Flash Lite` (for cost-efficiency).

### 🔧 Implementation Details

#### Frontend (LiveView & JS Hooks)

- **MentionsHandler Hook:** A complex JavaScript hook that manages the caret position, dropdown navigation (Arrow keys/Tab), and synchronizes the `@mention` text with the underlying backend search.
- **SidebarResizer Hook:** Handles mouse events to allow smooth, jagged-free resizing of the sidebar width.
- **Optimistic UI:** The chat interface updates immediately upon sending, while background tasks fetch answers.

#### Backend (Contexts & Tasks)

- **Parallel Search:** When a user types `@`, the backend spawns async `Task`s to query all connected CRM providers in parallel, aggregating results as they arrive (`handle_info`).
- **Token Retrieval Augmented Generation (RAG):**
  - We do not simply dump text into the prompt. When a contact is mentioned, we fetch their full JSON dump from the CRM.
  - **System Prompting:** We instruct Gemini to use a strict token format (`[[contact:provider:id:name]]`) when referencing entities.
  - **Rendering:** The frontend parses these tokens to render uniformly styled UI components (`<.crm_contact_chip />`), regardless of the underlying provider.

#### Data Model

- `ChatSession`: Represents a thread of conversation. Stores `accumulated_sources` (JSON blob) to keep the "Context Window" alive across multiple turns without re-fetching external APIs constantly.
- `ChatMessage`: Stores the individual turn, preserving the `sources` used at that specific point in time for historical accuracy.

---

## Known Issues & Limitations

- **Facebook Posting & App Review:**
  - Posting to Facebook is implemented via the Graph API to a user-managed Page.
  - Full functionality for all users (especially those not app administrators/developers/testers) typically requires a thorough app review process by Meta, potentially including Business Verification. This is standard for apps using Page APIs.
  - During development, posting will be most reliable for app admins to Pages they directly manage.
- **Error Handling & UI Polish:** While core paths are robustly handled, comprehensive error feedback for all API edge cases and advanced UI polish are areas for continued development beyond the initial 48-hour scope.
- **Prompt Templating for Automations:** The current automation prompt templating is basic (string replacement). A more sophisticated templating engine (e.g., EEx or a dedicated library) would be a future improvement.
- **Agenda Integration:** Currently we only sync when the calendar event has a `hangoutLink` or `location` field with a zoom or google meet link.

---

## Learn More (Phoenix Framework)

- Official website: https://www.phoenixframework.org/
- Guides: https://hexdocs.pm/phoenix/overview.html
- Docs: https://hexdocs.pm/phoenix
- Forum: https://elixirforum.com/c/phoenix-forum
- Source: https://github.com/phoenixframework/phoenix
