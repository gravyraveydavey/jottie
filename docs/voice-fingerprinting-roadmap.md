# Local voice fingerprinting roadmap

Started 4 November 2026. Branch: `codex/voice-fingerprinting`, based on this repository's default branch, `master` (there is no `main` branch).

## Intended behaviour

Enable local voice learning explicitly before recording. Capture reusable speaker embeddings during the existing FluidAudio Community-1 diarization pass, before successful transcription deletes audio. Manually assigning suitable speech to a BambooHR person enrolls that voice. Re-evaluate other captured meetings locally, including recordings made before enrollment. Preserve original transcript segments and acoustic labels; attach identity assignments separately. Existing text-only meetings cannot acquire fingerprints without their audio.

Use a Jottie-owned encrypted local store, keyed by company and employee ID. BambooHR remains the directory; no audio or embeddings go to BambooHR, Codex, exports, MCP or Microsoft publication. Profiles retain individual source contributions so correcting or removing an enrollment can reverse its effects. Model identity and preprocessing version travel with every sample. Automatic matches never enroll themselves.

## Implementation stages

- [x] Capture: opt-in setting; obtain normalized 256-dimensional per-window embeddings from the pinned FluidAudio version; retain track/time/source mappings; reject mixed, overlapping, short or invalid evidence; commit evidence before audio deletion.
- [x] Persistence: encrypted voice evidence separate from canonical meeting content and disposable search; durable profile contributions from explicit directory assignments; reversible corrections and deletion; safe company/disconnect boundaries.
- [x] Matching: multiple clean windows, absolute similarity threshold and runner-up margin; unknown remains valid; use matching model versions only; leave manual identities and explicit unknown corrections untouched.
- [x] Reprocessing: enrollment/correction re-evaluates existing saved evidence without audio, network access or summary regeneration; repeatable after restart; expose match provenance in the speaker UI.
- [x] Pilot controls: enable/disable, re-evaluate and erase voice data; report evidence availability and match results; existing summary revisions remain readable and indicate changed identities.
- [x] Automated verification: synthetic vectors and invented meetings for enrollment, cross-meeting updates, unknown guests, ambiguous matches, correction/retraction, model/tenant isolation, persistence/restart, audio failure ordering and export exclusion.
- [ ] Live pilot: recordings by the user, then one or two other explicitly participating test subjects. Record results separately from automated checks.

## First live acceptance test

1. Enable local speaker separation and voice learning. Use invented meeting content and keep summaries/publication disabled for the experiment.
2. Make at least three independent recordings of yourself saying different sentences for 30–60 seconds each. Confirm voice evidence was saved for each before audio deletion. Do not rely on the configured microphone owner name as a verified voice identity.
3. Assign suitable passages in just one recording to your BambooHR entry. Confirm that the other recordings are re-evaluated, matching identities carry voice provenance, and their original text/times/labels remain intact.
4. Restart Jottie and repeat re-evaluation. Correct the enrollment to unknown and confirm dependent automatic assignments retract. Re-enroll correctly and confirm recovery.
5. Add a second test subject without enrolling them. They should remain unknown. Enroll them in one recording and test recognition on a separate recording. Repeat with a third subject.
6. Add a conversation with two people, short utterances, a speakerphone, different microphones, and overlapping speech. Check false names as well as missed matches. Corrections apply only to the confirmed speech evidence.

Separate recordings are the evaluation units: adjacent overlapping windows from the enrollment recording are not independent test cases. The initial single-person test validates wiring, not discrimination between people. Start with conservative experimental thresholds; tune using held-out recordings and report assignment precision, unknown-speaker false assignments and speech coverage. Similarity scores are not probabilities. Auto-application remains an explicitly enabled pilot feature until the multi-person evaluation supports it.

## Scope and follow-ups

Initial implementation is the macOS pilot. It does not change the Windows app or claim Windows validation. Shared profile synchronization, alternate embedding backends (SpeechBrain/sherpa-onnx), calibrated thresholds from a representative evaluation set, and broad company rollout follow separately. Model changes require compatible evidence or re-enrollment, never comparing unrelated embedding spaces.

FluidAudio is preferred because Jottie already uses its diarizer and the pinned SDK exposes chunk embeddings. VoiceSens uses MFCC/GMM authentication with Watson challenge transcription and no absolute unknown-speaker rejection in its matching path. Dejavu recognizes repeated recordings rather than a person's new speech. Neither replaces the chosen pipeline.

## Validation record

The first implementation adds encrypted per-source evidence files under `Voiceprints/`, using AES-GCM and a Jottie-specific Keychain key. No vectors are stored in meeting JSON. Canonical manual passage assignments plus these encrypted source contributions are the durable enrollment record; bounded profile prototypes (up to 32 windows per person/model) are rebuilt during re-evaluation. This avoids a second, independently mutable identity database. No new durable work ledger is needed for this repeatable local reduction: after interruption, reload/startup re-evaluates the canonical inputs again.

Settings → Integrations → Voice learning provides **Remember voices on this Mac**, suggestion-only mode by default, an explicit experimental automatic-assignment switch, re-evaluation and erase controls. The Speakers tab reports usable window counts, suggestions and applied match provenance. UI reload, the background processing pass and explicit re-evaluation all reconcile saved recordings. Existing summaries are not regenerated automatically.

