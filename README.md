# 📡 SilentAirDrop

[![Platform](https://img.shields.io/badge/platform-macOS_13.0+-blue.svg)](https://developer.apple.com/macos/)
[![Language](https://img.shields.io/badge/language-Swift_5.9-orange.svg)](https://developer.apple.com/swift/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![X (Twitter)](https://img.shields.io/badge/X-%40gaptriko-black.svg?style=flat&logo=x&logoColor=white)](https://x.com/gaptriko)

A lightweight macOS menu bar utility that prevents the annoying Finder "Downloads" window from auto-opening and stealing focus after receiving files via AirDrop.

---

## 🛑 The Problem

Every time you receive a file via AirDrop, macOS forces Finder to open the `Downloads` folder and switches your active Space. This disrupts your workflow, especially if you are working in full-screen apps, coding, or gaming on multiple virtual desktops.

## 🚀 The Solution

**SilentAirDrop** is a background Swift daemon packaged inside a lightweight `.app` bundle.
- **Zero-latency:** Uses `FSEvents` to detect new files instantly.
- **Smart Detection:** Verifies if the file actually came from AirDrop (via `sharingd`).
- **User-Aware:** Won't block you if you open Finder manually (uses a 0.4s idle check).
- **Native UI:** Simple Menu Bar icon to manage the app (toggle blocker, auto-launch, hide icon).

---

## 📦 Installation

### Method 1: Pre-built Binary (Recommended)

1. Go to the [Releases](https://github.com/gaptriko/SilentAirDrop/releases) page and download `SilentAirDrop.dmg`.
2. Open the `.dmg` and drag **SilentAirDrop.app** into your **Applications** folder.
3. Launch the app. 

> [!IMPORTANT]
> Since this app is compiled locally and not signed with a paid Apple Developer certificate, macOS Gatekeeper might block it.
>
> **To fix this, run this command in Terminal:**
> ```bash
> xattr -d com.apple.quarantine /Applications/SilentAirDrop.app
> ```

4. Follow the prompts to grant **Accessibility** permissions (required to manage Finder focus) and allow access to the **Downloads** folder (required to detect incoming files).

### Method 2: Install via Terminal One-Liner

```bash
curl -sL https://raw.githubusercontent.com/gaptriko/SilentAirDrop/main/install.sh | bash
```

### Method 3: Build from Source

```bash
git clone https://github.com/gaptriko/SilentAirDrop.git
cd SilentAirDrop
chmod +x build.sh
./build.sh
```

---

## 🛠 How it Works Under the Hood

SilentAirDrop runs as a lightweight menu bar app (`.accessory` activation policy).
1. It registers an **FSEvent Stream** on the `~/Downloads` folder to detect changes.
2. It listens to `NSWorkspace.didActivateApplicationNotification`.
3. When Finder activates, it checks:
   - Was there a file write in the last 5 seconds?
   - Has the user been idle (no keyboard/mouse input) for at least 0.4 seconds?
4. If both conditions are met, it identifies the event as an AirDrop trigger, returns the focus to your previously active application, and closes the newly opened "Downloads" window via **Accessibility API** (`AXUIElement`).

---

## 📄 License

MIT License. Feel free to contribute!
