#!/usr/bin/env python3
"""Build the native M1 app and its independent, source-shared supervisor."""
import argparse
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile


def compile_app_icon(source, work, minimum_macos_version):
    catalog = work / "Assets.xcassets"
    iconset = catalog / "AppIcon.appiconset"
    iconset.mkdir(parents=True)
    metadata = {"author": "xcode", "version": 1}
    (catalog / "Contents.json").write_text(json.dumps({"info": metadata}), encoding="utf-8")
    images = [
        {"idiom": "mac", "size": f"{points}x{points}", "scale": f"{scale}x",
         "filename": f"AppIcon-{points * scale}.png"}
        for points in (16, 32, 128, 256, 512)
        for scale in (1, 2)
    ]
    for pixels in (16, 32, 64, 128, 256, 512):
        subprocess.run(
            ["/usr/bin/sips", "-z", str(pixels), str(pixels), str(source),
             "--out", str(iconset / f"AppIcon-{pixels}.png")],
            stdout=subprocess.DEVNULL, check=True,
        )
    shutil.copy2(source, iconset / "AppIcon-1024.png")
    (iconset / "Contents.json").write_text(
        json.dumps({"images": images, "info": metadata}), encoding="utf-8",
    )

    compiled = work / "Resources"
    compiled.mkdir()
    partial_plist = work / "AppIcon.plist"
    result = subprocess.run(
        ["xcrun", "actool", "--compile", str(compiled), "--platform", "macosx",
         "--target-device", "mac", "--minimum-deployment-target", minimum_macos_version,
         "--app-icon", "AppIcon", "--output-partial-info-plist", str(partial_plist),
         "--warnings", "--errors", "--output-format", "human-readable-text", str(catalog)],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise SystemExit(f"AppIcon compilation failed\n{result.stdout}{result.stderr}")
    with partial_plist.open("rb") as stream:
        icon_info = plistlib.load(stream)
    if not icon_info.get("CFBundleIconName"):
        raise SystemExit(f"AppIcon metadata missing\n{result.stdout}")
    return compiled, icon_info


root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
parser.add_argument("--output", type=pathlib.Path, default=root / "dist/Pikachu.app")
parser.add_argument("--bundle-id", default="ai.yuzio.pikachu")
parser.add_argument("--fixture-config", type=pathlib.Path)
parser.add_argument("--open", action="store_true", help="Open the app after building and verifying its signature.")
options = parser.parse_args()
minimum_macos_version = "27.0"
subprocess.run(["swift", "build", "--disable-sandbox", "--configuration", options.configuration, "--package-path", str(root)], check=True)
binary_dir = pathlib.Path(subprocess.check_output(
    ["swift", "build", "--disable-sandbox", "--configuration", options.configuration, "--package-path", str(root), "--show-bin-path"], text=True).strip())
app = options.output.resolve()
macos = app / "Contents/MacOS"
with tempfile.TemporaryDirectory(prefix="pikachu-app-icon-") as directory:
    resources, icon_info = compile_app_icon(
        root / "docs/design/app-icon/pikachu-appicon-square-1024.png",
        pathlib.Path(directory), minimum_macos_version,
    )
    macos.mkdir(parents=True, exist_ok=True)
    shutil.copytree(resources, app / "Contents/Resources", dirs_exist_ok=True)
    bundle = binary_dir / "Pikachu_PiRuntimeAdapter.bundle"
    shutil.copytree(bundle, app / "Contents/Resources" / bundle.name, dirs_exist_ok=True)
    logo_destination = app / "Contents/Resources/ProviderLogos"
    logo_destination.mkdir(exist_ok=True)
    for logo in (root / "PikachuApp/ProviderLogos").glob("*.png"):
        shutil.copy2(logo, logo_destination / logo.name)
    diagnostic = app / "Contents/Resources/M3Diagnostics.json"
    if options.fixture_config:
        if options.bundle_id == "ai.yuzio.pikachu":
            raise SystemExit("Diagnostic fixtures require a separate bundle identifier")
        shutil.copy2(options.fixture_config, diagnostic)
    elif diagnostic.exists():
        diagnostic.unlink()
    for name in ["Pikachu", "m0-supervisor"]:
        shutil.copy2(binary_dir / name, macos / name)
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({
            "CFBundleName": "Pikachu", "CFBundleDisplayName": "Pikachu",
            "CFBundleIdentifier": options.bundle_id, "CFBundleExecutable": "Pikachu",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1.0",
            "LSMinimumSystemVersion": minimum_macos_version, "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": True, **icon_info,
        }, stream)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(macos / "m0-supervisor")], check=True)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
# Updating Contents does not change the bundle directory's modification time.
os.utime(app, None)
print(app, flush=True)
if options.open and subprocess.run(["/usr/bin/open", str(app)]).returncode:
    raise SystemExit(f"Build succeeded, but Launch Services could not open {app}")
