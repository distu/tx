# Privacy and data flow

tx records only after you start a selected capture or activate dictation. Meeting audio and dictations can contain sensitive personal information. Obtain consent where required and inspect the capture indicator while recording.

## Data stored on the Mac

- Session metadata and transcripts: `~/Library/Application Support/tx/tx.sqlite`.
- Meeting audio: `~/Library/Application Support/tx/recordings/`.
- Optional dictation audio: `~/Library/Application Support/tx/dictations/`.
- Downloaded Whisper models: `~/Library/Caches/tx/whisper/`.

These paths are runtime data, not repository assets. Do not put them in GitHub issues or pull requests.

## Network paths

WhisperKit transcription runs locally after its model has been downloaded. The optional browser extension sends supported meeting metadata to the tx app through a loopback HTTP bridge bound to `127.0.0.1:49200`; it does not send that metadata to a tx service.

When Gemini API transcription is enabled, tx sends selected audio and its transcription prompt to Google. When Gemini meeting notes are enabled, it sends transcript text to Google. The optional Gemini API key is stored in the macOS Keychain and sent in the `x-goog-api-key` request header. Existing preference based keys are migrated on launch. API usage can incur separate charges.

When Codex meeting notes are enabled, tx invokes the official Codex CLI with transcript text. The CLI uses its existing ChatGPT login; tx does not read the CLI's token. This path does not send audio and does not replace the transcription engine. Review the CLI's terms and account limits for your use.

## Mute behavior

The app tries to capture your microphone track only when it has evidence that your microphone is enabled in the selected meeting. An unknown state leaves that track unavailable. This check depends on each meeting client's UI and can fail after the client changes. Verify the HUD before relying on a recording, and review the saved audio afterward.

## Logs and reports

System logs may contain process names, errors, and session identifiers. Share only redacted logs. Public reports should use invented meeting titles, participants, and transcript excerpts.
