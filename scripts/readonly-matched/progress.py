#!/usr/bin/env python3
"""Read only the lightweight journal; never touch a measured process or GUI."""
import collections,json,sys,time
from pathlib import Path
root=Path(sys.argv[1]);journal=root/'attempts.jsonl'
rows=[json.loads(line) for line in journal.read_text().splitlines()] if journal.exists() else []
counts=collections.Counter((r['fixture'],r['version']) for r in rows if r['qualified'] and r['comparable'])
print(json.dumps(dict(processes=len(rows),last=rows[-1]['sampleID'] if rows else None,
    pairs={f:min(counts[f,'baseline'],counts[f,'candidate']) for f in sorted({r['fixture'] for r in rows})},
    incomparable=sum(not r['comparable'] for r in rows),
    candidateStableFailures=sum(i['status']=='fail' for r in rows if r['version']=='candidate' for i in r['stableIssues']),
    unexpectedBaselineFailures=sum(i['status']=='fail' and not (r['fixture']=='workload.py' and i['scenario'] in ('font-only','color-font-wrap') and i['reason']=='fresh-anchor-measurement-missing') for r in rows if r['version']=='baseline' for i in r['stableIssues']),
    elapsedMinutes=round((time.time()-(root/'environment-before.json').stat().st_mtime)/60,1))))
