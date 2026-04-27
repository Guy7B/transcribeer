import SwiftUI

/// Transcription tab in Settings.
///
/// Split out of `SettingsView` to keep either file under the 600-line
/// threshold and because the transcription backend picker introduces a
/// non-trivial amount of backend-specific UI that doesn't belong in the
/// shell view. The Google STT API key lives in its own keychain entry with
/// the same debounced-save pattern the LLM key uses in `SettingsView`.
struct TranscriptionSettingsView: View {
    @Binding var config: AppConfig
    @State private var modelCatalog = ModelCatalogService()
    @State private var googleSttApiKey: String = ""
    @State private var googleSttSaveTask: Task<Void, Never>?
    @State private var pendingGoogleSttSave: Bool = false

    var body: some View {
        let kind = TranscriptionBackendKind.from(config.transcriptionBackend)

        return Form {
            backendSection

            // Backend-specific settings. The language section is shared
            // because all providers consume the same `config.language`
            // field. Diarization is backend-specific: v1 Google can inline
            // it (poorly, for Hebrew); WhisperKit and v2 always hand off to
            // Pyannote.
            switch kind {
            case .whisperkit:
                whisperModelSection
                languageSection
                pyannoteDiarizationSection
            case .googleSttV2:
                googleSTTV2Section
                languageSection
                pyannoteDiarizationSection
            case .googleStt:
                googleSTTModelSection
                languageSection
                googleSTTDiarizationSection
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear {
            googleSttApiKey = KeychainHelper.getAPIKey(
                backend: GoogleSTTBackend.keychainBackend,
            ) ?? ""
        }
        .onDisappear { flushGoogleSttKeySave() }
        .task {
            // Make sure whatever the user has selected is visible in the list,
            // then refresh from the network. If refresh fails the pre-seeded
            // entry keeps the UI usable.
            modelCatalog.ensureEntry(for: AppConfig.canonicalWhisperModel(config.whisperModel))
            await modelCatalog.refresh()
            modelCatalog.ensureEntry(for: AppConfig.canonicalWhisperModel(config.whisperModel))
        }
    }

    // MARK: - Shared sections

    private var backendSection: some View {
        Section {
            Picker("Backend", selection: Binding(
                get: { TranscriptionBackendKind.from(config.transcriptionBackend) },
                set: { newKind in
                    // Keep any pending Google STT key write from leaking into
                    // the next backend's settings while the user toggles.
                    flushGoogleSttKeySave()
                    config.transcriptionBackend = newKind.rawValue
                    save()
                },
            )) {
                ForEach(TranscriptionBackendKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
        } header: {
            Text("Backend")
        } footer: {
            Text(backendFooterText)
                .foregroundStyle(.secondary)
        }
    }

    private var backendFooterText: String {
        switch TranscriptionBackendKind.from(config.transcriptionBackend) {
        case .whisperkit:
            "On-device via WhisperKit. Audio never leaves the machine. " +
                "First run downloads the model (~0.1–1.5 GB)."
        case .googleSttV2:
            "Cloud via Google Speech-to-Text v2 (Chirp). Best Hebrew transcription " +
                "among cloud options. Requires the `gcloud` CLI + " +
                "`gcloud auth application-default login`."
        case .googleStt:
            "Cloud via Google Speech-to-Text v1 (legacy). Hebrew transcription " +
                "is poor — use v2 (Chirp) unless you can only authenticate with " +
                "an API key."
        }
    }

    private var languageSection: some View {
        Section {
            Picker("Language", selection: Binding(
                get: { TranscriptionLanguage.from(config.language) },
                set: { config.language = $0.rawValue; save() },
            )) {
                ForEach(TranscriptionLanguage.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } header: {
            Text("Language")
        } footer: {
            Text(languageFooterText)
                .foregroundStyle(.secondary)
        }
    }

    private var languageFooterText: String {
        if config.language == "auto" {
            return "Auto-detect runs a language-ID pass before transcription. "
                + "Explicit selection is faster and more reliable — recommended "
                + "if you only record in one or two languages."
        }
        let name = TranscriptionLanguage.from(config.language).displayName
        return "Transcribed as \(name). Override per-session from the transcript tab."
    }

    // MARK: - WhisperKit-specific

    private var whisperModelSection: some View {
        Section {
            whisperModelPicker
            TextField("Custom model repo (optional)", text: Binding(
                get: { config.whisperModelRepo },
                set: { config.whisperModelRepo = $0 },
            ))
            .onSubmit { save() }
        } header: {
            HStack {
                Text("Whisper model")
                Spacer()
                if modelCatalog.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await modelCatalog.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh model list")
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Models are downloaded on first use. Stored in ~/.transcribeer/models/.")
                Text("Custom repo: HuggingFace repo for ivrit-ai or other fine-tuned models")
                Text("(e.g. owner/ivrit-ai-whisper-large-v3-turbo-coreml).")
                if let message = modelCatalog.lastError {
                    Text(message).foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var whisperModelPicker: some View {
        let selected = AppConfig.canonicalWhisperModel(config.whisperModel)
        Picker("Model", selection: Binding(
            get: { selected },
            set: { config.whisperModel = $0; save() },
        )) {
            if modelCatalog.entries.isEmpty {
                Text(selected).tag(selected)
            } else {
                ForEach(modelCatalog.entries) { entry in
                    ModelPickerRow(entry: entry).tag(entry.id)
                }
            }
        }
        .pickerStyle(.menu)
        .disabled(modelCatalog.entries.isEmpty)
    }

    private var pyannoteDiarizationSection: some View {
        Section {
            Picker("Speaker detection", selection: Binding(
                get: { config.diarization },
                set: { config.diarization = $0; save() },
            )) {
                Text("pyannote").tag("pyannote")
                Text("none").tag("none")
            }
        } header: {
            Text("Diarization")
        } footer: {
            Text(config.diarization == "none"
                ? "Disabled — transcript will have a single unlabelled speaker."
                : "Detects and labels multiple speakers via local Pyannote.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Google STT-specific

    private var googleSTTModelSection: some View {
        Section {
            SecureField("API key", text: Binding(
                get: { googleSttApiKey },
                set: { newValue in
                    googleSttApiKey = newValue
                    scheduleGoogleSttKeySave(key: newValue)
                },
            ))
            Picker("Model", selection: Binding(
                get: { config.googleSttModel },
                set: { config.googleSttModel = $0; save() },
            )) {
                // v1 model IDs Google supports. Ordered by "best for meetings
                // first". Hebrew availability is probed in footer text below;
                // users can still type any ID directly into config.toml.
                Text("default").tag("default")
                Text("latest_long").tag("latest_long")
                Text("latest_short").tag("latest_short")
                Text("video").tag("video")
                Text("telephony").tag("telephony")
            }
        } header: {
            Text("Google STT")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if googleSttApiKey.isEmpty {
                    Text("Create an API key in Google Cloud Console → APIs & Services → Credentials.")
                        .foregroundStyle(.orange)
                } else {
                    Text("API key stored in Keychain. Audio POSTed inline in ~55s chunks (no GCS).")
                }
                googleSTTModelAdvice
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Surfaces the current (model, language) compatibility so users don't
    /// hit a `model is not supported for language : iw-IL` error at runtime.
    ///
    /// The matrix was probed directly against Google's /v1/speech:recognize
    /// on 2026-04-23; it may expand later (they've been adding languages
    /// to `latest_long` in waves). If Google enables more combinations,
    /// the warning here is the only piece that needs updating.
    @ViewBuilder
    private var googleSTTModelAdvice: some View {
        let lang = config.language.lowercased()
        let model = config.googleSttModel
        let hebrewLike = lang == "he" || lang == "auto"
        let hebrewSupported = model == "default" || model == "telephony"

        if hebrewLike && !hebrewSupported {
            Text(
                "⚠ Google STT v1 doesn't enable `\(model)` for Hebrew. " +
                    "Switch to `default` (recommended for meetings) or `telephony` (phone audio).",
            )
            .foregroundStyle(.orange)
        } else if hebrewLike {
            Text("`default` is the only meeting-appropriate v1 model that supports Hebrew today.")
        } else {
            Text("`latest_long` is the best general default; `default` is the safest cross-language choice.")
        }
    }

    private var googleSTTDiarizationSection: some View {
        let forcedPyannote = PipelineRunner.shouldForcePyannote(language: config.language)
        return Section {
            Toggle("Use Google diarization (skip Pyannote)", isOn: Binding(
                get: { config.googleSttDiarize && !forcedPyannote },
                set: { config.googleSttDiarize = $0; save() },
            ))
            .disabled(forcedPyannote)
        } header: {
            Text("Diarization")
        } footer: {
            if forcedPyannote {
                Text("Hebrew is auto-routed through Pyannote — Google v1's own " +
                    "diarization collapses Hebrew audio to a single speaker. " +
                    "Your toggle preference is preserved for non-Hebrew sessions.")
                    .foregroundStyle(.secondary)
            } else {
                Text(config.googleSttDiarize
                    ? "Speaker tags from Google's words response. Pyannote pass is skipped."
                    : "Google returns text only; the local Pyannote pass runs to label speakers.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Google STT v2 (Chirp)

    private var googleSTTV2Section: some View {
        Section {
            TextField("GCP project ID", text: Binding(
                get: { config.googleSttV2Project },
                set: { config.googleSttV2Project = $0; save() },
            ))
            .textContentType(.username)
            .autocorrectionDisabled()

            Picker("Region", selection: Binding(
                get: { config.googleSttV2Region },
                set: { config.googleSttV2Region = $0; save() },
            )) {
                // Multi-region endpoints first (Chirp 3's GA homes). Single
                // regions follow for users who need data residency or who
                // are running Chirp 2 (which lives in single regions).
                Text("us (multi-region — Chirp 3 default)").tag("us")
                Text("eu (multi-region — EU residency)").tag("eu")
                Text("us-central1 (Chirp 2)").tag("us-central1")
                Text("europe-west4 (Chirp 2)").tag("europe-west4")
                Text("asia-southeast1 (Chirp 2)").tag("asia-southeast1")
            }

            Picker("Model", selection: Binding(
                get: { config.googleSttV2Model },
                set: { config.googleSttV2Model = $0; save() },
            )) {
                Text("chirp_3 (recommended for Hebrew)").tag("chirp_3")
                Text("chirp_2").tag("chirp_2")
                Text("latest_long").tag("latest_long")
                Text("latest_short").tag("latest_short")
            }
        } header: {
            Text("Google STT (Chirp)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if config.googleSttV2Project.isEmpty {
                    Text("Enter your Google Cloud project ID. You must also run " +
                        "`gcloud auth application-default login` in Terminal.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Authenticates via `gcloud` (Application Default Credentials). " +
                        "Audio POSTed inline in ~55s chunks to " +
                        "`\(config.googleSttV2Region)-speech.googleapis.com` — no GCS upload.")
                }
                googleSTTV2Advice
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Model / language / region compatibility guidance.
    @ViewBuilder
    private var googleSTTV2Advice: some View {
        let lang = config.language.lowercased()
        let model = config.googleSttV2Model
        let region = config.googleSttV2Region
        let hebrewLike = lang == "he" || lang == "auto"

        if hebrewLike && model == "chirp_2" {
            Text(
                "⚠ Chirp 2 doesn't officially support Hebrew. In practice it " +
                    "returns Hebrew transcripts, but with occasional phrase loops. " +
                    "Prefer `chirp_3` for Hebrew.",
            )
            .foregroundStyle(.orange)
        } else if model == "chirp_3" && !(region == "us" || region == "eu") {
            Text(
                "⚠ Chirp 3 is only available in the `us` and `eu` multi-region " +
                    "endpoints. This request will fail.",
            )
            .foregroundStyle(.orange)
        } else if model.hasPrefix("chirp_2") && (region == "us" || region == "eu") {
            Text(
                "⚠ Chirp 2 lives in single-region endpoints (`us-central1`, " +
                    "`europe-west4`, `asia-southeast1`). The multi-region endpoint " +
                    "won't route Chirp 2 calls.",
            )
            .foregroundStyle(.orange)
        } else if hebrewLike {
            Text("Diarization is always provided by local Pyannote — Google's v2 " +
                "diarization doesn't support Hebrew.")
        }
    }

    // MARK: - Actions

    private func save() {
        ConfigManager.save(config)
    }

    /// Debounced keychain write for the Google STT API key. Mirrors the LLM
    /// key pattern in `SettingsView` but lives here so the transcription
    /// tab owns all of its own state.
    private func scheduleGoogleSttKeySave(key: String) {
        googleSttSaveTask?.cancel()
        pendingGoogleSttSave = true
        googleSttSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            KeychainHelper.setAPIKey(backend: GoogleSTTBackend.keychainBackend, key: key)
            await MainActor.run { pendingGoogleSttSave = false }
        }
    }

    private func flushGoogleSttKeySave() {
        guard pendingGoogleSttSave else { return }
        googleSttSaveTask?.cancel()
        googleSttSaveTask = nil
        pendingGoogleSttSave = false
        KeychainHelper.setAPIKey(
            backend: GoogleSTTBackend.keychainBackend,
            key: googleSttApiKey,
        )
    }
}
