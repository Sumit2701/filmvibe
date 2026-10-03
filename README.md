# FilmVibe

An iPhone camera that shoots RAW and develops every photo with a Fujifilm film‑simulation recipe.

- **107 recipes** from [Fuji X Weekly](https://fujixweekly.com) built in. Browse them, tweak any setting, or save your own.
- **Shoots RAW (DNG)** and develops it with Core Image plus custom Metal kernels: film simulation, grain, color chrome, highlight/shadow tone, white balance shift and dynamic range.
- **Live film look** in the viewfinder, so you see the recipe before you shoot.
- **Import** RAW or regular photos from your library and apply a recipe.
- **Engine Tuning** lets you change how strong every setting is and adjust each film simulation's profile. Export or paste the tuning as JSON.
- Keeps only the developed JPEG. You can optionally attach the DNG when saving to Photos.

## Download

FilmVibe isn't on the App Store. Each release includes an unsigned `.ipa` that you sideload:

1. Download `FilmVibe.ipa` from the [latest release](https://github.com/Sumit2701/filmvibe/releases/latest).
2. Install it with [AltStore](https://altstore.io), [SideStore](https://sidestore.io) or [Sideloadly](https://sideloadly.io). They sign the app with your own Apple ID.
3. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode** if iOS asks for it.

With a free Apple ID the app stops opening after 7 days. AltStore and SideStore can refresh it automatically; otherwise install it again.

Requires iOS 17 or later. It's developed and tested on an iPhone 13.

## Build from source

You need Xcode 26 or later and an iPhone, because the simulator has no camera.

1. Open `filmvibe/FilmVibe.xcodeproj`.
2. Select the **FilmVibe** target. Under **Signing & Capabilities**, pick your team and change the bundle identifier to something unique.
3. Run it on your device.

If Xcode reports a missing Metal toolchain, run `xcodebuild -downloadComponent MetalToolchain`.

To build an unsigned IPA locally, run `filmvibe/scripts/build-ipa.sh`. It writes `filmvibe/build/FilmVibe.ipa`.

### Releasing

Push a version tag. GitHub Actions builds the IPA and attaches it to a new release:

```sh
git tag v1.0 && git push origin v1.0
```

## Project layout

| Path | What's there |
| --- | --- |
| `filmvibe/FilmVibe/Engine` | Film engine: RAW develop and Metal Core Image kernels |
| `filmvibe/FilmVibe/Model` | Recipe model and `EngineTuning` defaults |
| `filmvibe/FilmVibe/Resources/Recipes.json` | Bundled recipes, each linked to its original article |
| `filmvibe/Tools/fvtest` | Mac command-line tool that runs the same engine on RAW files to make contact sheets and crops |

## Credits

The film recipes are by Ritchie Roesch at [Fuji X Weekly](https://fujixweekly.com). Each recipe in the app links to its original post.

FilmVibe isn't affiliated with Fujifilm. Film simulation names are Fujifilm's trademarks, and the looks here are approximations.

## License

The code is under the [MIT License](LICENSE).
