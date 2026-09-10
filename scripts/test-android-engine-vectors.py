#!/usr/bin/env python3
"""Build an isolated JNI test AAR and run A4 via the Kotlin dispatcher on an emulator.

Requires one adb device (ANDROID_SERIAL selects it). No release AAR is overwritten.
The scenario factory and exposed remote seams exist only in the temporary test build.
"""
import os, shutil, subprocess, tempfile
from pathlib import Path
from engine_contract_seams import prepare_contract_module

root = Path(__file__).resolve().parent.parent
sdk = Path(os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk")))
adb = str(sdk / "platform-tools/adb")
abi = subprocess.check_output([adb, "shell", "getprop", "ro.product.cpu.abi"], text=True).strip()
if abi not in {"arm64-v8a", "x86_64", "x86", "armeabi-v7a"}:
    raise SystemExit("Unsupported or unavailable test device ABI: " + abi)
with tempfile.TemporaryDirectory(prefix="openrung-android-contract-") as directory:
    temporary = Path(directory)
    core = prepare_contract_module(root / "android/punchbridge", temporary)
    staged = temporary / "repo"
    for name in ["android/punchbridge", "scripts", "testdata"]:
        shutil.copytree(root / name, staged / name)
    for name in ["package.json", "SINGBOX_VERSION", "android/build-libbox-release.sh"]:
        shutil.copy2(root / name, staged / name)
    graft = staged / "scripts/graft-engine-binding.sh"
    with graft.open("a") as output:
        output.write('\n# Test-only addition inside this isolated source tree.\n')
        output.write('tail -n +3 "$binding_source/engine_contract_harness.go" > "$libbox_dest/openrung_engine_contract_harness.go"\n')
    environment = dict(os.environ, CONNECTCORE_SRC=str(core))
    subprocess.run(["bash", str(staged / "android/build-libbox-release.sh")], env=environment, check=True)
    aar = staged / "android/app/libs/libbox.aar"
    subprocess.run([str(root / "android/gradlew"), "-p", str(root / "android"), "--no-daemon",
        "-PopenrungEngineContractAar=" + str(aar), "-PreactNativeArchitectures=" + abi,
        ":app:connectedDebugAndroidTest", "--stacktrace"], check=True)
