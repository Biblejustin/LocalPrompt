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
- Fullscreen keeps text at the top edge and hides the header and editor. A compact bottom bar has **Start/Pause**, ten-word navigation, slide status/setup, **Previous slide / Next slide**, **Match slide**, **Match notes**, a timer, microphone level, and **Exit full screen**. Controls have their own space below the script; narrow displays use two rows. Reconnect instructions and errors appear above the bar without leaving fullscreen. **⌃⌘F** toggles fullscreen; **Esc** exits; **⌘Return** starts/pauses.
- Change font size and margins, mirror text for teleprompter glass, hide the editor, or enter fullscreen.
- **⌘Return** starts/pauses. **⇧⌘R** rewinds. **⌘↑ / ⌘↓** move ten words. **⌘O** opens a script. **⇧⌘S** exports text.

## Obsidian note libraries

Use **Sermons**, **Bible Studies**, **Men’s Meetings**, or **Introduction to the Bible** in the header or File menu. Each picker remembers its own Obsidian folder and optional filename filter on this Mac. Existing sermon folders carry over; **⇧⌘O** still opens Sermons. Markdown notes from the chosen folder and its subfolders appear newest first. Search by filename or folder path, select a note, then click **Open sermon**, **Open Bible study**, **Open topic**, or **Open lesson**. Narrow windows use library icons with names shown on hover. No Obsidian plugin or account connection is required.

If a folder mixes different kinds of notes, set **Filename filter** to text contained in the filenames you want. This filter is remembered separately for each library and ignores case; clear it to show all Markdown notes. It filters filenames, not note contents or Obsidian tags.

The prompter hides YAML frontmatter and displays Obsidian wikilink labels. The editor and export retain the original Markdown. Embedded notes are not expanded. Existing `[[next-slide]]` cues continue to work.

**Open in browser** opens a Google Slides, Sheets, Docs, or Drive link from the current note in Brave (or the default browser if Brave is not installed). It finds links in frontmatter and the note body, including ordinary Markdown links. The button is greyed out when no supported link exists; multiple links appear in a menu. Find it below **Open / Export**, or inside **Slide cues** while fullscreen. Opening a file leaves reading and slide pairing unchanged; connect the deck through the Brave extension when ready.

**Refresh list** rescans the folder for new, renamed, or changed files. **Reload** beside “Obsidian copy” reads the selected note again after you edit it in Obsidian. Reload is manual and available only while paused; it never changes your script during a reading session. A changed note resets reading to the beginning and disconnects slide control. An unchanged reload keeps your place.

Opening or reloading a note replaces only LocalPrompt's local draft. It never writes back to your vault. The previous draft is saved locally; **File → Restore Previous Draft** swaps back, including its source association. This keeps one previous draft, not a full revision history. A missing or unreadable note leaves your current draft intact. Hidden files, packages, and symbolic links are excluded; imported notes must be UTF-8 Markdown and at most 5 MB.

## Slide cues

LocalPrompt can advance **Google Slides in Brave** or **PowerPoint for Mac**, running on the same Mac. Put `[[next-slide]]` on its own line after the last words for each slide:

```text
These are the last words for slide one.

[[next-slide]]

Now read the notes for slide two.
```

Cues stay in the editor and exported source, but disappear from the prompter and word count. Code examples and inline mentions remain ordinary text. In Voice follow, a cue fires when recognition reaches its preceding words; in Steady pace, it fires when timed reading crosses that position. Recognition can lag slightly behind your voice.

If the script has cues, **Start reading** requires a connected slideshow. For rehearsal without a deck, choose **Read without slides** explicitly. Pairing turns slide cues back on and starts a fresh cue pass from your current notes, so earlier browsing or rehearsal cannot silently disable later cues. Earlier cues are not replayed. Slide status stays visible at the bottom of the prompter, including fullscreen; the reading line remains at the top.

Connecting a deck does not create cues in your notes. If a connected deck has multiple slides but the loaded note has no cues, LocalPrompt warns and blocks reading and click-to-slide matching. Open the teleprompter copy prepared for that deck, or choose **Disconnect and read notes** for voice following without slides. Ordinary notes still work without a connected deck.

### Google Slides in Brave

