# Sous

A recipe and meal-planning app for iPhone, iPad and Mac. Local-first, German
UI, no server of its own — recipes live on the device and, if iCloud is on, in
the user's own private CloudKit database.

It is a personal app in the spirit of Mela, with the parts Mela leaves out:
nutrition computed against a real food database, a dinner planner, and a small
amount of on-device AI used only where language is genuinely the problem.
[VISION.md](VISION.md) is the design document — what the app is for, which
trade-offs were made, and what is deliberately out of scope.

## Status

Version 1.0, distributed through TestFlight. Requires iOS 26.5 or macOS 26.

## What it does

**Recipes.** A library with categories, favourites, search and a trash; a
Markdown-ish editor for text and steps; recipe variants that sit beside each
other as siblings in a group rather than overwriting one another; recipes that
link to other recipes (a curry references the naan, which is a recipe in its
own right).

**Importing and exporting.** From the web via schema.org JSON-LD — the
structured version of the page that recipe sites already publish, so no model
has to guess at it — through the share extension or a `sous://import` URL. From
and to Mela's `.melarecipes` archives. Images are downsized on import and
stored beside the recipe rather than inside it.

**Cooking.** A cook mode with scaled servings, several sessions at once with a
switcher bar, and step timers that run as Live Activities.

**Shopping.** A list built from the meal plan and from recipes picked by hand,
with quantities merged across recipes, sorted by supermarket aisle, and a
preferred store plus a shopping note per ingredient.

**Planning.** A meal plan whose entries are either dated or sit in an undated
pool, mirrored into the calendar; a dinner planner that fills a run of evenings
from the library.

**Nutrition.** Per-recipe values computed from the bundled BLS 4.0 catalog, an
NRF9.3 score, and category suggestions ("proteinreich", "ballaststoffreich")
that are offered to the cook rather than written on their behalf.

**Households.** Recipes, plan, shopping list and the hand-taught ingredient
vocabulary sync through CloudKit zone sharing: every library is a shared zone
from the first day, an invitation is the system sharing sheet, and a person can
belong to several households and switch between them.

**System integration.** App Intents and Shortcuts (add to the shopping list,
what's for dinner today, start cooking a recipe, open a recipe or the list).

### Where the AI is

Two places, both on-device Foundation Models, both narrow:

- `Resolving/AmountAIExtractor` — reading the amounts a step mentions when the
  grammar is open enough that a regex cannot.
- `Planning/MealSuitabilityClassifier` — guessing which slots a recipe suits
  when the library says nothing.

Everything else — arithmetic, nutrition, scaling, unit merging, parsing with a
closed grammar — is conventional code, on purpose. The nutrition pipeline in
`Scripts/` involves no model at all.

## Repository layout

| Path | What it is |
| --- | --- |
| `SousKit/` | A Swift package with the whole domain: model, parsing, catalog, nutrition, planning, shopping, persistence (SwiftData and Core Data), Mela and web exchange. No UI. |
| `Sous/` | The app — SwiftUI views, cook sessions, timers, App Intents, household switching. |
| `SousShare/` | The share extension: it opens the same editor the app uses, because iOS does not let an extension launch its host. |
| `SousWidgets/` | The cook-timer Live Activity. |
| `Scripts/nutrition/` | The pipeline that derives the bundled food data from the BLS workbook. Has its own [README](Scripts/nutrition/README.md). |
| `project.yml` | The source of truth for the Xcode project. |

The three targets share an app group (`group.me.raddatz.sous`) so the extension
and the app read the same store.

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

Three suites are opt-in and stay off in CI, because they either call a language
model or need a recipe library that is not in the repo:

```bash
SOUS_SPARRING=1 swift test --filter Sparring
SOUS_EFFORT_LIBRARY=/path/to/library.melarecipes swift test --filter EffortCalibration
SOUS_TAG_LIBRARY=/path/to/library.melarecipes swift test --filter NutritionTagCalibration
```

## CI and releases

[`ci.yml`](.github/workflows/ci.yml) runs on every push to `main` and every
pull request on a self-hosted macOS runner: regenerate the project, `swift
test`, then build for the iOS Simulator and for macOS. Nothing is signed, so it
needs no secrets.

[`release.yml`](.github/workflows/release.yml) archives and uploads to
TestFlight. It is started by hand (Actions → Release to TestFlight); a `v*` tag
is optional and only checks that git and `project.yml` agree on the version.

## Data and attribution

The bundled food data is derived from the **Bundeslebensmittelschlüssel (BLS)
4.0**, published by the Max Rubner-Institut under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The app carries that
attribution in its settings, and the dataset version and licence travel inside
`bls.json` itself so the credit cannot drift away from the numbers.

`PRIVACY.md` is the privacy policy the App Store listing points at.

No open-source licence is declared for the app's own code.
