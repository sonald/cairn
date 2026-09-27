#!/usr/bin/env python3
"""Alternate fresh native processes; retain all raw attempts, never silently trim outliers."""
import argparse, hashlib, json, math, statistics, subprocess, time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--baseline', required=True, type=Path)
p.add_argument('--candidate', required=True, type=Path)
p.add_argument('--baseline-receipt', required=True, type=Path)
p.add_argument('--candidate-receipt', required=True, type=Path)
p.add_argument('--manifest', required=True, type=Path)
p.add_argument('--out', required=True, type=Path)
p.add_argument('--scenario', choices=['all', 'identifiers', 'gutter', 'projection', 'reflow'], default='all')
p.add_argument('--samples', type=int, default=3)
p.add_argument('--max-pairs', type=int, default=3)
p.add_argument('--process-timeout', type=float, default=240)
p.add_argument('--stage-deadline', type=float, default=60)
p.add_argument('--scale-run', action='store_true')
p.add_argument('--supplemental', action='store_true', help='short separately labelled supplemental collection; not standalone acceptance')
p.add_argument('--pair-start', type=int, default=0)
p.add_argument('--require-ac-power', action='store_true')
a = p.parse_args()
assert a.samples >= 1 and a.max_pairs >= a.samples
assert a.pair_start >= 0
assert a.process_timeout > a.stage_deadline > 0
assert not a.out.exists(), 'Use a fresh output directory; do not overwrite raw attempts'
a.out.mkdir(parents=True)
raw = a.out / 'raw'; raw.mkdir()
receipts = {v: json.loads(getattr(a, v + '_receipt').read_text()) for v in ['baseline', 'candidate']}
for key in ['protocol', 'addonSHA256', 'readinessSHA256', 'installerSHA256']:
    assert receipts['baseline'][key] == receipts['candidate'][key], f'Mismatched harness {key}'
for version, receipt in receipts.items():
    assert receipt.get('sourceWasClean') is True and receipt.get('sealedBuild'), 'Require clean source + sealed build receipt'
    binary = getattr(a, version).resolve()
    expected = receipt['sealedBuild']
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == expected['binarySHA256'], 'Wrong executable for receipt'
    actual_resources = {str(file.relative_to(binary.parent)): hashlib.sha256(file.read_bytes()).hexdigest()
        for bundle in sorted(binary.parent.glob('*.bundle')) for file in sorted(bundle.rglob('*')) if file.is_file()}
    assert actual_resources == expected['resourceHashes'], 'Wrong/missing resource bundles for receipt'
manifest = json.loads(a.manifest.read_text())
assert manifest['schemaVersion'] == 1
fixtures = manifest['fixtures']
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
for entry in fixtures:
    file = a.manifest.parent / entry['path']
    data = file.read_bytes()
    assert sha(file) == entry['sha256'] and len(data) == entry['byteCount']
    assert data.count(b'\n') == entry['newlineCount']
required = {'workload.rs', 'workload.py', 'workload.ts', 'workload.tsx', 'large.rs', 'long-line.rs'}
if not a.scale_run:
    assert {e['path'] for e in fixtures} == required, 'Default acceptance uses all six frozen fixtures'
else:
    assert {f'scale-{n}.rs' for n in [10000,30000,50000,100000]} <= {e['path'] for e in fixtures}, 'Scale run requires all four frozen scales'

def command(*args):
    r = subprocess.run(args, text=True, capture_output=True)
    return dict(exit=r.returncode, stdout=r.stdout, stderr=r.stderr)
def environment():
    return dict(machine=command('sysctl', '-n', 'hw.model'), cpu=command('sysctl', '-n', 'machdep.cpu.brand_string'),
                memory=command('sysctl', '-n', 'hw.memsize'), os=command('sw_vers'), power=command('pmset', '-g', 'batt'),
                swift=command('swift', '--version'), sdk=command('xcrun', '--sdk', 'macosx', '--show-sdk-version'))
(a.out / 'environment-before.json').write_text(json.dumps(environment(), indent=2))
(a.out / 'fixture-manifest.json').write_text(json.dumps(manifest, indent=2))
(a.out / 'sources.json').write_text(json.dumps({v: dict(receipt=receipts[v], binary=str(getattr(a,v).resolve()), binarySHA256=sha(getattr(a,v))) for v in receipts},indent=2))
rows = []
valid = {(e['path'], v): 0 for e in fixtures for v in receipts}
expected_configs = {}
expected_outcomes = {}
observed_metrics = {}
def complete(fixture, version):
    groups = [events for (f,v,phase),events in observed_metrics.items() if (f,v)==(fixture,version)]
    for events in groups:
        if sum(e.get('operationStatus')=='pass' and isinstance(e.get('operationOnlyMs'),(int,float)) for e in events) < a.samples: return False
        if sum(e.get('drawStatus')=='pass' and isinstance(e.get('firstActualDrawMs'),(int,float)) for e in events) < a.samples: return False
        stable = [e.get('stable',{}) for e in events]
        # A declared deterministic precision limitation is reported, never repeatedly retried.
        supported = any(not (r.get('status')=='not_run' and r.get('policyLimited')) for r in stable)
        deterministic_failure = bool(stable) and all(r.get('status')=='fail' and r.get('deterministicFailure') for r in stable)
        if supported and not deterministic_failure and sum(r.get('status')=='pass' and isinstance(r.get('stableLayoutMs'),(int,float)) for r in stable) < a.samples: return False
    return bool(groups)