1. In LocalPrompt, open **Slide cues → Google Slides in Brave → Prepare Brave extension**. Finder opens the extension folder. This also registers the bundled local helper.
2. Open `brave://extensions`. Enable **Developer mode**, click **Load unpacked**, and select that **BraveExtension** folder. This extension ships with LocalPrompt; it is not yet in the Chrome Web Store.
3. Open your script in LocalPrompt and leave reading paused. Align your notes with the slide you want to start from.
4. Open your deck in Brave, click Brave's Extensions button → **LocalPrompt Slides → Connect this deck**. The extension opens the supported slideshow view in that same tab when needed. LocalPrompt pairs automatically; no URL editing or second Connect button is needed.
5. Check the displayed slide matches your notes, return to LocalPrompt, and start reading.

Both the normal deck editor and an existing standalone slideshow can be selected. If Google shows an embedded slideshow on an editor page, the extension opens the standalone slideshow automatically. This changes the tab's playback view, not the deck; Brave's Back button returns to the previous page. Presenter view and its speaker-notes window are not connection targets.

For later reading sessions: open your script in LocalPrompt, then select your deck once through the Brave extension. Keep LocalPrompt open while pairing. Connecting verifies the current slide; it does not start reading, rewind notes, or advance a slide. If reading or microphone preparation is active, connecting from Brave pauses it and keeps your place. After pairing, use **Match slide to notes** (or click your current word) to align the deck, then press **Start reading**. An in-flight slide command still must finish before reconnecting. Loading or editing notes disconnects slide control, so finish preparing your script before pairing. Keep **Google Slides in Brave** selected as the presentation target.

Once connected, **click any word in the prompter to move both notes and slideshow to that section**. Moving ten words with the transport buttons or keyboard does the same. The first section maps to slide 1; each `[[next-slide]]` starts the next section. For notes covering only part of a deck, set **Slide cues → Notes start on slide** to the slide belonging to the opening words. This setting resets to 1 when the script changes. Pairing midway through notes does not infer a different starting slide.

A manual jump pauses reading, selects the destination slide directly, and moves the text only after Brave confirms it. If reading was running, it resumes afterward. Jumping backward rearms later cues so rereading that section advances slides again. Additional clicks are ignored while a slide command is in progress. A failed jump leaves reading paused; check the slide before reconnecting.

Fullscreen's **Previous slide / Next slide** buttons move the connected Brave deck one slide while keeping your place in the notes. Reading pauses briefly for confirmation and resumes if it was running. These buttons leave cue history intact; the next unread cue advances from the corrected slide. Use **Match slide** while paused to return the deck to the section belonging to your current notes. Navigation is disabled while disconnected, busy, or preparing the microphone, and at the first/last slide. These manual slide buttons currently support Google Slides in Brave.

**Match notes**, beside **Match slide** in fullscreen, does the reverse: it reads the current slide from Brave and moves the teleprompter to the first word of that slide’s notes, without changing the slide. This also works after you move slides directly in Brave. It uses your script’s `[[next-slide]]` cues and **Notes start on slide** setting. Reading resumes if it was running; otherwise it stays paused. Jumping back rearms later cues. If the slide has no corresponding notes, LocalPrompt keeps your place and explains the mismatch.

For Sidecar, use the iPad as an **extended display**, move LocalPrompt there, and leave Brave's slideshow on your Mac or projector. LocalPrompt stays a Mac app; no iPad app is required. Automatic cues do not activate Brave or send global keyboard shortcuts.

The extension selects the next actual slide through Google Slides' slide picker, skipping unfinished animations on the current slide. It validates the deck, tab instance, slide order, and current position before each command. Reloading/closing the tab, switching decks, or losing the bridge disconnects slide control. Select the slideshow again through the extension before reconnecting. Google's presentation UI can change; unsupported or ambiguous controls stop with an error instead of guessing.

After updating or moving LocalPrompt.app, click **Prepare Brave extension** again, reload LocalPrompt Slides at `brave://extensions`, and reopen your slideshow before reconnecting. To remove this feature, remove the extension in Brave. Its files live under `~/Library/Application Support/LocalPrompt/BraveExtension`; native-host registrations are named `com.biblejustin.localprompt.slides.json` in the Chrome and Brave `NativeMessagingHosts` folders. Brave's macOS native messaging lookup uses the Chrome registration path on current releases.

