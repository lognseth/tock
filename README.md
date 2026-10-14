# Tock

A keyboard-driven to-do list for a plain markdown file of `- [ ]` checkboxes. Lives in your menu bar:
press a global shortcut, work through your tasks without touching the mouse, press Esc.
Prefer a real window? Open it from the menu bar, or make the shortcut open it (Settings → Window).

- Works with any `.md` files, one or several. Everything else in them is left untouched.
- Obsidian integration is optional (Settings → Obsidian).
- macOS 14+, universal binary, no dependencies.

## Install

```sh
./build.sh install      # builds, copies to /Applications (or ~/Applications without admin rights) and launches
./build.sh dmg          # or build/Tock-<version>.dmg
```

First launch asks for the markdown file. Add the app to Login Items from Settings if you like.

## Popup and window

- **Popup** (default): a quick overlay for capture and triage. Closes when you click away or press Esc.
- **Window**: resizable, remembers its position, with a sidebar of views, lists (your headings) and tags.
  The same keys work, and so does the mouse (click to select, double-click to edit, click the circle to complete).
- Settings → Window chooses which one the open shortcut shows, and whether Tock also appears in the Dock and ⌘Tab.
  Quick add always uses the popup, unless the window is already open.

## Keys

| | |
|---|---|
| `⌃⌥Space` | open the list (configurable) |
| `⌃⌥N` | quick add, closes when done. `⇧↩` adds another |
| `j` `k` `↑` `↓` | move. `g` `G` jump to top / bottom |
| `x` `space` | toggle done |
| `n` / `N` | new task below the selection / at the end |
| `e` `↩` | edit |
| `dd` | delete (with sub-tasks) |
| `t` | set due date |
| `s` | snooze: push the due date (`tomorrow`, `mon`, `+3d`, `24.12`) |
| `m` | move to another heading, in this or another file |
| `p` | cycle priority |
| `J` `K` | move task (with sub-tasks) down / up |
| `⇥` `⇧⇥` | indent / outdent |
| `/` | filter by text or `#tag` |
| `1` `2` `3` | All / Today / Upcoming |
| `u` `⌃R` | undo / redo |
| `H` | show or hide completed |
| `o` | open the file (default editor, or Obsidian if enabled) |
| `?` | all keys |

When adding or editing a task, type metadata inline:

```
Pay rent @fri !high ~monthly #home
```

`@tomorrow` `@mon` `@+3d` `@24.12` `@2026-10-20` set a due date, `!high|med|low` the priority,
`~daily|weekly|2w|weekday` a repeat, `#tag` a tag.

## Several files

Add more files in Settings → To-do files. All, Today and Upcoming merge them, and in the window the
sidebar groups the headings by file. The tray icon marks the **inbox** file that receives new tasks;
when you're looking at one file or heading, new tasks go there instead. `m` can move a task between files.

## Reminders

Settings → Reminders sends one notification a day, at the time you choose, listing what's overdue or due
today. Tock has to be running (turn on Launch at login). Tasks only carry dates, so there are no per-task times.

## File format

Standard markdown checkboxes. Metadata uses the common emoji convention
(the same one the Obsidian Tasks plugin uses), so it stays readable and portable:

```markdown
## Work
- [ ] Review PR #work 📅 2026-10-20 ⏫
  - [ ] Check migrations
- [ ] Water plants 📅 2026-10-14 🔁 every week
- [x] Renew passport
```

- `📅` due, `⏳` scheduled, `⏫ 🔼 🔽` priority, `🔁` repeat. Completing a repeating task adds the next one below it.
- Optionally stamps `✅ yyyy-MM-dd` on completion (Settings).
- Checkboxes inside code fences and YAML frontmatter are ignored.
- Edits made outside Tock are picked up within a couple of seconds, and Tock re-reads the file before every write.

## Obsidian (optional)

With it on: `o` opens the note in Obsidian, `[[wikilinks]]` show as clickable links, `l` jumps to the
first linked note. The vault is detected from a `.obsidian` folder above the file.

## Development

```sh
./build.sh test                      # 100+ self-checks (no XCTest needed)
.build/debug/Tock --snapshot out.png [today|upcoming|help|edit|welcome|dark]   # render the panel to a PNG
swift Scripts/make-icon.swift        # regenerate Resources/AppIcon.icns
```

## Releases

Releases are built by GitHub Actions. Pushing a tag builds a signed, notarized DMG and attaches it to a GitHub Release:

```sh
echo 1.2.0 > VERSION && git commit -am "chore: release 1.2.0"
git tag v1.2.0 && git push origin main v1.2.0     # v1.2.0-rc1 publishes a pre-release
```

The workflow needs these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12` | `base64 -i DeveloperID.p12`: the exported *Developer ID Application* certificate |
| `MACOS_CERTIFICATE_PASSWORD` | password chosen when exporting the `.p12` |
| `NOTARY_KEY_P8` | full text of the App Store Connect API key (`AuthKey_XXXX.p8`) |
| `NOTARY_KEY_ID` | its Key ID |
| `NOTARY_ISSUER_ID` | the Issuer ID from App Store Connect → Users and Access → Integrations |

`.github/workflows/ci.yml` runs the self-tests and an unsigned build on every push to `main` and on pull requests.

To build a notarized DMG locally, store credentials once
(`xcrun notarytool store-credentials tock --key AuthKey_XXXX.p8 --key-id … --issuer …`), then:

```sh
SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=tock ./build.sh dmg
```

Without `SIGN_ID` the app is ad-hoc signed and other Macs need right-click → Open the first time.
