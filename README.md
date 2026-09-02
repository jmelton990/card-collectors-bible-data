# Card Collector's Bible -- card data pipeline

This repo is **not** the Card Collector's Bible app. It's a small,
standalone data pipeline that turns
[PokemonTCG/pokemon-tcg-data](https://github.com/PokemonTCG/pokemon-tcg-data)
(a public, openly-licensed community dataset) into the
`card_index.db` / `card_index.json` / `index_manifest.json` files the
app downloads on first run and checks for updates on every launch.

It's kept separate from the app's own source on purpose: this repo
(and, once Pages is enabled, its published output) is public, and the
app's actual source, UI, and pricing-connector code are not. Nothing
in this repo is anything beyond a generic "convert an already-public
dataset into a SQLite file" script -- `tool/build_index.dart` is a
vendored copy of the exact same script that lives in the main app
repo's `tool/` folder.

## How it works

1. `.github/workflows/update-card-data.yml` runs weekly (and can be
   triggered manually from the Actions tab any time -- do this right
   after a new set actually drops, rather than waiting for the
   schedule).
2. It clones a fresh copy of pokemon-tcg-data and runs
   `tool/build_index.dart` against it.
3. If the resulting card count differs from what's already published
   (i.e. something actually changed -- a new set was added), it
   publishes the output to GitHub Pages. If nothing changed, it skips
   publishing entirely rather than forcing every installed app to
   re-download an identical dataset.
4. The app's `IndexUpdateService` (in the main app repo) checks the
   published `index_manifest.json` on every launch and downloads the
   new `card_index.json` only when its version is actually newer.

Nothing here pushes updates TO installed copies of the app -- they
each pull on their own schedule (every app launch), same as any
"check for updates" pattern.

## One-time setup

1. Push this repo to GitHub (**public** -- GitHub Pages needs that,
   unless you're on a paid plan that supports Pages on a private
   repo).
2. Repo Settings -> Pages -> under "Build and deployment", set
   **Source** to **GitHub Actions** (not "Deploy from a branch").
3. Repo Settings -> Secrets and variables -> Actions -> Variables ->
   add a repository variable named `PUBLISHED_MANIFEST_URL` set to:
   ```
   https://<your-github-username>.github.io/<this-repo-name>/index_manifest.json
   ```
   (This is only used so the workflow can skip publishing when
   nothing changed -- it works fine even before this is set, it'll
   just always publish.)
4. Actions tab -> "Update card data" -> Run workflow, once, to publish
   the first version.
5. In the main app repo, point these two placeholders at your real
   URLs from step 3's domain:
   - `lib/services/index_update/index_update_service.dart` ->
     `manifestUrl`
   - `lib/services/card_index/database_download_service.dart` ->
     `databaseUrl` (point this at
     `https://<your-username>.github.io/<this-repo-name>/card_index.db`)

After that, it's hands-off -- the schedule keeps it current, and a
manual run is one click away whenever you don't want to wait for a
new set to show up on the next scheduled check.

## Extending to other games

`tool/build_index.dart --game <id>` already supports coexisting games
in one database (each run only clears/rebuilds its own `--game`'s
rows). Adding Magic/Yu-Gi-Oh/Lorcana here means: vendor that game's
`tool/build_index_<game>.dart` into this repo's `tool/` folder too,
and add one more `dart run tool/build_index_<game>.dart --data-dir ...
--out-dir dist` line to the workflow before the "did it change" step.
