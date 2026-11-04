# Mac Cleaner Local

A native macOS utility for freeing memory, finding what fills your disk, and uninstalling apps with their leftovers. SwiftUI and Foundation only, no third-party dependencies, nothing leaves your Mac.

macOS 14 or later · Apple Silicon and Intel · MIT licensed

## Features

**Memory**
- Menu-bar panel with memory usage, the heaviest apps (helper processes inside each app bundle are counted), and Quit with confirmation.
- **Free up memory** runs macOS `/usr/sbin/purge`, which flushes file cache back to free RAM. It never quits apps.
- **Automatically free up** at a 60–95% threshold: sustained for 30 seconds, at most once every 15 minutes.
- `purge` needs root. Without setup each run asks for your administrator password. Turning on auto mode asks once to install `/etc/sudoers.d/app-cleaner-purge`, a rule allowing only `/usr/sbin/purge`. It is validated with `visudo -cf` before install; **Require password** removes it.

**Space Map**
- Scans your home folder, the whole data volume, or any folder with `getattrlistbulk(2)`.
- A sunburst grows live while scanning: rings are folder depth, angle is allocated size. Hover for name and size, click to drill in, click the center to go up.
- Sorted list with size and share; right-click for Reveal in Finder, Open, Copy Path, or Move to Trash.
- Stays on one volume and never follows symlinks. Items under 1 MB are merged into "smaller items". Hard links may be counted more than once.

**Disk Cleanup**
- Scans `~/Library/Caches`, `~/Library/Logs`, and large files in Downloads or a folder you choose.
- Every item is rated **Safe**, **Likely safe**, or **Review** with a reason, using fixed rules in [`DiskSafety.swift`](Sources/CleanerCore/DiskSafety.swift):
  - Caches are safe (apps recreate them); known tool download caches are likely safe (they re-download).
  - Logs are safe; logs from the last day are likely safe.
  - Installers are likely safe only when a matching app is installed in Applications.
  - Other files in Downloads need review; Spotlight's last-opened date is shown to help.
- Items owned by running apps are skipped. Each item is checked again before it moves, and one failing item never blocks the rest.

**Applications**
- Inventory of `/Applications` and `~/Applications`, grouped by vendor, sorted by name or size.
- Uninstall reviews the app and its related files (exact bundle-ID matches in your Library) before moving them to Trash.
- Remaining Files finds data left behind by apps that are no longer installed.
- Update checks for Sparkle, App Store, and Electron update feeds.

Everything is moved to Trash, never permanently deleted. Moving to Trash frees space only after you empty it.

## Install

Download the DMG from [Releases](../../releases), open it, and drag the app to Applications.

The build is ad-hoc signed, not notarized, so macOS blocks the first launch. Either:
- open it once, then use **System Settings → Privacy & Security → Open Anyway**, or
- remove the download flag: `xattr -dr com.apple.quarantine "/Applications/App Cleaner Local.app"`

Space Map and Disk Cleanup measure more with **Full Disk Access** (System Settings → Privacy & Security).

## Build

```sh
swift test
./scripts/build-app.sh                      # dist/App Cleaner Local.app
./scripts/packaging/build-universal.sh      # universal app in dist/universal
./scripts/packaging/create-dmg.sh "dist/universal/App Cleaner Local.app" dist/App-Cleaner.dmg "App Cleaner"
```

Open `Package.swift` in Xcode to develop. `electron/` contains an optional Electron launcher that wraps the native app.

## License

[MIT](LICENSE)
