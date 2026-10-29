# Jottie macOS pilot

The capture pipeline remains in the inherited executable target. New work is isolated into models, library persistence, knowledge processing, SwiftUI and MCP targets. JSON contracts are version 1; Windows should implement these contracts rather than sharing macOS view code.

## Persistence contract

The meeting.json file is the meeting commit marker and includes complete source text, speaker corrections, logical assignment and selected analysis revision. Analysis files and readable projections are written before that marker. Folder IDs never derive from names. A manually filed meeting remains manually filed on re-analysis.

The library actor serializes in-process writers; a filesystem lock coordinates writers in different processes. SQLite transactions protect durable job leases. A missing or corrupt search index is rebuildable; never delete work.sqlite to repair search. An interrupted revision can leave an unused analysis file, which is harmless because meeting.json selects the current revision.

Folder knowledge fingerprints the current subtree and meeting revisions. Source removal or a changed revision invalidates incremental context, forcing reconstruction from current evidence. Current context remains readable and visibly stale until replacement succeeds. Empty folders get an explicit empty context. Historical context remains local.

Codex uses ChatGPT authentication, an isolated temporary working directory, ephemeral sessions, schema-constrained output and disabled tools/integrations. Invalid evidence or tool calls reject the result. Prompts contain only prepared meeting content and folder labels. No fallback to APIs or other providers is performed.

## Codex summary settings and checks

The app menu's Settings command and the library's gear open the same Jottie settings. General contains the automatic Codex analysis switch, executable override, detected path/version and ChatGPT sign-in status. Recording settings now lives inside the main window and includes capture controls, permissions, startup and model management. See [directory, Trash and settings details](bamboohr-and-trash.md). The old Amanu provider-chain controls are hidden because they do not configure Jottie's native workflow.

Check Codex performs local version and sign-in checks without submitting a transcript. Test connection submits one small invented prompt and validates a structured response using the same runner as summaries. The equivalent CLI commands are `jottie codex` and `jottie codex --test`. Authentication checks use the CLI's `login status` command; see the [official CLI reference](https://learn.chatgpt.com/docs/cli/reference).

Discovery is shared by the recorder diagnostics and the analysis pipeline. It checks PATH, common installer locations, current and older ChatGPT/Codex desktop bundle layouts under both Applications directories, then the login shell. An explicit executable overrides automatic discovery. Processes preserve the Codex authentication location while removing inherited API keys.

On upgrade, an explicit `summary.backend: codex-cli` in Jottie's capture config enables native analysis only if summaries were not disabled and library settings have never been saved. Existing library settings, including an opt-out or edited prompt, always take precedence. Saving Jottie settings immediately schedules outstanding analysis; existing completed analyses regenerate only on request.

General settings now offer model and reasoning-effort selection. The model menu comes from the selected CLI's bundled catalog; account availability is still checked by Codex. A model-ID field supports models absent from that catalog. Blank choices use the isolated CLI/model defaults. The same choices apply to meeting summaries, tags, connection tests and folder context; completed meeting analysis is regenerated only explicitly. See the [official per-run configuration reference](https://learn.chatgpt.com/docs/developer-settings).

The Summary tab edits separate meeting-summary and folder-context prompts, each with preview/reset. Folder prompt/model changes mark context stale and rebuild it from the current subtree's structured meeting summaries. The reducer accepts `MeetingSummary` inputs, which contain no transcript field, and may cite only evidence already present in those summaries. Its prompt payload carries summary prose and source IDs, without transcript evidence quotations. Removals and changed source revisions continue to force reconstruction. Tags are capped at ten including the primary tag; analysis receives the existing tag catalog and normalises equivalent labels before saving. Existing over-limit records receive a local capped revision during reconciliation; the original revision stays in history and no Codex call is required.

## Import and processing

The top Import button accepts individual audio/video files as well as transcripts; the duplicate Import navigation item has been removed. All meetings includes unfiled meetings, and recording and AI filing behaviour are unchanged. Trash is a separate recoverable collection with 48-hour retention. Import accepts folders recursively and individual `.md`, `.markdown`, `.txt`, `.doc` and `.docx` documents, with one document per meeting. Word conversion runs locally using macOS textutil and only extracted text is retained. UTF-8/UTF-16 text and original Markdown content are preserved. Original files are untouched, repeated documents are deduplicated, updates retain manual filing, and unreadable files are reported while other documents continue. Legacy Amanu meeting bundles still import once with their existing summary/metadata, without also importing their Markdown projections or audio. Hidden files, symlinks, packages and Jottie's own library are excluded from scanning.

The expandable processing panel reports `Processing X of Y items (%)`, using successful completions from the current work set rather than unrelated historical jobs. Deferred/failed work stays in the expanded detail with retry controls; a failed item does not advance the completion percentage. Hover tooltips describe manager actions. The Queue page displays real outstanding work and its progress, including media conversion and unfinished transcription sessions with retry controls. See [Media import and speaker testing](media-import-and-speakers.md) for supported inputs and current diarization limits.