### PowerPoint for Mac

Start exactly one ordinary PowerPoint slideshow, then choose **Slide cues → PowerPoint for Mac → Connect PowerPoint**. Allow macOS Automation access when prompted. Ordinary shows and slide ranges are supported; custom/named shows are rejected. This adapter remains experimental pending live PowerPoint verification.

### Cue behavior

**Test next slide** moves the real slideshow once. Return it to the matching slide and reconnect before reading. Each cue runs once per pass. Connected Brave seeks synchronize the deck and begin a new cue pass from the destination; PowerPoint and disconnected seeks move notes only. **Rewind** rearms cues and disconnects: return the slideshow to its matching starting slide, then reconnect. Editing the script also disconnects. Pause cancels queued changes; an already-sent command may finish once, so check the slide and reconnect. Errors pause reading and commands are never retried automatically. The final slide stays visible.

Rehearse your complete deck before using automatic cues live. LocalPrompt does not import speaker notes; paste or open them as a script. Presentations on another computer and PowerPoint on Windows are not supported.

## Requirements and privacy

macOS 26 or newer and a Mac supported by Apple's SpeechTranscriber. This first build uses English (US). The microphone follows the macOS default input device; choose it in System Settings → Sound → Input before starting.

Recognition runs on this Mac. Audio is held in memory for recognition and is not saved by LocalPrompt. The app has no cloud transcription fallback, analytics, or network client. Apple may download a missing language model during setup. Once installed, the model supports offline transcription. macOS manages model storage.

Script draft, title, previous draft, library folder/source bookmarks, filename filters, and preferences are stored in local UserDefaults for `com.biblejustin.localprompt`. Folder indexing reads filenames and modification dates; note contents are read when opened or manually reloaded. Export important scripts as files. Imported documents are read only; export explicitly to write a file. Vault paths and note contents are not bundled with the app.

Slide troubleshooting events are saved locally in `~/Library/Logs/LocalPrompt/slides.jsonl` and one rotated backup, limited to 256 KiB each with owner-only permissions. Events contain timestamps, app version, fixed event names, and word/cue/slide counts. They never contain note text, speech, presentation titles, deck IDs, URLs, or raw error messages. Nothing is uploaded.

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
./scripts/test-browser-pairing.sh
./scripts/test-audio-level.sh
./scripts/test-manual-slide-sync.sh
./scripts/test-slide-diagnostics.sh
./scripts/build-app.sh
open "$HOME/Applications/LocalPrompt.app"
```

The build script makes an ad-hoc signed app and installs it in `~/Applications/LocalPrompt.app`. Temporary bundles and recovery copies live in `.build` folders marked `.noindex`, keeping build copies out of app search. Reopen the installed app after updating. It is not notarized for distribution to other Macs.

To create the downloadable Apple silicon ZIP and checksum without installing another copy:

```sh
./scripts/build-app.sh --package
```

The files are written to `dist/`. Packaging strips debug symbols, checks for private machine paths, validates the bundle and extracted signature, and verifies the archive's exact file list. It does not include user data or register another app in macOS search.

Core tests exercise partial transcript revisions, repeated phrases, omitted words, off-script speech, and manual seek. `scripts/SpeechCheck.swift` is an additional developer check for actual on-device recognition without microphone access. Compile it alongside `Sources/LocalPrompt/SpeechController.swift` and `Sources/LocalPrompt/AudioLevel.swift`, and provide a synthetic audio fixture matching its `expected` text.

## First-build scope

Voice following uses nearby phrase alignment with a bounded forward recovery search. It holds when speech cannot be confidently matched. Jumps beyond the recovery window, repeated passages, unusually pronounced names, and substantial paraphrasing may need a click to resynchronize. This is an independently implemented prototype, not PromptSmart's proprietary VoiceTrack engine. Live microphone behavior should be tried with your microphone and speaking style before using it for a recording or live event.

This version has one autosaved draft, previous-draft recovery, Obsidian note libraries, text/RTF import, and the main prompter window. PDF/DOCX import, automatic vault synchronization, remote control, camera recording, and a dedicated second-display output are not included.

## References

- [Apple: SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Apple: Speech privacy and permissions](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)
- [Apple: On-device speech model and asset installation](https://developer.apple.com/videos/play/wwdc2025/277/)
