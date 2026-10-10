# Contributing to tx

Thanks for helping make meeting capture and dictation more reliable and understandable.

## Good first contributions

- Reproduce a browser or meeting client detection issue with **synthetic** details.
- Improve accessibility or the English and Brazilian Portuguese translations.
- Improve a focused unit test for process isolation, mute state, or transcription output.
- Improve documentation for a supported macOS version or device.

Open an issue before large architectural changes so we can agree on the expected behavior. Small fixes can go directly to a pull request.

## Local setup

You need macOS 26.1 or newer, Apple Silicon, and Swift 6. Clone the repository, then run:

```bash
swift build
swift test
./scripts/build-app.sh debug
```

Use a separate test profile for manual UI work. Do not run experiments against personal recordings or a production database. See [Architecture](docs/ARCHITECTURE.md) and [Troubleshooting](docs/TROUBLESHOOTING.md).

## Interface translations

The app offers **System default**, **English**, and **Português (Brasil)** in Settings → General. The system choice resolves to Brazilian Portuguese when the Mac's primary language is `pt-BR`, and English otherwise. Source keys in SwiftUI are mostly Portuguese for compatibility with the original interface. Add English entries to `Sources/TxApp/App/Localization/en.lproj/Localizable.strings`; add Portuguese entries for new English source keys to the matching `pt-BR.lproj` file. Runtime strings use `InterfaceStrings`.

The app bundle is assembled by `scripts/build-app.sh`, which copies both `.lproj` directories into `Contents/Resources`. When changing translations, check both languages in the isolated demo profile and keep screenshots free of real meeting data.

## Pull requests

1. Explain the user visible problem and the change.
2. Describe exactly what you tested, including the browser/app and macOS version for capture work.
3. State any remaining limitations. A passing unit test does not prove real meeting capture.
4. Keep commits focused and include only source, documentation, or synthetic fixtures.
5. Check the diff for tokens, local paths, real meeting names, transcripts, audio, database files, and screenshots before pushing.

`swift test` is the baseline check. For audio changes, also test stopping through tx and verify that saved tracks are decodable and contain the expected audio. A process kill does not establish recording integrity.

## Privacy in issues and pull requests

Never attach real calls, participant names, transcript excerpts, account identifiers, API keys, or private application logs. Replace them with synthetic examples. For a vulnerability, follow [SECURITY.md](SECURITY.md) instead of filing a public issue.

## Code of conduct

Be constructive, respect privacy and consent, and help reviewers reproduce claims. Harassment and disclosure of other people's private meeting data are not acceptable.
