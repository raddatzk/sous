# Sharing

How a second person gets to see this library — and why that answer replaces
the sync section in `VISION.md` rather than implementing it.

## The decision: Mela's model

One invitation shares the whole collection, and Apple runs the invitation.
The recipes move out of CloudKit's default zone into a custom record zone in
the owner's private database, a single `CKShare` is placed on that zone, and
the system sharing sheet does the rest: invite, set permissions, accept,
revoke. Mela's own help describes exactly this shape — Settings → Sync →
Manage opens the sharing sheet, the *existing* collection is what gets
shared rather than a selection, and every participant may create, modify and
delete. Its stated requirement of iOS 15 / macOS 12 is the giveaway: that is
the release where Apple introduced zone-wide sharing. Before it, only a
single record hierarchy could be shared, which is the wrong shape for "my
whole library".

Sharing a zone rather than a recipe is also the honest match to what a
household is. Nobody wants to tick recipes into a share; the unit people
actually mean is the collection, the way `VISION.md` already frames it — the
household is the unit of sharing.

## What this deletes

The sync section in `VISION.md` designs a server. Zone sharing removes it,
along with everything built to make it safe:

* no Supabase, no Row Level Security, no plaintext/ciphertext split
* no household key, no X25519 wrapping, no in-house crypto behind an
  `encrypt`/`decrypt`/`wrapKeyFor`/`rotate` protocol
* no second secret: no Argon2id passphrase, no mandatory recovery code, no
  wrapped private key fetched by a new device
* no pending invitation state. `VISION.md` accepts that "inviting a member
  requires an existing member to come online", because only a member can
  wrap the household key for the invitee. Apple wraps it, so the invitation
  is just a link.

The privacy goal survives intact, and by a cheaper route: the operator
cannot read a private CloudKit database at all, so there is nothing to
encrypt against them and no key ceremony to get wrong.

## What it costs

**Android is gone.** `VISION.md` rules out CloudKit for exactly this reason
and it is still the true cost — not a technicality to be routed around
later. Everything else here follows from accepting it.

**SwiftData cannot do this.** Not a limitation to work around, a missing
API: in the iOS 26.5 SDK, `ModelConfiguration.CloudKitDatabase` offers
`.automatic`, `.none` and `.private(_:)` and nothing else, and the whole
SwiftData interface mentions neither `CKShare` nor `participant`. The
shared database is reachable only through `NSPersistentCloudKitContainer`
with `databaseScope = .shared`. The synchronized models therefore move to
Core Data. This is almost certainly why Mela sits there too.

**The migration is smaller here than it usually is**, for two reasons that
were not planned for this but pay for it anyway:

* the schema is flat. `StoredRecipe` has no relationships — ingredients and
  instructions are text, group membership is a plain `variantGroupID`,
  images are referenced by id. What normally makes a Core Data port
  expensive is an object graph, and there isn't one.
* `RecipeStore` is a narrow `Sendable` protocol over value types; no
  SwiftData type appears in a signature. A `CoreDataRecipeStore` is a swap
  behind the same door, and views, library and parsers never see it. The
  same shape holds for `MealPlanStore` and `ShoppingListStore`.

Seventeen stored models (~1030 lines) and eight store implementations
(~1100 lines) is the whole surface, and only the shared half of it moves.

**Do it before turning CloudKit on, not after.** Switching SwiftData to the
private database first and retrofitting invitations later means migrating
data that already lives in users' iCloud. The app is at 0.1 and syncs
nothing yet; this is the cheapest this decision will ever be.

## What is shared and what stays on the device

The split is not private-versus-public — everything here is the cook's own.
It is *worth syncing* versus *recomputable*.

**Shared** — what a person wrote, and what the other person should see:
`StoredRecipe`, `StoredRecipeImage`, `StoredVariantGroup`,
`StoredMealPlanEntry`, `StoredShoppingEntry`, `StoredShoppingPlanEntry`,
`StoredShoppingDemand`, `StoredIngredientVocabulary`.

