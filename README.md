# FilmVibe

An iPhone camera that shoots RAW and develops every photo with a Fujifilm film‑simulation recipe.

- **107 recipes** from [Fuji X Weekly](https://fujixweekly.com) built in. Browse them, tweak any setting, or save your own.
- **Shoots RAW (DNG)** and develops it with Core Image plus custom Metal kernels: film simulation, grain, color chrome, highlight/shadow tone, white balance shift and dynamic range.
- **Live film look** in the viewfinder, so you see the recipe before you shoot.
- **Import** RAW or regular photos from your library and apply a recipe.
- **Engine Tuning** lets you change how strong every setting is and adjust each film simulation's profile. Export or paste the tuning as JSON.
- Keeps only the developed JPEG. You can optionally attach the DNG when saving to Photos.

## Build it yourself

FilmVibe isn't on the App Store, and there are no prebuilt downloads. Build it and install it on your own iPhone with Xcode.

You need a Mac with Xcode 26 or later, and an iPhone on iOS 17 or later. The simulator has no camera. The app is developed and tested on an iPhone 13.

1. Open `filmvibe/FilmVibe.xcodeproj`.
2. Select the **FilmVibe** target. Under **Signing & Capabilities**, pick your team and change the bundle identifier to something unique. A free Apple ID works.
3. Connect your iPhone and run the app on it. If iOS asks, turn on **Settings → Privacy & Security → Developer Mode**.

If Xcode reports a missing Metal toolchain, run `xcodebuild -downloadComponent MetalToolchain`.

With a free Apple ID the app stops opening after 7 days. Run it from Xcode again to reinstall it.

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
