#!/usr/bin/env bash
# Builds Libmpv.xcframework: mpv + FFmpeg (LGPL, no GPL or nonfree parts) as ONE dynamic framework per
# platform, so the app links them dynamically and anyone can rebuild and swap them (LGPL relinking).
#
# How: MPVKit's own build scripts (pinned commit) compile FFmpeg and mpv from source as static archives,
# with two changes (see patch_mpvkit); then every archive is linked into a single dylib that only
# exports the libmpv API (`mpv_*`), wrapped as Libmpv.framework and gathered into an xcframework.
#
# Usage: ./build.sh [all|fetch|mpvkit|link|sources]   (default: all = fetch + mpvkit + link)
#   WORK_DIR  scratch directory, outside the repo (default: ~/Library/Caches/zapper-libmpv)
# Output (next to this script, ignored by git): Libmpv.xcframework, dist/Libmpv.xcframework.zip and its
# SwiftPM checksum, dist/libmpv-lgpl-sources.tar.gz (corresponding source, `sources` stage).
# Requirements: Xcode, Homebrew with meson, ninja, nasm, cmake, pkg-config, wget. See README.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${WORK_DIR:-$HOME/Library/Caches/zapper-libmpv}"
MPVKIT_REPO="https://github.com/mpvkit/MPVKit"
MPVKIT_TAG="0.41.0"
MPVKIT_COMMIT="613c0ccc3acf70e136aaff880a9b5fe8fdfaf5b8"
FRAMEWORK="Libmpv"
FRAMEWORK_VERSION="0.41.0"
# Minimum OS of the slices: what MPVKit compiles for (below the app's iOS 17 / macOS 26).
IOS_MIN="14.0"
MACOS_MIN="11.0"
# Slices: <MPVKit platform>:<arch list>:<xcframework variant>
SLICES=("ios:arm64:ios" "isimulator:arm64 x86_64:ios-simulator" "macos:arm64 x86_64:macos")
# Static libraries that must NOT end up in the dylib: GPL (smbclient), unused (bluray) or not used by
# FFmpeg in this configuration (OpenSSL: its TLS is GnuTLS). Linking fails if one of them were needed.
EXCLUDED_LIBS="smbclient bluray ssl crypto"

MPVKIT="$WORK_DIR/MPVKit"
DIST="$MPVKIT/dist"
OUT="$WORK_DIR/out"

log() { printf '\n==> %s\n' "$*"; }

fetch() {
  mkdir -p "$WORK_DIR"
  if [[ ! -d "$MPVKIT/.git" ]]; then
    log "Cloning MPVKit $MPVKIT_TAG"
    git clone --quiet --branch "$MPVKIT_TAG" "$MPVKIT_REPO" "$MPVKIT"
  fi
  local head
  head="$(git -C "$MPVKIT" rev-parse HEAD)"
  [[ "$head" == "$MPVKIT_COMMIT" ]] || { echo "MPVKit is at $head, expected $MPVKIT_COMMIT" >&2; exit 1; }
  patch_mpvkit
}

# The only changes to MPVKit's build. Idempotent: it starts from the pinned commit each time.
patch_mpvkit() {
  local main="$MPVKIT/Sources/BuildScripts/XCFrameworkBuild/main.swift"
  git -C "$MPVKIT" checkout --quiet -- "$main"
  # 1. FFmpeg without --enable-nonfree. MPVKit passes it even in its "LGPL" variant, and it turns the
  #    FFmpeg build into "nonfree and unredistributable" (see `avutil_license()` in its binaries).
  #    --enable-version3 stays: gmp and gnutls bring LGPL-3, so FFmpeg is LGPL-3.0-or-later.
  sed -i '' 's/ *"--enable-nonfree",//' "$main"
  # 2. Neither libsmbclient (GPL, only used by MPVKit-GPL) nor libbluray (Blu-ray discs, useless here).
  sed -i '' -e 's/^\( *\)try BuildSmbclient().buildALL()/\1\/\/ try BuildSmbclient().buildALL()/' \
            -e 's/^\( *\)try BuildBluray().buildALL()/\1\/\/ try BuildBluray().buildALL()/' "$main"
  # Sanity checks: GPL stays off (no enable-gpl argument is passed) and the edits applied.
  ! grep -q '"--enable-nonfree"' "$main" || { echo "patch_mpvkit: nonfree still enabled" >&2; exit 1; }
  grep -q '// try BuildSmbclient' "$main" && grep -q '// try BuildBluray' "$main" \
    || { echo "patch_mpvkit: libraries not disabled" >&2; exit 1; }
}

