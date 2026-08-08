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
- **Fast detection:** Uses file-level `FSEvents` with a short debounce to collect multi-file transfers.
- **Path-aware detection:** Uses file-level events for new items directly inside Downloads.
- **Per-file rules:** Keep Finder closed—or let it open—for broad file types and exact extensions.
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

## ⚙️ Settings and File Rules

Open the menu bar icon and choose **Settings…** to configure:

- Whether SilentAirDrop is enabled.
- Launch at login. This option is available when SilentAirDrop is opened from `/Applications` or `~/Applications`; Settings explains what to do when it is unavailable.
- Menu bar icon visibility. Hiding it lasts until SilentAirDrop is launched again.
- A link to the [SilentAirDrop GitHub repository](https://github.com/gaptriko/SilentAirDrop).

If macOS requires approval for Launch at Login, Settings shows a shortcut to the Login Items system panel.

The File Rules section includes:

- A default behavior for unmatched files.
- Overrides for images, video, audio, PDFs, archives, documents, apps and disk images, folders, or other files.
- Exact extension overrides such as `dmg`, `jpg`, or `tar.gz`.
- Import and export of File Rules using a versioned JSON file.

Exact extensions are case-insensitive and take priority over file-type rules. If a transfer contains multiple items, Finder opens when any item is configured to **Let Finder open**. Rules apply immediately and persist across launches.

Export includes the File Rules currently shown in Settings, including unsaved edits. Import replaces the rules shown for review but does not apply them until you click **Save**. General settings such as Launch at Login are never included.

For example, you can keep Finder closed for everything except `.dmg` files, or let Finder open for archives while keeping image transfers silent. SilentAirDrop never moves, renames, or deletes received files.

> [!NOTE]
> macOS file-system events do not identify the app that created a file. SilentAirDrop applies these rules to new top-level items detected in Downloads during its short Finder-activation window.

---

## 🛠 How it Works Under the Hood

SilentAirDrop runs as a lightweight menu bar app (`.accessory` activation policy).
1. It registers a file-level **FSEvent Stream** on the `~/Downloads` folder and records newly created or renamed top-level items.
2. It classifies each item using its exact extension and macOS `UTType` metadata.
3. It listens to `NSWorkspace.didActivateApplicationNotification`.
4. When Finder activates, it checks:
   - Was there a file write in the last 5 seconds?
   - Has the user been idle (no keyboard/mouse input) for at least 0.4 seconds?
5. It resolves exact-extension rules first, then file-type rules, then the default behavior. If every recent item should stay silent, it restores the previous app and closes the newly opened Downloads window through the **Accessibility API** (`AXUIElement`).

---

## 📄 License

MIT License. Feel free to contribute!
