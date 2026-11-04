# App Cleaner Desktop distribution

This is an Electron launcher with a bundled universal SwiftUI companion, not a rewrite of the cleaning UI in JavaScript. Both are inside one app bundle. No local development tools or separate native-app installation are required on the destination Mac.

## Rebuild
From repository root:
```sh
./scripts/packaging/build-universal.sh
npm ci --prefix electron
npm test --prefix electron
node electron/package.cjs arm64
node electron/package.cjs x64
codesign --force --deep --sign - 'dist/electron/App Cleaner Desktop-darwin-arm64/App Cleaner Desktop.app'
codesign --force --deep --sign - 'dist/electron/App Cleaner Desktop-darwin-x64/App Cleaner Desktop.app'
./scripts/packaging/create-dmg.sh 'dist/electron/App Cleaner Desktop-darwin-arm64/App Cleaner Desktop.app' 'dist/App-Cleaner-Electron-0.3.0-AppleSilicon.dmg' 'App Cleaner Desktop'
./scripts/packaging/create-dmg.sh 'dist/electron/App Cleaner Desktop-darwin-x64/App Cleaner Desktop.app' 'dist/App-Cleaner-Electron-0.3.0-Intel.dmg' 'App Cleaner Desktop Intel'
```
DMG script refuses to overwrite an existing artifact; use a new versioned output name when rebuilding.

Security: local-only page, restrictive CSP, sandbox/context isolation, no renderer Node integration, denied permissions/navigation/new windows, one fixed IPC action with sender validation, native launch through execFile with literal arguments. No arbitrary path/command API. Electron and packager versions are pinned in package-lock.json.

The native code requires macOS 14+. Packages are ad-hoc signed, not Developer ID signed/notarized. Only Apple silicon execution was tested locally. Intel binary architecture and DMG/signature structure were verified; Intel hardware testing remains outstanding. Runtime auto-updates are not configured.
