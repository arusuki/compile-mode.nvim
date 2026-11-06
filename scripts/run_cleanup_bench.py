#!/usr/bin/env python3
"""Compare cleanup changes with an isolated baseline in the normal event loop."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', type=Path, required=True)
parser.add_argument('--output', type=Path, default=ROOT/'doc/measurements/highlight-cleanup-comparison.json')
args = parser.parse_args()
baseline = args.baseline.resolve()
assert baseline != ROOT
shutil.copytree(ROOT/'scripts', baseline/'scripts', dirs_exist_ok=True)
results = []
with tempfile.TemporaryDirectory(prefix='compile-cleanup-') as tmp:
    for reverse in (False, True):
        for count in (10000, 100000):
            for name in (('after', 'before') if reverse else ('before', 'after')):
                directory = ROOT if name == 'after' else baseline
                dest = Path(tmp)/'result.json'
                env = dict(os.environ, AUDIT_LINES=str(count), AUDIT_SAMPLES='5', AUDIT_RESULT=str(dest), NVIM_LOG_FILE=str(Path(tmp)/'nvim.log'))
                result = subprocess.run(['nvim', '--headless', '--clean', '-u', 'scripts/minimal_init.lua', '-c', 'luafile scripts/emacs/scheduling_event_loop.lua'], cwd=directory, env=env, capture_output=True, text=True, timeout=120)
                if result.returncode:
                    raise RuntimeError(result.stdout + result.stderr)
                row = json.loads(dest.read_text())
                row.update(implementation=name, reverse=reverse)
                row['median_ms'] = statistics.median(s['ms'] for s in row['samples'])
                row['max_gap_ms'] = max(g['gap'] for s in row['samples'] for g in s['scheduled'])
                row['max_setup_gap_ms'] = max((g['gap'] for s in row['samples'] for g in s['scheduled'] if g['phase']=='setup'), default=0)
                results.append(row)
                print(reverse, count, name, round(row['median_ms'],2), round(row['max_gap_ms'],2), round(row['max_setup_gap_ms'],2), flush=True)
report = {
    'method': 'Normal event loop, 5 ms heartbeat, one warmup and five measured samples; second run reverses implementation order. Full output, recognized errors and final mark counts checked.',
    'platform': platform.platform(),
    'baseline_head': subprocess.check_output(['git','rev-parse','HEAD'],cwd=baseline,text=True).strip(),
    'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'lua').rglob('*.lua')},
    'harness_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__).resolve(),ROOT/'scripts/emacs/scheduling_event_loop.lua']},
    'results': results,
}
args.output.write_text(json.dumps(report,indent=2)+'\n')
