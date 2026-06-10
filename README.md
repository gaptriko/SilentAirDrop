# SilentAirDrop

A lightweight macOS menu bar utility that prevents the annoying Finder "Downloads" window from auto-opening and stealing focus after receiving files via AirDrop.

## The Problem
Every time you receive a file via AirDrop, macOS forces Finder to open the Downloads folder and switches your active Space. This disrupts your workflow, especially if you are working in full-screen apps or multiple desktops.

## The Solution
**SilentAirDrop** is a background Swift daemon packed inside a lightweight `.app` bundle. It features:
- 🚀 **Zero-latency:** Uses FSEvents to detect new files instantly.
- 🎯 **Smart Detection:** Uses extended file attributes (`xattr`) to verify if the file actually came from AirDrop (via `sharingd`).
- 🧠 **User-Aware:** Won't block you if you open Finder manually.
- 🍏 **Native UI:** Simple Menu Bar icon to manage the app (toggle blocker, auto-launch, hide icon).

## Installation

### Method 1: The Easy Way (GUI)
1. Go to the [Releases](../../releases) page and download `SilentAirDrop.dmg`.
2. Double-click the downloaded `.dmg` file to open it.
3. Drag the **SilentAirDrop.app** icon into the **Applications** folder.
4. Launch the app from Applications. Follow the prompts to grant **Accessibility** permissions and allow access to the **Downloads** folder.

### Method 2: The Geek Way (Terminal)
If you prefer the command line, just paste this one-liner into your Terminal. It will automatically download the latest `.dmg`, install it to `/Applications`, and launch it:
```bash
curl -sL https://raw.githubusercontent.com/gaptriko/SilentAirDrop/main/install.sh | bash
```

## Build from Source
If you prefer to build the application from source yourself:
```bash
git clone https://github.com/gaptriko/SilentAirDrop.git
cd SilentAirDrop
chmod +x build.sh
./build.sh
```
This will compile the Swift code and generate a fresh `SilentAirDrop.dmg` ready to use.

## Requirements
- macOS 13.0 or newer (Ventura).

## License
MIT
