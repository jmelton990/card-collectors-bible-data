// Run this OFFLINE (not on-device) to regenerate assets/card_index.db
// whenever a game's source data publishes something new.
//
// Usage (Pokémon, the only game with a working pipeline so far):
//   1. git clone https://github.com/PokemonTCG/pokemon-tcg-data.git
//   2. dart run tool/build_index.dart --data-dir path/to/pokemon-tcg-data --game pokemon
//
// --game defaults to 'pokemon' if omitted, so existing usage still
// works unchanged. Adding another game (Magic, Yu-Gi-Oh, etc.) means
// writing a NEW script that reads THAT game's data source and maps it
// into the same output shape used below — this file's actual
// PokemonTCG-specific JSON parsing only applies to Pokémon; the
// --game flag exists so the database itself is ready for more games
// once those pipelines exist, not because this file already handles
// them.
//
// --out-dir defaults to 'assets' (this app's own bundled-asset
// folder, matching every existing invocation of this script
// unchanged) but can point anywhere. This is what lets the exact
// same script run standalone in the separate data-publishing repo's
// CI workflow (see that repo's .github/workflows/update-card-data.yml)
// without assuming it's running from inside this Flutter project --
// there it's pointed at a plain output folder that gets published to
// GitHub Pages instead of an app's assets/ folder.
//
// IMPORTANT: running this does NOT wipe the whole database anymore —
// only rows matching --game are cleared and replaced. This is what
// lets Pokémon and (eventually) other games' data coexist in the same
// assets/card_index.db, built by separate runs of separate
// game-specific scripts.
//
// This walks cards/en/*.json, downloads each card's small image (used
// to compute the reference pHash), and writes everything into a
// SQLite DB that ships in the app bundle — so end users never need to
// hit the network just to identify a card.
//
// Runs in two phases:
//   Phase 1 (fast, no network): parse every JSON file and write all
//   card metadata immediately, with phash left at 0 as a placeholder.
//   This alone takes well under a second for the whole dataset, and
//   the resulting DB is already usable for name/set/number search
//   (see CardIndex.searchByName) even before a single image has been
//   downloaded.
//   Phase 2 (slow, network-bound): download and hash every card's
//   image, using a pool of concurrent requests rather than one
//   sequential request at a time — that sequential pattern was the
//   actual reason this used to take so long, since ~20k one-at-a-time
//   round-trips add up fast even on a fast connection.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main(List<String> args) async {
  final dataDirIndex = args.indexOf('--data-dir');
  if (dataDirIndex == -1 || dataDirIndex + 1 >= args.length) {
    stderr.writeln(
      'Usage: dart run tool/build_index.dart --data-dir <path> [--game pokemon]',
    );
    exit(1);
  }
  final gameIndex = args.indexOf('--game');
  final game = (gameIndex != -1 && gameIndex + 1 < args.length)
      ? args[gameIndex + 1]
      : 'pokemon';

  final outDirIndex = args.indexOf('--out-dir');
  final outDir = (outDirIndex != -1 && outDirIndex + 1 < args.length)
      ? args[outDirIndex + 1]
      : 'assets';

  final dataDir = Directory(args[dataDirIndex + 1]);
  final cardsDir = Directory('${dataDir.path}/cards/en');
  final setsFile = File('${dataDir.path}/sets/en.json');

  if (!cardsDir.existsSync() || !setsFile.existsSync()) {
    stderr.writeln('Could not find cards/en or sets/en.json under $dataDir');
    exit(1);
  }

  final sets = (jsonDecode(setsFile.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
  final setNameById = {for (final s in sets) s['id'] as String: s['name'] as String};

  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Absolute path, not relative — sqflite_common_ffi resolves a
  // relative path against ITS OWN internal database-storage folder
  // (.dart_tool/sqflite_common_ffi/databases/), not against the
  // current working directory. That mismatch is what caused a fully
  // successful run to still leave assets/card_index.db missing: the
  // database really was written, just to the wrong place. An
  // absolute path sidesteps that resolution entirely.
  final outFile = File('$outDir/card_index.db').absolute;
  outFile.parent.createSync(recursive: true);
  final outPath = outFile.path;
  // Open (don't delete) — an existing database may already contain
  // other games' rows that this run shouldn't touch.
  final db = await databaseFactory.openDatabase(outPath);

  await db.execute('''
    CREATE TABLE IF NOT EXISTS cards (
      id TEXT PRIMARY KEY,
      game TEXT,
      name TEXT,
      set_id TEXT,
      set_name TEXT,
      number TEXT,
      rarity TEXT,
      types TEXT,
      small_image_url TEXT,
      large_image_url TEXT,
      phash INTEGER
    )
  ''');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_name ON cards(name)');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_set_number ON cards(set_id, number)');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_game ON cards(game)');

  // Clear out only THIS game's existing rows before inserting fresh
  // ones — re-running for 'pokemon' should refresh Pokémon data
  // without touching any other game's rows already in the same file.
  final clearedCount = await db.delete('cards', where: 'game = ?', whereArgs: [game]);
  stdout.writeln("Cleared $clearedCount existing '$game' rows before rebuilding.");

  // === PHASE 1: metadata only, no network =============================
  stdout.writeln("Phase 1: reading '$game' card metadata (no network)...");

  final cardRows = <Map<String, dynamic>>[];
  final imageJobs = <(String id, String smallUrl)>[];

  for (final file in cardsDir.listSync().whereType<File>()) {
    if (!file.path.endsWith('.json')) continue;
    final setId = file.uri.pathSegments.last.replaceAll('.json', '');
    final cards = (jsonDecode(file.readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();

    for (final card in cards) {
      final images = card['images'] as Map<String, dynamic>?;
      final smallUrl = images?['small'] as String?;
      final largeUrl = images?['large'] as String?;
      if (smallUrl == null) continue;

      cardRows.add({
        'id': card['id'],
        'game': game,
        'name': card['name'],
        'set_id': setId,
        'set_name': setNameById[setId] ?? setId,
        'number': card['number'],
        'rarity': card['rarity'] ?? 'Unknown',
        'types': (card['types'] as List?)?.join(',') ?? '',
        'small_image_url': smallUrl,
        'large_image_url': largeUrl ?? smallUrl,
        'phash': 0, // filled in during Phase 2 below
      });
      imageJobs.add((card['id'] as String, smallUrl));
    }
  }

  final insertBatch = db.batch();
  for (final row in cardRows) {
    insertBatch.insert('cards', row);
  }
  await insertBatch.commit(noResult: true);
  stdout.writeln(
    'Phase 1 done: ${cardRows.length} cards written '
    '(name/set/number search is usable right now — hashes are still pending).',
  );

  // === PHASE 2: download + hash images, concurrently ===================
  stdout.writeln(
    'Phase 2: downloading images and computing hashes (${imageJobs.length} total)...',
  );

  // How many requests to have in flight at once. Higher = faster, but
  // more aggressive against the image host — 24 is a reasonable
  // middle ground; lower it if you start seeing a lot of timeouts or
  // failures in the "Skipping image for ..." lines below (a sign of
  // rate-limiting), raise it if the connection clearly has headroom.
  const concurrency = 24;

  int completed = 0;
  int nextIndex = 0;

  Future<void> worker() async {
    while (true) {
      // Claiming a job (reading nextIndex, then incrementing it) has
      // no await in between, so this is safe under Dart's
      // single-threaded cooperative scheduling even with several
      // workers running — no other worker's code can interleave
      // between the read and the increment.
      final myIndex = nextIndex;
      if (myIndex >= imageJobs.length) return;
      nextIndex++;
      final (id, smallUrl) = imageJobs[myIndex];

      int pHash = 0;
      try {
        final resp = await http.get(Uri.parse(smallUrl));
        final decoded = img.decodeImage(resp.bodyBytes);
        if (decoded != null) {
          pHash = _computePHash(decoded);
        }
      } catch (e) {
        stderr.writeln('Skipping image for $id: $e');
      }

      // A single update-by-primary-key is fast enough on its own not
      // to need batching here — Phase 2's bottleneck is entirely the
      // network/image-decode time above, not this write.
      await db.update('cards', {'phash': pHash}, where: 'id = ?', whereArgs: [id]);

      completed++;
      if (completed % 200 == 0) {
        stdout.writeln('Hashed $completed / ${imageJobs.length} images...');
      }
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
  stdout.writeln('Phase 2 done: ${imageJobs.length} images processed.');

  // Emit the JSON twin used by the web backend (see
  // lib/services/card_index/backend_web.dart) — ALL games' rows
  // combined, same field names, just serialized as a plain array
  // instead of a SQLite file, since plain sqflite has no web target.
  final allRows = await db.query('cards');
  File('$outDir/card_index.json').writeAsStringSync(jsonEncode(allRows));

  // Manifest bundled into the app so it knows, on first launch, what
  // version of the data it already shipped with — the index-update
  // service (lib/services/index_update/) compares this against a
  // remote manifest at the same shape and only downloads when the
  // remote version is newer. card_count reflects the WHOLE database
  // (every game combined), not just this run's game, since that's
  // what's actually shipping. Bump by re-running this script; a Unix
  // timestamp is simplest since "newer" is all that's ever checked.
  final manifest = {
    'version': DateTime.now().millisecondsSinceEpoch,
    'card_count': allRows.length,
  };
  File('$outDir/index_manifest.json').writeAsStringSync(jsonEncode(manifest));

  await db.close();
  stdout.writeln(
    "Done. ${cardRows.length} '$game' cards written this run "
    '(${allRows.length} total across all games) to $outPath, '
    '$outDir/card_index.json, $outDir/index_manifest.json',
  );
}

// Same difference-hash algorithm as lib/services/perceptual_hash.dart —
// keep these in sync, since query hashes and reference hashes must be
// computed identically for Hamming distance comparisons to be meaningful.
int _computePHash(img.Image image) {
  const size = 8;
  final resized = img.copyResize(image,
      width: size + 1, height: size, interpolation: img.Interpolation.average);
  final gray = img.grayscale(resized);

  int hash = 0;
  int bit = 0;
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final left = img.getLuminance(gray.getPixel(x, y));
      final right = img.getLuminance(gray.getPixel(x + 1, y));
      if (left > right) hash |= (1 << bit);
      bit++;
    }
  }
  return hash;
}
