# WilderLoader

A small Mac app for offloading memory cards. It shows which files on a card, disk or folder are already on your other drives or NAS, and where.

![A card with one shoot that isn't backed up yet](docs/missing.png)

- See every shoot on the card, with a line to each drive that already has it. Anything that isn't backed up shows up in yellow.
- Drag a shoot to a drive to copy it. Every copy is checked against the original with xxHash-64.
- Copy to two drives at once. If one fills up, the other keeps going.
- Sort copies with folder templates, like `Project/01_RAW/Cam A/2026-11-05`.
- Finds renamed copies by size and samples of their content.
- Plays a sound and sends a notification when the copy is done.
- Click the dot on a drive to see which folders each date ended up in.
- Format and eject the card from the app when everything is there.
- No account and no cloud. Everything stays on your Mac.

## Formats

WilderLoader looks for cinema RAW and video (BRAW, R3D, ARRIRAW, Canon Cinema RAW, CinemaDNG, MXF, ProRes and more), photo RAW from the major brands, action and 360 cameras, and audio recorders (WAV, BWF, RF64, W64, AIFF, MP3, FLAC and more). Sidecar files like XML, RMD and SRT are copied along with their clip.

No list can cover everything. If a card holds a file WilderLoader doesn't recognize, it tells you and blocks the green format button, so you decide what to do with it.

![Everything on the card is on a drive](docs/safe.png)

![Which folders each date ended up in](docs/map.png)

The screenshots use demo data.

## Safety

WilderLoader never overwrites a file. It only erases when you format a card, and it asks first. Unless every file has had a full check against its copy, you have to type the card's name to format. Files found only in the list for a disconnected drive are matched by name and size, so they count as unchecked until you connect the drive. Files it doesn't recognize also make you type the name. It's a beta, so please don't trust it as your only backup yet.

## Download

Get the latest zip under [Releases](../../releases). It needs Apple silicon and macOS 14 or later.

The app isn't notarized yet, so macOS will warn you the first time you open it. If you'd rather not trust a prebuilt app, build it yourself.

## Build

You need the Swift toolchain from Xcode or the Command Line Tools.

```bash
./build.sh
```

The app ends up in `build/WilderLoader.app`.

To run the self-test, which creates and erases temporary disk images:

```bash
swift build && .build/debug/Kortkoll --selftest
```

The Swift target is still called `Kortkoll`, the app's first name.

## License

[MIT](LICENSE). The Bebas Neue font is licensed separately under the [SIL Open Font License](Resources/Fonts/OFL.txt).
