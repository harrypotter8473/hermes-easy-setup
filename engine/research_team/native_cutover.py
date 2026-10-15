"""Detach only the four selected research profiles from an existing Hermes host.

Task Scheduler ownership and backup are checked by the installer first. This
helper never kills a process, stops the personal gateway, or deletes history.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import re
import sys
import time


def detach(source, home, names, timeout=30):
    if len(names) != 4 or len(set(names)) != 4 or any(
            not re.fullmatch(r"research-(lead|scout|worker|reviewer)", n) for n in names):
        raise ValueError("ResearchProfileSetRejected")
    # Inspect the supplied path before resolve() can hide a junction/symlink.
    source, home = Path(os.path.abspath(source)), Path(os.path.abspath(home))
    for path in (source, home, *(home / "profiles" / name for name in names)):
        if not path.is_dir() or path.is_symlink():
            raise ValueError("ResearchProfilePathRejected")
        for part in (path, *path.parents):
            if getattr(part.lstat(), "st_file_attributes", 0) & 0x400:
                raise ValueError("ResearchProfilePathRejected")
    os.environ["HERMES_HOME"] = str(home)
    sys.path[:0] = [str(source), str(source / "venv" / "Lib" / "site-packages")]
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        from gateway.status import get_running_pid, get_runtime_status_running_pid, read_runtime_status
        # Modern multiplexers support per-profile detachment. Older Hermes may
        # have only standalone tasks; those must already be stopped by setup.
        try:
            from gateway.control_socket import request_unserve_profile
        except ImportError:
            request_unserve_profile = None
        candidates = [home] + [p for p in (home / "profiles").iterdir()
                               if p.is_dir() and not p.is_symlink()
                               and not getattr(p.lstat(), "st_file_attributes", 0) & 0x400]
        deadline = time.monotonic() + timeout
        requested = set()
        selected_homes = {home / "profiles" / name for name in names}
        while True:
            active, unknown_routing = [], []
            for candidate in candidates:
                runtime = read_runtime_status(candidate / "gateway_state.json")
                runtime_pid = get_runtime_status_running_pid(runtime or {}, expected_home=candidate)
                # A multiplexer owns only its host PID file. Served profiles
                # generally have no PID/status file, so probing them alone can
                # falsely report all four stopped when the host record is lost.
                pid = get_running_pid(candidate / "gateway.pid", cleanup_stale=False) or runtime_pid
                if pid:
                    if candidate in selected_homes:
                        active.append(candidate.name)
                        continue
                    served = runtime.get("served_profiles") if isinstance(runtime, dict) else None
                    if (runtime_pid != pid or not isinstance(served, list) or
                            any(not isinstance(name, str) or not name for name in served) or
                            len(served) != len(set(served))):
                        # Neither absent metadata nor an old runtime record is
                        # proof of detachment. Do not stop the personal host or
                        # start a second response path while its roster is unknown.
                        unknown_routing.append(candidate.name)
                        continue
                    for name in names:
                        if name in served:
                            active.append(name)
                            key = (str(candidate), name)
                            if request_unserve_profile is not None and key not in requested:
                                request_unserve_profile(candidate, name)
                                requested.add(key)
            if not active and not unknown_routing:
                return {"detached": True, "profiles": names}
            if time.monotonic() >= deadline:
                return {"detached": False, "profiles": sorted(set(active)),
                        "reason": "ExistingGatewayRoutingUnverified" if unknown_routing else "ExistingResearchGatewayStillRunning"}
            time.sleep(.25)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--home", required=True)
    parser.add_argument("--profiles", required=True)
    args = parser.parse_args()
    try:
        answer = detach(args.source, args.home, args.profiles.split(","))
    except Exception as error:
        answer = {"detached": False, "reason": type(error).__name__}
    print(json.dumps(answer))
    return 0 if answer["detached"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
