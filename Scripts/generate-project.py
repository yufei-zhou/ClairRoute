#!/usr/bin/env python3
"""Regenerate the checked-in Xcode project; no package manager or build side effects."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parent.parent
project = root/'ClairRoute.xcodeproj'
project.mkdir(exist_ok=True)
objects = {}

def oid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(object_key, isa, **fields):
    key=oid(object_key); objects[key]={'isa':isa,**fields}; return key
def plist(value, depth=0):
    if isinstance(value,dict):
        return '{\n'+''.join('\t'*(depth+1)+json.dumps(str(k))+ ' = '+plist(v,depth+1)+';\n' for k,v in value.items())+'\t'*depth+'}'
    if isinstance(value,list): return '(\n'+''.join('\t'*(depth+1)+plist(v,depth+1)+',\n' for v in value)+'\t'*depth+')'
    return json.dumps(str(value))

refs={}
for directory in ['App','Shared','Helper']:
    for p in sorted((root/directory).glob('*.swift')):
        path=p.relative_to(root).as_posix()
        refs[path]=obj(path,'PBXFileReference',lastKnownFileType='sourcecode.swift',path=path,sourceTree='<group>')
resources=['Resources/mihomo','Resources/CoreManifest.json','Resources/mihomo-LICENSE','Resources/THIRD-PARTY-NOTICES.txt','Resources/geosite.dat','Resources/GeoManifest.json','Resources/AppIcon.icns','README.md']
for path in resources+['Resources/local.nano.ClairRoute.Helper.plist','Resources/local.nano.ClairRoute.RecoveryGuard.plist']:
    filetype = 'image.icns' if path.endswith('.icns') else ('compiled.mach-o.executable' if path.endswith('mihomo') else 'text')
    refs[path]=obj(path,'PBXFileReference',lastKnownFileType=filetype,path=path,sourceTree='<group>')
appProduct=obj('AppProduct','PBXFileReference',explicitFileType='wrapper.application',includeInIndex=0,path='ClairRoute.app',sourceTree='BUILT_PRODUCTS_DIR')
helperProduct=obj('HelperProduct','PBXFileReference',explicitFileType='compiled.mach-o.executable',includeInIndex=0,path='ClairRouteHelper',sourceTree='BUILT_PRODUCTS_DIR')
guardProduct=obj('GuardProduct','PBXFileReference',explicitFileType='compiled.mach-o.executable',includeInIndex=0,path='ClairRouteRecoveryGuard',sourceTree='BUILT_PRODUCTS_DIR')
scriptsRef=obj('MaintenanceScripts','PBXFileReference',lastKnownFileType='folder',path='Scripts',sourceTree='<group>')
products=obj('Products','PBXGroup',name='Products',children=[appProduct,helperProduct,guardProduct],sourceTree='<group>')
groups=[]
for directory in ['App','Shared','Helper','Resources']:
    groups.append(obj('Group'+directory,'PBXGroup',name=directory,children=[v for k,v in refs.items() if k.startswith(directory+'/')],sourceTree='<group>'))
main=obj('MainGroup','PBXGroup',children=groups+[refs['README.md'],scriptsRef,products],sourceTree='<group>')

def buildref(target,path,ref=None,settings=None):
    data={'fileRef':ref or refs[path]}
    if settings: data['settings']=settings
    return obj(target+'build'+path,'PBXBuildFile',**data)
def sources(target,dirs):
    return obj(target+'sources','PBXSourcesBuildPhase',buildActionMask=2147483647,
        files=[buildref(target,p) for p in refs if p.endswith('.swift') and p.split('/')[0] in dirs],runOnlyForDeploymentPostprocessing=0)

common={'MACOSX_DEPLOYMENT_TARGET':'26.0','SDKROOT':'macosx','ARCHS':'arm64',
        'SWIFT_VERSION':'6.0','SWIFT_STRICT_CONCURRENCY':'complete',
        'CLANG_ENABLE_MODULES':'YES','ENABLE_HARDENED_RUNTIME':'YES','ENABLE_APP_SANDBOX':'NO',
        'CODE_SIGN_STYLE':'Manual','CODE_SIGNING_ALLOWED':'NO','CODE_SIGN_IDENTITY':'-',
        'CODE_SIGN_INJECT_BASE_ENTITLEMENTS':'NO','CLAIRROUTE_CERT_SHA1':'',
        'COPY_PHASE_STRIP':'NO','ALWAYS_SEARCH_USER_PATHS':'NO'}
def configs(name,extra):
    ids=[]
    for configuration in ['Debug','Release']:
        settings={**common,**extra,'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if configuration=='Debug' else '-O',
            'DEBUG_INFORMATION_FORMAT':'dwarf' if configuration=='Debug' else 'dwarf-with-dsym'}
        ids.append(obj(name+configuration,'XCBuildConfiguration',buildSettings=settings,name=configuration))
    return obj(name+'configlist','XCConfigurationList',buildConfigurations=ids,defaultConfigurationIsVisible=0,defaultConfigurationName='Debug')

helperTarget=oid('HelperTarget')
proxy=obj('HelperProxy','PBXContainerItemProxy',containerPortal=oid('Project'),proxyType=1,remoteGlobalIDString=helperTarget,remoteInfo='ClairRouteHelper')
dep=obj('HelperDependency','PBXTargetDependency',target=helperTarget,targetProxy=proxy)
helperSources=sources('Helper',{'Helper','Shared'})
helperFrameworks=obj('HelperFrameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)
obj('HelperTarget','PBXNativeTarget',buildConfigurationList=configs('Helper',{
        'PRODUCT_NAME':'ClairRouteHelper','PRODUCT_BUNDLE_IDENTIFIER':'local.nano.ClairRoute.Helper',
        'INFOPLIST_FILE':'Resources/Helper-Info.plist','CREATE_INFOPLIST_SECTION_IN_BINARY':'YES',
        'GENERATE_INFOPLIST_FILE':'NO','SKIP_INSTALL':'YES'}),
    buildPhases=[helperSources,helperFrameworks],buildRules=[],dependencies=[],name='ClairRouteHelper',
    productName='ClairRouteHelper',productReference=helperProduct,productType='com.apple.product-type.tool')
guardTarget=obj('GuardTarget','PBXNativeTarget',buildConfigurationList=configs('Guard',{
        'PRODUCT_NAME':'ClairRouteRecoveryGuard','PRODUCT_BUNDLE_IDENTIFIER':'local.nano.ClairRoute.RecoveryGuard',
        'INFOPLIST_FILE':'Resources/Helper-Info.plist','CREATE_INFOPLIST_SECTION_IN_BINARY':'YES',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'CLAIRROUTE_RECOVERY_GUARD',
        'GENERATE_INFOPLIST_FILE':'NO','SKIP_INSTALL':'YES'}),
    buildPhases=[sources('Guard',{'Helper','Shared'}),obj('GuardFrameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)],
    buildRules=[],dependencies=[],name='ClairRouteRecoveryGuard',productName='ClairRouteRecoveryGuard',productReference=guardProduct,productType='com.apple.product-type.tool')
guardProxy=obj('GuardProxy','PBXContainerItemProxy',containerPortal=oid('Project'),proxyType=1,remoteGlobalIDString=guardTarget,remoteInfo='ClairRouteRecoveryGuard')
guardDep=obj('GuardDependency','PBXTargetDependency',target=guardTarget,targetProxy=guardProxy)
appSources=sources('App',{'App','Shared'})
appFrameworks=obj('AppFrameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)
appResources=obj('AppResources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=[buildref('App',p) for p in resources]+[buildref('App','MaintenanceScripts',scriptsRef)],runOnlyForDeploymentPostprocessing=0)
embedHelper=obj('EmbedHelper','PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=6,
    files=[buildref('App','EmbeddedHelper',helperProduct,{'ATTRIBUTES':['CodeSignOnCopy']}),buildref('App','EmbeddedGuard',guardProduct,{'ATTRIBUTES':['CodeSignOnCopy']})],name='Embed privileged helpers',runOnlyForDeploymentPostprocessing=0)
embedDaemon=obj('EmbedDaemon','PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='Contents/Library/LaunchDaemons',dstSubfolderSpec=1,
    files=[buildref('App','Resources/local.nano.ClairRoute.Helper.plist'),buildref('App','Resources/local.nano.ClairRoute.RecoveryGuard.plist')],name='Embed service definitions',runOnlyForDeploymentPostprocessing=0)
appTarget=obj('AppTarget','PBXNativeTarget',buildConfigurationList=configs('App',{
        'PRODUCT_NAME':'ClairRoute','PRODUCT_BUNDLE_IDENTIFIER':'local.nano.ClairRoute',
        'INFOPLIST_FILE':'Resources/App-Info.plist','GENERATE_INFOPLIST_FILE':'NO',
        'LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/../Frameworks']}),
    buildPhases=[appSources,appFrameworks,appResources,embedHelper,embedDaemon],buildRules=[],dependencies=[dep,guardDep],name='ClairRoute',productName='ClairRoute',productReference=appProduct,productType='com.apple.product-type.application')
proj=obj('Project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2700'},
    buildConfigurationList=configs('Project',{}),compatibilityVersion='Xcode 14.0',developmentRegion='en',knownRegions=['en','zh-Hans','Base'],mainGroup=main,productRefGroup=products,projectDirPath='',projectRoot='',targets=[appTarget,helperTarget,guardTarget])
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n'+plist({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':proj})+'\n')
schemes=project/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
(schemes/'ClairRoute.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES" buildForTesting="NO">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{appTarget}" BuildableName="ClairRoute.app" BlueprintName="ClairRoute" ReferencedContainer="container:ClairRoute.xcodeproj"/>
  </BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO">
  <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{appTarget}" BuildableName="ClairRoute.app" BlueprintName="ClairRoute" ReferencedContainer="container:ClairRoute.xcodeproj"/></BuildableProductRunnable>
 </LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print('Generated ClairRoute.xcodeproj and shared scheme.')
