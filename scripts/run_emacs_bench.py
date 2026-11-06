#!/usr/bin/env python3
"""Serial Emacs/Neovim comparison: same bytes, full parsing, clean configs."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import statistics
import shutil
import subprocess
import tarfile
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--emacs', default=os.environ.get('EMACS', 'emacs'))
    parser.add_argument('--baseline-emacs', help='Also measure a separate installed Emacs executable')
    parser.add_argument('--compare-native', action='store_true', help='Compare byte/native libraries in the same Emacs build')
    parser.add_argument('--baseline-nvim', type=Path, help='Isolated checkout of the plugin before changes')
    parser.add_argument('--upstream', type=Path, help='Isolated checkout of upstream main')
    parser.add_argument('--reverse', action='store_true', help='Run Neovim before Emacs')
    parser.add_argument('--samples', type=int, default=7)
    parser.add_argument('--output', type=Path, default=ROOT / 'doc/measurements/emacs-comparison.json')
    args = parser.parse_args()
    assert args.samples >= 3
    results = []
    corpora = {}
    native_metadata = None
    editors = ('emacs-byte', 'emacs-native', 'nvim') if args.compare_native else ('emacs', 'nvim')
    if args.baseline_emacs:
        editors = ('emacs-original',) + editors
    if args.upstream:
        args.upstream = args.upstream.resolve()
        assert args.upstream != ROOT
        shutil.copytree(ROOT / 'scripts', args.upstream / 'scripts', dirs_exist_ok=True)
        editors += ('nvim-upstream',)
    if args.baseline_nvim:
        args.baseline_nvim = args.baseline_nvim.resolve()
        assert args.baseline_nvim != ROOT
        shutil.copytree(ROOT / 'scripts', args.baseline_nvim / 'scripts', dirs_exist_ok=True)
        editors += ('nvim-baseline',)
    if args.reverse:
        editors = tuple(reversed(editors))
    with tempfile.TemporaryDirectory(prefix='compile-emacs-') as tmp:
        directory = Path(tmp)
        native_dir = directory / 'native'
        if args.compare_native:
            native_dir.mkdir()
            proc = subprocess.run([args.emacs, '-Q', '--batch', '-l', 'scripts/emacs/prepare-native.el'],
                                  cwd=ROOT, env=dict(os.environ, BENCH_NATIVE_DIR=str(native_dir)),
                                  capture_output=True, text=True, timeout=300)
            if proc.returncode:
                raise RuntimeError((proc.stdout + proc.stderr)[-8000:])
            native_metadata = json.loads((native_dir / 'metadata.json').read_text())
            print('Prepared bytecode and native libraries in temporary directory', flush=True)
        # Rebuild exactly the historical rg fixture from committed source.
        archive = subprocess.check_output(['git', 'archive', 'a4aff49', 'lua', 'spec'], cwd=ROOT)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(directory / 'reference', filter='data')
        rg = subprocess.run(['rg', '--line-number', '--no-heading', '--color', 'never', 'a', 'lua', 'spec'],
                            cwd=directory / 'reference', capture_output=True, check=True).stdout
        # rg traversal order is not guaranteed; canonicalize once for both editors.
        rg = b'\n'.join(sorted(rg.splitlines())) + b'\n'
        fixtures = {
            'plain': ''.join(f'build step {i} complete\n' for i in range(1, 10001)).encode(),
            'errors': ''.join(f'file.c:{i}:1: error: failure\n' for i in range(1, 10001)).encode(),
            'log': rg,
        }
        for kind, data in fixtures.items():
            path = directory / f'{kind}.txt'
            path.write_bytes(data)
            corpora[kind] = {'lines': len(data.splitlines()), 'bytes': len(data),
                             'sha256': hashlib.sha256(data).hexdigest(),
                             'max_line_bytes': max(map(len, data.splitlines()))}
            for mode in ('parse', 'stream'):
                records = {}
                for editor in editors:
                    dest = directory / 'result.json'
                    dest.unlink(missing_ok=True)
                    env = dict(os.environ, BENCH_INPUT=str(path), BENCH_MODE=mode,
                               BENCH_SAMPLES=str(args.samples), BENCH_RESULT=str(dest),
                               NVIM_LOG_FILE=str(directory / 'nvim.log'))
                    if editor == 'nvim-upstream':
                        env['BENCH_UPSTREAM'] = '1'
                    if args.compare_native and editor in ('emacs-byte', 'emacs-native'):
                        env.update(BENCH_NATIVE_DIR=str(native_dir), BENCH_EMACS_CODE=editor.split('-')[1])
                    command = ([args.baseline_emacs if editor == 'emacs-original' else args.emacs, '-Q', '--batch', '-l', 'scripts/emacs/benchmark.el'] if not editor.startswith('nvim')
                               else ['nvim', '--headless', '--clean', '-u', 'scripts/minimal_init.lua',
                                     '-l', 'scripts/emacs/benchmark.lua'])
                    proc = subprocess.run(command, cwd=({'nvim-upstream': args.upstream, 'nvim-baseline': args.baseline_nvim}.get(editor) or ROOT), env=env, capture_output=True, text=True, timeout=180)
                    if proc.returncode or not dest.exists():
                        raise RuntimeError((proc.stdout + proc.stderr)[-8000:])
                    result = json.loads(dest.read_text())
                    result.update(kind=kind, editor_name=editor)
                    result['median_ms'] = statistics.median(s['ms'] for s in result['samples'])
                    result['worst_gap_ms'] = max(s['gap_ms'] for s in result['samples']) if mode == 'stream' else None
                    records[editor] = set(Path(str(dest) + '.records').read_text().splitlines())
                    expected = len(data.splitlines()) if kind != 'plain' else 0
                    assert all(s['recognized'] == expected for s in result['samples'])
                    results.append(result)
                    print(f'{kind}/{mode}/{editor}: {result["median_ms"]:.2f} ms, gap={result["worst_gap_ms"]}, recognized={result["samples"][0]["recognized"]}', flush=True)
                assert all(value == records['nvim'] for value in records.values()), 'Recognized lines differ'
                results[-1]['recognized_line_sets_equal'] = True
        files = [p for folder in ('lua', 'plugin', 'scripts') for p in (ROOT / folder).rglob('*')
                 if p.suffix in ('.lua', '.el', '.py', '.vim')]
        report = {'measured_at': datetime.now(timezone.utc).isoformat(), 'platform': platform.platform(), 'reverse_editor_order': args.reverse,
                  'emacs_executable': args.emacs, 'baseline_emacs_executable': args.baseline_emacs, 'native_preparation': native_metadata,
                  'baseline_nvim_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=args.baseline_nvim, text=True).strip() if args.baseline_nvim else None,
                  'upstream_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=args.upstream, text=True).strip() if args.upstream else None,
                  'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)},
                  'corpora': corpora, 'results': results}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')

if __name__ == '__main__':
    main()
