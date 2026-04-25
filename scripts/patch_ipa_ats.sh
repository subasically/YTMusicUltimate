#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/app.ipa" >&2
  exit 1
fi

IPA_PATH="$1"
if [[ ! -f "$IPA_PATH" ]]; then
  echo "ipa not found: $IPA_PATH" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

unzip -q "$IPA_PATH" -d "$WORKDIR"

APP_DIR="$(find "$WORKDIR/Payload" -maxdepth 1 -type d -name '*.app' | head -n 1)"
if [[ -z "$APP_DIR" ]]; then
  echo "could not find app bundle in ipa" >&2
  exit 1
fi

PLIST_PATH="$APP_DIR/Info.plist"

/usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity" "$PLIST_PATH" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSExceptionDomains dict" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSExceptionDomains:62.146.177.62 dict" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSExceptionDomains:62.146.177.62:NSExceptionAllowsInsecureHTTPLoads bool true" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSExceptionDomains:62.146.177.62:NSIncludesSubdomains bool true" "$PLIST_PATH"

PATCHED_IPA="$WORKDIR/patched.ipa"
(
  cd "$WORKDIR"
  zip -qr "$PATCHED_IPA" Payload
)

mv "$PATCHED_IPA" "$IPA_PATH"

echo "patched ATS in $IPA_PATH"
