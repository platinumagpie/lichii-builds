# Lichii Builds

A small Windows tray app that watches GitHub for new **Lichii** emulator builds, tells you when one comes out, and installs it when you say yes. Nothing downloads on its own.

It watches **Frizti's fork** ([Frizti/Fritchii](https://github.com/Frizti/Fritchii)) and the **main repo** ([zortos293/Lichii](https://github.com/zortos293/Lichii)) by default, and you can add any other Lichii fork.

## Get it

1. **[Download Lichii Builds](https://github.com/platinumagpie/lichii-builds/archive/refs/heads/main.zip)** (a zip).
2. Unzip it somewhere it can stay (Documents is fine).
3. Double-click **Start Lichii Builds.bat**. If Windows asks whether to run it, choose *Run* / *Run anyway*.
4. Pick which builds to watch and where they go, then **Save and start**.

A gradient **L** icon appears by the clock. Left-click it for your builds, right-click for the menu.

## What it does

- Checks GitHub every 15 / 30 / 60 minutes.
- When a new build is out, a card slides in at the bottom right: **Download & install** or **Later**. It waits while a fullscreen game is up.
- Installing moves your old build into your "old builds" folder. Saves, mods and shader cache live in Lichii's AppData folder, so they're never touched.
- Optional **test builds**: unreleased builds the Lichii devs post on GitHub (needs a free GitHub token, set in Settings).
- Updates itself: when a new version of this app is out, it offers **Update now**. One click, your settings stay. (Publishing an update = changing `VERSION` in this repo.)

## Good to know

- Windows 10 / 11. Nothing to install: it runs on the PowerShell that comes with Windows.
- Tested on Windows 11. Windows 10 should work but hasn't been tried yet.
- Lichii's own "check for updates" only looks at the main repo, even inside the Frizti build, so use this app for Frizti updates.

Not affiliated with the Lichii project. Lichii is by zortos293; the Frizti fork is by Frizti.
