# The data pipeline

How `Community/` becomes the data set the app reads, and how it gets there. What
the YAML says, and how to change it, is in `Community/README.md`; this file is
for whoever runs the machinery.

**Edit the YAML in `Community/`, never the resources.** They are compiled output
(`SousKit/Sources/SousKit/Resources/`), and CI fails when they differ from
`compile(Community/)`.

## Compiling

You need not compile by hand:
- **A pull request** that changes `Community/` is compiled by
  `.github/workflows/compile-data.yml`: where the resources differ, it commits
  them to the branch as "Compile Community/" and runs CI on that commit. A YAML edit
  in the browser is a whole change. (Branches of this repository only; a fork
  compiles itself.)
- **Locally**, `Scripts/hooks/pre-commit` compiles when a commit stages a change
  under `Community/`, and stages the resources with it. It steps aside while `Community/`
  holds unstaged changes, and never blocks a commit. Once per clone:

```
python3 -m venv Scripts/data/.venv                         # the hook prefers this one
Scripts/data/.venv/bin/pip install -r Scripts/data/requirements.txt
git config core.hooksPath Scripts/hooks
```

By hand, where you want to see the result first:

```
python3 -m pip install -r Scripts/data/requirements.txt   # once: PyYAML, jsonschema
python3 Scripts/data/compile.py                            # writes the resources
python3 Scripts/data/compile.py --check                    # what CI runs
cd SousKit && swift test                                   # BundledDataTests, the scorecard
```

## The data set and its version


The compiled files are one **data set**, and
`compile.py` writes its `manifest.json` last: the format (`schema`), the
release (`dataVersion`), and the SHA-256 of every file. The app reads a set
only through its manifest, the one it ships and the ones it fetches.

`dataVersion` is `YYYYMMDDnn`: the UTC day the compiler first saw this content,
and a counter within the day. Nobody sets it. `compile.py` raises it whenever
any file's bytes change and leaves it alone otherwise, so compile again after
extracting a new release of a source too. Bundled and published data are one series, so an app
update with newer data always wins over an older fetched set.

Two data pull requests open at once both raise the version; their manifests
conflict, and the second one compiles again on top of the first.
`--check --since <base>` fails when the data changed and the version did not
grow.

## Shared adjustments

Households share their local answers from the app ("Anpassungen teilen"). A
nightly workflow in a private inbox repository files them as issues, one per
name, with the reports as a `json sous-catalog` block (`Scripts/data/inbox.py`).
Labelling an issue there approves it — `als-alias`, `als-sorte`, or
`neues-wort` with a `kat:<Kategorie>` — and `Scripts/data/approve.py` turns it
into a pull request here that edits `Community/`, compiled. Only these mechanical
cases are written; values, weights and products stay with the curator. The
issue closes once the pull request is merged. The workflows for the inbox
repository are kept here as `Scripts/data/inbox-workflow.yml` and
`Scripts/data/inbox-approve-workflow.yml`.

## Publishing

After a merge to `main` that touches the data, the Action *Publish data*
(`.github/workflows/publish-data.yml`) runs `compile.py --check` and
`Scripts/data/publish.py`, which puts exactly the bundled files into the app's
CloudKit container, public database:

- a `DataRelease` record `release-<dataVersion>`, one asset per file in a
  field named after it (`kitchen_words.json` → `kitchen_words`), plus the
  manifest. Every asset is read back and checked against the manifest.
- only then the pointer `current-v<schema>` (type `CurrentRelease`), which
  carries the version and the manifest. Apps read it at most every 20 hours,
  by id, fetch only the files whose hash changed, and use the new set from
  their next cold start.

A push publishes to **development**, which debug builds read, and once that
succeeded to **production**: the merge is the review, and what is merged for
the catalog goes out. `publish.py` holds the resources against `Community/` itself
first, since a direct push publishes too. *Run workflow* publishes to one
environment by hand — a retry, or `--point-to`. Each environment keeps its
own server-to-server key as the secrets `CLOUDKIT_KEY_ID` and
`CLOUDKIT_PRIVATE_KEY`.

**Who may write.** Both record types grant read to everyone (no iCloud
account needed) and create and write only to the role `Publisher`, which
only the publisher's user record holds — the record the key acts as. The app
also takes a pointer or release only from that user (`CloudKitReleaseSource`)
and only of the right type: record names are unique across all types of the
zone, so a name taken first with any type that signed-in users may create
would otherwise pass. That is why no other type in the public database may
let signed-in users create records either — except `CatalogSubmission`, the
shared adjustments, which signed-in users create and only `Publisher` reads.
Core Data's types get a create grant by default whenever their schema is
initialized in development, so **check the roles before every production
deploy of the schema**:

```sh
xcrun cktool export-schema --team-id MDQY93XVHF --container-id iCloud.me.raddatz.sous \
  --environment development | grep -c 'GRANT CREATE TO "_icloud"'   # wants 1: CatalogSubmission
```

**Releases are never deleted.** `publish.py --point-to <dataVersion>` turns
the pointer to an older release, which stops devices that have not fetched
the newer one yet; a device that has keeps it, since a client never goes
back. The real undo is a revert in `Community/`, which compiles to a new, higher
version.

To publish by hand, with the key of the environment in
`CLOUDKIT_KEY_ID` and `CLOUDKIT_PRIVATE_KEY_FILE`:

```sh
python3 Scripts/data/publish.py --environment development --commit "$(git rev-parse HEAD)"
```
