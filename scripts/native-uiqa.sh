#!/usr/bin/env bash
# Explicit, serial, headless interaction QA on one receipt-bound simulator.
# Never launches Simulator.app, downloads a runtime, erases a device, or touches other devices.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-inspect}"
if [[ $# -gt 0 ]]; then shift; fi
SOURCE="$ROOT"
EVIDENCE="$ROOT/.coordination/native-uiqa"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root) SOURCE="$2"; shift 2 ;;
    --evidence-root) EVIDENCE="$2"; shift 2 ;;
    --runtime-identifier) RUNTIME="$2"; shift 2 ;;
    *) echo "Unknown option." >&2; exit 2 ;;
  esac
done
[[ "$MODE" == inspect || "$MODE" == run ]] || { echo "Use inspect or run." >&2; exit 2; }
if [[ "$MODE" == inspect ]]; then
  python3 - <<'PY'
import json,subprocess
for kind in ('runtimes','devices'):
    value=json.loads(subprocess.check_output(['xcrun','simctl','list',kind,'-j']))[kind]
    if kind=='runtimes': value=[{k:r[k] for k in ('name','identifier','isAvailable')} for r in value]
    else: value=[{'name':d['name'],'udid':d['udid'],'state':d['state'],'runtime':r} for r,ds in value.items() for d in ds if d.get('isAvailable')]
    print(json.dumps({kind:value}))
PY
  exit 0
