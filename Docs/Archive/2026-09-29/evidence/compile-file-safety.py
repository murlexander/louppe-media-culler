import pathlib, subprocess, os
root=pathlib.Path('/private/tmp/louppe-audit-2026-09-29')
build=root/'swift-build/out'
products=build/'Products/Debug'
inter=build/'Intermediates.noindex/Louppe.build/Debug'
objs=inter/'Louppe-19F76ED9046C3B-testable-t.build/Objects-normal/arm64'
cmd=['/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc', '-sdk', '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk', '-I', str(products), '-F',str(products), '-Xcc','-fmodule-map-file='+str(build/'Intermediates.noindex/GeneratedModuleMaps/XMPBridge.modulemap'), str(root/'file-safety-harness.swift'), '-o',str(root/'file-safety-harness'), '-Xlinker','-filelist', '-Xlinker',str(objs/'Louppe-19F76ED9046C3B-testable.LinkFileList'), '-Xlinker','-filelist','-Xlinker',str(inter/'XMPBridge-t.build/Objects-normal/arm64/XMPBridge.LinkFileList'), '-framework','Sparkle','-framework','CoreServices','-lc++','-Xlinker','-rpath','-Xlinker',str(products), '-module-cache-path',str(root/'harness-module-cache')]
result=subprocess.run(cmd,capture_output=True,text=True)
print(result.stdout, result.stderr)
print('exit',result.returncode)
