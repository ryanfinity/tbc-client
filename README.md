# Lankhmar — client files

Everything that lives on **your** machine for the Lankhmar realm: the launcher,
the add-ons, and the manifest that keeps them current.

You do **not** need to download anything from this page by hand. Grab the
launcher once and it handles the rest, forever.

---

## Setting up (once)

**1. Get the game client.** Ryan will send you the World of Warcraft 2.4.3
folder. Unzip it wherever you like — your Desktop is fine. It does not need to
be installed, and it will not touch any retail WoW you already have.

The realm address is already set up in that folder, so there is nothing to
configure and no files to edit.

**2. Put the launcher in that folder.** Download
[`LankhmarLauncher.exe`](dist/launcher/LankhmarLauncher.exe?raw=1) and drop it in
next to `WoW.exe`.

**3. Run `LankhmarLauncher.exe`.** It will ask once which optional add-ons you
want, download everything, and start the game.

From then on, **always start the game with the launcher instead of `WoW.exe`.**
That is the only thing you have to remember. It keeps you current automatically —
you will never be told to go and copy files again.

---

## "Windows protected your PC"

You will almost certainly see this the first time, and it is expected.

Windows shows that warning for any program it has not seen many people run
before — and the launcher's job (download files, then start another program) is
exactly the shape it is suspicious of. Nothing is wrong.

Click **More info** → **Run anyway**. You only have to do it once.

If your antivirus quarantines it instead, allow it and run again.

---

## What the launcher does and does not touch

**It manages:** the add-ons listed in `manifest.json` (and, later, the custom
game patch).

**It never touches:**

- the game client itself
- `WTF/` — your settings, keybinds, and add-on positions live there and are
  always safe
- any add-on you installed yourself

It works out what to do by checking the files actually on disk, so a file that
gets damaged or half-copied is simply repaired next time you launch.

---

## Add-ons

| Add-on | | What it does |
|---|---|---|
| **Merc Panel** | required | Control bars for your mercenary squad — raid markers, stay/follow, stances, and a settings panel. Type `/merc` in game. |
| **Quest Tracker** | optional | Removes the 5-quest tracking limit and shows quest mobs on tooltips. |

Merc Panel is required because it is the interface for the mercenary system
itself — without it, a core part of the realm has no controls.

To change your optional add-on choices, delete `lankhmar-launcher.json` from
your WoW folder and run the launcher again.

---

## If something goes wrong

The launcher prints exactly what it was doing when it failed, and it changes
nothing when it fails. Send Ryan a screenshot of the window.

Two common ones:

- **"World of Warcraft is already running"** — close the game fully, then
  relaunch. It refuses to update files the game has open, rather than leaving a
  half-applied update.
- **"Could not reach the update server"** — it starts the game anyway with what
  you already have. Being unable to check for updates never stops you playing.
- **The realm doesn't show up on the character screen** — if Ryan tells you the
  server address has changed, open `realmlist.wtf` in your WoW folder with
  Notepad and replace the whole file with the one line he gives you.
