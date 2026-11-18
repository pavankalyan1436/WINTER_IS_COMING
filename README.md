#           ❄︎ WinterIsComing ❄︎

Let it snow on your Mac! ☃️

Snow falls on your desktop and piles up on your windows and Dock. Roll it into snowballs and build a little snowman. It's all one Swift file, and every flake is drawn in code.

<!-- ![demo](docs/demo.gif) -->

## What it can do ✨

- 🌨️ **Cozy snowfall**: three layers of flakes (near, middle and far) drifting in a gentle wind
- 🏔️ **Snow piles up** on top of your windows, along the Dock and at the bottom of the screen
- 🪟 **Drag a window and *whoosh*!** The snow flies off. The faster you drag, the farther it goes
- ⚪ **Roll snowballs** just by moving your mouse sideways over the snow (no clicking!). They grow as they roll
- 🎳 **Snowballs push each other** along, and one that's pushed off the edge falls down
- 🖐️ **Hold a snowball** with the left mouse button and carry it anywhere
- ⛄ **Stack three snowballs** and they turn into a snowman with a carrot nose and a red scarf
- 💥 **A falling snowball goes *poof*** into a soft heap of snow, ready to be rolled again
- ✨ **Snowman lights**: every snowman wears twinkling colored string lights (switch them off in the ❄︎ menu)

### Holiday extras 🎄

| Shortcut | What happens |
| --- | --- |
| **⌥C** | A snowplow drives along the bottom and clears the snow |
| **⌥P** | Kids, or sometimes a family, come out to play: snowball fights, sledding and building snowmen. Press again to send them home |
| **⌥T** | A decorated Christmas tree pops up with lights, ornaments and a star. Press again to take it down |
| **⌥S** | Santa flies across the sky in his reindeer sleigh and drops presents under the tree |

The snow also keeps falling after your Mac wakes from sleep.

## Download 🎁

1. Grab `WinterIsComing-mac-vX.zip` from [Releases](https://github.com/yike-shi/WINTER_IS_COMING/releases/latest)
2. Unzip it and drag **WinterIsComing** into your Applications folder
3. Double-click it. The first time, macOS will block it because the app isn't from the App Store. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only need to do this once ✨

## Build it yourself 🛠️

```sh
git clone https://github.com/yike-shi/WINTER_IS_COMING.git
cd WINTER_IS_COMING
zsh build.sh
```

Use the ❄︎ in the menu bar to pause, pick light, medium or heavy snow, clear the snow, or quit.

- No `swiftc`? Run `xcode-select --install` first.
- Want snow on the Dock too? Turn on **WinterIsComing** (or **Terminal**, if you run it with `build.sh`) in System Settings → Privacy & Security → Accessibility.
- Want your own `.app`? Run `zsh make_app.sh 1.0`.

## Windows version 🪟 (beta)

You asked for it, so here it is! Snow falls on your Windows desktop and piles up on your windows and the taskbar, and dragging a window still sends it flying. Snowballs and snowmen are coming soon ⛄

```sh
cd WINTER_IS_COMING/windows
dotnet run -c Release
```

Use the ❄ icon in the system tray to pause, pick the snow amount, clear the snow, or quit. You'll need the [.NET 8 SDK](https://dotnet.microsoft.com/download) (`winget install Microsoft.DotNet.SDK.8`).

## Make it yours 🎨

Every setting lives at the top of `WinterIsComing.swift` (`enum Cfg`): how many flakes fall, how fast they fall, how tall the piles get, how big a snowball can grow… Change a number and run `zsh build.sh` again.

## License

[MIT](LICENSE) · Made with 💙 and a little help from Claude
