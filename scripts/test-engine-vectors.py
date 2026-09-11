#!/usr/bin/env python3
"""Run A4 through the binding using connectcore's existing deterministic seams.

v0.6.1's seams are private. A temporary copy changes ONLY their identifier
visibility for this test invocation. No cached module files, implementations,
expectations, or release artifacts are changed. The tagged engine remains the
implementation under test; there is no fork of its state machine.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from engine_contract_seams import prepare_contract_module

root = Path(__file__).resolve().parent.parent
binding = root / "android/punchbridge"
with tempfile.TemporaryDirectory(prefix="openrung-engine-contract-") as directory:
    temporary = Path(directory)
    module_copy = prepare_contract_module(binding, temporary)
    workspace = temporary / "go.work"
    workspace.write_text(f'go 1.25.0\nuse "{binding}"\nreplace github.com/openrung/openrung/connectcore => "{module_copy}"\n')
    environment = dict(os.environ, GOWORK=str(workspace))
    subprocess.run(["go", "test", "-tags", "openrung_contract",
                    "-run", "TestOpenRungEngineSequences", *sys.argv[1:], "."], cwd=binding, env=environment, check=True)
