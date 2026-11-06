# FCP Plugin Manager

**English** | [中文](README.md)

A small native macOS utility for managing Final Cut Pro plug-ins: list them, disable and re-enable them, back them up, delete them, and rename them. Everything runs locally — no network, no telemetry, no uploads.

> **This is not a free-for-commercial-use open source project.**
> The source is publicly visible under the [PolyForm Noncommercial 1.0.0](LICENSE): personal study, research, noncommercial use and modification are allowed; **commercial use is not**.
> The version sold on the App Store is published commercially by the copyright holder (Huang Zongjing). For commercial licensing, contact the copyright holder first.

---

## What it does

Final Cut Pro plug-ins are scattered across half a dozen directories, mixing system-wide and per-user installs. Turning a few off for a while, or clearing out the ones you never use, means a lot of manual folder digging. This tool puts all of those directories into one list:

- **Scan** — system-wide and per-user Effect / Generator / Transition / Title folders, plus `/Library/Plug-ins/FxPlug` and `~/Library/Plug-ins/FxPlug`, all in one pass
- **Disable unused plug-ins per project** — drop in a `.fcpxml` file or a whole `.fcpbundle` library, see which effects each project actually uses, and disable only the rest. Libraries are parsed from a read-only copy; the original is never touched
- **Disable / enable** — user-level plug-ins are moved out of their folder so FCP stops seeing them immediately, and can be put back on their original path at any time
- **Backup and restore** — an automatic backup is taken before deletion, and can be restored from the Backups tab; restoring never overwrites a plug-in that is already there
- **Delete** — the dangerous one. Always last, always double-confirmed, always backed up first
- **Rename** — changes the real folder name, so the name in the FCP menu changes too; every rename is recorded in a ledger so you can restore the original name later
- **Import a name map** — CSV or JSON with two columns, original identifier → new name. You get a preview (old name / new name / reason it would fail) before anything is written
- **Batch operations** — disable, enable, restore or restore-original-name for everything or by category, with a progress bar and a Stop button
- **Operation log and undo** — every step is recorded; deletions and disables can be undone
- **Bilingual UI** — Chinese by default, switchable to English in Settings
- **Origin detection** — Apple built-in / third-party / unknown, decided from the bundle identifier and code signature instead of guessing from the install location
- **`fcpplugin` command-line tool** — the same binary with `--cli`, built for scripts and AI agents: query, batch rename, disable, enable, restore in one line

## Disabling unused plug-ins per project

A large plug-in collection slows down FCP startup and makes the menus very long. This feature answers one question: **which plug-ins does the project I'm working on actually use?**

1. Click **Scan Project** and drop in a `.fcpxml` file or a whole `.fcpbundle` library
2. The panel lists events and projects. Choose the whole library, or tick a single project
3. The counts update live — *N used / M unused* — then click **Disable the M unused plug-ins…**
4. Each disable operation is recorded as a batch, and a batch can be restored at any time, returning you to the exact state you had before

About reading `.fcpbundle` directly:

- The library's index files (`CurrentVersion.flexolibrary`, the `CurrentVersion.fcpevent` of every event and project, `CurrentVersion.plist`, `Settings.plist`, `Effects.map`) are copied into a temporary directory with `ditto`. `Render Files` and media are skipped. Parsing happens on the copy; the original library is never written to, locked, or given a new modification date
- SQLite is opened read-only, and effect references are read from the archived object graph. FCP's built-in effects (colour correction, colour conform and friends) are not counted as plug-ins
- If the library is currently open in FCP, the tool says so and stays read-only. Temporary copies are deleted when the scan finishes
- If the format is not understood — too new a version, missing fields, corrupted files — the tool says exactly that ("this tool cannot read this library's format yet") and offers **Choose XML file…** as a fallback. **It never invents a list**

If a particular library cannot be read, export a `.fcpxml` from FCP with *File → Export XML* and drop that in instead; the result is the same.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later (or matching Command Line Tools) to build
- Swift 5.9+, no third-party dependencies

## Installation

### Use the prebuilt app

Download `FCP-Plugin-Manager-<version>.zip` from [Releases](../../releases), unzip it, and drag `FCP 插件管理.app` into Applications. If macOS blocks the first launch, right-click the app and choose **Open**.

> The zip is not notarized by Apple. If macOS says the developer cannot be verified, open **System Settings → Privacy & Security** and click **Open Anyway**, or right-click the app and choose **Open**.
>
> The app's own interface is localized; the bundle keeps its Chinese display name.

### Build it yourself

```bash
git clone https://github.com/huangzongjingziliu-png/fcp-plugin-manager.git
cd fcp-plugin-manager
swift build
swift run FCPXPluginManager
```

To build a double-clickable app (it is also installed into `~/Applications` and zipped into `dist/`):

```bash
./Scripts/build_app.sh
```

> When building on an exFAT external drive, add `--scratch-path /tmp/fcp-build`; otherwise code signing can fail because of `._*` metadata files.

Run the tests (they only use temporary directories and never touch real plug-ins):

```bash
swift test --scratch-path /tmp/fcp-test-build
```

## Using the app

1. It scans automatically on launch. The sidebar groups plug-ins as All / Effects / Generators / Transitions / Titles, with a total at the bottom
2. Select plug-ins and use the context menu or the buttons at the bottom; Disable and Enable are the ones you will use most
3. The Disabled tab shows the real state of every record:
   - **Disabled (in effect)** — the plug-in really is gone from its original location
   - **Waiting for admin command (not in effect)** — a system-level plug-in has not been authorized yet, and FCP still loads it
   - **Record incomplete** — a record left by an older version; its original location is unknown
