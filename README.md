# Jottie

A native macOS meeting library built on Amanu’s MIT-licensed recording and local transcription engine. Jottie keeps full text, uses your signed-in Codex CLI for structured analysis, organises meetings into folders, and maintains cited folder knowledge.

## Pilot workflow

1. Build and launch `Jottie.app` using `make app` and `open .build/Jottie.app`. Complete microphone/system-audio setup and download a local transcription model.
2. Open **Recordings** from the recording window or menu bar to show the new library. You can also run `jottie library` to open the library without capture.
3. Open **Settings → General** from the app menu or library gear and enable automatic Codex analysis. The status shows the detected executable, version and ChatGPT sign-in; **Check Codex** refreshes it. **Test connection** submits a small invented prompt using your Codex allowance. Select an executable if automatic discovery cannot find it. Transcripts and selected context go to OpenAI; subscription usage limits apply. There is no paid API fallback.
4. Create your folder tree. Folder names and comma-separated aliases match the AI’s primary tag. Unknown or ambiguous matches stay in Inbox. Dragging a meeting makes its assignment authoritative until you move it again.
5. Choose calendars under **Settings → Calendars**. Enable calendar context separately under Recording settings and relaunch. Calendar invitees are candidates, not verified speakers.
6. Folder context checks default to hourly while the app runs. Change the interval or use **Update now**. Parents include descendant meetings. Pending changes show the last successful context as stale.

**Import Amanu records** copies text and metadata from meeting folders (or a recordings root), preserves originals, deduplicates repeat imports and excludes audio. Select one or multiple meetings and use **Export Markdown** to write UUID-named files. **Speakers** corrects channel labels without changing source utterances; regenerate analysis explicitly to apply corrections to summaries.

## Storage and recovery

Jottie uses `~/Library/Application Support/Jottie/`:

- `Capture/`: the inherited recoverable recording pipeline. Temporary audio is deleted only after a successful durable transcript; failed sessions keep it for retry.
- `Meetings/<UUID>/meeting.json`: canonical full meeting record. Transcript and Markdown projections sit beside it; previous structured analysis lives in `Analysis/`.
- `folders.json`: logical tree, aliases, destinations and stable folder IDs. Filing never moves capture files.
- `Contexts/<UUID>/`: current JSON/Markdown knowledge plus previous revisions.
- `search.sqlite`: disposable FTS5 search index, rebuilt from canonical records.
- `work.sqlite`: durable leases, retries and publication status, independent of search.
- `PublicationReceipts/`: hashes and remote versions used to verify publication retries.
- `Trash/`: recoverable local meeting bundles removed from the visible library.

Capture preferences and setup state are isolated under `~/.config/jottie`. The app has its own bundle ID and CLI, and does not send upstream analytics or use Amanu’s update feed. Audio, transcripts, credentials and settings from an existing Amanu installation are not adopted automatically.

Back up the complete Jottie directory and its private configuration. Do not sync live SQLite databases or the Capture folder with a cloud filesystem. Publish through the app instead. To restore an item from Jottie Trash, quit Jottie, move its bundle back to `Meetings/<UUID>/`, then reopen the app.

## Local MCP

Use **Settings → General → Copy Codex MCP configuration** or add:

```toml
[mcp_servers.jottie]
command = "/absolute/path/to/Jottie.app/Contents/MacOS/Jottie"
args = ["mcp", "serve"]
```

For a development executable, use the path returned by `swift build --show-bin-path`, followed by `/jottie`. `jottie mcp serve --library /path/to/library` can read a different library. This process does not start capture, run Codex, sign into Microsoft or write meeting records.

Tools: `search_meetings`, `get_meeting`, `get_transcript`, `list_folders`, `get_folder_context`. Results contain stable meeting/segment IDs and freshness/revision information. Transcript pages and searches accept `cursor` and `limit` (1–100). ChatGPT remote access is a later phase.

## SharePoint / OneDrive

See [Microsoft pilot onboarding](docs/jottie-microsoft.md). Register an approved public macOS application, enter tenant/client IDs in Settings, sign in, and explicitly connect selected folder subtrees to existing destination folder links. Inbox remains local. Microsoft permission or consent failures hold publication; Jottie never broadens scopes automatically.

Publishing produces text, Markdown and JSON, never audio or capture logs. Stable-ID meeting folders retain immutable revisions with a current manifest. Folder knowledge has immutable history plus a version-checked **Current Context.txt**. Remote edits are held for review rather than overwritten. Local moves and deletion do not delete previously published records.

## Development

The new targets are `JottieModels`, `JottieLibrary`, `JottieKnowledge`, `JottieUI` and `JottieMCP`. The inherited `amanu` executable target remains the capture adapter; its public executable product is `jottie`.

```sh
swift build
swift test --no-parallel
make app
```

[Implementation and pilot checks](docs/jottie-pilot.md) document boundaries and manual verification. Automated tests use synthetic meetings, fake model outputs and mocked Microsoft responses. Actual recording permissions, Microsoft tenant onboarding and live publication require validation on the target machine. Windows follows macOS pilot validation; its source and testing rules remain in AGENTS.md.

## Provenance and licence

Jottie is a fork of [Amanu](https://github.com/gsamat/amanu), which originated from Quill. Preserve [LICENSE](LICENSE), [FORK.md](FORK.md) and [third-party notices](THIRD-PARTY-NOTICES.md). Biscotti informed feature expectations; no Biscotti source or assets are included.

[Inherited Amanu reference](docs/upstream-amanu.md) documents the original implementation, including features deliberately disabled or replaced in the Jottie pilot. It is historical reference, not Jottie’s active data-flow policy.
