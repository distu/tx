# Troubleshooting

## Fn does not start dictation

Check Input Monitoring and Accessibility permissions for the current build of tx. On macOS, the Globe/Fn key may be assigned to a system action; set **System Settings → Keyboard → Press 🌐 key to → Do Nothing**. Restart tx after permission changes.

## The meeting records other people but not my voice

Look at the live microphone state in tx. If it says the meeting microphone is not linked or its state is unknown, tx does not have enough evidence to include your microphone track. Make sure the meeting app is supported, the meeting window is visible to accessibility, and any optional browser integration is active. Test with a short synthetic call and inspect the saved microphone track. Please report the app/browser version and steps without sharing real audio.

## There is audio but no transcript

Open the session in Library and use **Transcribe now** after the recording has stopped. Confirm that a Whisper model is downloaded in Settings and that the saved track is decodable. A completed recording and a completed transcription are separate states. If the app was killed during recording, its media file might not have been finalized.

## My transcript contains speech during silence

Speech recognition can hallucinate on silence or noise. Review the audio before using the text as a record. Include a synthetic reproduction and the model name in an issue; do not upload private audio publicly.

## Two browser meetings are mixed

Core Audio capture is process based. Tabs within one browser process may share audio. Use separate browser instances with distinct profiles, or separate applications, and verify that tx selected the intended process.

## Permissions are requested after every build

Ad hoc signing may change the app identity seen by macOS privacy controls. `scripts/setup-local-cert.sh` provides a stable local development identity, but it changes keychain trust settings and should be reviewed before use. A notarized public distribution is planned.
