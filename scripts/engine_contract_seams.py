"""Expose only test seam identifiers in a private copy of the pinned module."""
import json, re, shutil, subprocess, sys
from pathlib import Path

def prepare_contract_module(binding, temporary):
    module = json.loads(subprocess.check_output(
        ["go", "list", "-m", "-json", "github.com/openrung/openrung/connectcore"], cwd=binding))
    if module.get("Replace") or module["Version"] != "v0.6.1":
        sys.exit("Review the test seam adapter when changing the connectcore pin; tagged v0.6.1 required")
    source = Path(module["Dir"])
    names = ["probeTunnel", "healthProbe", "dialRelay", "fetchRelays", "tunnelReady",
             "requestWSSTicket", "dialWSS", "checkNetworkAlive", "lookupGeo",
             "healthTick", "heartbeatTick", "wssBridge"]
    pattern = re.compile(r"\b(" + "|".join(names) + r")\b")
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
    return module_copy
