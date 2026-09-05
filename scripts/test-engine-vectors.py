#!/usr/bin/env python3
"""Run A4 through the binding using connectcore's existing deterministic seams.

v0.5.0's seams are private. A temporary copy changes ONLY their identifier
visibility for this test invocation. No cached module files, implementations,
expectations, or release artifacts are changed. The tagged engine remains the
implementation under test; there is no fork of its state machine.
"""
import json
import os
import shutil
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
binding = root / "android/punchbridge"
module = json.loads(subprocess.check_output(
    ["go", "list", "-m", "-json", "github.com/openrung/openrung/connectcore"], cwd=binding))
if module.get("Replace") or module["Version"] != "v0.5.0":
    sys.exit("Review the test seam adapter when changing the connectcore pin; tagged v0.5.0 required")
source = Path(module["Dir"])
names = ["probeTunnel", "healthProbe", "dialRelay", "fetchRelays", "tunnelReady",
         "requestWSSTicket", "dialWSS", "checkNetworkAlive", "lookupGeo",
         "healthTick", "heartbeatTick", "wssBridge"]
pattern = re.compile(r"\b(" + "|".join(names) + r")\b")
with tempfile.TemporaryDirectory(prefix="openrung-engine-contract-") as directory:
    temporary = Path(directory)
    module_copy = temporary / "connectcore"
    shutil.copytree(source, module_copy)
    for copied in module_copy.rglob("*"):
        copied.chmod(copied.stat().st_mode | 0o200)
    seen = set()
    for original in module_copy.glob("*.go"):
        if original.name.endswith("_test.go"):
            continue
        text = original.read_text()
        def rename(match):
            name = match.group(0)
            seen.add(name)
            return "OpenRungTest" + name[0].upper() + name[1:]
        modified = pattern.sub(rename, text)
        if modified != text:
            original.write_text(modified)
    if seen != set(names):
        sys.exit("Tagged connectcore test seams changed: " + repr(set(names) - seen))
    workspace = temporary / "go.work"
    workspace.write_text(f'go 1.25.0\nuse "{binding}"\nreplace github.com/openrung/openrung/connectcore => "{module_copy}"\n')
    environment = dict(os.environ, GOWORK=str(workspace))
    subprocess.run(["go", "test", "-tags", "openrung_contract",
                    "-run", "TestOpenRungEngineSequences", *sys.argv[1:], "."], cwd=binding, env=environment, check=True)
