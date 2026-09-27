#!/usr/bin/env python3
"""Compare two isolated runs; functional agreement is not adoption evidence."""
import json, math, sys
from pathlib import Path
ordinary, chunked = (json.loads(Path(path).read_text()) for path in sys.argv[1:3])
checks = {}
for key in ("fixtureSHA256", "sourceUTF16", "chunkUnits", "font", "viewport", "osVersion"):
    checks["same_" + key] = ordinary[key] == chunked[key]
for label, result in (("ordinary", ordinary), ("chunked", chunked)):
    for key in ("sourceUnchanged", "textKit2Present", "expectedContentManager", "eofSelectionMatches", "axCharacterCountMatches"):
        checks[label + "_" + key] = result[key] is True
    for i, selection in enumerate(result["crossChunkSelections"]):
        for key in ("nativeCopyMatches", "axSelectedTextMatches", "axStringForRangeMatches"):
            checks[f"{label}_selection{i}_{key}"] = selection[key] is True
left = {sample["utf16"]: sample["rect"] for sample in ordinary["geometry"]}
right = {sample["utf16"]: sample["rect"] for sample in chunked["geometry"]}
checks["sameGeometrySamples"] = left.keys() == right.keys()
for label, result in (("ordinary", ordinary), ("chunked", chunked)):
    checks[label + "_allCaretSamplesVisible"] = all(sample.get("visible", False) for sample in result["geometry"])
for offset in left.keys() & right.keys():
    a, b = left[offset], right[offset]
    checks[f"validGeometry_{offset}"] = all(math.isfinite(v) for v in a + b) and a[3] > 0 and b[3] > 0
    checks[f"sameGeometry_{offset}"] = max(abs(x - y) for x, y in zip(a, b)) <= 1
out = {"status": "functional_probe_pass" if all(checks.values()) else "functional_probe_fail",
       "adoption": "defer", "checks": checks,
       "unvalidated": ["native drag/Shift and active selection end", "VoiceOver navigation", "font/width matrix",
                       "30 interleaved Release samples and peak-memory comparison", "large-document resource lifetime"]}
print(json.dumps(out, indent=2))
sys.exit(0 if all(checks.values()) else 1)
