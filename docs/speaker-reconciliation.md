# Calendar context and local speaker separation

The reported failure had two independent causes. Recent captures had no calendar invitees. The saved selection pointed at `Default — Calendar`, while the Exchange calendars were unchecked; the app therefore had no invitation identities to reconcile with the successfully synced BambooHR cache. Separately, Parakeet's per-track transcription assigned the entire system track to `them`. That label represented an audio channel, not a detected individual voice.

Synthetic regression tests reproduced a third issue: importing an unchanged transcript again ignored changed calendar metadata. Another test reproduced email matching failures when addresses included whitespace or an upper-case `MAILTO:` prefix. These are now covered at their repository/directory boundaries.

## Calendar and directory behaviour

Integrations lists accounts alongside calendar names and reports the selected available calendars. The actual work calendar must be selected and saved; Jottie does not guess between Exchange calendars or combine unrelated overlapping events. Calendar access granted from Integrations is picked up by the capture watcher without requiring a restart. A refreshed EventKit store avoids stale calendar objects after account changes. Recording directly after initial access still depends on macOS making the grant available.

The Speakers tab now exposes the attached event, the invitation roster, **Find / change calendar event**, and **Refresh directory matches**. The event chooser reads a bounded set of events near the recording from the saved calendar selection. Choosing an event stores a canonical snapshot and manual override, then refreshes local BambooHR matches without contacting Codex. Existing summaries remain versioned and change only on explicit regeneration. Source rescans do not override a manually attached event or manual speaker corrections.

Calendar identities include available work emails and the organiser, with duplicate invitees removed. Directory matching remains email-first and unique-name-only when no email exists; whitespace and mailto casing are normalised. Ambiguous names remain unresolved. A directory match does not establish attendance or identify a speaker channel. Accepting an evidence-backed candidate can prefill its uniquely matched job title.

## Distinguishing remote voices

Under Settings → Recording → Local speech models, **Local speaker separation** downloads the FluidAudio offline Community-1 model set into Jottie's own model directory. A successful download validates the models and enables `transcription.separate_speakers`. It is off for existing installations until this explicit setup. Models are loaded directly through Core ML during transcription; missing or corrupt assets cannot trigger a download fallback. Deleting the models disables separation.

When enabled, the remote track (or a mono imported recording) is diarized locally. Parakeet retains its real word timestamps so a sentence containing two voices can become separate anonymous speaker turns without guessing where to divide its text. Microphone and remote track offsets remain intact. Ambiguous overlap, silence and coarse segments without sufficient timing evidence stay unresolved. Other local engines without word timings can only assign an existing segment when one voice clearly dominates it. Voice embeddings remain transient inside the model and are not stored as reusable voice profiles or sent to BambooHR/Codex.

The transcription remains incomplete if the requested separation step fails. Audio is preserved for retry; after the complete transcript is committed, normal text-only cleanup applies. No audio is sent to a cloud service. Only anonymised labels/times and the transcript reach the library and opted-in text analysis.

This is probabilistic voice separation, not verified identity recognition. Similar voices, crosstalk, quiet speakers and poor audio can still produce unresolved or incorrect voice clusters. Invitees and transcript evidence help propose names afterwards; no one-to-one mapping is inferred from invitation order. The UI says **speaker labels** rather than claiming the number of people from the channel count.

## Existing records and validation limits

Attendee context and directory matches can be repaired for existing records without audio. A transcript whose audio has already been deleted cannot be reliably re-diarized; Jottie does not invent missing voice boundaries from a roster. Shared-channel warnings explain that renaming `them` affects all of its passages. New separation applies to future transcription, or recovery/retranscription only where audio still exists.

Tests use invented audio/timing and directory fixtures. They cover metadata-only updates, manual event precedence, email normalisation, preservation of corrections, two voices in one ASR span, overlap, coarse timings, track offsets and audio retention on missing models. Live meeting accuracy remains a separate validation step.

Model source: [FluidInference speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml). Community-1 conversion artifacts use CC BY 4.0; source attribution and provenance are linked in THIRD-PARTY-NOTICES.md. Model files are downloaded separately and are not bundled into Jottie's application.

Validation outcome: all 772 inherited/capture tests and 46 Jottie tests passed, as did 30 packaging-script checks (two optional skips). A separate opt-in check downloaded the public Community-1 artifacts and loaded all Core ML models successfully without any real recording. That check exposed and fixed a mismatch between the SDK repository slug and its local cache-directory alias; runtime now uses the SDK-provided folder name. Packaging passed signature, embedded-framework launch and macOS 14.2 checks. Unrelated icon work was left unchanged.

On 28 October 2026, after the existing analysis finished, Jottie 0.6.5 (448) replaced the existing bundle in place and launched through LaunchServices. The user's chosen **Exchange — Calendar** was selected and saved, with the former Default calendar deselected. Native UI inspection confirmed the downloaded speaker models and enabled local speaker separation for future recordings. The event chooser retrieved Exchange invitations successfully. Attaching the matching invitation to the recent recording reconciled all eight invitees with the local BambooHR directory, including job titles, without changing its existing summary revision or renaming its shared voice channel. A new real multi-speaker recording is still required to assess separation accuracy.
