#!/usr/bin/env python3
"""Serial diagnostic controls for compilation heartbeat stalls (not GUI latency)."""
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parent.parent
cases = [(10000, v, False) for v in ('baseline', 'fresh', 'no_marks', 'no_gc', 'timer1', 'clear_chunks')]
cases += [(n, 'baseline', False) for n in (1000, 50000, 100000)]
cases += [(n, 'event_loop', False) for n in (10000, 100000)]
cases += [(100000, 'clear_chunks', False), (10000, 'baseline', True), (100000, 'baseline', True)]
results=[]
with tempfile.TemporaryDirectory(prefix='compile-scheduling-') as tmp:
    for count, variant, trace in cases:
        dest=Path(tmp)/'result.json'
        env=dict(os.environ,AUDIT_LINES=str(count),AUDIT_VARIANT=variant,AUDIT_TRACE=str(int(trace)),AUDIT_SAMPLES='5',AUDIT_RESULT=str(dest),NVIM_LOG_FILE=str(Path(tmp)/'nvim.log'))
        command=['nvim','--headless','--clean','-u','scripts/minimal_init.lua']
        command += ['-c','luafile scripts/emacs/scheduling_event_loop.lua'] if variant == 'event_loop' else ['-l','scripts/emacs/scheduling_audit.lua']
        p=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,text=True,timeout=120)
        if p.returncode: raise RuntimeError(p.stdout+p.stderr)
        row=json.loads(dest.read_text())
        row['median_ms']=statistics.median(x['ms'] for x in row['samples'])
        row['max_gap_ms']=max(g['gap'] for x in row['samples'] for g in x['scheduled'])
        row['max_stream_gap_ms']=max(g['gap'] for x in row['samples'] for g in x['scheduled'] if g['phase']=='stream')
        results.append(row)
        print(count,variant,trace,round(row['median_ms'],2),round(row['max_gap_ms'],2),round(row['max_stream_gap_ms'],2),flush=True)
report={'method':'Five measured runs plus one discarded warmup; variants are experimental harness controls, not production changes.', 'harness_sha256': {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__).resolve(), ROOT/'scripts/emacs/scheduling_audit.lua', ROOT/'scripts/emacs/scheduling_event_loop.lua']}, 'platform':platform.platform(),'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'lua').rglob('*.lua')},'results':results}
(ROOT/'doc/measurements/scheduling-audit.json').write_text(json.dumps(report,indent=2)+'\n')
