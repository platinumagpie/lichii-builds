Lichii Builds
=============

A little tray app that watches GitHub for new Lichii emulator builds, tells
you when one comes out, and installs it when you say yes. Nothing downloads
on its own.

Setup (once)
------------
1. Unzip this folder somewhere it can stay (Documents is fine).
2. Double-click "Start Lichii Builds.bat".
   Windows may ask whether you want to run it, since it came from the
   internet: choose Run / Run anyway.
3. A setup window opens:
   - turn on the builds you want (Frizti, Main, or any other Lichii fork)
   - "Change" picks where each one lives. Already have Lichii? Pick that
     folder and the first check offers the newest build for it.
   - pick where old builds go, and how often to check
4. Save and start. A gradient "L" icon appears by the clock. If you don't
   see it, click the ^ arrow next to the clock and drag it onto the taskbar.

It starts with Windows from then on (you can turn that off in Settings).

Using it
--------
- Left-click the icon: what you have, what's on GitHub, Download buttons.
- Right-click: Check now, open folder, log, Settings, Exit.
- New build out: a card slides in at the bottom right with
  Download & install / Later. It waits while a fullscreen game is up, so it
  won't pop up in the middle of a game.
- Installing moves your old build into the "old builds" folder. Saves, mods
  and shader cache live in Lichii's own AppData folder, so they're not
  touched.
- If Lichii is open, it asks you to close it first.

Test builds (optional)
----------------------
Besides real releases, the Lichii devs post test builds that aren't
released yet. In Settings, each repo has:
  Releases        only real releases (the default)
  + Test builds   also test builds from the repo's main branch
  + Experimental  test builds from every branch, including experiments
Test builds need a free GitHub token: Settings > "Get a free token", create
it, paste it in. (A token with no boxes ticked should be enough; not
confirmed yet.) Test builds are less stable than releases.

Updating this app
-----------------
When a new version of Lichii Builds is out, a card offers "Update now".
One click: it downloads it, keeps your settings, keeps the previous version
in the "old versions" folder, and restarts itself. The right-click menu and
the panel offer it too. Your version is shown at the bottom of the
right-click menu.

Icon dot: none = up to date, orange = new build, blue = working,
red = problem (right-click > Open log), gray = couldn't reach GitHub.

Good to know
------------
- Lichii's own "check for updates" only looks at the main repo
  (zortos293/Lichii), even inside the Frizti build. So for Frizti, update
  with this app, not from inside Lichii.
- If one of the repos gets renamed or moved on GitHub, the app follows it
  by itself and shows a card telling you what changed.
- Windows 10 and 11 only. Needs nothing installed: it uses PowerShell, which
  comes with Windows.
- Tested on one Windows 11 PC. Windows 10 should work but hasn't been tried
  (the menu will have square corners there).
- Status.bat shows what's installed and whether the tray app is running.
- To remove it: right-click the icon > Settings > turn off Start with
  Windows, then right-click > Exit, then delete this folder.
