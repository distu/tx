# tx Meet Bridge (optional Chromium extension)

This extension reads supported Google Meet and Microsoft Teams web page metadata and sends it to the running tx app on your Mac. It can help associate a meeting title and participants with a capture, and provide a browser mute signal. Basic process audio capture works without the extension.

## Install for development

1. Open `chrome://extensions` in Chrome or the corresponding extensions page in a Chromium based browser.
2. Enable **Developer mode**.
3. Select **Load unpacked** and choose this `Extensions/tx-meet/` directory.
4. Run tx and join a supported meeting. Keep the meeting page open while you record.

The bridge listens only at `http://127.0.0.1:49200/`. The extension has permissions for supported Meet/Teams domains and this local endpoint. Review [`manifest.json`](manifest.json) before enabling it.

## Data sent to tx

The extension can send the meeting URL or ID, page title, participant names, and mute state exposed by the page. That information stays on your Mac unless you explicitly select an optional cloud feature in tx. Browser page structures change, so these signals are best effort. The tx HUD shows when microphone state is unverified.

Do not put real meeting IDs, participant names, or screenshots of private calls in public bug reports. Use synthetic examples.
