# Jottie macOS pilot

The capture pipeline remains in the inherited executable target. New work is isolated into models, library persistence, knowledge processing, SwiftUI and MCP targets. JSON contracts are version 1; Windows should implement these contracts rather than sharing macOS view code.

## Persistence contract

The meeting.json file is the meeting commit marker and includes complete source text, speaker corrections, logical assignment and selected analysis revision. Analysis files and readable projections are written before that marker. Folder IDs never derive from names. A manually filed meeting remains manually filed on re-analysis.

The library actor serializes in-process writers; a filesystem lock coordinates writers in different processes. SQLite transactions protect durable job leases. A missing or corrupt search index is rebuildable; never delete work.sqlite to repair search. An interrupted revision can leave an unused analysis file, which is harmless because meeting.json selects the current revision.

Folder knowledge fingerprints the current subtree and meeting revisions. Source removal or a changed revision invalidates incremental context, forcing reconstruction from current evidence. Current context remains readable and visibly stale until replacement succeeds. Empty folders get an explicit empty context. Historical context remains local.

Codex uses ChatGPT authentication, an isolated temporary working directory, ephemeral sessions, schema-constrained output and disabled tools/integrations. Invalid evidence or tool calls reject the result. Prompts contain only prepared meeting content and folder labels. No fallback to APIs or other providers is performed.

## Codex summary settings and checks

The app menu's Settings command and the library's gear open the same Jottie settings. General contains the automatic Codex analysis switch, executable override, detected path/version and ChatGPT sign-in status. Recording settings opens the separate capture/permissions form; its summary link returns to Jottie settings. The old Amanu provider-chain controls are hidden because they do not configure Jottie's native workflow.

Check Codex performs local version and sign-in checks without submitting a transcript. Test connection submits one small invented prompt and validates a structured response using the same runner as summaries. The equivalent CLI commands are `jottie codex` and `jottie codex --test`. Authentication checks use the CLI's `login status` command; see the [official CLI reference](https://learn.chatgpt.com/docs/cli/reference).

Discovery is shared by the recorder diagnostics and the analysis pipeline. It checks PATH, common installer locations, current and older ChatGPT/Codex desktop bundle layouts under both Applications directories, then the login shell. An explicit executable overrides automatic discovery. Processes preserve the Codex authentication location while removing inherited API keys.

On upgrade, an explicit `summary.backend: codex-cli` in Jottie's capture config enables native analysis only if summaries were not disabled and library settings have never been saved. Existing library settings, including an opt-out or edited prompt, always take precedence. Saving Jottie settings immediately schedules outstanding analysis; existing completed analyses regenerate only on request.

Verified on 26 October 2026: the final packaged app discovered the ChatGPT-bundled Codex CLI 0.163.0-alpha.10.2 with a minimal `/usr/bin:/bin` PATH, confirmed ChatGPT sign-in and received a valid structured response to an invented connection-test prompt. The 767 inherited Swift tests and all 24 Jottie tests passed (the optional offscreen UI preview was skipped). Recording and transcription were idle before the previous development instance was closed and replaced. This check did not submit a real transcript.

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
