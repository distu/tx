# Architecture

tx is a Swift 6 macOS application with a menu bar interface. `TxCore` contains capture, process discovery, transcription, storage, and domain models. `TxApp` contains SwiftUI screens, app lifecycle, dictation coordination, and the optional Codex CLI integration.

## Recording flow

1. Process discovery finds apps with active audio and groups helper processes with their parent instance.
2. A Core Audio process tap captures the selected application's output. A separate microphone tap can capture the user's voice when a supported mute signal says the meeting microphone is enabled.
3. The pipeline writes app and microphone channels separately, plus a playback track. The session stays local under `~/Library/Application Support/tx/recordings/`.
4. On a normal stop, the writers finish and validate their files. The session is stored as recorded, then transcription runs. A failed or incomplete transcription can be retried from saved audio.
5. GRDB stores sessions, segments, projects, and dictations in a local SQLite database. FTS5 indexes transcript text for search.

Core Audio taps isolate operating system processes. They cannot separate two browser tabs that share one process. Process grouping and meeting metadata help associate a capture with the correct app instance, but users should still verify the selected source.

## Mute signals

Microphone capture is controlled by meeting specific signals from accessibility, automation, or the optional browser extension. An unknown signal is treated as unverified, so it does not grant microphone capture. The HUD exposes the live state to help users spot a missing signal before relying on a recording.

Browser metadata is best effort. The optional extension reads supported Meet/Teams page state and posts it to a loopback bridge on `127.0.0.1:49200`. The app can also inspect supported browser windows through macOS automation and accessibility APIs. No extension is required for basic process audio capture.

## Transcription and intelligence

- `TranscriptionEngine` uses WhisperKit and loads models on demand. The default path runs locally.
- `GeminiTranscriptionEngine` is opt in and sends audio to the Gemini API. Its current inline request limit is 18 MB.
- Meeting minutes and briefings are generated from **text already transcribed**, either through the ChatGPT signed-in Codex CLI or the Gemini API. The Codex CLI path does not accept audio.
- Global dictation uses a separate microphone and paste workflow; the prior clipboard contents are restored after paste.

## Repository map

```text
Sources/TxCore/       Audio, process, meeting, transcription, data, models
Sources/TxApp/        SwiftUI app, windows, settings, dictation, text tools
Extensions/tx-meet/  Optional Chromium extension for meeting metadata
Tests/TxCoreTests/   Domain and capture behavior tests
scripts/             Local build and development utilities
```

## Data boundaries

The application support directory, caches, recordings, database, and CLI login state are outside this repository and must never be committed. See [Privacy and data flow](PRIVACY.md).