The capture adapter explicitly L2-normalizes raw offline vectors, fingerprints the installed model files and preprocessing, preserves per-track offsets, disables exclusive overlap trimming while capturing evidence, and saves evidence before the transcript completion marker. Failed evidence writes retain audio. Windows with mixed identities or inadequate original passage coverage do not enroll. Matching requires at least two independent non-overlapping windows, similarity at least 0.80 and a margin of at least 0.12 against every competing profile on every window. These constants are pilot choices, not calibrated probabilities. Only sufficiently covered original passages (and their cleanup mappings) receive assignments.

Disabling voice learning retracts automatic matches but retains encrypted evidence for re-enabling. Erase switches learning off, invalidates in-flight capture generations, removes evidence/key and retracts automatic assignments while retaining manual corrections. Company changes/disconnect erase old voice evidence; inactive/missing directory people and trashed meetings cannot contribute to active profiles. Permanent Trash purges delete the associated encrypted evidence.

Focused automated checks passed for cross-recording enrollment/restart, correction and retraction, guests/ambiguity/model isolation, suggestions/manual precedence, encryption/export exclusion, erasure/tenant boundaries, Trash and mixed-window rejection. Capture checks passed for offsets, successful evidence commit, audio deletion and audio preservation on evidence failure or disabled separation. Full-suite, real-model and native UI validation results follow below. No human recognition accuracy is established by synthetic tests.


### Verification on 4 November 2026

- Full capture suite: 791 reported tests passed, with LocalVQE required. This includes the new evidence-before-transcript ordering checks and an opt-in installed-model run on a 40-second, locally synthesized, invented speech fixture. The model run produced valid normalized window embeddings without downloads or real meeting audio.
- Library suite: 126 reported tests passed after preserving ordinary settings round trips, including the opt-in native view renders. Final additions protect the microphone-owner default during regeneration and require each query window to beat the runner-up; both passed in the final 128-test library run. A final stable-employee-ID check also covers directory name/title changes without re-enrollment.
- Packaging-script suite: 30 tests passed with two optional skips.
- Inspected native renders of Integrations settings, an applied voice match and a suggestion-only speaker row. The render fixture also checks that a manual enrollment followed by the normal view-model reload updates the independent recording.
- Computer Use timed out twice, so live clicking was not verified. Microphone/TCC flows, production Keychain access from the packaged app and recognition of actual test subjects remain live pilot checks. Encryption tests use isolated injected keys. No live BambooHR, Codex or Microsoft requests were used.

### Repeating the automated checks

Run the normal Swift test suite on macOS (`swift test --no-parallel`). On this machine, Command Line Tools requires the Testing macro plugin compiler option described in `jottie-pilot.md`; the workspace module-cache environment also avoids the restricted home cache. Set `AMANU_REQUIRE_LOCALVQE=1` for the full capture run.

Optional checks:

- `JOTTIE_VOICE_RENDER_QA=1` with `--filter voiceNativeViewsRenderWithSyntheticEnrollment` writes invented-data previews to `/tmp/jottie-voice-qa/`.
- `JOTTIE_VOICE_MODEL_AUDIO=/tmp/jottie-voice-model-speech.wav` and `JOTTIE_VOICE_MODEL_ROOT=/path/to/Jottie/models/speakers` with `--filter voiceEmbeddingExtractionWithInstalledModelsAndSyntheticSpeech` exercises installed models, without a download fallback. Generate this fixture locally; do not use a real meeting for development.
- `JOTTIE_VOICE_UI_QA=1` with `--filter interactiveVoiceEnrollmentFixture` opens a temporary invented library for a manual correction check. Assign Alice Example in the enrollment recording, inspect the independent recording, then create `/tmp/jottie-voice-ui-finish` to finish the fixture. Remove that sentinel before a new run. This test needs interactive computer access and does not touch the real library.

Individual-person forgetting controls, richer rejected-match diagnostics and evaluation of larger profile galleries remain follow-ups after the initial human pilot. Erase-all and correction/Trash-driven enrollment retraction are available now.


### Pilot bundle

The branch builds an arm64 development app at `.build/.voice-fingerprinting/Jottie.app`. Packaging verifies its signature, embedded-framework startup and macOS 14.2 compatibility. Quit the running Jottie before opening this pilot bundle for recording tests. Under Settings → Integrations, enable Remember voices on this Mac and save; enable Automatically assign strong voice matches as well when testing direct assignment rather than suggestions. Under Recording, use Parakeet and enable/download Local speaker separation. Start recording only after these settings are saved.

This is an ad-hoc signed local development build, not a Windows build or a published/notarized release. The human acceptance sequence above remains outstanding.


Final outcome: all 129 reported library tests passed, including employee-ID stability through a directory rename, microphone-owner suppression during mocked regeneration and the per-window runner-up/coverage checks. The focused capture/separation rerun passed 11 checks. The arm64 pilot bundle passed signature, embedded-framework launch and macOS 14.2 checks. The full 791-check capture result, 30 Python checks and separate native renders/installed-model checks above complete automated verification for this pilot; human recognition remains unverified.
