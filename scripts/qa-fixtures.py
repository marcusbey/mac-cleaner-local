#!/usr/bin/env python3
"""Create only uniquely named, task-owned fixtures for native UI acceptance."""
import json, pathlib, plistlib, uuid
home = pathlib.Path.home()
run = uuid.uuid4().hex[:10]
base = home / 'Applications' / ('Cleaner UI QA ' + run)
manifest = {'run':run,'apps':[],'related':[],'remaining':[]}
for label in ['Alpha','Beta']:
    bid = 'com.cleanerqa.' + run + '.' + label.lower()
    app = base / ('Cleaner QA ' + label + '.app')
    (app/'Contents'/'MacOS').mkdir(parents=True)
    (app/'Contents'/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bid,'CFBundleName':'Cleaner QA '+label,'CFBundleVersion':'1','CFBundleShortVersionString':'1.0','CFBundlePackageType':'APPL','CFBundleExecutable':'Fixture'}))
    exe = app/'Contents'/'MacOS'/'Fixture'
    exe.write_text('#!/bin/sh\nexit 0\n');exe.chmod(0o755)
    cache = home/'Library'/'Caches'/bid
    cache.mkdir();(cache/'fixture.txt').write_text('Disposable App Cleaner QA data '+run)
    manifest['apps'].append(str(app));manifest['related'].append(str(cache))
orphan = home/'Library'/'Caches'/('org.cleanerqa.orphan'+run)
orphan.mkdir();(orphan/'fixture.txt').write_text('Disposable orphan QA data '+run)
manifest['remaining'].append(str(orphan))
out = pathlib.Path('.artifacts/acceptance');out.mkdir(parents=True,exist_ok=True)
(out/'fixtures.json').write_text(json.dumps(manifest,indent=2))
print(json.dumps(manifest,indent=2))