4. The Backups tab restores single items or batches. Conflicts are checked up front, and plug-ins that are still in place are never overwritten
5. The **⋯** menu at the top has: import a name map, restore original names, switch language

Plug-in origin is decided from the bundle identifier and code signature: `com.apple.*` or an Apple signature means **Apple built-in**; everything else is **third-party**; if neither can be read, the item is marked **unknown** rather than guessed. Batch disable skips Apple built-ins by default and includes third-party plug-ins whether they are installed for all users or just you; plug-ins in the all-users location are handled with a single administrator authorization.

## Command-line tool

`fcpplugin` is the same binary as the GUI, with `--cli` switching it into command-line mode. To install:

```bash
./Scripts/build_app.sh     # build the app first
./Scripts/install_cli.sh   # installs to ~/bin/fcpplugin by default
```

If `~/bin` is not on your PATH, add `export PATH="$HOME/bin:$PATH"` to `~/.zshrc`.

Common examples (everything that changes files is a dry run unless you add `--yes`):

```bash
# List every plug-in as JSON, easy for other programs to parse
fcpplugin list --json

# Only one category
fcpplugin list --category effects

# Only disabled items
fcpplugin list --disabled --json

# Disable by name (prints what it will do first)
fcpplugin disable --path "3D Camera Rig" --yes

# Disable a whole category
fcpplugin disable --category transitions --yes

# Turn everything back on
fcpplugin enable --all --yes

# Restore a specific backup
fcpplugin restore --backup "3D Camera Rig_20261106-101500-123" --yes

# Rename one plug-in
fcpplugin rename --path "3D Camera Rig" --name "3D Camera Rig EN" --yes

# Rename in bulk from a mapping file (preview first, then add --yes)
fcpplugin rename --map names.json
fcpplugin rename --map names.json --yes

# Inspect the rename ledger / operation log
fcpplugin ledger --json
fcpplugin log --json

# Restore original names from the ledger
fcpplugin restore-name --category effects --yes
fcpplugin restore-name --all --yes
```

Safety rules:

- Every command that changes files **defaults to a dry run**; `--yes` is required to execute
- For system-level plug-ins the CLI only prints copy-pasteable `sudo mv` commands; it never escalates privileges itself
- There is no bulk delete in the CLI
- Restoring skips plug-ins that already exist at the destination instead of overwriting them

### Batch renaming with an AI agent

The CLI does not translate anything — that is the agent's job:

1. `fcpplugin list --json > plugins.json`
2. Have the agent produce a mapping from that list: `{"original path": "English name"}`
3. `fcpplugin rename --map map.json` to preview, then add `--yes` once it looks right

Names are validated before anything runs: empty names, illegal characters such as `/`, duplicates in the same folder and missing paths are all flagged in the preview, so a batch never fails halfway through.

## How data safety is enforced

This tool moves real plug-in files, so a few rules are hard-coded:

- **Back up before deleting** — if the backup fails, the operation is aborted; there is no path where something is deleted without a backup
- **Never overwrite** — if restoring or renaming would collide with an existing plug-in, the operation is refused and explained so you can decide
- **Delete goes to the Trash** — via `NSWorkspace.recycle`, so *Put Back* works
- **System-level plug-ins are never changed silently** — they need an administrator password; if you cancel, you get a command to run and a "pending" marker, never a fake success
- **No guessing** — if the rename ledger is damaged or a record is missing metadata, the tool says the original name or location is unknown instead of making one up
- **Renames are recorded in a ledger** — original name, new name, folder, time and status are stored in the app's own directory, independently of backups

## Where data lives

```
~/Library/Application Support/FCPPluginManager/
  Backups/     pre-deletion backups (one directory per plug-in, with .metadata)
  Disabled/    disabled plug-ins and their records
  Renames/     rename ledger, ledger.json
  Operations/  operation log, log.json
```

Uninstalling the app does not remove this data. When you are sure you no longer need it, delete the whole `FCPPluginManager` directory.

## Project layout

```
Package.swift                          SwiftPM manifest
FCPXPluginManager/
  FCPXPluginManager.swift              entry point; --cli switches to CLI mode
  PluginCategory.swift                 categories, origins, sidebar enums (pure data)
  PluginViewModel.swift                scanning, backup, restore, disable, logs
  ContentView.swift                    all UI and interaction
  ProjectScan.swift                    project scanning, matching, per-batch disabling
  FCPBundleReader.swift                read-only .fcpbundle parser (SQLite + NSKeyedArchiver)
  ProjectBatches.swift                 disable batches and precise restore
  HoverEffects.swift                   hover animations
  RenameMap.swift                      name-map parsing, rename preview, execution
  RenameLedger.swift                   rename ledger and original-name restore
  Localization.swift                   Chinese/English strings
  CLIRunner.swift                      command-line implementation
Tests/FCPXPluginManagerTests/          unit tests (temporary directories only)
Scripts/
  build_app.sh                         build, install, package the zip
  install_cli.sh                       install fcpplugin
  make_icon.swift                      generate the icon with AppKit
```

Detailed architecture notes are in [DEVELOPMENT.md](DEVELOPMENT.md) (Chinese).

## Privacy

Fully offline: no network calls, no analytics, no uploads. See [PRIVACY.md](PRIVACY.md).

## License

Source-available, but **not** an OSI-approved open source licence. Noncommercial use is allowed; commercial use is not. Full terms in [LICENSE](LICENSE).

If you make something with this tool, I would like to hear about it. Bugs and feature requests: open an issue.

## Disclaimer

This is a third-party tool and is not affiliated with Apple Inc. It moves, backs up and deletes plug-in files — make sure you know what you are doing, and keep your own copy of any plug-in that matters.
