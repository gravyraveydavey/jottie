# Jottie privacy and data flow

Recording and transcription run on this Mac. Jottie uses local Parakeet, Whisper or GigaAM, with no cloud-audio fallback. Audio is temporary: it is deleted after a durable successful transcript. Interrupted or failed transcription keeps audio locally so it can be recovered or retried. Recoverable text, prior analysis and trashed records remain under the Jottie data directory until you remove them.

## Optional Codex analysis

Enable analysis explicitly in Library Settings. Jottie gives your signed-in Codex CLI the full transcript, selected meeting/calendar context and folder labels. Codex sends this text to OpenAI using your ChatGPT account; its terms, policies and usage allowance apply. This is local transcription with optional remote text analysis, not a promise of fully offline AI. There is no metered API or alternate-provider fallback.

The subprocess uses ephemeral sessions, an isolated temporary directory, structured output and disabled tools/integrations. Temporary input, response and trace files are removed after the request completes. Jottie does not log raw transcript text to its processing ledger.

## Calendars and speakers

Calendar access is optional. Only selected calendars supply meeting titles and invitees. Calendar-triggered recording is an independent preference. An invitation is not proof that someone attended or spoke. AI speaker candidates remain unconfirmed until a user accepts a correction; original transcript text and labels are retained.

## Optional SharePoint publication

Publishing requires Microsoft sign-in and an explicit destination for selected folder subtrees. It sends transcript, analysis and eligible folder-context text/Markdown/JSON to Microsoft Graph. Audio and capture logs are excluded. Tokens are managed by MSAL in Jottie's private Keychain cache. Local settings store destination/account identifiers, not access tokens.

Remote revisions are retained. Local deletion, moving a meeting or disabling publishing does not revoke access to copies already published. Permissions come from Microsoft and the chosen destination; AI classifications never grant access.

## Local MCP

The optional stdio MCP service exposes read-only meeting search, summaries, transcripts and folder context to the local client that launches it. It does not open a network listener. That client may send returned meeting text to its own model provider under the client's policies. Configure access only in clients you intend to use with this library.

## Analytics, updates and downloads

The Jottie pilot does not send upstream product analytics and does not use Amanu's update feed. Model downloads still contact their configured upstream distribution hosts. Codex and Microsoft authentication contact their providers when those features are used. No Jottie account or hosted meeting database is required.