build_mpvkit() {
  log "Building FFmpeg and mpv with MPVKit (LGPL, static archives) — this takes a while"
  # `enable-gpl` is deliberately absent: FFmpeg gets no --enable-gpl and mpv gets -Dgpl=false.
  (cd "$MPVKIT" && make build platform=ios,macos)
  check_licenses
}

# Refuses to continue if any FFmpeg archive does not declare itself LGPL.
check_licenses() {
  local lib
  for lib in "$DIST"/FFmpeg/*/thin/*/lib/libavutil.a; do
    if ! strings "$lib" | grep -q 'libavutil license: LGPL version 3 or later'; then
      echo "check_licenses: $lib is not LGPL-3.0-or-later:" >&2
      strings "$lib" | grep 'libavutil license' >&2 || true
      exit 1
    fi
  done
  if grep -rq -- '--enable-gpl\|--enable-nonfree' "$DIST"/FFmpeg/*/thin/*/lib/pkgconfig 2>/dev/null; then
    echo "check_licenses: FFmpeg configured with GPL or nonfree components" >&2
    exit 1
  fi
}

sdk_name() {
  case "$1" in ios) echo iphoneos ;; isimulator) echo iphonesimulator ;; macos) echo macosx ;; esac
}

target_triple() {
  case "$1" in
    ios) echo "$2-apple-ios$IOS_MIN" ;;
    isimulator) echo "$2-apple-ios$IOS_MIN-simulator" ;;
    macos) echo "$2-apple-macos$MACOS_MIN" ;;
  esac
}