## MCP connection fields

Use Name **Jottie** and Description **Search local meeting summaries, transcripts and folder knowledge**. Connection is a **local stdio command**, launched from the copied `mcp_servers.jottie` configuration. Authentication is **none** for this local connection: access is limited by the macOS account and file permissions. Codex sign-in is separate and used only for analysis.

The Codex dialog's **Server URL / Tunnel** choices describe other transports; neither is an address for this stdio service. When the dialog has no command transport, paste the copied block into Codex Settings → Configuration → config.toml. It includes the current executable and exact library directory. Jottie does not create a tunnel or expose an HTTP endpoint. [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference) documents the distinction between `command`/`args` and `url`. Remote/tunnel setup remains a later phase.

## Custom UI scope

See [Custom interface feasibility](custom-ui-feasibility.md). A custom component system is feasible in SwiftUI without replacing the backend or stack. The supplied prototype is now implemented natively; see [Native interface implementation](native-ui-design.md) for scope, interaction mapping and known differences.

## Feedback pass verification — 26 October 2026

The full suite passed with 767 inherited Swift tests and 32 Jottie tests; the optional offscreen UI preview was skipped. The Python suite ran 26 tests with two optional skips. New coverage includes settings migration/model arguments, CLI model catalog parsing, summary-only folder payloads, prompt invalidation, evidence restrictions, capped/reused tags and retained historical revisions, recursive text/Word imports, deduplication/manual filing and batch progress. A live invented connection-test prompt succeeded with explicit `gpt-6.1-sol` and `low` reasoning selections. No real transcript was submitted for this test. Interactive checks of the newly added controls and tooltips remain part of the pilot's manual QA.

Verified on 26 October 2026: the final packaged app discovered the ChatGPT-bundled Codex CLI 0.163.0-alpha.10.2 with a minimal `/usr/bin:/bin` PATH, confirmed ChatGPT sign-in and received a valid structured response to an invented connection-test prompt. The 767 inherited Swift tests and all 24 Jottie tests passed (the optional offscreen UI preview was skipped). Recording and transcription were idle before the previous development instance was closed and replaced. This check did not submit a real transcript.

## Menu bar placement — 29 October 2026

The menu bar uses Jottie's medium-weight waveform, with template rendering while idle and red/orange recording states. The inherited status window and About window use the same mark.

A missing icon on the development Mac was caused by placement outside the MacBook's usable status-icon region, despite both the app and macOS visibility switches being enabled. Temporary diagnostics found the item at x=604; the screen's auxiliary top-right region began at x=825. Giving the item a stable `JottieRecordingStatus` autosave name and seeding its initially unset preferred position from the right edge moved it to x=1260. The seed is applied only when no saved position exists, preserving subsequent user rearrangements. Tests skip real status-item preferences and check seeding/preservation in an isolated defaults suite.

All eight focused menu/setup tests passed, along with the native build, packaged launch, signature and macOS 14.2 compatibility checks. Temporary geometry diagnostics were removed after the live placement check. The user separately confirmed that the soundwave is visible in the menu bar and its menu opens correctly.

## Manual verification

Use invented meeting data for development. Confirm these flows before treating the pilot as ready for daily use:

1. Build/sign Jottie.app, launch through LaunchServices, complete its own permission prompts, and check Amanu's settings and grants are unaffected.
2. Record a synthetic conversation, stop it, and confirm transcript durability followed by audio deletion. Repeat with an interrupted recording and a deliberately unavailable transcription model.
3. Enable Codex explicitly. Verify analysis, primary-tag routing, unknown/duplicate aliases, manual drag filing and regeneration after a prompt change.
4. Import the same Amanu fixture twice. Verify one meeting, unchanged source bytes and no copied audio.
5. Search accented text, filter by tag/date/subtree, select multiple records and export Markdown.
6. Move an analysed meeting between folders. Force context refresh and check both ancestor chains, source links, open actions, pending decisions and old-folder removal.
7. Restart after a deferred job; check its retry status and use Retry. Disable analysis and confirm transcription still works.
8. Start the MCP service with the GUI closed. Use a real MCP client to initialise, list tools, search, fetch paginated transcripts and inspect context freshness.
9. Follow Microsoft onboarding with an approved test destination. Check immutable revisions/current projections, interruptions, offline retry, remote edit conflicts and destination/account mismatches. No audio or capture log should appear remotely.

Local automated tests do not establish that microphone/system-audio TCC grants, Codex account access or Microsoft tenant consent work on another machine. Windows changes require the connected Windows host, a verified source branch, native builds/tests and GUI checks per AGENTS.md.

## Pilot boundaries

