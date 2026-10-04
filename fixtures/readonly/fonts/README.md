# V06 synthetic process-font fixtures

These two 5 KiB TrueType files are original rectangle-outline ASCII glyphs created by `generate.py` with the already-installed fontTools FontBuilder. No existing font is copied. The generator and its generated outlines are covered by the repository's [MIT license](../../../LICENSE).

Both files have the exclusive PostScript name `CairnReadonlyV06Synthetic-Regular` and unitsPerEm=1000. A has 500-unit advances, B has 900-unit advances. Names/table hashes/byte hashes are recorded in manifest.json; deterministic head timestamps avoid accidental fixture churn. Regenerate with:

```bash
python3 fixtures/readonly/fonts/generate.py
```

Do not install these into system/user font folders. `ReadonlyFontRegistrationTests` registers and unregisters only with `CTFontManagerScope.process`. The first test relies on actual Core Text registration notifications to trigger AppDelegate and checks the Reader's real font URL, hmtx table hash, glyph advance, source and selection. It does not call ReaderFontResolver.refresh(). A real registration/unregistration failure such as InUse is recorded with a BLOCKED message and fails the test; it cannot produce a replacement PASS. Cleanup errors remain process-scoped and are printed. The process should run in isolation so a registration cannot interfere with another font test.

The second test posts a controlled distributed notification solely to verify the required AppDelegate route. It deliberately does NOT claim a real persistent/session font installation or replacement. Reader settings are overridden only in the process's volatile argument domain and restored; persistent preferences are not written.

Run these checks in separate processes, with no other native benchmark active:

```bash
CAIRN_READONLY_FONT_EVIDENCE_DIR="$PWD/.build/readonly/font-registration" \
  swift test --no-parallel --filter readonlyFontProcessReplacementChangesRealFontWithoutChangingReaderSource

CAIRN_READONLY_FONT_EVIDENCE_DIR="$PWD/.build/readonly/font-routing" \
  swift test --no-parallel --filter readonlyFontDistributedNotificationRoutesToAppDelegateWithoutInstallingFonts
```

Notification readiness pumps actual native run-loop turns as well as yielding the main actor. CI runs each font check in a fresh process to exclude delayed local notifications from the distributed-routing check.

[Historical registration evidence](../../../docs/evidence/font-registration.json) records the tested Reader font URLs, table hashes, glyph widths and preserved source/selection. It is an earlier observation, not current test status; rerun the relevant command when changing this mechanism. These fixtures must remain process-scoped and must not change system fonts.
