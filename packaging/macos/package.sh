#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_path="${PHANTTY_MACOS_APP_PATH:-"$repo_root/zig-out/bin/Phantty.app"}"
version="${PHANTTY_MACOS_VERSION:-}"
sign_identity="${PHANTTY_MACOS_SIGN_IDENTITY:--}"
notary_profile="${PHANTTY_MACOS_NOTARY_PROFILE:-}"
entitlements="${PHANTTY_MACOS_ENTITLEMENTS:-"$repo_root/packaging/macos/Phantty.entitlements"}"
dist_dir="${PHANTTY_MACOS_DIST_DIR:-"$repo_root/zig-out/dist/macos"}"

if [[ -z "$version" ]]; then
  version="$(grep -E '^[[:space:]]*\.version[[:space:]]*=' "$repo_root/build.zig.zon" | sed -E 's/.*"([^"]+)".*/\1/')"
fi

if [[ ! -d "$app_path" ]]; then
  echo "missing app bundle: $app_path" >&2
  exit 1
fi

plist="$app_path/Contents/Info.plist"
binary="$app_path/Contents/MacOS/Phantty"
if [[ ! -f "$plist" || ! -f "$binary" ]]; then
  echo "invalid app bundle layout: $app_path" >&2
  exit 1
fi

plutil -lint "$plist" >/dev/null

codesign_args=(--force --sign "$sign_identity" --options runtime --entitlements "$entitlements")
if [[ "$sign_identity" != "-" ]]; then
  codesign_args+=(--timestamp)
fi
codesign "${codesign_args[@]}" "$app_path"
codesign --verify --strict --verbose=2 "$app_path"

mkdir -p "$dist_dir"
staging="$(mktemp -d "${TMPDIR:-/tmp}/phantty-macos-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

ditto "$app_path" "$staging/Phantty.app"
ln -s /Applications "$staging/Applications"

tag_version="$version"
if [[ "$tag_version" != v* ]]; then
  tag_version="v$tag_version"
fi
dmg_path="$dist_dir/phantty-macos-$tag_version.dmg"
rm -f "$dmg_path"
hdiutil create -volname "Phantty" -srcfolder "$staging" -ov -format UDZO "$dmg_path" >/dev/null

if [[ -n "$notary_profile" ]]; then
  xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$dmg_path"
  xcrun stapler staple "$app_path"
else
  echo "notarization skipped: set PHANTTY_MACOS_NOTARY_PROFILE to submit with notarytool" >&2
fi

verified=0
for attempt in 1 2 3 4 5; do
  if hdiutil verify "$dmg_path" >/dev/null; then
    verified=1
    break
  fi
  sleep 1
done
if [[ "$verified" != 1 ]]; then
  echo "failed to verify dmg after retries: $dmg_path" >&2
  exit 1
fi
echo "$dmg_path"
