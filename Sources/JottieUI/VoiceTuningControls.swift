import SwiftUI
import JottieModels

@MainActor struct VoiceTuningControls: View {
    @Binding var tuning: VoiceTuning
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            score("Voice-match similarity", value: $tuning.matchSimilarity, range: 0.4...0.95,
                help: "Minimum similarity to an enrolled person. Lower values accept more matches. 70/100 is a score, not a 70% probability of identity.")
            score("Same-voice clustering similarity", value: $tuning.clusteringSimilarity, range: 0.2...0.95,
                help: "Lower values allow more merging during initial speaker clustering; higher values tend to split voices. The later refinement step can still change the speaker count.")
            count("Known voices per audio track", value: $tuning.knownSpeakersPerTrack)
            hint("For a solo test, choose 1. Return to Automatic for normal meetings. Microphone and system/imported audio are processed separately, so this is a count per track.")
            DisclosureGroup("Advanced matching and speech filters") {
                VStack(alignment: .leading, spacing: 18) {
                    score("Lead over next person", value: $tuning.matchMargin, range: 0...0.5,
                        help: "Minimum gap between the two best identity scores, in score points. Keep this separate from the match threshold to reject similar candidates.")
                    Stepper("Independent windows per match: \(tuning.minimumMatchingWindows)", value: $tuning.minimumMatchingWindows, in: 1...8)
                        .font(JottieStyle.font(12))
                    hint("Agreeing windows on the same audio track can support one another across fragmented speaker labels. Enrollment always requires at least two manually confirmed windows.")
                    count("Maximum voices per track", value: $tuning.maximumSpeakersPerTrack)
                        .disabled(tuning.knownSpeakersPerTrack > 0)
                    hint("An optional upper limit for automatic separation. A known count overrides this limit.")
                    HStack {
                        Text("Minimum speech for embedding").font(JottieStyle.font(12, .medium))
                        Spacer()
                        Text(String(format: "%.2f s", tuning.minimumEmbeddingSpeechSeconds)).font(JottieStyle.mono(12))
                    }
                    Slider(value: $tuning.minimumEmbeddingSpeechSeconds, in: 1...5, step: 0.25)
                    hint("Higher values ignore more brief speech when building clusters. They can also miss short contributions. Reusable voice windows additionally need at least two seconds of valid support.")
                }.padding(.top, 12)
            }.font(JottieStyle.font(12))
            hint("Save to re-evaluate identity matches in saved recordings. Separation controls apply to future transcription; deleted audio cannot be separated again. Existing manual corrections are retained.")
            Button("Reset tuning defaults") { tuning = VoiceTuning() }.buttonStyle(JottieButtonStyle(compact: true))
        }
    }
    private func hint(_ value: String) -> some View {
        Text(value).font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted).fixedSize(horizontal: false, vertical: true)
    }
    private func score(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(JottieStyle.font(12, .medium)); Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))/100").font(JottieStyle.mono(12))
            }
            Slider(value: value, in: range, step: 0.01).accessibilityLabel(title)
            hint(help)
        }
    }
    private func count(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title).font(JottieStyle.font(12, .medium)); Spacer()
            Picker(title, selection: value) {
                Text("Automatic").tag(0)
                ForEach(1...12, id: \.self) { Text(String($0)).tag($0) }
            }.labelsHidden().frame(width: 150)
        }
    }
}

@MainActor struct VoiceDiagnosticsView: View {
    let entries: [VoiceDiagnostic]
    let capture: VoiceTuning?
    @ViewState private var expanded = true
    var body: some View {
        DisclosureGroup("Voice matching details", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                if let capture {
                    Text("Recorded with clustering \(Int((capture.clusteringSimilarity * 100).rounded()))/100 · known voices per track: \(capture.knownSpeakersPerTrack == 0 ? "automatic" : String(capture.knownSpeakersPerTrack)) · minimum speech: \(String(format: "%.2f s", capture.minimumEmbeddingSpeechSeconds))")
                } else { Text("No separation settings were saved with this recording. Retained voice evidence can still be re-evaluated.") }
                Text("me = microphone; them = system or imported audio. Scores describe similarity, not identity probability.")
                ForEach(entries) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.speaker + " · " + item.reason).font(JottieStyle.font(12, .medium))
                        Text("\(item.storedWindows) saved · \(item.usableWindows) usable independent windows · \(item.supportingWindows) supporting this identity on the track")
                        if let name = item.bestName, let similarity = item.similarity {
                            Text("Best candidate: \(name) · weakest window similarity \(String(format: "%.2f", similarity))")
                            if let runner = item.runnerUpName, let score = item.runnerUpSimilarity {
                                Text("Competing candidate: \(runner) · strongest competing score \(String(format: "%.2f", score)) · smallest lead \(String(format: "%.2f", item.margin ?? 0))")
                            } else { Text("No competing enrolled person for these windows.") }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted).padding(.top, 10)
        }.font(JottieStyle.font(12))
    }
}
