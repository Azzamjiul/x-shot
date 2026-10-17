# X-Shot

X-Shot is a native, offline screenshot and annotation app for Apple Silicon Macs. Capture a full screen, a window, or a selected area from the menu bar. Each capture opens the overlay editor immediately and is copied to the clipboard. Annotate in place, drag the toolbar out of the way, then choose Copy or Save. Copy and Save show a green confirmation and keep the editor open so you can continue editing. With the Text tool active, click for a text box or drag an empty area to set its size. Text wraps to the box width; Enter adds a line and Command-Enter finishes typing. Drag existing text to reposition it or double-click to edit it. Select text and drag its left or right handle to change the box width and wrapping. Use the pt menu with the Text tool to change the font size of selected text or the text you are typing. Choose a color from the palette to recolor selected text or the text you are typing. Press Delete or Forward Delete to remove selected text when you are not typing. Undo/Redo restores deleted text as well as text moves, resizes, font sizes, colors, and edits. `Shift-Command-9` starts Capture Area by default; change it with **Set Capture Shortcut…** in the menu bar.

Closing the editor saves the PNG automatically if it has not already been saved. Automatic saves use the folder last chosen with Save, or the Desktop until you choose one.

With the Rectangle, Arrow, or Line tool active, click the border or stroke of an existing matching shape to select it. Drag the shape to move it, drag its handles to resize it (corners for rectangles, endpoints for lines and arrows), or press Delete. Use the toolbar palette and px menu to change the selected shape's color and line thickness. Undo/Redo restores these changes. Start on an empty area to draw another shape.

For area and full-screen captures, the editor keeps the entire frozen display. Use Crop to move or resize the screenshot region at any time, including after adding annotations. Copy and Save export only the current crop; annotations stay anchored to the frozen screen. Crop moves and resizes share Undo/Redo history with annotations, with one history entry per drag.

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