# Every static archive MPVKit produced (or downloaded prebuilt) for one platform/arch.
archives_for() {
  local platform="$1" arch="$2" lib name skip excluded
  find "$DIST"/*/"$platform"/thin/"$arch"/lib -maxdepth 1 -name '*.a' 2>/dev/null | sort | while read -r lib; do
    name="$(basename "$lib" .a)"; name="${name#lib}"
    skip=0
    for excluded in $EXCLUDED_LIBS; do [[ "$name" == "$excluded" ]] && skip=1; done
    [[ $skip == 0 ]] && echo "$lib"
  done
}

link_slice() {
  local platform="$1" arch="$2" dest="$3"
  local sdk triple sdk_path libmpv install_name
  sdk="$(sdk_name "$platform")"
  triple="$(target_triple "$platform" "$arch")"
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  libmpv="$DIST/libmpv/$platform/thin/$arch/lib/libmpv.a"
  [[ -f "$libmpv" ]] || { echo "Missing $libmpv" >&2; exit 1; }
  if [[ "$platform" == macos ]]; then
    install_name="@rpath/$FRAMEWORK.framework/Versions/A/$FRAMEWORK"
  else
    install_name="@rpath/$FRAMEWORK.framework/$FRAMEWORK"
  fi

  local archives=()
  while IFS= read -r a; do [[ "$a" != "$libmpv" ]] && archives+=("$a"); done < <(archives_for "$platform" "$arch")

  local frameworks=(AVFoundation AudioToolbox CoreAudio CoreFoundation CoreMedia CoreVideo CoreText
                    CoreGraphics Foundation IOSurface Metal QuartzCore Security VideoToolbox)
  if [[ "$platform" == macos ]]; then
    frameworks+=(AppKit Cocoa IOKit OpenGL CoreServices ApplicationServices)
  else
    frameworks+=(UIKit OpenGLES)
  fi
  local fw_flags=()
  for f in "${frameworks[@]}"; do fw_flags+=(-framework "$f"); done

  # mpv's macOS backend has Swift code: the Swift runtime ships with the OS (macOS 11+, iOS 14+).
  local swift_lib
  swift_lib="$(dirname "$(xcrun --find swiftc)")/../lib/swift/$sdk"

  log "Linking $FRAMEWORK for $platform $arch (${#archives[@]} archives + libmpv)"
  mkdir -p "$(dirname "$dest")"
  xcrun --sdk "$sdk" clang -dynamiclib \
    -target "$triple" -isysroot "$sdk_path" \
    -install_name "$install_name" \
    -compatibility_version 1.0 -current_version "$FRAMEWORK_VERSION" \
    -Wl,-force_load,"$libmpv" "${archives[@]}" \
    -Wl,-exported_symbols_list,"$HERE/exports.txt" \
    -Wl,-dead_strip -Wl,-no_warn_duplicate_libraries \
    -L"$sdk_path/usr/lib/swift" -L"$swift_lib" \
    "${fw_flags[@]}" \
    -lc++ -lz -lbz2 -liconv -lxml2 -lexpat -lresolv \
    -o "$dest"
  strip -x "$dest"
}

write_plist() {
  local path="$1" platform="$2" min supported
  case "$platform" in
    ios) min="$IOS_MIN"; supported="iPhoneOS" ;;
    isimulator) min="$IOS_MIN"; supported="iPhoneSimulator" ;;
    macos) min="$MACOS_MIN"; supported="MacOSX" ;;
  esac
  local min_key="MinimumOSVersion"
  [[ "$platform" == macos ]] && min_key="LSMinimumSystemVersion"
  cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$FRAMEWORK</string>
  <key>CFBundleIdentifier</key><string>app.zapperiptv.$FRAMEWORK</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$FRAMEWORK</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$FRAMEWORK_VERSION</string>
  <key>CFBundleVersion</key><string>$FRAMEWORK_VERSION</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$supported</string></array>
  <key>$min_key</key><string>$min</string>
</dict>
</plist>
PLIST
}

# Libmpv.framework for one platform; the module is `Libmpv`, as in MPVKit, so `import Libmpv` still works.
make_framework() {
  local platform="$1" archs="$2" dir="$3"
  local fw="$dir/$FRAMEWORK.framework" root headers
  rm -rf "$fw"
  if [[ "$platform" == macos ]]; then
    root="$fw/Versions/A"
    mkdir -p "$root/Resources"
    write_plist "$root/Resources/Info.plist" "$platform"
  else
    root="$fw"
    mkdir -p "$root"
    write_plist "$root/Info.plist" "$platform"
  fi
  headers="$root/Headers"
  mkdir -p "$headers" "$root/Modules"
  cp -R "$DIST/libmpv/$platform/thin/${archs%% *}/include/mpv" "$headers/"
  cat > "$root/Modules/module.modulemap" <<'MAP'
framework module Libmpv [system] {
    umbrella "."
    export *
}
MAP
  local thin=() arch
  for arch in $archs; do
    link_slice "$platform" "$arch" "$OUT/thin/$platform/$arch/$FRAMEWORK"
    thin+=("$OUT/thin/$platform/$arch/$FRAMEWORK")
  done
  lipo -create "${thin[@]}" -output "$root/$FRAMEWORK"
  if [[ "$platform" == macos ]]; then
    ln -s A "$fw/Versions/Current"
    ln -s "Versions/Current/$FRAMEWORK" "$fw/$FRAMEWORK"
    ln -s Versions/Current/Headers "$fw/Headers"
    ln -s Versions/Current/Modules "$fw/Modules"
    ln -s Versions/Current/Resources "$fw/Resources"
  fi
}

link_all() {
  rm -rf "$OUT"
  local slice platform archs args=()
  for slice in "${SLICES[@]}"; do
    IFS=: read -r platform archs _ <<< "$slice"
    make_framework "$platform" "$archs" "$OUT/frameworks/$platform"
    args+=(-framework "$OUT/frameworks/$platform/$FRAMEWORK.framework")
  done
  log "Creating $FRAMEWORK.xcframework"
  rm -rf "$HERE/$FRAMEWORK.xcframework"
  xcodebuild -create-xcframework "${args[@]}" -output "$HERE/$FRAMEWORK.xcframework" >/dev/null
  mkdir -p "$HERE/dist"
  rm -f "$HERE/dist/$FRAMEWORK.xcframework.zip"
  (cd "$HERE" && ditto -c -k --sequesterRsrc --keepParent "$FRAMEWORK.xcframework" "dist/$FRAMEWORK.xcframework.zip")
  (cd "$HERE" && swift package compute-checksum "dist/$FRAMEWORK.xcframework.zip" > "dist/$FRAMEWORK.xcframework.checksum")
  # A copy outside the checkout, so another worktree can reuse it without rebuilding.
  cp "$HERE/dist/$FRAMEWORK.xcframework.zip" "$HERE/dist/$FRAMEWORK.xcframework.checksum" "$WORK_DIR/"
  log "Done: $HERE/$FRAMEWORK.xcframework (checksum $(cat "$HERE/dist/$FRAMEWORK.xcframework.checksum"))"
}

# Corresponding source of everything inside the framework (LGPL-2.1 §6, LGPL-3.0 §4): MPVKit at the
# pinned commit plus the patch build.sh applies, the FFmpeg and mpv trees it compiled (MPVKit's patches
# already applied), and every other component of sources.lock cloned at its tag (with submodules),
# refusing any tag that no longer points at the pinned commit.
sources() {
  local src="$WORK_DIR/sources/libmpv-lgpl-sources"
  rm -rf "$src"; mkdir -p "$src/upstream"
  log "Collecting corresponding source in $src"
  git -C "$MPVKIT" archive --format=tar --prefix=MPVKit/ HEAD | tar -x -C "$src"
  git -C "$MPVKIT" diff > "$src/MPVKit-zapper.patch"
  local tree
  for tree in "$DIST"/FFmpeg-* "$DIST"/libmpv-*; do
    [[ -d "$tree" ]] || continue
    tar -C "$(dirname "$tree")" --exclude .git -cf - "$(basename "$tree")" | tar -x -C "$src"
  done
  local name url tag commit dir head
  while read -r name url tag commit; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    [[ "$name" == mpv || "$name" == FFmpeg ]] && continue
    dir="$src/upstream/$name-$tag"
    git -c advice.detachedHead=false clone --quiet --recursive --depth 1 --branch "$tag" "$url" "$dir"
    head="$(git -C "$dir" rev-parse HEAD)"
    [[ "$head" == "$commit" ]] || { echo "sources: $name $tag is $head, expected $commit" >&2; exit 1; }
    find "$dir" -name .git -prune -exec rm -rf {} +
  done < "$HERE/sources.lock"
  cp "$HERE/build.sh" "$HERE/exports.txt" "$HERE/sources.lock" "$HERE/README.md" "$src/"
  mkdir -p "$HERE/dist"
  tar -C "$(dirname "$src")" -czf "$HERE/dist/libmpv-lgpl-sources.tar.gz" "$(basename "$src")"
  log "Done: $HERE/dist/libmpv-lgpl-sources.tar.gz"
}

case "${1:-all}" in
  all) fetch; build_mpvkit; link_all ;;
  fetch) fetch ;;
  mpvkit) fetch; build_mpvkit ;;
  link) link_all ;;
  sources) sources ;;
  *) echo "Usage: $0 [all|fetch|mpvkit|link|sources]" >&2; exit 2 ;;
esac
