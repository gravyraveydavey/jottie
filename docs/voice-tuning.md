# Speaker separation and voice matching controls

Settings → Integrations → Voice learning contains the tuning controls. Save settings before recording. Scores expressed as `70/100` are normalized similarity scores, not a 70% probability that the identity is correct.

| Control | Default | Meaning and direction | Applies to |
| --- | --- | --- | --- |
| Voice-match similarity | 70/100 | Minimum similarity to the best enrolled identity. Lower accepts more windows, including potentially incorrect matches. Previously fixed at 80/100. | Saved voice evidence and new recordings |
| Same-voice clustering similarity | 60/100 | Similarity cut used by the initial agglomerative clustering. Lower permits more merging; higher permits more splitting. Later VBx refinement can still change the number of clusters. | Future transcription |
| Known voices per audio track | Automatic | An explicit count for controlled tests. Try **1** for a solo recording. Return to Automatic before ordinary meetings. This is per track, not a meeting-wide headcount. | Future transcription |
| Lead over next person | 12/100 score points | Required difference between the best and next identity score for each supporting window. Lower reduces ambiguity rejection; zero removes this gap requirement. | Saved voice evidence and new recordings |
| Independent windows per match | 2 | Non-overlapping, agreeing windows needed for identity support on one audio track. Lower accepts shorter evidence; enrollment still requires two manually confirmed windows. | Saved voice evidence and new recordings |
| Maximum voices per track | Automatic | Upper limit when the count is unknown. Known voices overrides this limit. | Future transcription |
| Minimum speech for embedding | 1 second | Minimum speech support used by the diarizer's embedding extraction. Raising it ignores more brief material but can miss short contributions. Reusable saved voice windows additionally require at least two seconds and sufficient transcript coverage. | Future transcription |

The pinned FluidAudio SDK's clustering property is described as a Euclidean distance in one configuration comment, but its [actual AHC implementation](https://github.com/FluidInference/FluidAudio/blob/19600a485baa4998812e4654b70d2bab8f2c9949/Sources/FluidAudio/Diarizer/Offline/Clustering/AHCClustering.swift) treats the value as cosine similarity and converts it with `sqrt(2 - 2 * similarity)`. Jottie exposes the similarity actually consumed by that implementation. These are centroid-linkage clustering cuts, not calibrated pairwise identity confidence.

Other internal settings remain unchanged: VBx warm-start Fa = 0.07 and Fb = 0.8, ten-second segmentation windows with two-second steps, overlap exclusion for embedding extraction, and the existing word-to-voice overlap checks (65% coverage and 20% winner lead). Reusable evidence uses 80% passage/window coverage. These quantities measure different things and should not be combined into one confidence percentage. The Community-1 powerset model does not use the SDK's generic speech onset/offset thresholds, so they are not presented as working confidence controls.

## Historical re-evaluation

The first pilot required two windows under each anonymous label. A solo voice split into three labels could have one valid window per label and never be assigned historically. A deterministic synthetic reproduction confirmed this failure even with identical embeddings. Matching now scores windows individually, then allows agreeing windows for the same employee and audio track to support one another across fragmented labels. It does not combine microphone and system-track votes or infer identities from label order.

Only covered passages receive a name. Rejected windows, explicit manual corrections, ambiguous candidates and incompatible model versions retain their existing protections. An unusable early window is filtered before selecting independent windows, so it cannot hide a later clean one. Automatic assignments still never enroll themselves.

The Speakers tab's **Voice matching details** shows saved and usable window counts, same-track support, best/competing candidate scores and rejection reasons. A new recording also retains the separation settings used during capture. Earlier recordings have no tuning snapshot and are identified accordingly. `me` labels belong to the microphone; `them` labels belong to system or imported audio. An unresolved label such as `me unknown` is not proof of another person.

Identity tuning can be replayed from retained embeddings after audio deletion. Clustering controls cannot recover discarded audio or previously discarded embeddings; they affect future transcription or a new import of retained original audio. Original transcript text, times and acoustic labels remain unchanged during identity replay. Multiple anonymous labels may resolve to one person in the displayed speaker rows.

## Next controlled test

1. Save the 70/100 identity default and re-evaluate the four previous solo recordings. Inspect diagnostics where speech remains unassigned. Confirm there are enrolled profiles and at least two usable supporting windows on that track.
2. Record fresh solo speech with Known voices per audio track = 1. Check the stored capture settings, usable evidence and resulting assignments. This verifies the controlled count; it does not prove automatic separation is accurate.
3. Return to Automatic. Hold identity settings fixed while comparing clustering at 60/100 and then 55/100 on new solo recordings with the same device and conditions. Compare surplus clusters and missed speech. Do not change several controls at once.
4. Add an unregistered test subject before relaxing identity thresholds further, then enroll them in a separate recording. Compare false names as well as missed matches. For meetings, use Automatic unless the true count on each individual audio track is known.

The user reported four real solo recordings with two or three speaker entries each, partial voice matches on subsequent recordings, and no successful historical assignment during the first pilot. This establishes that part of the real voice-learning path works; it is not an accuracy benchmark. Synthetic regression results and installed-model/UI checks for this tuning pass are recorded in the roadmap separately from these human observations.
