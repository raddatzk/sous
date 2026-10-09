# Sous

<p align="center">
  <img src="docs/sous.gif" alt="Sous: scaling a recipe, cook mode, planning a week and making a recipe vegan in the AI chat" width="800">
</p>

Your recipes, your meal plan and your shopping list in one app — for iPhone,
iPad and Mac, in German. Sous does the sums for you: amounts follow the
servings, nutrition comes per serving, a week of dinners is planned with one
tap, and the shopping list adds amounts up across recipes.

Your recipes stay yours. There is no Sous server and no account: recipes live
on your devices and, if iCloud is on, in your own private iCloud.

Sous runs on iOS 27 and macOS 26.5 and is currently distributed through
TestFlight.

## What it does

**Recipes.** A library with categories, favourites, search and a trash, and an
editor for ingredients and steps. Variations of a dish — the vegan one, the one
for a crowd — sit beside the original as variants instead of overwriting it.
Recipes can link to other recipes: the curry points to the naan, which is a
recipe of its own.

**Importing.** Share a recipe page from Safari and Sous reads the recipe the
site already publishes in structured form, so nothing has to be guessed. You
can bring your collection along from the archives other recipe apps export,
and export it again — the whole library, or a single recipe to pass on, also
as Markdown or PDF.

**Cooking.** A cook mode with the servings you chose, every amount scaled down
to the steps, step timers that keep running as Live Activities, and several
dishes at once with a switcher bar.

**Planning.** A meal plan with dated entries and an undated pool for "sometime
this week", mirrored into your calendar if you like. The dinner planner fills a
run of evenings from your library.

**Shopping.** A list built from the meal plan or from recipes you pick, with
amounts merged across recipes ("1,6 l Gemüsebrühe" from two soups), sorted by
supermarket aisle, with a preferred store and a note per ingredient.

**Nutrition.** Values per serving for every recipe, computed from the German
food database (BLS 4.0), a nutrient score, and suggested categories such as
"proteinreich" or "ballaststoffreich" — offered to you, never added on your
behalf.

**Households.** Share your library, meal plan and shopping list with the people
you cook with, through iCloud sharing. You can belong to several households and
switch between them.

**Shortcuts and Siri.** Add something to the shopping list, ask what's for
dinner today, start cooking a recipe, or open a recipe or the list.

## AI, only where you want it

Sous does its arithmetic — scaling, nutrition, merging amounts — with plain
code, not with a model. AI comes in at two narrow places:

- **"Mit KI bearbeiten"** reworks a recipe on request — "Vegan machen",
  "Glutenfrei machen" or your own prompt. **"Für Sous optimieren"** tidies up
  an imported recipe: amounts in a clean form, each step with its ingredients.
  Sous checks every line of the answer before it offers anything, nothing
  changes until you accept, and the original is kept as a version.

  You choose how it is asked. Either Sous copies the prompt and you paste it
  into a chat you already use — Claude, ChatGPT, Gemini, Grok, Le Chat or
  Copilot, with any subscription and no extra cost. Or you give Sous an API key
  of your own (Anthropic, OpenAI, Gemini, Grok, or a local server such as
  Ollama or LM Studio) and it asks directly in a chat inside the app. The key
  sits in your iCloud keychain; a household can share one. If you want none of
  this, switch it off in the settings and the AI entries disappear.

- When a recipe doesn't say whether it is a lunch or a dinner, the planner asks
  Apple's on-device model. Nothing leaves the device for that.

## Privacy

Sous collects nothing. Recipes and plans are stored on your device and in your
own iCloud, with no analytics, ads or tracking. What leaves it is only what you
send yourself: a recipe to the AI provider you chose, an invitation to your
household, or a correction you share with the ingredient catalog.
[PRIVACY.md](docs/PRIVACY.md) is the full privacy policy.

## Food data

The ingredient catalog and its nutrition values are maintained in the open, in
[`Community/`](Community/README.md) — a missing ingredient, a spelling Sous
doesn't know or a wrong value can be fixed with a pull request, even from the
browser.

The values come mostly from the **Bundeslebensmittelschlüssel (BLS) 4.0**,
published by the Max Rubner-Institut under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), and, for foods it
does not list, from Ciqual (Anses, Licence Ouverte 2.0), USDA FoodData Central
(CC0) and product labels. Every value names its source in the app, on the
ingredient and on the settings' "Datenquellen" page. See `Community/NOTICE`.

## Contributing

How to build, test and release the app is in
[CONTRIBUTING.md](docs/CONTRIBUTING.md).

No open-source licence is declared for the app's own code.