def power_snapshot():
    result = command('pmset','-g','batt')
    return dict(capturedAtUnix=time.time(), isAC=result['exit']==0 and "Now drawing from 'AC Power'" in result['stdout'], **result)
for pair in range(a.pair_start, a.pair_start + a.max_pairs):
    # Alternate AB / BA and rotate fixtures to avoid assigning one version all first runs.
    order = ['baseline', 'candidate'] if pair % 2 == 0 else ['candidate', 'baseline']
    rotated = fixtures[pair % len(fixtures):] + fixtures[:pair % len(fixtures)]
    for entry in rotated:
        if all(complete(entry['path'],v) for v in receipts): continue
        pair_results = []
        for version in order:
            sample_id = f'{entry["path"]}.pair-{pair:03d}.{version}'
            output = raw / (sample_id + '.json')
            started = time.monotonic()
            error = None
            power_before = power_snapshot() if a.require_ac_power else None
            if a.require_ac_power and not power_before['isAC']:
                (a.out/'power-blocked.json').write_text(json.dumps(dict(status='blocked',sampleID=sample_id,reason='AC required before native launch',power=power_before),indent=2))
                raise SystemExit('BLOCKED: AC power unavailable before native launch; existing raw retained')
            try:
                with (raw / (sample_id + '.log')).open('w') as log:
                    result = subprocess.run([str(getattr(a,version).resolve()), '--self-test-readonly', '--matched-perf',
                        '--matched-scenario', a.scenario, '--fixture', str((a.manifest.parent / entry['path']).resolve()),
                        '--output', str(output.resolve()), '--sample-id', sample_id,
                        '--code-sha', receipts[version]['sourceSHA'], '--stage-deadline-seconds', str(a.stage_deadline)],
                        stdout=log, stderr=log, timeout=a.process_timeout)
                code = result.returncode
            except subprocess.TimeoutExpired:
                code, error = None, 'process timeout'
            power_after = power_snapshot() if a.require_ac_power else None
            try:
                value = json.loads(output.read_text()) if output.exists() else {}
            except (json.JSONDecodeError, OSError) as exc:
                value, error = {}, 'invalid app JSON: ' + str(exc)
            good = value.get('matchedProtocol') == 's7-v2' and value.get('fixtureSHA256') == entry['sha256']
            good &= value.get('codeSHA') == receipts[version]['sourceSHA']
            good &= all(p.get('readiness',{}).get('status') != 'fail' for p in value.get('phaseSetups',[]))
            config = {k:value.get(k) for k in ['resolvedFontName','fontFeatureRequests','effectiveFontFeatures','fontFallbackReason','settings','sourceCost','readonlyFlags','initialTheme','windowAppearance','windowPt','viewportPt','os']}
            if good:
                expected_configs.setdefault(entry['path'], config)
                good &= config == expected_configs[entry['path']]
                if not good: error = 'non-comparable font/geometry/environment configuration'
            if good:
                outcome = [(e['scenario'], e.get('occurrenceCount'), e.get('selection'), e.get('affinity')) for e in value['events']]
                expected_outcomes.setdefault(entry['path'], outcome)
                good &= outcome == expected_outcomes[entry['path']]
                if not good: error = 'non-comparable selected ranges or identifier result count'
            comparable = bool(good)
            good &= code in (0,1)
            good &= all(e.get('applicable') is False or (e.get('operationStatus')=='pass' and e.get('drawStatus')=='pass') for e in value.get('events',[]))
            row = dict(sampleID=sample_id, fixture=entry['path'], version=version, qualified=bool(good), comparable=comparable,
                       exit=code, error=error, powerBefore=power_before, powerAfter=power_after,
                       stableIssues=[dict(scenario=e['scenario'],status=e.get('stable',{}).get('status'),
                                          reason=e.get('stable',{}).get('reason')) for e in value.get('events',[])
                                     if e.get('stable',{}).get('status') in ('fail','not_run')],
                       elapsedProcessSeconds=time.monotonic()-started, output=str(output))
            pair_results.append((row,value))
        pair_ac = not a.require_ac_power or all(r['powerBefore']['isAC'] and r['powerAfter']['isAC'] for r,v in pair_results)
        for row,value in pair_results:
            row['powerPairQualified'] = pair_ac
            if not pair_ac:
                row['qualified'] = row['comparable'] = False
                row['error'] = 'AC power changed or was unavailable within paired process boundaries'
            if row['comparable']:
                for event in value['events']:
                    if event.get('applicable') is False: continue
                    observed_metrics.setdefault((row['fixture'],row['version'],event['scenario']),[]).append(event)
            if row['qualified']: valid[(row['fixture'],row['version'])] += 1
            rows.append(row)
            with (a.out/'attempts.jsonl').open('a') as journal: journal.write(json.dumps(row)+'\n')
            print(row['sampleID'], 'valid' if row['qualified'] else 'invalid', flush=True)
    if all(complete(f,v) for f,v in valid): break

