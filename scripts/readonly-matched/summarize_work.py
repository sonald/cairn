#!/usr/bin/env python3
"""Supplement a completed matched run with paired outcomes and actual work distributions."""
import argparse,collections,json,math,statistics
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('directory',type=Path);a=p.parse_args()
rows=[json.loads(line) for line in (a.directory/'attempts.jsonl').read_text().splitlines()]
def stats(values):
    if not values:return dict(n=0,p50=None,p95=None,max=None)
    return dict(n=len(values),p50=statistics.median(values),p95=sorted(values)[math.ceil(len(values)*.95)-1],max=max(values))
fixtures=sorted({r['fixture'] for r in rows});reports=[];pair_reports=[]
for fixture in fixtures:
    members=[r for r in rows if r['fixture']==fixture]
    pairs=collections.defaultdict(dict)
    for row in members:
        pair=row['sampleID'].split('.pair-')[1].split('.')[0]
        pairs[pair][row['version']]=row
    paired=[]
    for pair,versions in sorted(pairs.items()):
        good=set(versions)=={'baseline','candidate'} and all(r['qualified'] and r['comparable'] for r in versions.values())
        if good:paired.append(pair)
    pair_reports.append(dict(fixture=fixture,pairedValidOperationDrawObservations=len(paired),validPairIDs=paired,totalPairs=len(pairs)))
    for version in ['baseline','candidate']:
        data=[json.loads(Path(r['output']).read_text()) for r in members if r['version']==version and r['comparable']]
        phases=sorted({e['scenario'] for d in data for e in d['events']})
        events_report=[]
        for phase in phases:
            events=[e for d in data for e in d['events'] if e['scenario']==phase]
            work={}
            for boundary in ['operationDelta','interactionDelta']:
                keys=sorted({k for e in events for k in e.get(boundary,{})})
                work[boundary]={key:stats([e[boundary][key] for e in events if key in e.get(boundary,{})]) for key in keys}
            events_report.append(dict(scenario=phase,samples=len(events),
                applicable=sum(e.get('applicable') is not False for e in events),
                stableStatuses=dict(collections.Counter(e.get('stable',{}).get('status',e.get('status')) for e in events)),
                stableReasons=dict(collections.Counter(e.get('stable',{}).get('reason',e.get('reason')) for e in events if e.get('stable',{}).get('reason',e.get('reason')))),
                latency={k:stats([e[k] for e in events if isinstance(e.get(k),(int,float))]) for k in ['operationOnlyMs','firstActualDrawMs','operationAndSynchronousDrawMs','coldLoadToFirstDrawMs','coldLoadToStableMs']},
                stableLayoutMs=stats([e['stable']['stableLayoutMs'] for e in events if isinstance(e.get('stable',{}).get('stableLayoutMs'),(int,float))]),work=work))
        reports.append(dict(fixture=fixture,version=version,comparableProcesses=len(data),events=events_report,
            peakPhysBytes=stats([d['peakPhysBytes'] for d in data if isinstance(d.get('peakPhysBytes'),int)])))
result=dict(schemaVersion=1,paired=pair_reports,reports=reports,limitations=['Missing counter fields remain absent; they are not invented zeros','Paired operation/draw validity does not upgrade failed or limited stable-anchor metrics'])
(a.directory/'work-and-pairs.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(pair_reports,indent=2))
