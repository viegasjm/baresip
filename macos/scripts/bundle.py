#!/usr/bin/env python3
"""Create a local macOS app, including the engine and its non-system libraries."""
import pathlib, shutil, subprocess, sys, plistlib
root = pathlib.Path(__file__).resolve().parents[2]
app = root / 'macos/dist/Baresip Mac.app'
if app.exists(): shutil.rmtree(app)
contents = app / 'Contents'
macos = contents / 'MacOS'
resources = contents / 'Resources'
engine = resources / 'Engine'
libs = engine / 'lib'
for folder in [macos, libs]: folder.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'build/swift/release/BaresipMac', macos / 'BaresipMac')
shutil.copy2(root / 'build/engine/baresip', engine / 'baresip')
shutil.copytree(root / 'share', engine / 'sounds', dirs_exist_ok=True)
ca = pathlib.Path('/opt/homebrew/etc/ca-certificates/cert.pem')
if not ca.exists(): ca = pathlib.Path('/usr/local/etc/ca-certificates/cert.pem')
shutil.copy2(ca, engine / 'ca-certificates.crt')
licences = resources / 'Licenses'
licences.mkdir()
shutil.copy2(root / 'LICENSE', licences / 'Baresip.txt')
shutil.copy2(root / 'vendor/re/LICENSE', licences / 'Libre.txt')

def dependencies(file):
    return [line.strip().split(' (')[0] for line in subprocess.check_output(['otool', '-L', str(file)], text=True).splitlines()[1:]]
seen = {}
def bundle(binary, source):
    for dependency in dependencies(source):
        if dependency.startswith(('/usr/lib/', '/System/Library/')): continue
        path = pathlib.Path(dependency)
        if dependency.startswith('@loader_path/'):
            path = source.parent / dependency.removeprefix('@loader_path/')
        if dependency.startswith('@rpath/'):
            name = path.name
            options = [source.parent / name, root / 'build/deps/lib' / name, pathlib.Path('/opt/homebrew/lib') / name]
            path = next((x for x in options if x.exists()), path)
        if path.resolve() == source.resolve(): continue
        if not path.exists(): raise RuntimeError(f'Cannot resolve library {dependency} from {source}')
        target = libs / path.name
        if path.name not in seen:
            seen[path.name] = path
            shutil.copy2(path.resolve(), target)
            target.chmod(0o755)
            bundle(target, path.resolve())
            subprocess.run(['install_name_tool', '-id', '@rpath/' + path.name, str(target)], check=True)
        replacement = ('@loader_path/lib/' if binary == engine / 'baresip' else '@loader_path/') + path.name
        subprocess.run(['install_name_tool', '-change', dependency, replacement, str(binary)], check=True)
bundle(engine / 'baresip', root / 'build/engine/baresip')
# Preserve notices from every bundled Homebrew dependency, including transitives.
for source in seen.values():
    resolved = source.resolve()
    if 'Cellar' not in resolved.parts: continue
    index = resolved.parts.index('Cellar')
    prefix = pathlib.Path(*resolved.parts[:index + 3])
    package = resolved.parts[index + 1]
    for pattern in ['LICENSE*', 'COPY*', 'AUTHORS*', 'README.ijg']:
        for file in prefix.rglob(pattern):
            if file.is_file():
                label = '-'.join(file.relative_to(prefix).parts)
                shutil.copy2(file, licences / (package + '-' + label))

info = dict(CFBundleName='Baresip Mac', CFBundleDisplayName='Baresip Mac', CFBundleIdentifier='com.viegasjm.baresip-mac', CFBundleExecutable='BaresipMac', CFBundlePackageType='APPL', CFBundleShortVersionString='0.1.6', CFBundleVersion='7', LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True, NSMicrophoneUsageDescription='Baresip Mac uses your microphone for SIP calls.', NSPrincipalClass='NSApplication')
with (contents / 'Info.plist').open('wb') as file: plistlib.dump(info, file)
for binary in [*libs.iterdir(), engine / 'baresip', macos / 'BaresipMac']:
    subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True, capture_output=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
print(app)
