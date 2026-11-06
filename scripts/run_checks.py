#!/usr/bin/env python3
"""Run each issue probe/benchmark in a fresh, bounded Neovim process."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=("issues", "benchmark"))
    parser.add_argument("--cases", help="comma-separated case names (default: all)")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--sizes", default="1000,10000")
    parser.add_argument("--timeout", type=int, default=60, help="seconds per case")
    args = parser.parse_args()
    if args.samples < 3 or args.timeout < 1:
        parser.error("use at least 3 samples and a positive timeout")
    sizes = [int(value) for value in args.sizes.split(",")]
    if not sizes or any(value <= 0 for value in sizes):
        parser.error("sizes must be positive integers")
    destination = args.output or ROOT / ".measurements" / f"{args.suite}.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, BENCH_SAMPLES=str(args.samples), BENCH_SIZES=args.sizes)
    nvim = env.get("NVIM", "nvim")
    results = []
    with tempfile.TemporaryDirectory(prefix="compile-mode-check-") as directory:
        result_file = Path(directory) / "result.json"
        env["COMPILE_MODE_RESULT"] = str(result_file)
        env["NVIM_LOG_FILE"] = str(Path(directory) / "nvim.log")

        def run(case):
            result_file.unlink(missing_ok=True)
            command = [nvim, "--headless", "--clean", "-u", "scripts/minimal_init.lua",
                       "-l", f"scripts/{args.suite}.lua", case]
            try:
                proc = subprocess.run(command, cwd=ROOT, env=env, text=True,
                                      capture_output=True, timeout=args.timeout)
            except subprocess.TimeoutExpired:
                return {"name": case, "passed": False, "error": f"timeout after {args.timeout}s"}
            if proc.returncode or not result_file.exists():
                return {"name": case, "passed": False, "error": (proc.stdout + proc.stderr)[-8000:],
                        "exit_code": proc.returncode}
            data = json.loads(result_file.read_text())
            if isinstance(data, dict) and (proc.stdout or proc.stderr):
                data["process_output"] = (proc.stdout + proc.stderr)[-8000:]
            return data

        available = run("list")
        if not isinstance(available, list):
            raise RuntimeError(f"Could not list cases: {available}")
        selected = args.cases.split(",") if args.cases else sorted(available)
        unknown = set(selected) - set(available)
        if unknown:
            parser.error(f"unknown cases: {sorted(unknown)}")
        for case in selected:
            result = run(case)
            results.append(result)
            label = "PASS" if result.get("passed", True) else "FAIL"
            detail = f" median={result['median_ms']:.3f}ms" if "median_ms" in result else ""
            print(f"{label} {case}{detail}", flush=True)

    files = sorted({p for folder in ("lua", "plugin", "ftplugin", "scripts")
                    for p in (ROOT / folder).rglob("*") if p.suffix in (".lua", ".vim", ".py")})
    digest = hashlib.sha256()
    for file in files:
        digest.update(str(file.relative_to(ROOT)).encode())
        digest.update(file.read_bytes())
    metadata = {
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "machine": platform.machine(),
        "nvim": subprocess.check_output([nvim, "--version"], text=True).splitlines()[:3],
        "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "git_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)),
        "source_sha256": digest.hexdigest(), "suite": args.suite,
        "samples": args.samples, "sizes": sizes,
        "dependencies": {},
    }
    for name in ("PLENARY_PATH", "BALEIA_PATH"):
        path = env.get(name)
        if path:
            proc = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"], text=True, capture_output=True)
            metadata["dependencies"][name] = {"path": path, "revision": proc.stdout.strip()}
    destination.write_text(json.dumps({"metadata": metadata, "results": results}, indent=2) + "\n")
    failed = sum(not result.get("passed", True) for result in results)
    print(f"{len(results) - failed} passed, {failed} failed; results: {destination}")
    return bool(failed)


if __name__ == "__main__":
    raise SystemExit(main())
