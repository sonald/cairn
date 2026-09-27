#!/usr/bin/env python3
"""Original rectangle-outline ASCII test fonts; no installed font is copied.
Requires the existing fontTools installation. Generated output is deterministic.
"""
from pathlib import Path
import hashlib
import json
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

root = Path(__file__).resolve().parent
name = "CairnReadonlyV06Synthetic-Regular"
manifest = {"generator": "generate.py", "postScriptName": name, "unitsPerEm": 1000, "fonts": []}
for label, advance in [("A", 500), ("B", 900)]:
    builder = FontBuilder(1000, isTTF=True)
    order = [".notdef"] + [f"ascii{code}" for code in range(32, 127)]
    builder.setupGlyphOrder(order)
    builder.setupCharacterMap({code: f"ascii{code}" for code in range(32, 127)})
    glyphs = {}
    for glyph in order:
        pen = TTGlyphPen(None)
        if glyph != "ascii32":
            pen.moveTo((40, 0))
            pen.lineTo((advance - 40, 0))
            pen.lineTo((advance - 40, 700))
            pen.lineTo((40, 700))
            pen.closePath()
        glyphs[glyph] = pen.glyph()
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({glyph: (advance, 0 if glyph == "ascii32" else 40) for glyph in order})
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupNameTable({"familyName": "CairnReadonlyV06Synthetic", "styleName": "Regular",
                           "uniqueFontIdentifier": name + ";fixture-" + label,
                           "fullName": "CairnReadonlyV06Synthetic " + label,
                           "psName": name, "version": "Version 1.000",
                           "copyright": "Original synthetic test glyphs; MIT license, see repository LICENSE."})
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    builder.setupPost(isFixedPitch=1)
    builder.setupMaxp()
    builder.font.recalcTimestamp = False
    builder.font["head"].created = builder.font["head"].modified = 2082844800
    path = root / f"CairnReadonlyV06-{label}.ttf"
    builder.save(path)
    manifest["fonts"].append({"file": path.name, "advanceUnits": advance,
                              "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                              "hmtxSHA256": hashlib.sha256(builder.font.getTableData("hmtx")).hexdigest()})
(root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
