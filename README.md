# Murmur

A native macOS menu bar app for recording meetings with local Whisper AI transcription. Three recording modes — file recording, push-to-talk with auto-paste, and continuous hands-free dictation. **Completely offline, no API keys required** for core features.

## Recording Modes

### 1. File Recording (Cmd+Space)
Traditional recording that saves to disk. Captures both system audio and microphone with live chunked transcription.

- Press **Cmd+Space** to start/stop
- Creates a timestamped session folder with audio + transcript
- Live transcription updates every 15 seconds while recording
- Speaker separation (mic vs system audio)
- Menu bar icon turns **green** while recording

### 2. Push-to-Talk (Double-tap Cmd)
Quick voice capture that transcribes and pastes directly into your active window.

- **Double-tap Cmd** to start recording
- **Double-tap Cmd** again to stop
- Transcription is automatically pasted into whatever app you were using
- No files saved — audio is transient, deleted after paste
- Menu bar icon turns **blue** while recording

### 3. Continuous / VAD Mode (Quadruple-tap Cmd)
Hands-free dictation with voice activity detection. Automatically detects when you speak, transcribes, and pastes.

- **Quadruple-tap Cmd** to toggle on/off
- Listens for speech, records while you talk
- When you stop speaking (configurable silence threshold), it transcribes and pastes
- Optionally auto-presses Enter after paste
- Supports a trigger word (e.g., "vortex") to submit
- No files saved — audio is transient
- Menu bar icon turns **red** while active

## Features

- **Bundled Whisper AI** — offline transcription, no API keys needed
- **2-second pre-buffer** — captures audio from before you press record
- **Editable keyboard shortcuts** — customize all hotkeys in Settings
- **Configurable modifier key** — use Cmd, Option, or Control for tap gestures
- **System + mic audio** — captures both sides of a conversation

## Installation

### From DMG (Recommended)
1. Download `Murmur-Installer.dmg` from [Releases](https://github.com/theaichimera/murmur/releases)
2. Drag **Murmur** to **Applications**
3. Right-click and select **Open** on first launch
4. Grant permissions when prompted

### From Source
```bash
git clone https://github.com/theaichimera/murmur.git
cd murmur
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/build.sh
cp -r build/Murmur.app /Applications/
```

## Permissions

| Permission | Why | Required for |
|------------|-----|-------------|
| **Microphone** | Record your voice | All modes |
| **Screen Recording** | Capture system audio via ScreenCaptureKit | File recording |
| **Accessibility** | Global hotkeys + auto-paste | All modes |

Grant in **System Settings > Privacy & Security** if not prompted.

## Settings

Access via the menu bar icon > **Settings** (Cmd+,):

- **Recordings folder** — where file recordings are saved (default: `~/Documents/Murmur/`)
- **Keyboard shortcuts** — customize file recording hotkey
- **Modifier tap key** — choose Cmd, Option, or Control for double/quadruple-tap
- **Audio devices** — select microphone and speaker
- **Continuous mode** — silence threshold, trigger word

## Requirements

- macOS 13.0+ (Ventura or later)
- Apple Silicon (M1/M2/M3/M4)

## Project Structure

```
murmur/
├── Murmur/
│   ├── Sources/
│   │   ├── MurmurApp.swift        # App entry, hotkey handling, tap detection
│   │   ├── SimpleRecorder.swift   # All recording modes, VAD, transcription
│   │   ├── Settings.swift         # Preferences, shortcut recorder, settings UI
│   │   └── Logger.swift           # File + console logging
│   ├── Package.swift
│   └── Sources/Resources/
│       └── whisper/               # Bundled whisper-cli + model
└── scripts/
    └── build.sh                   # Build + sign (requires DEVELOPER_ID env var)
```

## Building

```bash
# Build from source (requires Apple Developer ID for signing)
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/build.sh
cp -r build/Murmur.app /Applications/
```

## Troubleshooting

### App won't open
Right-click the app and select "Open", or: `xattr -cr /Applications/Murmur.app`

### No system audio
Check Screen Recording permission in System Settings > Privacy & Security.

### Double-tap not working
Check Accessibility permission. Restart Murmur after granting.

### Transcription empty
Ensure the recording is long enough (>1 second of speech). Check `~/Documents/Murmur/murmur.log` for details.

## License

MIT