fi
SOURCE="$(cd "$SOURCE" && pwd)"
[[ "$EVIDENCE" == /*/.coordination/* ]] || { echo "Evidence must use an absolute private .coordination path." >&2; exit 2; }
[[ -d "$SOURCE/apple/Frameworks/HgsCore.xcframework" ]] || { echo "Build the matching core XCFramework before UI QA." >&2; exit 1; }
[[ -f "$SOURCE/apple/HomeGardenStudioUITests/NativeInteractionTests.swift" ]] || { echo "UI test source is missing." >&2; exit 1; }
command -v xcodegen >/dev/null
code=0
CLEANER="$HOME/ashcode/diskcleaner/bin/diskcleaner"
if [[ -x "$CLEANER" ]]; then
  "$CLEANER" check --no-tui || code=$?
elif [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  # Hosted runners do not have the owner's local cleaner. Check available bytes;
  # never remove caches, install a cleaner, or download a simulator runtime.
  python3 - "$SOURCE" <<'PY'
import shutil,sys
if shutil.disk_usage(sys.argv[1]).free < 10_000_000_000:
    sys.exit('Headless QA requires at least 10 GB available on the hosted runner.')
PY
else
  echo "Local native QA requires the installed diskcleaner preflight." >&2
  exit 1
fi
[[ "$code" == 0 || "$code" == 10 ]] || exit "$code"
mkdir -p "$EVIDENCE"
LOCK="$EVIDENCE/run.lock"
mkdir "$LOCK" 2>/dev/null || { echo "This QA evidence directory already has an active lock. Inspect its owner; do not remove another run's lock." >&2; exit 1; }
printf '%s\n' "$$" > "$LOCK/pid"
DEVICE=""
BOOTED=0
cleanup() {
  local result=$?
  trap - EXIT
  if [[ "$BOOTED" == 1 ]]; then
    bounded_command "$ATTEMPT/shutdown.log" 60 xcrun simctl shutdown "$DEVICE" || result=1
    python3 - "$DEVICE" "$ATTEMPT/lifecycle.json" <<'PY' || result=1
import json,pathlib,subprocess,sys
devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','-j'],timeout=30))['devices']
states=[d['state'] for group in devices.values() for d in group if d['udid']==sys.argv[1]]
pathlib.Path(sys.argv[2]).write_text(json.dumps({'device_udid':sys.argv[1],'shutdown_confirmed':states==['Shutdown']})+'\n')
sys.exit(0 if states==['Shutdown'] else 1)
PY
  fi
  if [[ -f "$LOCK/pid" && "$(cat "$LOCK/pid")" == "$$" ]]; then rm "$LOCK/pid"; rmdir "$LOCK"; fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ATTEMPT="$EVIDENCE/$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
mkdir "$ATTEMPT"
DEVICE="$(python3 - "$EVIDENCE/device.json" "$SOURCE" "$ATTEMPT" "$RUNTIME" <<'PY'
import hashlib,json,pathlib,subprocess,sys,uuid
receipt=pathlib.Path(sys.argv[1]); source=pathlib.Path(sys.argv[2]); out=pathlib.Path(sys.argv[3])
runtime=sys.argv[4]; device_type='com.apple.CoreSimulator.SimDeviceType.iPhone-16'
run=lambda args:subprocess.check_output(args,text=True)
def require(condition,message='Invalid simulator ownership receipt or runtime.'):
    if not condition:raise ValueError(message)
runtimes=json.loads(run(['xcrun','simctl','list','runtimes','-j']))['runtimes']
require(runtime.startswith('com.apple.CoreSimulator.SimRuntime.iOS-26-'))
require(any(r['identifier']==runtime and r.get('isAvailable') for r in runtimes),'Required installed iOS26 runtime is unavailable; no download attempted.')
devices=json.loads(run(['xcrun','simctl','list','devices','-j']))['devices']
if receipt.exists():
    owned=json.loads(receipt.read_text())
    require(owned['owner']=='homegardenstudio/native-uiqa' and owned['runtime']==runtime)
    require(owned['name'].startswith('HGS Native UIQA ') and owned['device_type']==device_type)
    match=[d for d in devices.get(runtime,[]) if d['udid']==owned['udid']]
    require(len(match)==1 and match[0]['name']==owned['name'] and match[0]['state']=='Shutdown' and match[0]['deviceTypeIdentifier']==device_type,'Receipt device is missing, renamed, changed, or already running; refusing to take it over.')
else:
    name='HGS Native UIQA '+uuid.uuid4().hex[:12]
    require(all(d['name']!=name for ds in devices.values() for d in ds))
    device=run(['xcrun','simctl','create',name,device_type,runtime]).strip()
    uuid.UUID(device)
    owned={'owner':'homegardenstudio/native-uiqa','name':name,'udid':device,'runtime':runtime,'device_type':device_type}
    with receipt.open('x') as f:json.dump(owned,f,indent=2)
identity={'device':owned,'source_commit':run(['git','-C',str(source),'rev-parse','HEAD']).strip(),
          'source_diff_sha256':hashlib.sha256(subprocess.check_output(['git','-C',str(source),'diff','HEAD'])).hexdigest(),
          'source_dirty':bool(run(['git','-C',str(source),'status','--porcelain']))}
identity['qa_source_sha256']={name:hashlib.sha256((source/name).read_bytes()).hexdigest() for name in
    ('apple/HomeGardenStudioUITests/NativeInteractionTests.swift','scripts/native-uiqa.sh','apple/project.yml')}
(out/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
print(owned['udid'])
PY
)"
echo "Evidence: $ATTEMPT"
xcodegen generate --spec "$SOURCE/apple/project.yml" --project "$SOURCE/apple" > "$ATTEMPT/project-generation.log" 2>&1
bounded_command() {
  python3 - "$@" <<'PY'
import os,signal,subprocess,sys
with open(sys.argv[1],'w') as log:
    process=subprocess.Popen(sys.argv[3:],stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try: result=process.wait(timeout=int(sys.argv[2]))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGINT)
        try: process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGTERM)
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL);process.wait()
        result=124
sys.exit(result)
PY
}
# Compile while the task-owned device is shut down, reducing pressure on small hosts.
bounded_command "$ATTEMPT/build-for-testing.log" 600 xcodebuild -jobs 1 \
  -project "$SOURCE/apple/HomeGardenStudio.xcodeproj" -scheme HomeGardenStudioUIQA \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$SOURCE/apple/build/UIQA-DerivedData" \
  -disableAutomaticPackageResolution -skipPackageUpdates 'OTHER_SWIFT_FLAGS=-driver-batch-count 1' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= \
  HGS_PRODUCTION_GATEWAY_URL= HGS_SANDBOX_GATEWAY_URL= build-for-testing
xcrun simctl boot "$DEVICE" > "$ATTEMPT/boot.log" 2>&1
BOOTED=1
python3 - "$DEVICE" "$ATTEMPT/boot.log" <<'PY'
import subprocess,sys
try:
    with open(sys.argv[2],'a') as log:
        result=subprocess.run(['xcrun','simctl','bootstatus',sys.argv[1]],stdout=log,stderr=subprocess.STDOUT,timeout=600)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print('Task-owned simulator did not become ready within ten minutes.',file=sys.stderr)
    sys.exit(124)
PY
status=0
export_status=0
bounded_command "$ATTEMPT/xcodebuild.log" 900 xcodebuild -jobs 1 -project "$SOURCE/apple/HomeGardenStudio.xcodeproj" -scheme HomeGardenStudioUIQA \
  -destination "platform=iOS Simulator,id=$DEVICE" -destination-timeout 60 \
  -derivedDataPath "$SOURCE/apple/build/UIQA-DerivedData" -resultBundlePath "$ATTEMPT/Interaction.xcresult" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 300 \
  -only-testing:HomeGardenStudioUITests -disableAutomaticPackageResolution -skipPackageUpdates \
  'OTHER_SWIFT_FLAGS=-driver-batch-count 1' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= \
  HGS_PRODUCTION_GATEWAY_URL= HGS_SANDBOX_GATEWAY_URL= test-without-building || status=$?
# Preserve a framebuffer image even when a killed XCTest run cannot finalize its bundle.
if [[ "$status" != 0 ]]; then
  bounded_command "$ATTEMPT/fallback-screenshot.log" 30 xcrun simctl io "$DEVICE" screenshot "$ATTEMPT/last-screen.png" || true
fi
if [[ -d "$ATTEMPT/Interaction.xcresult" ]]; then
  xcrun xcresulttool export attachments --path "$ATTEMPT/Interaction.xcresult" --output-path "$ATTEMPT/attachments" > "$ATTEMPT/attachment-export.log" 2>&1 || export_status=1
  xcrun xcresulttool get test-results summary --path "$ATTEMPT/Interaction.xcresult" > "$ATTEMPT/summary.json" 2> "$ATTEMPT/summary-error.log" || export_status=1
fi
python3 - "$ATTEMPT" "$status" "$export_status" <<'PY'
import json,pathlib,sys
out=pathlib.Path(sys.argv[1]);status=int(sys.argv[2]);export_status=int(sys.argv[3]);passed=False
try:
    summary=json.loads((out/'summary.json').read_text())
    passed=summary['result']=='Passed' and summary['totalTestCount']==2 and summary['passedTests']==2 and summary['failedTests']==0 and summary['skippedTests']==0
except (OSError,ValueError,KeyError):pass
pngs=list((out/'attachments').rglob('*.png')) if (out/'attachments').exists() else []
receipt={'command_exit':status,'export_exit':export_status,'two_ui_tests_passed':passed,'exported_png_count':len(pngs),'visual_review_performed':False}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt))
sys.exit(0 if status==0 and export_status==0 and passed and len(pngs)>=5 else 1)
PY
