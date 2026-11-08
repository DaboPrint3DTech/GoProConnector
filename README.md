# GoPro Connector

A native macOS app (SwiftUI) to browse and download the files on a **GoPro HERO8 Black** over WiFi,
without plugging in a USB cable. It also works with HERO5–HERO7, which use the same API.

Like GoPro Quik, it turns on the camera's WiFi over Bluetooth and connects the Mac to it automatically.

The app is available in **English** and **Italian** and follows the language of your Mac. To pick a
different language for this app only: System Settings › General › Language & Region › Applications.

## Features

- **Automatic connection**: turns on the camera's WiFi over Bluetooth, reads the network name and password
  from the camera and joins the Mac to it. Manual connection is also available.
- **Previews**: thumbnail grid. Double-click or press Space for a full-size preview: photos load at original
  quality, videos stream from the low-resolution `.LRV` proxy (or from the original file with the
  "Original quality" switch). Use ← → to move between files.
- **Views**: icons or list (sortable table); icon size with the slider or ⌘+ / ⌘- / ⌘0; grouping by day.
- **Filters and search**: by type (video, photo, burst, time lapse), by day, by status (not downloaded /
  already downloaded); search by name, date or type; sort by date, name or size.
- **Copy** (⌘D): downloads to the default folder or to a folder you choose. Files already on the Mac with
  the same size are skipped.
- **Move** (⇧⌘D): downloads, checks the size, and only then deletes the file from the camera.
- **Delete** (⌫): deletes from the SD card, after confirmation.
- Bursts and time lapses are downloaded as a group into a subfolder; file dates on the Mac are set to the
  time of capture; `.LRV` proxies can optionally be downloaded too.
- **Transfer queue** with progress, speed, **estimated time left** and finish time, cancel and retry.
  The first estimate uses the speed of previous downloads and is refined after a couple of seconds.
