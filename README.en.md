<div align="center">
  <img src="assets/route-shield.png" width="120" height="120" alt="Route Shield icon">
  <h1>Route Shield</h1>
  <p>Check your public IP before opening apps on macOS.</p>
  <p><a href="README.md">Русский</a> · <strong>English</strong></p>
  <p><a href="https://github.com/01trisha/route-shield/releases">Download</a> · <a href="#from-source">Install from source</a> · <a href="LICENSE">MIT License</a></p>
</div>

Route Shield lives in the menu bar. Choose the apps you want to check, then launch them from the Route Shield menu or a Dock shortcut. The menu and the prelaunch window show your public IPv4 and IPv6 addresses and the country associated with them.

- **App list.** Drag apps from Finder and Route Shield reads their bundle IDs.
- **Dock shortcuts.** Each shortcut uses the original app's icon and opens the IP check window.
- **IP monitoring.** Enable notifications and force-quitting selected apps when your IP changes. The two settings work independently.
- **Russian and English.** Change the interface language and login behavior in Settings.

## Installation

**Requires macOS 13 Ventura or later.** The release build supports both Apple silicon and Intel Macs. IP checks use an internet connection and the system copy of `curl` included with macOS. To build from source, install Git and Xcode Command Line Tools with the macOS 13 SDK or later. A full Xcode installation also works. The build uses only system tools and the Apple toolchain. [Install the Command Line Tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools/)

### Prebuilt app

1. Download `Route-Shield-v…-macOS-universal.dmg` from the **Assets** list in [GitHub Releases](https://github.com/01trisha/route-shield/releases).
2. Open the DMG and drag **Route Shield.app** onto the **Applications** shortcut in the disk image. If you downloaded the ZIP, extract it and move the app to **Applications** manually.
3. Open the app from **Applications**. The Route Shield icon appears in the menu bar.

Each download has a matching SHA-256 checksum.

The release build uses an ad hoc signature. If Gatekeeper blocks the downloaded copy, use the source installation below. Distribution with Apple notarization requires a Developer ID signature. [Apple's notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

### From source

On a new Mac, run `xcode-select --install` and finish the installation in the macOS dialog. If the tools are already installed, proceed with the commands below.

```sh
git clone https://github.com/01trisha/route-shield.git
cd route-shield
./install.sh
```

The script checks the requirements, builds the app, copies it to `/Applications/Route Shield.app`, and opens it. If the Command Line Tools are missing, the script offers to install them through macOS. Run the script again once the tools are installed.

If your account cannot write to `/Applications`, run `./install.sh --user` to install the app in `~/Applications`. Use `--no-open` to install it and open it later.

Before updating, quit Route Shield from its menu. The installer replaces the existing app bundle. Your app list and preferences are stored separately.

## First run

Choose your language in the welcome window and select **Continue**. Route Shield suggests Russian if Russian is your preferred macOS language and English for all other languages.

1. Click the Route Shield icon in the menu bar and choose **Add Apps…**. Open **Applications** in Finder and drag an app such as Calculator into the drop area.
2. Open the Route Shield menu again and select Calculator. Wait for the IPv4 and IPv6 checks, then choose **Open** or **Cancel**.
3. To launch apps from the Dock, choose **Create or Update Dock Shortcuts**. Drag the shortcuts from `~/Applications/Route Shield` into the Dock in place of the original icons.
4. Click the Route Shield icon and choose **Settings…**. In **General**, choose which connection details appear in the menu and the prelaunch window, change the language, or enable launch at login or force-quit. In **Notifications**, enable notifications, choose what they include, and send a test banner. The **About Us** tab links to the GitHub repository.

The app list lives at `~/Library/Application Support/VPN Guard/.env`, the same path used by earlier versions. Choose **Open .env** to remove an ID from the `APPS=` line or add another ID separated by a comma.

If you pinned shortcuts from the old `~/Applications/VPN Guard` folder, recreate them and pin the copies from `~/Applications/Route Shield`. New shortcuts use the language selected in Settings.

After updating Route Shield, choose **Create or Update Dock Shortcuts** so that the shortcuts pick up the new code and translations.

## How IP checks work

Route Shield makes HTTPS requests to [ipify](https://www.ipify.org/) for IPv4 and [ifconfig.me](https://ifconfig.me/) for IPv6. Each service sees the public IP of the request. With split tunneling, a selected app may use a different route.

Route Shield sends the detected public IP addresses to Country.is to estimate the country. If IPv4 and IPv6 map to different countries, the menu and prelaunch window show both. The lookup runs separately from monitoring and leaves **Open** available as soon as the IP checks finish. [Country.is](https://country.is/)

When monitoring is enabled, Route Shield checks after macOS network events, after wake, and about every two minutes. The first successful result establishes a baseline for each address family. A failed request by itself does not count as an IP change.

For each detected change, Route Shield sends one notification with the new IP address, country, or both. If force-quit is enabled and apps were closed, a second notification lists them.

**The prelaunch check applies only to apps opened through the Route Shield menu or its shortcuts.** Launching an app directly from Finder, Spotlight, or its original Dock icon bypasses the check. Force-quit runs after Route Shield detects an IP change. An app can still access the network before detection, and force-quitting can discard unsaved changes.

## Build and package

```sh
./build.sh      # Build the .app for this Mac in build/
./package.sh    # Build the universal .app, DMG, ZIP, and checksums in build/
```
