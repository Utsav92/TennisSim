"""Generates TennisSim.xcodeproj (macOS app + iOS app sharing game/rendering/C++ code). Run after adding/removing files."""
import os, hashlib
root = os.path.dirname(os.path.abspath(__file__))
base = os.path.join(root, 'TennisSim')

def walk(sub, exts):
    out = []
    for d, _, fs in os.walk(os.path.join(base, sub)):
        for f in fs:
            if f.endswith(exts): out.append(os.path.relpath(os.path.join(d, f), base))
    return sorted(out)

def ident(s): return hashlib.md5(s.encode()).hexdigest()[:24].upper()
exts = ('.swift', '.metal', '.cpp')
shared = [s for sub in ('Game', 'Input', 'Rendering', 'Sim', 'Audio') for s in walk(sub, exts)] + ['App/SettingsStore.swift']
mac_only = ['App/main.swift', 'App/AppDelegate.swift', 'App/SelfTest.swift', 'App/SnapshotTool.swift']
ios_only = walk('iOS', exts)
headers = walk('Sim', ('.h',)) + ['TennisSim-Bridging-Header.h']
objs = walk('Assets', ('.obj', '.hum'))
for f in shared + mac_only + ios_only + headers + objs: assert os.path.exists(os.path.join(base, f)), f

def ftype(s):
    return {'.swift': 'sourcecode.swift', '.metal': 'sourcecode.metal', '.cpp': 'sourcecode.cpp.cpp', '.h': 'sourcecode.c.h', '.obj': 'text', '.hum': 'file'}[os.path.splitext(s)[1]]

o = ['// !$*UTF8*$!', '{', 'archiveVersion = 1;', 'classes = {};', 'objectVersion = 60;', 'objects = {']
allfiles = shared + mac_only + ios_only + headers + objs
fref = {f: ident('fr' + f) for f in allfiles}

targets = [
    dict(name='TennisSim', srcs=shared + mac_only, fw=['Metal', 'MetalKit', 'MetalFX', 'GameController', 'AVFoundation', 'AppKit'], product='TennisSim.app',
         settings='SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 26.0; INFOPLIST_KEY_NSPrincipalClass = NSApplication; '
                  'PRODUCT_BUNDLE_IDENTIFIER = com.utsav.TennisSim; CODE_SIGN_IDENTITY = "-"; ENABLE_HARDENED_RUNTIME = NO; '
                  'INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.sports-games";'),
    dict(name='TennisSim-iOS', srcs=shared + ios_only, fw=['Metal', 'MetalKit', 'GameController', 'AVFoundation', 'UIKit'], product='TennisSim-iOS.app',
         settings='SDKROOT = iphoneos; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; IPHONEOS_DEPLOYMENT_TARGET = 26.0; '
                  'TARGETED_DEVICE_FAMILY = "1,2"; PRODUCT_BUNDLE_IDENTIFIER = com.utsav.TennisSim.ios; '
                  'INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; '
                  'INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"; '
                  '"OTHER_LDFLAGS[sdk=iphoneos*]" = "-framework MetalFX"; INFOPLIST_KEY_UIRequiresFullScreen = YES; INFOPLIST_KEY_UIStatusBarHidden = YES; CODE_SIGN_STYLE = Automatic;'),
]
for t in targets:
    n = t['name']
    t['bf'] = {s: ident(f'bf{n}{s}') for s in t['srcs']}
    t['rbf'] = {s: ident(f'rbf{n}{s}') for s in objs}
    t['fwref'] = {f: ident(f'ffr{n}{f}') for f in t['fw']}
    t['fwbf'] = {f: ident(f'fbf{n}{f}') for f in t['fw']}
    for k in ('app', 'tgt', 'srcp', 'fwp', 'resp', 'cfgt', 'dbg', 'rel'): t[k] = ident(f'{k}{n}')

MAIN, GRP, PROD, PROJ, CFGP, DBGP, RELP = [ident(x) for x in 'main grp prod proj cfgp dbgp relp'.split()]

o.append('/* Begin PBXBuildFile section */')
for t in targets:
    for s in t['srcs']:
        if not s.endswith('.h'): o.append(f'{t["bf"][s]} = {{isa = PBXBuildFile; fileRef = {fref[s]};}};')
    for x in objs: o.append(f'{t["rbf"][x]} = {{isa = PBXBuildFile; fileRef = {fref[x]};}};')
    for f in t['fw']: o.append(f'{t["fwbf"][f]} = {{isa = PBXBuildFile; fileRef = {t["fwref"][f]};}};')
o.append('/* End PBXBuildFile section */')
o.append('/* Begin PBXFileReference section */')
for f in allfiles: o.append(f'{fref[f]} = {{isa = PBXFileReference; lastKnownFileType = {ftype(f)}; path = "{f}"; sourceTree = "<group>";}};')
for t in targets:
    for f in t['fw']:
        o.append(f'{t["fwref"][f]} = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {f}.framework; path = System/Library/Frameworks/{f}.framework; sourceTree = SDKROOT;}};')
    o.append(f'{t["app"]} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {t["product"]}; sourceTree = BUILT_PRODUCTS_DIR;}};')
