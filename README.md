# FullScreenWeb

iOS app that opens web pages in fullscreen on an external monitor or TV. Pick sites from shortcuts on your iPhone, control browsing with a captured mouse pointer, and tweak scale/offset so the page fits the display (including overscan). Optional address bar and basic ad blocking are included.

## Features

- Fullscreen web view on an external display (HDMI / USB-C / AirPlay)
- Link shortcuts on the phone for quick navigation
- Mouse pointer capture to control the external display
- Scale and offset controls for TV overscan
- Optional address bar and ad blocking
- Ukrainian and English UI

## Requirements

- Mac with **Xcode 16** (or newer) that can build for **iOS 18.5+**
- Apple ID (free Apple Developer account is enough for your own device)
- Physical **iPhone or iPad** on iOS 18.5 or later  
  External display is the main use case — the Simulator can run the app UI, but not a real second screen / mouse capture workflow.

## Run on your iOS device

### 1. Open the project

```bash
open FullScreenWeb.xcodeproj
```

Or double-click `FullScreenWeb.xcodeproj` in Finder.

### 2. Sign in to Xcode

1. Open **Xcode → Settings… → Accounts**
2. Click **+** and add your Apple ID
3. Select the account → **Manage Certificates…** → add an **Apple Development** certificate if you don’t have one

### 3. Set your signing team

Team ID is **not** stored in the Xcode project. Copy the local config and put your Apple Team ID there:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Edit `Config/Local.xcconfig` and replace `YOUR_TEAM_ID` with your Team ID (Xcode → Settings → Accounts → your team, or [developer.apple.com/account](https://developer.apple.com/account)).

Then in Xcode:

1. Select the **FullScreenWeb** target → **Signing & Capabilities**
2. Enable **Automatically manage signing**
3. Confirm your Team appears (from `Local.xcconfig`)
4. If Xcode complains about the bundle ID (`YarDev.FullScreenWeb`), change **Bundle Identifier** to something unique, e.g. `com.yourname.FullScreenWeb`

`Config/Local.xcconfig` is gitignored — do not commit it.

### 4. Connect the device

1. Plug the iPhone/iPad into the Mac with a cable (or use wireless debugging after the first trust)
2. Unlock the device and tap **Trust** if prompted
3. In Xcode’s toolbar, pick your device from the run destination menu (not a Simulator)

### 5. Build and run

1. Press **⌘R** (or the Play button)
2. On the device, if you see **Untrusted Developer**:
   - Go to **Settings → General → VPN & Device Management**
   - Trust your developer certificate
   - Open the app again from the Home Screen or re-run from Xcode

The app should install and launch on the device.

### 6. Use with an external display

1. Connect a monitor/TV (cable adapter or AirPlay / Screen Mirroring)
2. On the phone, the status should show the monitor as connected
3. Open a shortcut — the page appears fullscreen on the external display
4. Move a finger / mouse on the phone — pointer capture starts automatically when an external display is connected

## Project structure

| Path | Role |
|------|------|
| `FullScreenWeb/` | App source (SwiftUI phone UI + UIKit external display / WebKit) |
| `FullScreenWeb.xcodeproj` | Xcode project |
| `Config/Shared.xcconfig` | Shared build settings (optionally includes `Local.xcconfig`) |
| `Config/Local.xcconfig.example` | Template for your Team ID — copy to `Local.xcconfig` |
| `FullScreenWebTests/` | Unit tests |
| `FullScreenWebUITests/` | UI tests |

No Swift Package Manager dependencies — open the `.xcodeproj` and build.

## Troubleshooting

| Issue | What to try |
|-------|-------------|
| Signing / provisioning errors | Create `Config/Local.xcconfig` from the example; set a valid `DEVELOPMENT_TEAM`; change Bundle ID if needed |
| “Untrusted Developer” | Trust the certificate under **Settings → VPN & Device Management** |
| Device not listed | Unlock phone, trust the computer, use a data cable; enable Developer Mode on iOS 16+ if asked |
| Deployment target too high | Update the device to iOS 18.5+, or lower **iOS Deployment Target** in the target’s **General** tab (may need code changes) |
| No second screen | Confirm the display is connected and iOS shows it as an external display; AirPlay mirroring vs extended display can behave differently |

## License

Licensed under the [GNU General Public License v3.0](LICENSE).
