from pathlib import Path
import subprocess,json,re,time,statistics,tempfile
exe=str(Path(__file__).resolve().parents[4]/'.build/reliability-ui-final/Cairn.app/Contents/MacOS/codeinsight-app')
out=Path('/tmp/cairn-resource-benchmark.jsonl')
with out.open('w') as log:
 for mib in (0,64,256):
  base=Path(f'/tmp/cairn-v0-resource-{mib}')
  for i in range(25):
   cold=i<5
   root=Path(tempfile.mkdtemp(prefix=f'cairn-resource-{mib}-cold-')) if cold else base
   if cold:subprocess.run(['git','clone','--quiet','--local',str(base),str(root)],check=True)
   start=time.monotonic()
   r=subprocess.run(['/usr/bin/time','-l',exe,'--self-test-switch',str(root)],capture_output=True,text=True,timeout=60)
   metrics={}
   for line in r.stdout.splitlines():
    try:
     v=json.loads(line)
     if 'firstPaintMS' in v:metrics=v
    except ValueError:pass
   match=re.search(r'(\d+)\s+maximum resident set size',r.stderr)
   row=dict(payloadMiB=mib,phase='cold-index' if cold else 'warm-index',run=i,exit=r.returncode,elapsedSeconds=time.monotonic()-start,peakRSSBytes=int(match[1]) if match else None,**metrics)
   log.write(json.dumps(row)+'\n');log.flush()
   if r.returncode:Path(f'/tmp/cairn-bench-failure-{mib}-{i}.log').write_text(r.stdout+r.stderr)
  print('finished tier',mib,flush=True)
print(out,flush=True)
