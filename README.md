# X-Shot

X-Shot is a native, offline screenshot and annotation app for Apple Silicon Macs. Capture a full screen, a window, or a selected area from the menu bar, annotate it, then copy or save the PNG. `Shift-Command-9` starts Capture Area directly.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Screen Recording permission

## Install the unsigned release

X-Shot is currently distributed without an Apple Developer ID signature or Apple notarization. Continue only if you downloaded it from this project's official GitHub Releases page. macOS will ask you to approve the app manually the first time you open it.

1. Download the `X-Shot-*-arm64.dmg` file and its `.sha256` file from the GitHub release.
2. Optionally verify the download from Terminal in the download directory:

   ```sh
   shasum -a 256 -c X-Shot-*-arm64.dmg.sha256
   ```

3. Open the DMG and drag **X-Shot** to **Applications**.
4. Try to open X-Shot once. macOS may block it because the developer cannot be verified.
5. Within about one hour of that blocked launch, open **System Settings > Privacy & Security**, scroll to **Security**, then click **Open Anyway** for X-Shot and confirm.
6. Allow **Screen Recording** when requested, then quit and reopen X-Shot.

Do not disable Gatekeeper globally. The SHA-256 checksum detects a mismatched or corrupted download, but it does not replace publisher authentication. If you do not trust the prebuilt app, build it from source.

If macOS says X-Shot **will damage your computer** or the app is **damaged**, do not override that warning. Delete it, download it again from the official release, verify the checksum, and report the issue. Organization-managed Macs may disable **Open Anyway**; those installations require approval from IT.

## Build from source

Open `X-Shot.xcodeproj` in Xcode, select **My Mac**, then run the `X-Shot` scheme.

## Create an unsigned release

Run:

```sh
./scripts/build-unsigned-release.sh
```

The script runs the unit tests, produces an ad-hoc-signed arm64 Release build with Hardened Runtime enabled, verifies it, and creates these files in `dist/`:

- `X-Shot-<version>-arm64.dmg`
- `X-Shot-<version>-arm64.dmg.sha256`

The app works completely offline and does not upload screenshots, collect telemetry, or keep screenshot history.
