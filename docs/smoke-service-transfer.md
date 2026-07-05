# Smoke: background "Transfer to iPod" on real hardware

Operator runbook for **B.9-followup #1** — a one-transfer smoke of the
*service entry points* on a real iPod before OSS/ship. The core drag & drop
sync path is device-proven; what is **untried on hardware** is the two
background entry points added in B.9:

- Finder right-click → **Services → Transfer to iPod** (`NSServices`)
- the `podflick://transfer?path=…` URL scheme (Shortcuts / Automator)

Both funnel through the same code
([AppState.handleTransferRequest](../Sources/PodFlick/App/AppState.swift)),
so smoking the Finder path exercises most of it; the `podflick://` leg is an
optional second pass.

## Preconditions

- An iPod Video **5G/5.5G** connected and mounted as a disk (any of the fleet:
  the HFS+ 60GB or the FAT32/Rockbox DMRD).
- `ffmpeg` on `PATH`.
- A short **video** file to transfer (`public.movie` UTI — `.mp4`/`.mov`/`.m4v`).
  Non-movie files deliberately do **not** get the Services menu item
  (`NSSendFileTypes: public.movie` in [project.yml](../project.yml)).

## Setup — install to /Applications

The Finder Services menu item only appears once the built `.app` lives in
`/Applications` (a build-folder copy runs fine when invoked directly via
`NSPerformService`, but Finder won't surface it in the menu — this is the
followup-#2 gotcha, and it gates this smoke).

```
xcodegen generate
xcodebuild -project PodFlick.xcodeproj -scheme PodFlick \
  -configuration Release -derivedDataPath build build
rm -rf /Applications/PodFlick.app
cp -R build/Build/Products/Release/PodFlick.app /Applications/
open /Applications/PodFlick.app   # first launch registers the Service + URL scheme
/System/Library/CoreServices/pbs -flush   # force the Services cache to re-scan
```

Quit the app after that first launch (⌘Q, or the status-menu **Quit**) so the
cold-launch path below is actually cold.

---

## Test A — Finder Service, cold (quiet) launch

This is the headline path: app **not** running, transfer launches it windowless.

1. In Finder, **right-click the video** → **Services** → **Transfer to iPod**.
   - _Expect:_ the menu item is present (proves the `/Applications` +
     `pbs -flush` registration took).
2. _Expect:_ **no Dock icon flash, no window.** The app launches as an
   `LSUIElement` agent and stays `.accessory`
   ([AppState.enterBackgroundMode](../Sources/PodFlick/App/AppState.swift)).
   A flash here = a launch-phase regression.
3. _Expect:_ an **iPod menu-bar (status) item** appears, showing a live row like
   `<title> — Converting` / `Writing DB`.
4. First run only: a **notification-permission prompt** may appear — allow it.
5. _Expect:_ on completion, a **banner** "Transferred to iPod — "<title>" is
   ready to watch." (banners are opted-in even though the app is active — the
   `willPresent` delegate; if it lands silently in Notification Center only,
   that delegate regressed).
6. From the **status menu**, click **Eject <device>**.
   - _Expect:_ Eject is enabled only when the queue is idle; then a
     "Safe to disconnect" banner.
7. **On the iPod** (after eject + physical unplug, or via the device UI):
   open **Videos** and confirm the transferred clip is listed and **plays**.
   This is the ground-truth check — the DB write landed.

## Test B — Finder Service, app already running (optional)

1. Launch PodFlick normally (window visible, iPod connected).
2. Right-click a video → Services → **Transfer to iPod**.
   - _Expect:_ the window **stays**; the item shows up in the in-window queue
     list with progress (no background/status-item mode — `launchPhase` is
     already false).
3. Confirm completion in the queue list, then verify on-device as in A.7.

## Test C — podflick:// URL scheme (optional)

```
open "podflick://transfer?path=/absolute/path/to/clip.mp4"
```

- Cold (app quit): behaves like Test A (quiet launch, status item, banner).
- Running: behaves like Test B (queued in the window).
- Multiple `&path=` items enqueue multiple files.

## Negative check — no iPod

With **no iPod connected**, invoke the service once.
- _Expect:_ a **"No iPod connected"** notification and the app does **not**
  strand itself windowless in accessory mode
  ([AppState.handleTransferRequest](../Sources/PodFlick/App/AppState.swift)
  resolves the device before going quiet).

---

## Pass criteria

- [ ] Service menu item appears from `/Applications`
- [ ] Cold launch is silent (no Dock flash, no window) + status item shows
- [ ] Completion banner pops while the app is active
- [ ] Eject from the status menu → "Safe to disconnect"
- [ ] Clip plays on the iPod's Videos menu
- [ ] No-iPod case notifies instead of stranding

Record the result (device used, pass/fail per box, any surprise) in the B.9
followups note or the session wrap.