- macOS Apple Silicon local transcription; no cloud-audio fallback.
- Single-user folder knowledge and publishing, not shared multi-writer project memory.
- Folder hierarchy is logical metadata. Exports and remote projections are portable views.
- Failed/sensitive publication stays local and visible in processing status. No remote deletion or two-way edit ingestion.
- No inherited analytics endpoint or updater feed. Public release automation must be configured for Jottie before publication.
- The standalone library command opens text data without starting capture; the default app starts the recorder as well.

## Initial verification — 26 October 2026

The macOS arm64 build and automated suites passed: 767 inherited Swift tests, 15 Jottie tests, and the Python packaging-script suite (23 tests, 3 optional skips). The full Swift pass required the pinned LocalVQE runtime/model; the model digest, universal native library and synthetic audio processing were verified.

A separate stdio client initialised MCP, listed all five tools, searched an empty synthetic library and confirmed no files were created there. The SwiftUI hierarchy also rendered with invented meeting data. This offscreen render does not reliably capture native controls and does not establish interactive GUI correctness.

The local bundle at .build/Jottie.app is ad-hoc signed, arm64, and passes the macOS 14.2 compatibility check. It is a development pilot, not a notarised public release. Local packaging reused the installed Amanu app's matching pinned LocalVQE runtime and SHA-verified model; the normal source-build route still needs CMake and the asset compiler.

The first bundle crashed before application startup: its ad-hoc signature enabled the hardened runtime, whose library validation rejected MSAL because ad-hoc code has no signing team identity. Local ad-hoc packaging now explicitly clears runtime flags; builds signed with a real identity retain the hardened runtime. The rebuilt app passed the executable launch check and started through LaunchServices, remaining running with its normal startup message. This verifies startup, not recording or interactive workflows.

Every `make app` now runs `scripts/verify-app-launch.py` against the finished signed bundle, from a temporary working directory without DYLD environment overrides. It requests CLI help, so it exercises framework loading without starting capture. Three macOS integration tests cover successful framework loading, the hardened/ad-hoc failure and corrected signature, and missing embedded frameworks masked by developer environment paths. The updated Python suite ran 26 tests with two optional skips.

The Computer Use connection timed out, so interactive GUI validation could not be completed. Real microphone/system-audio permission flows, live Codex analysis, Microsoft tenant consent/sign-in and actual SharePoint publication remain unverified. No real meeting content was submitted to providers during development.

On this machine, standalone Command Line Tools did not automatically discover Swift Testing's macro plugin. The test invocation supplied the installed testing/libTestingMacros.dylib through Swift's load-plugin-library compiler option. An ordinary configured Xcode toolchain should use the standard command in the README.

## One manager window and development rebuilds

The meeting/transcription manager is Jottie's only main window. It contains recording status, elapsed time, pause/resume, automatic recording and an expandable live transcript. Launch, Dock reopen, menu commands and second-instance activation reveal that same window; reopening never toggles it away. Closing it leaves recording/background work running. Settings and first-run permission dialogs remain auxiliary windows or sheets.

`make app` assembles and verifies a hidden staging bundle before replacing `.build/Jottie.app` at its existing path. `make run-app` then opens that bundle through LaunchServices. Use `APP=/absolute/path/Jottie.app` consistently if choosing another installation location. A failed verification leaves the installed bundle untouched; a failed replacement restores it. The installer checks capture claims and live work leases before gracefully closing a running development instance. If work is active, finish it or quit Jottie and rerun the build. It never force-kills a recording, creates a permanent backup app, or resets permissions. The obsolete sibling `Jottie-update.app` is removed after successful installation.

Keep the bundle identifier `com.gravyraveydavey.jottie` and use the same signing identity across builds (`make SIGN_ID="Apple Development: …"`, or the distribution identity). Library files, Keychain configuration and capture preferences remain outside the bundle and are not replaced. In-place replacement alone cannot guarantee TCC grant persistence with ad-hoc signatures: their code requirement can change when the executable changes. No valid code-signing certificate was available on the development Mac during this update, so local pilot builds remain ad-hoc signed. Configure a persistent Apple signing identity for dependable permission continuity. The installer refuses to replace an app signed by a team with an ad-hoc build or another team's signature.

Verification on 27 October 2026: 767 inherited Swift tests and the existing 32-test Jottie run passed (the optional preview was skipped), followed by the new manager close/reopen regression test. All 30 Python tests passed with two optional skips, including replacement rollback, active capture protection, signing-team protection and duplicate-bundle cleanup. The final arm64 pilot bundle passed signature, loader and macOS 14.2 checks. LaunchServices opened one canonical Jottie process; only `.build/Jottie.app` remains. Real recording permissions and capture were not re-tested in this pass.

## Prototype-based native workspace

The native manager now follows the supplied Jottie frontend prototype. Settings and Queue live within the same manager window. Stars and manual speaker job titles are stored in canonical meeting metadata; older records remain compatible. Existing summary revisions, local transcription, capture/recovery, filing, exports, evidence and MCP behaviour remain available. See [Native interface implementation](native-ui-design.md) for exact screen mappings, keyboard/drag interactions, provenance-related differences and verification.