The pantry mark belongs here for the same reason the shopping list does: "we
have that at home" is a statement about one kitchen, not about one phone. It
does not appear as a row of its own, though — `StoredPantryFlag` is legacy,
long since folded into the vocabulary entry as `isPantry`, and only the
vocabulary migration still reads it. It stays behind in SwiftData with the
other legacy rows. The vocabulary belongs here because teaching an ingredient
its spelling or its nutrition by hand is work, and nobody should do it twice.

The two review markers — `StoredAmountReview`, `StoredIngredientReview` —
are shared as well, and that is a judgment worth stating: they record that a
person looked at a recipe's open questions and settled them. Since the
recipe is shared, the settlement is too, and it is keyed to a content hash,
so an edit reopens the question for everybody at once.

**Local** — derived, and cheaper to rebuild than to sync:
`StoredCatalogIngredient` (built from the bundled `bls.json`, 1.9 MB, plus
800 KB of synonyms — this must never enter anyone's iCloud quota),
`StoredRecipeEnrichment` and `StoredRecipeNutrition` (both caches bound to a
content hash), and the two legacy rows kept only so a migration can read
them, `StoredIngredientAliasOverride` and `StoredCatalogNutrition`.

The nutrition cache deserves its own sentence, because "it is only a cache"
is the weaker half of the reason. `RecipeContentHash` covers the recipe's
text and the recipes it links to — not the BLS version the figures were
computed against, which ships with the app and may differ between two
devices. A synced cache would therefore carry numbers from a device with a
newer catalog to one with an older, where the same aggregator would never
have produced them, and the stale hash would match all the while. Recomputing
costs milliseconds; that kind of silent disagreement costs trust in every
figure on the screen.

The container therefore splits in two regardless of Core Data, and that
split — not the entitlement — is the actual work in the first step.

## Several households, and why each one is shared from the start

A person belongs to their own library, to a flat share, and to a family, and
sees one at a time. This is not an extra feature bolted onto zone sharing —
it is what the architecture already produces: households the user owns are
zones in their private database, households they joined arrive in the shared
one, and both kinds sit in the two local stores side by side. The switch is
therefore a filter over what is already on the device. Nothing signs out,
nothing re-downloads.

It also answers the question Mela's help leaves open — what an invitee sees
when they already have recipes of their own. Their library is simply another
entry beside "WG" and "Familie". Nothing has to be merged into the
collection they joined, and nothing of theirs becomes visible to it.

**Every household is a shared zone from the first day, including the one
nobody else is in.** Sharing cannot be switched on afterwards for free:
`share(_:to:)` moves the objects into the share's record zone, so promoting
a private library would relocate every recipe and every image through
iCloud, with new record identities, at exactly the wrong moment — the one
where somebody is waiting to send an invitation. A `CKShare` whose only
participant is its owner is an ordinary state and costs nothing to hold, so
the library is created inside one and inviting is reduced to opening the
sharing sheet. The relocation is paid once, on an empty store.

Two consequences worth stating. Moving a recipe between households is a copy
into a different zone rather than an edited field, because the zone is what
grants access — the household reference on the row follows the zone, it does
not decide it. And Core Data does not allow relationships across shares,
which costs nothing here: the schema has none.

## Calendar and shopping list through Apple

A separate surface, not a fallback for the above. The weekly plan becomes
calendar events and the shopping list becomes a reminders list, both through
EventKit, and both shareable by Apple's own means. Two things follow that
zone sharing does not give:

* the other person does not need Sous. A shared reminders list is ticked off
  in the supermarket by whoever is standing there.
* it is where a household actually feels shared — the plan and the list are
  the time-critical surfaces; the recipe text is not.

Neither replaces zone sharing: exported events and reminders are a
projection, and nothing flows back into a recipe.

## Open questions

* **Whether the owner's library is the household** or a household is a zone
  nobody owns personally. Mela's answer is the former, which makes leaving
  and dissolving asymmetric.
* **Whether the local half moves to Core Data as well.** It does not have to:
  the catalog and the caches sync with nothing. Keeping them on SwiftData
  leaves two persistence frameworks in one app, which is only bearable
  because the seam is exactly the store protocols; moving them anyway buys
  evenness and costs a rewrite nothing else asks for.
* Conflict handling, which zone sharing does not solve — two people editing
  one recipe's text still needs an answer, and the "text is the truth" rule
  in `VISION.md` means it cannot be a field-level merge.