# Nearest-rank p95; no trimmed observations. Each phase keeps its own measured population.
def stats(values):
    if not values: return dict(n=0,p50=None,p95=None,max=None)
    return dict(n=len(values), p50=statistics.median(values), p95=sorted(values)[math.ceil(.95*len(values))-1], max=max(values))
summaries = []
for entry in fixtures:
    for version in receipts:
        attempts = [r for r in rows if r['fixture']==entry['path'] and r['version']==version]
        qualified = [json.loads(Path(r['output']).read_text()) for r in attempts if r['qualified']]
        completed = [json.loads(Path(r['output']).read_text()) for r in attempts if r['comparable']]
        phases = sorted(phase for (f,v,phase) in observed_metrics if (f,v)==(entry['path'],version))
        metrics = {}
        for phase in phases:
            events = observed_metrics[(entry['path'],version,phase)]
            metrics[phase] = {key:stats([e[key] for e in events if isinstance(e.get(key),(int,float)) and e.get('operationStatus' if key=='operationOnlyMs' else 'drawStatus')=='pass']) for key in ['operationOnlyMs','firstActualDrawMs','operationAndSynchronousDrawMs','coldLoadToFirstDrawMs','coldLoadToStableMs']}
            metrics[phase]['operationStatus']='pass' if metrics[phase]['operationOnlyMs']['n']>=a.samples else 'fail'
            metrics[phase]['drawStatus']='pass' if metrics[phase]['firstActualDrawMs']['n']>=a.samples else 'fail'
            metrics[phase]['stableLayoutMs']=stats([e['stable']['stableLayoutMs'] for e in events if isinstance(e.get('stable',{}).get('stableLayoutMs'),(int,float))])
            stable_values = [e.get('stable',{}) for e in events]
            limitations = [r for r in stable_values if r.get('status')=='not_run']
            metrics[phase]['stableStatus'] = ('not_run' if len(limitations)==len(events) else
                'pass' if metrics[phase]['stableLayoutMs']['n'] >= a.samples else 'fail')
            metrics[phase]['stableLimitations'] = limitations
            metrics[phase]['viewportSettledMs'] = stats([r['viewportSettledMs'] for r in limitations if 'viewportSettledMs' in r])
        summaries.append(dict(fixture=entry['path'],version=version,operationAndDrawQualifiedProcessSamples=len(qualified),attempts=len(attempts),
                              status='pass' if complete(entry['path'],version) and all(m['stableStatus'] in ('pass','not_run') for m in metrics.values()) else 'fail',
                              collectionComplete=complete(entry['path'],version),metrics=metrics,
                              coldInputPreparationMs=stats([v['coldInputPreparationMs'] for v in completed]),
                              diagnosticCompletedOperations=[dict(sampleID=v['sampleID'],scenario=e['scenario'],status=e['status'],
                                  operationOnlyMs=e.get('operationOnlyMs'),firstActualDrawMs=e.get('firstActualDrawMs'))
                                  for v in completed for e in v['events']],
                              peakPhysBytes=stats([v['peakPhysBytes'] for v in completed if isinstance(v.get('peakPhysBytes'),int)])))
regressions = []
for entry in fixtures:
    by_version = {r['version']:r for r in summaries if r['fixture']==entry['path']}
    for metric in ['operationOnlyMs','firstActualDrawMs','stableLayoutMs','coldLoadToFirstDrawMs','coldLoadToStableMs']:
        b = by_version['baseline']['metrics'].get('cold-display',{}).get(metric,{}).get('p95')
        c = by_version['candidate']['metrics'].get('cold-display',{}).get(metric,{}).get('p95')
        if b is not None and c is not None and c > max(b * 1.10, b + 2):
            regressions.append(dict(fixture=entry['path'], metric=metric, baselineP95=b,candidateP95=c,
                                    investigationThreshold=max(b*1.10,b+2),status='requires_written_review'))
(a.out/'environment-after.json').write_text(json.dumps(environment(),indent=2))
summary=dict(schemaVersion=1,status='pass' if all(s['status']=='pass' for s in summaries) else 'fail',
             scope='matched metric sample collection; limited stable metrics remain not_run',
             supplemental=a.supplemental, standaloneAcceptanceEligible=(a.samples >= 30 and not a.supplemental), requiredSamples=a.samples, pairStart=a.pair_start, requireACPower=a.require_ac_power,
             scenario=a.scenario, coldRegressionReviewRequired=regressions, summaries=summaries, anomalies=[r for r in rows if not r['qualified'] or any(i['status']=='fail' for i in r['stableIssues'])],
             limitations=['Statistical capture pass is not release approval; evaluate correctness and regression thresholds separately'])
(a.out/'summary.json').write_text(json.dumps(summary,indent=2))
raise SystemExit(0 if summary['status']=='pass' else 1)