- **Info**: app menu › About GoPro Connector, or Settings (⌘,) › Info, with the version
  and links to the [DaboPrint3DTech](https://github.com/DaboPrint3DTech) GitHub profile. The same links are
  in the Help menu.

## Installation

You build the app on your own Mac from the source code; it takes a few minutes and you only do it once.

### Requirements

- macOS 14 Sonoma or later, on an Intel or Apple silicon Mac
- Xcode Command Line Tools (free, installed in step 1)
- An administrator account to copy the app into Applications
- A Mac with Bluetooth and WiFi (every recent Mac has both)

### 1. Install the Command Line Tools

Open **Terminal** (Applications › Utilities › Terminal) and run:

```bash
xcode-select --install
```

A window appears: click **Install** and wait for it to finish. If Terminal says the tools are already
installed, go to the next step. A full Xcode installation works too.

### 2. Download the project

With Git (included in the Command Line Tools):

```bash
git clone https://github.com/DaboPrint3DTech/GoProConnector.git
```

```bash
cd GoProConnector
```

Or, without Git: on the GitHub page click **Code › Download ZIP**, double-click the ZIP in Downloads to
unzip it, then in Terminal type `cd ` (with a space), drag the unzipped folder onto the Terminal window and
press Return.

### 3. Build and install into Applications

```bash
scripts/build-app.sh --install
```

The script compiles the app (the first build takes a minute or two), creates **GoPro Connector.app**,
copies it into `/Applications` and registers it with macOS. From then on it shows up in **Launchpad**,
**Spotlight** and the **Applications** folder, like any other app.

- If you get `permission denied`, run `zsh scripts/build-app.sh --install` instead.
- If you are not an administrator, run `scripts/build-app.sh` (without `--install`): it creates the app in
  the `build` folder; drag it into Applications in Finder and macOS will ask for an administrator password.
- To keep it in the Dock: open the app, right-click its Dock icon › Options › Keep in Dock.

Because you build the app yourself, macOS opens it without any "unidentified developer" warning.

### 4. First launch: permissions and pairing

1. Open **GoPro Connector** from Launchpad or Applications.
2. macOS asks for access to **Bluetooth** and to the **local network**: allow both. If you denied one by
   mistake, turn it back on in System Settings › Privacy & Security › Bluetooth (or › Local Network).
3. Put the camera in pairing mode: on the HERO8 swipe down › Preferences › Connections › Connect Device ›
   GoPro App. Close GoPro Quik on your phone (or turn off the phone's Bluetooth) so it doesn't take the
   camera's connection.
4. In the app click **Turn On WiFi via Bluetooth and Connect** and confirm the pairing request if macOS
   shows one.

From then on just open the app (or press ⌘K): it remembers the camera, turns on its WiFi and connects the
Mac by itself. When you are done, **Disconnect and Turn Off GoPro WiFi** puts the Mac back on your home
network.

### Updating

From the project folder:

```bash
git pull
```

```bash
scripts/build-app.sh --install
```

If you downloaded the ZIP, download it again and repeat step 3. Settings, the paired camera and the download
history are kept. macOS may ask for the Bluetooth permission again after an update.

### Uninstalling

Drag **GoPro Connector** from Applications to the Trash. To also remove its settings, cache and history:

```bash
rm -rf ~/Library/Caches/GoProConnector ~/Library/Application\ Support/GoProConnector ~/Library/Logs/GoProConnector.log
```

```bash
defaults delete it.dabo.GoProConnector
```

The camera's WiFi password is stored in the Keychain: open Keychain Access, search for `GoProConnector.wifi`
and delete the item.

## Staying online while downloading

A Mac has a single WiFi card and can join only one WiFi network at a time (2.4 or 5 GHz makes no
difference: it is the same radio). While it is connected to the GoPro, it has no Internet over WiFi. To stay
online you need a second connection:

- an **Ethernet cable** from the Mac to your router (recommended: Ethernet normally comes before WiFi in the
  network service order, so Internet goes through the cable and WiFi stays free for the GoPro);
- or an iPhone connected over USB with Personal Hotspot turned on.

When a second connection is active, the sidebar shows "Internet via …".
The app polls the camera every 5 seconds, which keeps it awake during long downloads.

## Trying it without a camera

The mock server in `tools/` imitates the HERO8 HTTP API:

```bash
swift tools/make_mock_assets.swift tools/mock_assets
```

```bash
python3 tools/mock_gopro.py --port 18765
```

Then in Settings (⌘,) › Connection set host `127.0.0.1` and ports `18765` / `18765`
(set them back to `10.5.5.9`, 80, 8080 for the real camera, or use **Restore Defaults**).

The app icon is generated by `tools/make_icon.swift` (`swift tools/make_icon.swift Resources/AppIcon.icns`).

## Project structure

- `Sources/GoProConnector/Services/GoProClient.swift`: the camera's HTTP API (media list, thumbnails,
  delete, status)
- `Services/GoProBluetooth.swift`: Bluetooth pairing and turning the camera's WiFi on and off
- `Services/WiFiJoiner.swift`: joins the Mac to the camera's network; Keychain storage
- `Services/TransferManager.swift` + `Downloader.swift`: download queue, move, verification, history,
  estimated time
- `Services/ThumbnailLoader.swift`: thumbnails with a disk cache and at most 3 parallel requests
- `ViewModels/LibraryViewModel.swift`: state, filters, selection, actions
- `Views/`: SwiftUI interface
- `scripts/build-app.sh`: builds the `.app` bundle and installs it
- `Resources/it.lproj`: Italian translation (`Localizable.strings` for the interface, `InfoPlist.strings` for
  the permission prompts). The English texts in the code are the keys; to add a language, copy `it.lproj`
  to a new folder (for example `de.lproj`), translate the values and add the language to
  `CFBundleLocalizations` in `Resources/Info.plist`.

## GoPro API used (HERO5–HERO8)

| Function | Request |
|---|---|
| Camera info | `GET :80/gp/gpControl/info` |
| Status (battery, SD card) | `GET :80/gp/gpControl/status` |
| File list | `GET :8080/gp/gpMediaList` |
| Thumbnail / screennail | `GET :8080/gp/gpMediaMetadata?p=100GOPRO/FILE[&t=screennail]` |
| Download | `GET :8080/videos/DCIM/100GOPRO/FILE` |
| Delete file / group | `GET :80/gp/gpControl/command/storage/delete[/group]?p=100GOPRO/FILE` |
| Turn WiFi on / off (Bluetooth) | write `03 17 01 01` / `03 17 01 00` to characteristic `GP-0072` |
