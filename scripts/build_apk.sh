#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBSPEC="$ROOT_DIR/pubspec.yaml"
FLUTTER_APK="$ROOT_DIR/build/app/outputs/flutter-apk/app-release.apk"
DIST_DIR="$ROOT_DIR/build/apk"
BUMP="patch"
DRY_RUN=0
PRUNE_ONLY=0
KEEP_APKS=3
DEBUG_SIGNING=0
FLUTTER_ARGS=()

prune_old_apks() {
  [[ -d "$DIST_DIR" ]] || return 0
  local index=0
  local apk
  while IFS= read -r apk; do
    index=$((index + 1))
    if (( index > KEEP_APKS )); then
      echo "Removing old APK: $apk"
      rm -f -- "$apk"
    fi
  done < <(find "$DIST_DIR" -maxdepth 1 -type f -name 'bookoo_brew-v*.apk' -exec ls -1t {} +)
}

usage() {
  cat <<'USAGE'
Usage: scripts/build_apk.sh [--bump patch|minor|major|build] [--no-bump] [--dry-run] [--prune-only] [--debug-signing] [-- FLUTTER_BUILD_ARGS...]

Builds a release APK and copies it to build/apk/ with the version in the file name.
After a successful build, only the 3 most recent APKs are kept.

Defaults:
  --bump patch    1.0.14+57 -> 1.0.15+58

Options:
  --bump build    1.0.14+57 -> 1.0.14+58
  --bump minor    1.0.14+57 -> 1.1.0+58
  --bump major    1.0.14+57 -> 2.0.0+58
  --no-bump       Rebuild the current version.
  --dry-run       Print the version/output path without building.
  --prune-only    Delete older APKs without changing the version or building.
  --debug-signing Explicit local-test fallback ONLY when key.properties is absent.
                  Existing private signing configuration always wins.
  -- ARGS...      Extra flutter build apk flags (e.g. private dart-define file).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bump)
      [[ $# -ge 2 ]] || {
        echo "Missing value for --bump" >&2
        exit 2
      }
      BUMP="$2"
      shift 2
      ;;
    --no-bump)
      BUMP="none"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --debug-signing)
      DEBUG_SIGNING=1
      shift
      ;;
    --)
      shift
      FLUTTER_ARGS=("$@")
      break
      ;;
    --prune-only)
      PRUNE_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$PRUNE_ONLY" == "1" ]]; then
  prune_old_apks
  find "$DIST_DIR" -maxdepth 1 -type f -name 'bookoo_brew-v*.apk' -exec ls -lh {} +
  exit 0
fi

current_version="$(awk '/^version: / {print $2; exit}' "$PUBSPEC")"
if [[ -z "$current_version" ]]; then
  echo "Could not find a version line in $PUBSPEC" >&2
  exit 1
fi

version_name="${current_version%%+*}"
if [[ "$current_version" == *"+"* ]]; then
  build_number="${current_version##*+}"
else
  build_number="0"
fi

IFS='.' read -r major minor patch <<< "$version_name"
if [[ -z "${major:-}" || -z "${minor:-}" || -z "${patch:-}" ]]; then
  echo "Expected semantic version like 1.0.14+57, got: $current_version" >&2
  exit 1
fi

case "$BUMP" in
  major)
    major=$((major + 1))
    minor=0
    patch=0
    build_number=$((build_number + 1))
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    build_number=$((build_number + 1))
    ;;
  patch)
    patch=$((patch + 1))
    build_number=$((build_number + 1))
    ;;
  build)
    build_number=$((build_number + 1))
    ;;
  none)
    ;;
  *)
    echo "Invalid bump mode: $BUMP" >&2
    usage >&2
    exit 2
    ;;
esac

next_version="$major.$minor.$patch+$build_number"
target_apk="$DIST_DIR/bookoo_brew-v$next_version.apk"

echo "Current version: $current_version"
echo "Next version:    $next_version"
echo "Output APK:      $target_apk"

if [[ "$DRY_RUN" == "1" ]]; then
  exit 0
fi

if [[ ! -f "$ROOT_DIR/android/key.properties" && "$DEBUG_SIGNING" != "1" ]]; then
  echo "Release needs your own android/key.properties, or explicit --debug-signing for local testing." >&2
  exit 1
fi
if [[ "$DEBUG_SIGNING" == "1" ]]; then
  export ORG_GRADLE_PROJECT_bookooAllowDebugSigning=true
  echo "Debug-signing fallback permitted for LOCAL TESTING only; an existing release signer is unchanged."
fi

if [[ "$next_version" != "$current_version" ]]; then
  tmp_pubspec="$(mktemp)"
  awk -v old="$current_version" -v new="$next_version" '
    /^version: / && !done {
      print "version: " new
      done = 1
      next
    }
    { print }
  ' "$PUBSPEC" > "$tmp_pubspec"
  mv "$tmp_pubspec" "$PUBSPEC"
fi

(cd "$ROOT_DIR" && flutter build apk --release ${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"})

mkdir -p "$DIST_DIR"
cp "$FLUTTER_APK" "$target_apk"
prune_old_apks
ls -lh "$target_apk"
