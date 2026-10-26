# LocalPrompt

A native Mac teleprompter that follows your voice using Apple's on-device speech model. Built with SwiftUI, AppKit, SpeechAnalyzer, and SpeechTranscriber. No API key, account, subscription, or third-party package required.

## Download for Mac

[Download the latest release](https://github.com/Biblejustin/LocalPrompt/releases/latest). Choose the **LocalPrompt macOS arm64 ZIP** under Assets. Requires an **Apple silicon (M-series) Mac with macOS 26 or later**. The download does not support Intel Macs. No Xcode or build tools needed.

1. Unzip the download.
2. Drag **LocalPrompt.app** into your **Applications** folder.
3. Open LocalPrompt. Click **Start reading** and allow microphone access. Apple may download its English (US) speech model on first use.

This release is **ad-hoc signed, not Developer ID signed or notarized by Apple**. If macOS blocks it because the developer cannot be verified, and you trust this download, try opening it once, then go to **System Settings → Privacy & Security → Open Anyway**. See [Apple's first-launch instructions](https://support.apple.com/en-us/102445). A managed Mac may restrict this option.

The release includes `SHA256SUMS.txt` to verify the ZIP with `shasum -a 256 -c SHA256SUMS.txt` from the folder containing both downloads. The archive contains only the app; saved scripts, preferences, audio, and speech model assets are not bundled.

## Run

Open LocalPrompt from Applications (local builds install into `~/Applications/LocalPrompt.app`). Click **Start reading**, allow microphone access, then read the script aloud. The green word marks your next unread word. Recognition needs a short phrase to establish a confident match; it does not necessarily advance on every isolated word.

- Paste a script, or open UTF-8 TXT, Markdown, or RTF. The prompter renders Markdown headings, bold, italics, block quotes, lists, links, and code. The editor and exported file retain your original source.
- Speech follows rendered words. Hidden link URLs and generated list numbers are excluded from tracking; clicking and highlighting use the rendered text positions.
- Your current draft and reading preferences save locally between launches.
- Use **Voice follow** for speech-driven scrolling or **Steady pace** for timed scrolling.
- While either mode is running, LocalPrompt keeps the display awake, including during pauses in your speech and ad-libs. Pausing playback, finishing the script, or quitting releases the sleep protection. Your Mac's normal sleep settings stay unchanged.
- After a skipped sentence, voice following can recover within the next 320 script words when it hears a strong, distinctive phrase. Short or ambiguous phrases hold your place until there is enough evidence; clicking a word still lets you jump explicitly.
- Click a word to jump there. Use the transport buttons to rewind or move ten words.
- The active reading line stays near the top of the prompter, keeping your eyes closer to your audience.
- Fullscreen hides the header, editor, status, progress, and playback controls. Text starts at the top edge. **⌃⌘F** toggles fullscreen; **Esc** exits and restores controls. **⌘Return** starts/pauses while fullscreen; word navigation shortcuts still work. A speech error returns to the controls so its message is visible.
- Change font size and margins, mirror text for teleprompter glass, hide the editor, or enter fullscreen.
- **⌘Return** starts/pauses. **⇧⌘R** rewinds. **⌘↑ / ⌘↓** move ten words. **⌘O** opens a script. **⇧⌘S** exports text.

## Slide cues

LocalPrompt can advance **Google Slides in Brave** or **PowerPoint for Mac**, running on the same Mac. Put `[[next-slide]]` on its own line after the last words for each slide:

```text
These are the last words for slide one.

[[next-slide]]

Now read the notes for slide two.
```

Cues stay in the editor and exported source, but disappear from the prompter and word count. Code examples and inline mentions remain ordinary text. In Voice follow, a cue fires when recognition reaches its preceding words; in Steady pace, it fires when timed reading crosses that position. Recognition can lag slightly behind your voice.

### Google Slides in Brave

1. In LocalPrompt, open **Slide cues → Google Slides in Brave → Prepare Brave extension**. Finder opens the extension folder. This also registers the bundled local helper.
2. Open `brave://extensions`. Enable **Developer mode**, click **Load unpacked**, and select that **BraveExtension** folder. This extension ships with LocalPrompt; it is not yet in the Chrome Web Store.
3. Open your Google Slides deck in **Slideshow** mode. Use the presentation tab whose URL contains `/present`; the editor and presenter-notes window are deliberately rejected.
4. Click Brave's Extensions button, open **LocalPrompt Slides**, and click **Connect this slideshow**. This selects that exact tab.
5. Return to LocalPrompt, align your notes with the displayed slide, and click **Connect Google Slides**. Start reading.

For later reading sessions, open **Slide cues → Connect Google Slides** in LocalPrompt first to start the local bridge. Select your slideshow through the Brave extension, then click **Connect Google Slides** again to confirm its position. Loading or editing notes disconnects slide control, so finish preparing your script before pairing.

For Sidecar, use the iPad as an **extended display**, move LocalPrompt there, and leave Brave's slideshow on your Mac or projector. LocalPrompt stays a Mac app; no iPad app is required. Automatic cues do not activate Brave or send global keyboard shortcuts.

The extension selects the next actual slide through Google Slides' slide picker, skipping unfinished animations on the current slide. It validates the deck, tab instance, slide order, and current position before each command. Reloading/closing the tab, switching decks, or losing the bridge disconnects slide control. Select the slideshow again through the extension before reconnecting. Google's presentation UI can change; unsupported or ambiguous controls stop with an error instead of guessing.

After updating or moving LocalPrompt.app, click **Prepare Brave extension** again, reload LocalPrompt Slides at `brave://extensions`, and reopen your slideshow before reconnecting. To remove this feature, remove the extension in Brave. Its files live under `~/Library/Application Support/LocalPrompt/BraveExtension`; native-host registrations are named `com.biblejustin.localprompt.slides.json` in the Chrome and Brave `NativeMessagingHosts` folders. Brave's macOS native messaging lookup uses the Chrome registration path on current releases.

### PowerPoint for Mac

Start exactly one ordinary PowerPoint slideshow, then choose **Slide cues → PowerPoint for Mac → Connect PowerPoint**. Allow macOS Automation access when prompted. Ordinary shows and slide ranges are supported; custom/named shows are rejected. This adapter remains experimental pending live PowerPoint verification.

### Cue behavior

**Test next slide** moves the real slideshow once. Return it to the matching slide and reconnect before reading. Each cue runs once per pass. Manual seeking does not advance slides or replay crossed cues. **Rewind** rearms cues and disconnects: return the slideshow to its matching starting slide, then reconnect. Editing the script also disconnects. Pause cancels queued changes; an already-sent command may finish once, so check the slide and reconnect. Errors pause reading and commands are never retried automatically. The final slide stays visible.

Rehearse your complete deck before using automatic cues live. LocalPrompt does not import speaker notes; paste or open them as a script. Presentations on another computer and PowerPoint on Windows are not supported.

## Requirements and privacy

macOS 26 or newer and a Mac supported by Apple's SpeechTranscriber. This first build uses English (US). The microphone follows the macOS default input device; choose it in System Settings → Sound → Input before starting.

Recognition runs on this Mac. Audio is held in memory for recognition and is not saved by LocalPrompt. The app has no cloud transcription fallback, analytics, or network client. Apple may download a missing language model during setup. Once installed, the model supports offline transcription. macOS manages model storage.

Script draft, title, and preferences are stored in local UserDefaults for `com.biblejustin.localprompt`. Export important scripts as files. Imported documents are read only; export explicitly to write a file.

Optional Brave slide control uses a bundled extension with only `activeTab`, `scripting`, and `nativeMessaging` permissions. It accesses the slideshow tab you explicitly select. Slide identity and position pass through a native helper and a private Unix socket on this Mac. No local web server, cloud relay, API key, microphone access, or full browsing-history permission is required. The extension never receives your script or audio. Google Slides itself remains Google's web service.

Optional PowerPoint control uses local macOS Apple Events to read the active slideshow's identity and position and advance it. macOS manages that permission in System Settings → Privacy & Security → Automation. Neither slide adapter uploads your script or presentation.

If microphone access was denied, enable LocalPrompt in System Settings → Privacy & Security → Microphone. If voice setup fails, the app shows an error and Steady pace remains available.

## Build and verify

Requires Apple's Swift 6.2+ toolchain and macOS 26+ SDK. No external Swift packages.

```sh
git clone https://github.com/Biblejustin/LocalPrompt.git
cd LocalPrompt
swift test
node --test Tests/BrowserExtensionTests/*.test.mjs
./scripts/build-app.sh
open "$HOME/Applications/LocalPrompt.app"
```

The build script makes an ad-hoc signed app and installs it in `~/Applications/LocalPrompt.app`. Temporary bundles and recovery copies live in `.build` folders marked `.noindex`, keeping build copies out of app search. Reopen the installed app after updating. It is not notarized for distribution to other Macs.

To create the downloadable Apple silicon ZIP and checksum without installing another copy:

```sh
./scripts/build-app.sh --package
```

The files are written to `dist/`. Packaging strips debug symbols, checks for private machine paths, validates the bundle and extracted signature, and verifies the archive's exact file list. It does not include user data or register another app in macOS search.

Core tests exercise partial transcript revisions, repeated phrases, omitted words, off-script speech, and manual seek. `scripts/SpeechCheck.swift` is an additional developer check for actual on-device recognition without microphone access. Compile it alongside `Sources/LocalPrompt/SpeechController.swift` and provide a synthetic audio fixture matching its `expected` text.

## First-build scope

Voice following uses nearby phrase alignment with a bounded forward recovery search. It holds when speech cannot be confidently matched. Jumps beyond the recovery window, repeated passages, unusually pronounced names, and substantial paraphrasing may need a click to resynchronize. This is an independently implemented prototype, not PromptSmart's proprietary VoiceTrack engine. Live microphone behavior should be tried with your microphone and speaking style before using it for a recording or live event.

This version has one autosaved draft, text/RTF import, and the main prompter window. PDF/DOCX import, script libraries, remote control, camera recording, and a dedicated second-display output are not included.

## References

- [Apple: SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Apple: Speech privacy and permissions](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)
- [Apple: On-device speech model and asset installation](https://developer.apple.com/videos/play/wwdc2025/277/)
