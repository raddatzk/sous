# Contributing to Sous

Everything a developer needs: where things live, how to build and test, and how
a build reaches TestFlight. What the app does for its users is in the
[README](../README.md); [VISION.md](VISION.md) is the design document — what the
app is for, which trade-offs were made, and what is deliberately out of scope.

Ingredient data, nutrition sources and AI providers are maintained as YAML in
`Community/` and have their own guide: [Community/README.md](../Community/README.md).
A change there needs no Xcode at all.

## Repository layout

| Path | What it is |
| --- | --- |
| `SousKit/` | A Swift package with the whole domain: model, parsing, catalog, nutrition, planning, shopping, persistence (SwiftData and Core Data), import and export. No UI. |
| `Sous/` | The app — SwiftUI views, cook sessions, timers, App Intents, household switching. |
| `SousShare/` | The share extension: it opens the same editor the app uses, because iOS does not let an extension launch its host. |
| `SousWidgets/` | The cook-timer Live Activity. |
| `Community/` | What the community maintains, as YAML — the ingredient catalog (words, spellings, varieties, BLS codes), products, nutrition sources, weights, categories and AI providers — and the one place it is edited. |
| `Scripts/data/` | The compiler that turns `Community/` into the bundled resources; CI checks the two agree. |
| `Scripts/sources/` | `extract.py`: turns a source's download (the BLS workbook, Ciqual, USDA) into `Community/sources/<id>.json`, for a new release. |
| `project.yml` | The source of truth for the Xcode project. |

The three targets share an app group (`group.me.raddatz.sous`) so the extension
and the app read the same store.

### Where the AI is

Two places, both narrow:

- `Planning/MealSuitabilityClassifier` — on-device Foundation Models, guessing
  which slots a recipe suits when the library says nothing.
- `Resolving/RecipeOptimization` and the AI chat — Sous writes the prompt, asks
  the cook's provider directly with their own key or lets them paste it into a
  chat of their own, and reads the answer back. A fixed reader checks every
  line of it; only what passes is offered, and without an answer nothing
  changes. The providers are listed in `Community/ki/`.

Everything else — arithmetic, nutrition, scaling, unit merging, parsing with a
closed grammar, the amounts a step takes — is conventional code, on purpose.
The nutrition pipeline in `Scripts/` involves no model at all.

## Building

The checked-in `.xcodeproj` drifts from `project.yml`. Regenerate it after
pulling, and whenever files are added or removed:

```bash
brew install xcodegen && xcodegen generate
```

Then open `Sous.xcodeproj` and run the `Sous` scheme, or build from the command
line:

```bash
xcodebuild build -scheme Sous -destination 'platform=macOS' -configuration Release CODE_SIGNING_ALLOWED=NO
```

## Tests

The domain tests live with the package and need no simulator:

```bash
cd SousKit && swift test
```

Four suites are opt-in and stay off in CI, because they either call a language
model or need a recipe library that is not in the repo:

```bash
SOUS_SPARRING=1 swift test --filter MealSuitabilitySparring
SOUS_EFFORT_LIBRARY=/path/to/library.melarecipes swift test --filter EffortCalibration
SOUS_TAG_LIBRARY=/path/to/library.melarecipes swift test --filter NutritionTagCalibration
SOUS_OPTIMIZE_LIBRARY=/path/to/export.sousrecipes SOUS_OPTIMIZE_OUT=/path/to/out \
    swift test --filter RecipeOptimizationSparring
```

## CI and releases

[`ci.yml`](../.github/workflows/ci.yml) runs on every push to `main` and every
pull request on GitHub's `xcode-27` image, the one that carries Xcode 27 and
with it the iOS 27 SDK: regenerate the project, `swift test`, then build for the
iOS Simulator and for macOS. Nothing is signed, so it
needs no secrets. The repository is public, so a pull request can come from
anyone — which is exactly why this does not run on a Mac of ours. Beside it, a
Linux job checks that the bundled resources equal what `Community/` compiles to.
The catalog's own two workflows, [`compile-data.yml`](../.github/workflows/compile-data.yml)
and [`publish-data.yml`](../.github/workflows/publish-data.yml), are described in
[`Community/README.md`](../Community/README.md).

[`release.yml`](../.github/workflows/release.yml) archives the iOS and the macOS
app and uploads both to TestFlight, on the same hosted image. It is started by
hand (Actions → Release to TestFlight → Run workflow). It signs, so it needs the
certificates as secrets: `DIST_CERT_P12`, `MAC_INSTALLER_P12`, `DEV_CERT_P12`
(each with its password) and the App Store Connect API key. The development
certificate signs nothing that ships — it is there so automatic signing has an
identity to archive with instead of minting a new one on every run.

### Versioning

Nobody bumps a version by hand for a build. The release job computes it:

- `CFBundleShortVersionString` = `<major>.<commits on main>`, the major number
  taken from `MARKETING_VERSION` in `project.yml` (`1.0`).
- `CFBundleVersion` = 10 × run number + attempt.

The commit count grows with every commit on `main`, so each new state is a
higher version on its own — App Store Connect demands that for every App Store
release and closes a version to further builds once it is out — and the iOS and
the macOS build of one run carry the same version. The build number only has to
be unique within a version; ten per run keeps a re-run (same run number, next
attempt) from repeating the build of an upload that already went through. The
job checks out the full history and fails on a shallow clone, which would count
a single commit. Local builds are `1.0` with build 1.

Two consequences. Rewriting `main`'s history (a force-push after a rebase or
squash) can lower the count and get uploads rejected as older versions. And
since every build is a new version, every TestFlight build for external testers
goes through a Beta App Review first; internal testers are not affected. Raise
the major number only to say something to users — it is never needed to get past
a store check.

Tags are set by the workflow, not by hand: after a successful upload a small
follow-up job tags the built commit `v1.252`, so git shows which state went to
TestFlight. Uploading the same state again keeps the first tag. That job is the
only one with write access to the repository; the build and upload job can only
read. The version a commit would get:

```bash
echo "1.$(git rev-list --count HEAD)"
```

## Data and attribution

Every nutrition source is registered in `Community/sources/`, travels with the
data set as `sources.json`, and is shown on the settings' "Datenquellen" page;
every row names its source under the ingredient. See `Community/NOTICE`.

`docs/` holds what is not code: this guide, the design document, the privacy
policy the App Store listing points at (`PRIVACY.md`), the Icon Composer source
of the app icon (`sous.icon`; the build uses the copy in `Sous/`), and the
README demo (`sous.gif`), cut from the launch video.