o.append('/* End PBXFileReference section */')
o.append('/* Begin PBXFrameworksBuildPhase section */')
for t in targets:
    o.append(f'{t["fwp"]} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({",".join(t["fwbf"][f] for f in t["fw"])}); runOnlyForDeploymentPostprocessing = 0;}};')
o.append('/* End PBXFrameworksBuildPhase section */')
o.append('/* Begin PBXGroup section */')
o.append(f'{MAIN} = {{isa = PBXGroup; children = ({GRP}, {PROD}); sourceTree = "<group>";}};')
o.append(f'{PROD} = {{isa = PBXGroup; children = ({",".join(t["app"] for t in targets)}); name = Products; sourceTree = "<group>";}};')
o.append(f'{GRP} = {{isa = PBXGroup; children = ({",".join(fref[f] for f in allfiles)}); path = TennisSim; sourceTree = "<group>";}};')
o.append('/* End PBXGroup section */')
o.append('/* Begin PBXNativeTarget section */')
for t in targets:
    o.append(f'{t["tgt"]} = {{isa = PBXNativeTarget; buildConfigurationList = {t["cfgt"]}; buildPhases = ({t["srcp"]}, {t["fwp"]}, {t["resp"]}); buildRules = (); dependencies = (); name = "{t["name"]}"; productName = "{t["name"]}"; productReference = {t["app"]}; productType = "com.apple.product-type.application";}};')
o.append('/* End PBXNativeTarget section */')
o.append('/* Begin PBXProject section */')
o.append(f'{PROJ} = {{isa = PBXProject; attributes = {{LastUpgradeCheck = 2700;}}; buildConfigurationList = {CFGP}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {MAIN}; productRefGroup = {PROD}; projectDirPath = ""; projectRoot = ""; targets = ({",".join(t["tgt"] for t in targets)});}};')
o.append('/* End PBXProject section */')
o.append('/* Begin PBXResourcesBuildPhase section */')
for t in targets:
    o.append(f'{t["resp"]} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(t["rbf"][x] for x in objs)}); runOnlyForDeploymentPostprocessing = 0;}};')
o.append('/* End PBXResourcesBuildPhase section */')
o.append('/* Begin PBXSourcesBuildPhase section */')
for t in targets:
    o.append(f'{t["srcp"]} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(t["bf"][s] for s in t["srcs"] if not s.endswith(".h"))}); runOnlyForDeploymentPostprocessing = 0;}};')
o.append('/* End PBXSourcesBuildPhase section */')
o.append('/* Begin XCBuildConfiguration section */')
common = ('SWIFT_OBJC_BRIDGING_HEADER = "TennisSim/TennisSim-Bridging-Header.h"; HEADER_SEARCH_PATHS = "$(SRCROOT)/TennisSim"; '
          'CLANG_CXX_LANGUAGE_STANDARD = "c++20"; SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES; ONLY_ACTIVE_ARCH = NO;')
o.append(f'{DBGP} = {{isa = XCBuildConfiguration; buildSettings = {{{common} SWIFT_OPTIMIZATION_LEVEL = "-Onone"; MTL_ENABLE_DEBUG_INFO = YES;}}; name = Debug;}};')
o.append(f'{RELP} = {{isa = XCBuildConfiguration; buildSettings = {{{common} SWIFT_OPTIMIZATION_LEVEL = "-O"; SWIFT_COMPILATION_MODE = wholemodule;}}; name = Release;}};')
for t in targets:
    s = f'PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleDisplayName = TennisSim; CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 0.1; {t["settings"]}'
    o.append(f'{t["dbg"]} = {{isa = XCBuildConfiguration; buildSettings = {{{s}}}; name = Debug;}};')
    o.append(f'{t["rel"]} = {{isa = XCBuildConfiguration; buildSettings = {{{s}}}; name = Release;}};')
o.append('/* End XCBuildConfiguration section */')
o.append('/* Begin XCConfigurationList section */')
o.append(f'{CFGP} = {{isa = XCConfigurationList; buildConfigurations = ({DBGP}, {RELP}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}};')
for t in targets:
    o.append(f'{t["cfgt"]} = {{isa = XCConfigurationList; buildConfigurations = ({t["dbg"]}, {t["rel"]}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}};')
o.append('/* End XCConfigurationList section */')
o += ['};', f'rootObject = {PROJ};', '}']
pd = os.path.join(root, 'TennisSim.xcodeproj'); os.makedirs(pd, exist_ok=True)
open(os.path.join(pd, 'project.pbxproj'), 'w').write('\n'.join(o))
print('shared', len(shared), 'mac', len(mac_only), 'ios', len(ios_only))
