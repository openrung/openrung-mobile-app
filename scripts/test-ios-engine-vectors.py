#!/usr/bin/env python3
"""Build an isolated test framework and run unchanged A4 scenarios from Swift.

The release XCFramework is never overwritten. Only the tagged module's existing
network/clock/process seams are exposed, using the shared Go/Kotlin harness.
Requires Xcode, XcodeGen and a booted iOS simulator (IOS_SIMULATOR_UDID overrides).
"""
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from engine_contract_seams import prepare_contract_module

root = Path(__file__).resolve().parent.parent
simulator = os.environ.get("IOS_SIMULATOR_UDID")
if not simulator:
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "booted", "-j"]))
    simulator = next((d["udid"] for group in devices["devices"].values() for d in group if d["state"] == "Booted"), None)
if not simulator:
    raise SystemExit("Boot an iOS simulator or set IOS_SIMULATOR_UDID")
with tempfile.TemporaryDirectory(prefix="openrung-ios-contract-") as directory:
    temporary = Path(directory)
    core = prepare_contract_module(root / "android/punchbridge", temporary)
    staged = temporary / "repo"
    for name in ["android/punchbridge", "scripts", "testdata", "ios/scripts"]:
        shutil.copytree(root / name, staged / name)
    for name in ["package.json", "SINGBOX_VERSION", "ios/project.yml", "ios/build-libbox-release.sh"]:
        shutil.copy2(root / name, staged / name)
    with (staged / "scripts/graft-engine-binding.sh").open("a") as output:
        output.write('\n# Test-only addition inside this isolated source tree.\n')
        output.write('tail -n +3 "$binding_source/engine_contract_harness.go" > "$libbox_dest/openrung_engine_contract_harness.go"\n')
    subprocess.run(["bash", str(staged / "ios/build-libbox-release.sh")], env=dict(os.environ, CONNECTCORE_SRC=str(core)), check=True)
    framework = staged / "ios/ThirdParty/Libbox.xcframework"
    project = {
        "name": "EngineContract", "options": {"deploymentTarget": {"iOS": "16.0"}},
        "targets": {"EngineContractTests": {
            "type": "bundle.unit-test", "platform": "iOS",
            "sources": [{"path": str(root / p)} for p in ["ios/EngineContractTests", "ios/Shared/EngineEventDispatcher.swift", "ios/Shared/ConnectionStatus.swift", "ios/Shared/CountryGeo.swift"]],
            "dependencies": [{"framework": str(framework), "embed": False}, {"sdk": "Network.framework"}, {"sdk": "UIKit.framework"}, {"sdk": "libresolv.tbd"}],
            "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "com.openrung.enginecontract", "GENERATE_INFOPLIST_FILE": "YES", "CODE_SIGNING_ALLOWED": "NO", "SWIFT_VERSION": "5.0"}}}},
        "schemes": {"EngineContractTests": {"build": {"targets": {"EngineContractTests": ["test"]}}, "test": {"targets": ["EngineContractTests"]}}}}
    spec = temporary / "project.json"
    spec.write_text(json.dumps(project))
    subprocess.run(["xcodegen", "generate", "--spec", str(spec)], check=True)
    subprocess.run(["xcodebuild", "-project", str(temporary / "EngineContract.xcodeproj"), "-scheme", "EngineContractTests", "-destination", "platform=iOS Simulator,id=" + simulator,
                    "-derivedDataPath", str(temporary / "build"), "-parallel-testing-enabled", "NO", "test"], check=True)
