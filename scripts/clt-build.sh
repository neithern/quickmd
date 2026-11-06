#!/bin/bash
#
# clt-build.sh — build QuickMD.app with the Command Line Tools alone.
#
# The CLT Swift toolchain does not ship SwiftUI's macro plugins, so two things
# are rewritten in a throwaway copy of the sources:
#   1. `@State`  -> `@LegacyState`, an alias for the still-present `State`
#      property-wrapper struct in SwiftUICore;
#   2. `#Preview { ... }` blocks are removed (they are preview-only and are
#      both at the end of their files in this project).
#
# The real sources are never modified.  Each copy is named *.clt.swift and
# starts with a #sourceLocation directive pointing back at the real file, so
# DWARF (and therefore Zed/lldb breakpoints) uses the real source paths.  The
# copy is compiled through a generated SwiftPM package so rebuilds are
# incremental; if SwiftPM cannot run in the current environment the script
# falls back to invoking swiftc directly.  The result is a normal .app bundle
# with Info.plist, Mermaid.js, mathFonts.bundle, any .lproj localizations and
# (when possible) an app icon rebuilt from Assets.xcassets.  A Debug build
# writes its dSYM next to the bundle (<name>.app.dSYM), not inside it.
#
# Usage
#   scripts/clt-build.sh [options]
#   scripts/clt-build.sh build [Debug|Release] [options]
#   scripts/clt-build.sh release [options]
#   scripts/clt-build.sh run [Debug|Release] [options]
#   scripts/clt-build.sh path [Debug|Release]
#   scripts/clt-build.sh info
#   scripts/clt-build.sh clean
#
# Options
#   -c, --configuration <debug|release>  Build configuration (default: debug)
#   -o, --output <path>                  Output bundle
#                                        (default: .build/clt/<Config>/QuickMD.app)
#       --scratch <path>                 Build scratch dir (default: .build/clt/spm)
#       --engine <auto|spm|swiftc>       Build engine (default: auto)
#       --clean                          Remove build products (keep sources/caches)
#       --distclean                      Remove the whole scratch dir and the bundle
#       --no-sign                        Skip ad-hoc code signing
#   -h, --help                           Show this help
#
# Environment
#   APPSTORE=1             Compile with -D APPSTORE (Tip Jar variant)
#   ARCH=arm64|x86_64      Override the target architecture (forces swiftc)
#
# Notes
#   * Only the host architecture is built through SwiftPM.  Cross-architecture
#     builds use the swiftc engine, which is not incremental.
#   * Assets.xcassets is not compiled (actool ships with Xcode).  AppIcon.icns
#     is rebuilt from the catalog's PNGs with iconutil; named colors fall back
#     to the system defaults.
#   * The app is ad-hoc signed and runs without the App Sandbox, like an Xcode
#     debug build with CODE_SIGNING_ALLOWED=NO.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CALLER_PWD="$PWD"

PRODUCT="QuickMD"
SOURCE_DIR="$ROOT/QuickMD/QuickMD"
PBXPROJ="$ROOT/QuickMD/QuickMD.xcodeproj/project.pbxproj"
BUILD_ROOT="$ROOT/.build/clt"
DEFAULT_SCRATCH="$BUILD_ROOT/spm"

CONFIGURATION="debug"
OUTPUT=""
SCRATCH="$DEFAULT_SCRATCH"
ENGINE="auto"
DO_SIGN=1
DO_CLEAN=0
DO_DISTCLEAN=0
ACTION="build"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

usage() {
    cat <<'USAGE'
clt-build.sh — build QuickMD.app without Xcode (Command Line Tools only).

The sources are copied to a scratch directory, @State and #Preview are
rewritten there, and the copy is compiled through a generated SwiftPM package.
SwiftPM is incremental; auto falls back to a direct compiler invocation when
SwiftPM is unavailable.

Usage
  scripts/clt-build.sh [options]
  scripts/clt-build.sh build [Debug|Release] [options]
  scripts/clt-build.sh release [options]
  scripts/clt-build.sh run [Debug|Release] [options]
  scripts/clt-build.sh path [Debug|Release]
  scripts/clt-build.sh info
  scripts/clt-build.sh clean

Options
  -c, --configuration <debug|release>  Build configuration (default: debug)
  -o, --output <path>                  Output bundle
                                       (default: .build/clt/<Config>/QuickMD.app)
      --scratch <path>                 Build scratch dir (default: .build/clt/spm)
      --engine <auto|spm|swiftc>       Build engine (default: auto)
      --clean                          Remove build products (keep sources/caches)
      --distclean                      Remove the whole scratch dir and the bundle
      --no-sign                        Skip ad-hoc code signing
  -h, --help                           Show this help

Environment
  APPSTORE=1             Compile with -D APPSTORE (Tip Jar variant)
  ARCH=arm64|x86_64      Override the target architecture (forces swiftc)

Notes
  * Requires the Xcode Command Line Tools (Swift 5.9+).
  * The app icon is regenerated from Assets.xcassets with iconutil; the asset
    catalog itself is not compiled because actool ships with Xcode only.
  * The app is ad-hoc signed and does not use the App Sandbox.
  * The script signs the bundle but does not verify it; run codesign/plutil
    yourself if you need a verification pass.
USAGE
}

absolute() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *)  printf '%s/%s' "$CALLER_PWD" "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

if [ $# -gt 0 ]; then
    case "$1" in
        build|release|run|path|info|clean)
            ACTION="$1"
            shift
            ;;
    esac
fi

if [ "$ACTION" = "release" ]; then
    CONFIGURATION="release"
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--configuration)
            [ $# -ge 2 ] || die "$1 requires a value"
            CONFIGURATION="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
            shift 2
            ;;
        -o|--output)
            [ $# -ge 2 ] || die "$1 requires a value"
            OUTPUT="$2"
            shift 2
            ;;
        --scratch)
            [ $# -ge 2 ] || die "$1 requires a value"
            SCRATCH="$2"
            shift 2
            ;;
        --engine)
            [ $# -ge 2 ] || die "$1 requires a value"
            ENGINE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
            shift 2
            ;;
        --clean)
            DO_CLEAN=1
            shift
            ;;
        --distclean)
            DO_CLEAN=1
            DO_DISTCLEAN=1
            shift
            ;;
        --no-sign)
            DO_SIGN=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        Debug|Release|debug|release)
            CONFIGURATION="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
            shift
            ;;
        *)
            die "unknown option: $1 (see --help)"
            ;;
    esac
done

case "$CONFIGURATION" in
    debug)   CONFIG_DIR="Debug" ;;
    release) CONFIG_DIR="Release" ;;
    *) die "configuration must be 'debug' or 'release', got '$CONFIGURATION'" ;;
esac

case "$ENGINE" in
    auto|spm|swiftc) ;;
    *) die "engine must be 'auto', 'spm' or 'swiftc', got '$ENGINE'" ;;
esac

[ -z "$OUTPUT" ] || OUTPUT="$(absolute "$OUTPUT")"
SCRATCH="$(absolute "$SCRATCH")"
OUTPUT="${OUTPUT:-$BUILD_ROOT/$CONFIG_DIR/$PRODUCT.app}"

case "$OUTPUT" in
    *.app) ;;
    *) die "output must be an .app bundle: $OUTPUT" ;;
esac
[ "$OUTPUT" != "$ROOT" ] || die "refusing to use the project root as the output bundle"
[ "$OUTPUT" != "$SCRATCH" ] || die "output and scratch must be different paths"

# `clean` is the legacy "remove .build/clt" action.  Like the old script it
# removes every configuration; --clean/--distclean only touch this build.
if [ "$ACTION" = "clean" ]; then
    rm -rf "$OUTPUT" "$OUTPUT.dSYM" "$BUILD_ROOT"
    note "removed $BUILD_ROOT"
    exit 0
fi

if [ "$ACTION" = "path" ]; then
    printf '%s\n' "$OUTPUT"
    exit 0
fi

# ---------------------------------------------------------------------------
# Read build settings from the Xcode project
# ---------------------------------------------------------------------------

[ -f "$PBXPROJ" ] || die "missing $PBXPROJ"

# pbx_value <SETTING> [<value to exclude>]
pbx_value() {
    grep -o "$1 = [^;]*;" "$PBXPROJ" 2>/dev/null \
        | { if [ $# -ge 2 ]; then grep -v -- "$2" || true; else cat; fi; } \
        | head -1 \
        | sed 's/^[^=]*= *//; s/;$//; s/^"//; s/"$//' || true
}

# The app target's values come first, but excluding "Tests" keeps this correct
# if the test target is ever reordered in the project file.
DEPLOYMENT_TARGET="$(
    grep -o 'MACOSX_DEPLOYMENT_TARGET = [0-9.]*;' "$PBXPROJ" 2>/dev/null \
        | grep -o '[0-9][0-9.]*' \
        | awk -F. 'BEGIN { major = -1; minor = -1 }
                   { if ($1 + 0 > major || ($1 + 0 == major && $2 + 0 > minor)) {
                         major = $1 + 0; minor = $2 + 0; best = $0 } }
                   END { if (best != "") print best }' || true
)"
[ -n "$DEPLOYMENT_TARGET" ] || DEPLOYMENT_TARGET="13.0"

MARKETING_VERSION="$(pbx_value MARKETING_VERSION Tests)"
[ -n "$MARKETING_VERSION" ] || MARKETING_VERSION="1.0"
BUILD_VERSION="$(pbx_value CURRENT_PROJECT_VERSION Tests)"
[ -n "$BUILD_VERSION" ] || BUILD_VERSION="1"
BUNDLE_ID="$(pbx_value PRODUCT_BUNDLE_IDENTIFIER Tests)"
[ -n "$BUNDLE_ID" ] || BUNDLE_ID="pl.falami.studio.QuickMD"
APPICON_NAME="$(pbx_value ASSETCATALOG_COMPILER_APPICON_NAME Tests)"
[ -n "$APPICON_NAME" ] || APPICON_NAME="AppIcon"
DEVELOPMENT_LANGUAGE="$(pbx_value developmentRegion)"
[ -n "$DEVELOPMENT_LANGUAGE" ] || DEVELOPMENT_LANGUAGE="en"

HOST_ARCH="$(uname -m)"
ARCH="${ARCH:-$HOST_ARCH}"
case "$ARCH" in
    arm64|x86_64) ;;
    *) die "unsupported ARCH '$ARCH' (expected arm64 or x86_64)" ;;
esac

if [ "$ARCH" != "$HOST_ARCH" ]; then
    case "$ENGINE" in
        spm)  die "SwiftPM builds the host architecture only; use --engine swiftc to build $ARCH" ;;
        auto) warn "ARCH=$ARCH differs from host $HOST_ARCH; using the swiftc engine"
              ENGINE="swiftc" ;;
    esac
fi

SWIFT_BIN="$(xcrun --find swift 2>/dev/null || command -v swift 2>/dev/null || true)"

if [ "$ENGINE" = "auto" ] && [ -z "$SWIFT_BIN" ]; then
    warn "swift not found in PATH; using the swiftc engine"
    ENGINE="swiftc"
fi
if [ "$ENGINE" = "spm" ] && [ -z "$SWIFT_BIN" ]; then
    die "swift not found — install the Command Line Tools: xcode-select --install"
fi

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------

SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
[ -n "$SDK" ] && [ -d "$SDK" ] \
    || die "macOS SDK not found — install the Command Line Tools: xcode-select --install"

if [ "$ENGINE" = "swiftc" ] || [ "$ENGINE" = "auto" ]; then
    SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
    [ -n "$SWIFTC" ] || die "swiftc not found — install the Command Line Tools: xcode-select --install"
fi

SWIFT_VERSION_LINE="$("$SWIFT_BIN" --version 2>/dev/null | head -1 | sed 's/^.*version //' | awk '{ print $1 }' || true)"

# ---------------------------------------------------------------------------
# info
# ---------------------------------------------------------------------------

if [ "$ACTION" = "info" ]; then
    cat <<EOF
SDK:              $SDK
Swift:            ${SWIFT_VERSION_LINE:-?}
Host:             $HOST_ARCH
Target arch:      $ARCH
Deployment:       macOS $DEPLOYMENT_TARGET
Bundle id:        $BUNDLE_ID
Version:          $MARKETING_VERSION ($BUILD_VERSION)
Product:          $PRODUCT
Engine:           $ENGINE
Output:           $OUTPUT
Scratch:          $SCRATCH
Debug app:        $BUILD_ROOT/Debug/$PRODUCT.app
Release app:      $BUILD_ROOT/Release/$PRODUCT.app
EOF
    exit 0
fi

# ---------------------------------------------------------------------------
# Scratch directory and caches
# ---------------------------------------------------------------------------

if [ "$DO_DISTCLEAN" -eq 1 ]; then
    note "removing $SCRATCH, $OUTPUT and $OUTPUT.dSYM"
    rm -rf "$SCRATCH" "$OUTPUT" "$OUTPUT.dSYM"
fi

mkdir -p "$SCRATCH"

# Compiler caches normally live under the user's cache directory, which may be
# unwritable in sandboxed/CI environments; keep them in the scratch dir.
export CLANG_MODULE_CACHE_PATH="$SCRATCH/module-cache"
export SWIFT_MODULECACHE_PATH="$SCRATCH/module-cache"
export TMPDIR="$SCRATCH/tmp"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$TMPDIR" "$SCRATCH/cache" "$SCRATCH/config" "$SCRATCH/security"

if [ "$DO_CLEAN" -eq 1 ]; then
    note "removing build products (sources and caches are kept)"
    rm -rf "$OUTPUT" "$OUTPUT.dSYM" "$SCRATCH/bin"
    if [ -f "$SCRATCH/Package.swift" ]; then
        "$SWIFT_BIN" package --package-path "$SCRATCH" clean >/dev/null 2>&1 \
            || warn "could not clean SwiftPM build products; continuing"
    fi
fi

PKG_SRC="$SCRATCH/Sources/$PRODUCT"

write_if_changed() { # <target> ; content on stdin
    local target="$1" tmp="$1.new"
    cat > "$tmp"
    if ! cmp -s "$tmp" "$target" 2>/dev/null; then
        mv -f "$tmp" "$target"
    else
        rm -f "$tmp"
    fi
}

# ---------------------------------------------------------------------------
# Generate the SwiftPM manifest and sync the rewritten sources
# ---------------------------------------------------------------------------

note "generating SwiftPM manifest (macOS $DEPLOYMENT_TARGET)"
write_if_changed "$SCRATCH/Package.swift" <<EOF
// swift-tools-version:5.9
// Generated by scripts/clt-build.sh — do not edit.
import PackageDescription

let package = Package(
    name: "$PRODUCT",
    platforms: [.macOS("$DEPLOYMENT_TARGET")],
    products: [
        .executable(name: "$PRODUCT", targets: ["$PRODUCT"])
    ],
    targets: [
        .executableTarget(
            name: "$PRODUCT",
            path: "Sources/$PRODUCT"
        )
    ],
    swiftLanguageVersions: [.v5]
)
EOF

# sync_swift_dir <from> <to>
# Rewrites @State, drops the trailing #Preview block, and prepends a
# #sourceLocation directive pointing at the real file.  The directive keeps the
# original line numbers (it affects the line after itself) and makes the
# compiler emit real source paths in DWARF, so Zed/lldb breakpoints bind even
# though the compiler is reading the rewritten copy.
#
# The copy is named <name>.clt.swift: #sourceLocation normally makes the
# physical and logical files produce the same #fileID, which Swift 6.4 warns
# about for every file.  The suffix keeps the physical #fileID distinct.
# Files are only touched when their content actually changed so SwiftPM stays
# incremental.
sync_swift_dir() {
    local from="$1" to="$2"
    local src name dest tmp real real_escaped original
    mkdir -p "$to"

    for src in "$from"/*.swift; do
        [ -e "$src" ] || continue
        name="$(basename "$src")"
        dest="${name%.swift}.clt.swift"
        tmp="$to/.$dest.tmp"
        real="$from/$name"
        real_escaped="$(printf '%s' "$real" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        {
            printf '#sourceLocation(file: "%s", line: 1)\n' "$real_escaped"
            sed -E 's/@State([[:space:]])/@LegacyState\1/g' "$src" \
                | sed '/^[[:space:]]*#Preview/,$d'
        } > "$tmp"
        if cmp -s "$tmp" "$to/$dest" 2>/dev/null; then
            rm -f "$tmp"
        else
            mv -f "$tmp" "$to/$dest"
        fi
    done

    for src in "$to"/*.swift; do
        [ -e "$src" ] || continue
        name="$(basename "$src")"
        case "$name" in
            CLTCompat.swift)
                continue
                ;;
            *.clt.swift)
                original="${name%.clt.swift}.swift"
                [ -e "$from/$original" ] || rm -f "$src"
                ;;
            *)
                # Legacy unrenamed copy from an older scratch directory.
                rm -f "$src"
                ;;
        esac
    done
}

note "syncing sources from QuickMD/QuickMD"
sync_swift_dir "$SOURCE_DIR" "$PKG_SRC"
sync_swift_dir "$SOURCE_DIR/Views" "$PKG_SRC/Views"
sync_swift_dir "$SOURCE_DIR/SwiftMath" "$PKG_SRC/SwiftMath"
sync_swift_dir "$SOURCE_DIR/SwiftMath/Tokenization" "$PKG_SRC/SwiftMath/Tokenization"

write_if_changed "$PKG_SRC/CLTCompat.swift" <<'EOF'
import SwiftUI

// Command Line Tools do not ship SwiftUI's macro plugins. The State property
// wrapper struct is still present in the SDK; expose it under a name that does
// not resolve to the @State macro.
typealias LegacyState<Value> = State<Value>
EOF

EXPECTED_SOURCES="$(find "$SOURCE_DIR" -name '*.swift' | wc -l | tr -d ' ')"
ACTUAL_SOURCES="$(find "$PKG_SRC" -name '*.swift' | wc -l | tr -d ' ')"
if [ "$ACTUAL_SOURCES" -ne "$((EXPECTED_SOURCES + 1))" ]; then
    die "source copy incomplete ($ACTUAL_SOURCES/$((EXPECTED_SOURCES + 1)) files); try --distclean"
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

BINARY=""
ENGINE_USED=""

spm_environment_failure() {
    [ -f "$SCRATCH/build.log" ] || return 1
    grep -qE 'Operation not permitted|unable to write manifest|unable to open output file|Invalid manifest|sandbox-exec|Permission denied|SwiftShims' "$SCRATCH/build.log" 2>/dev/null
}

spm_has_compiler_errors() {
    [ -f "$SCRATCH/build.log" ] || return 1
    grep -qE '\.swift:[0-9]+:[0-9]+: (fatal )?error:' "$SCRATCH/build.log" 2>/dev/null
}

build_spm() {
    local log="$SCRATCH/build.log"
    local args=(-c "$CONFIGURATION")
    local help
    help="$("$SWIFT_BIN" build --help 2>/dev/null || true)"

    # SwiftPM sandboxes manifest/tool execution with sandbox-exec, which
    # nested sandboxes reject; its default caches may also be outside the
    # writable area.
    case "$help" in
        *--disable-sandbox*) args+=(--disable-sandbox) ;;
    esac
    case "$help" in
        *--cache-path*)
            args+=(--cache-path "$SCRATCH/cache"
                   --config-path "$SCRATCH/config"
                   --security-path "$SCRATCH/security")
            ;;
    esac
    if [ "$CONFIGURATION" = "debug" ]; then
        args+=(-Xswiftc -DDEBUG)
    fi
    if [ "${APPSTORE:-0}" = "1" ]; then
        args+=(-Xswiftc -DAPPSTORE)
    fi
    # Map the throwaway source tree back to the real files so Zed/lldb
    # breakpoints in QuickMD/QuickMD/*.swift bind correctly.
    args+=(-Xswiftc -debug-prefix-map -Xswiftc "$PKG_SRC=$SOURCE_DIR")
    args+=(-Xswiftc -file-prefix-map  -Xswiftc "$PKG_SRC=$SOURCE_DIR")

    note "building with SwiftPM ($CONFIGURATION, swift ${SWIFT_VERSION_LINE:-?})"
    if ! "$SWIFT_BIN" build --package-path "$SCRATCH" "${args[@]}" 2>&1 | tee "$log"; then
        return 1
    fi

    local bin_dir
    bin_dir="$("$SWIFT_BIN" build --package-path "$SCRATCH" "${args[@]}" --show-bin-path 2>/dev/null || true)"
    [ -n "$bin_dir" ] || die "could not determine the SwiftPM bin path"
    BINARY="$bin_dir/$PRODUCT"
    [ -f "$BINARY" ] || die "expected product not found at $BINARY"
    ENGINE_USED="swiftpm"
    return 0
}

build_swiftc() {
    [ -n "${SWIFTC:-}" ] \
        || die "swiftc not found — install the Command Line Tools: xcode-select --install"
    local bin_dir="$SCRATCH/bin/$CONFIG_DIR"
    local rsp="$SCRATCH/compile.rsp"
    local list="$SCRATCH/sources.list"
    local flags
    local rel=""

    mkdir -p "$bin_dir"
    BINARY="$bin_dir/$PRODUCT"

    if [ "$CONFIGURATION" = "release" ]; then
        flags="-O"
    else
        flags="-Onone -g -D DEBUG"
    fi
    if [ "${APPSTORE:-0}" = "1" ]; then
        flags="$flags -D APPSTORE"
    fi

    find "$PKG_SRC" -name '*.swift' -print > "$list"

    case "$PKG_SRC" in
        "$ROOT"/*) rel="${PKG_SRC#"$ROOT"/}" ;;
    esac

    {
        printf '%s\n' '-parse-as-library'
        printf '%s\n' '-sdk' "\"$SDK\""
        printf '%s\n' '-target' "\"$ARCH-apple-macosx$DEPLOYMENT_TARGET\""
        printf '%s\n' '-swift-version' '5'
        printf '%s\n' '-module-name' "$PRODUCT"
        printf '%s\n' '-module-cache-path' "\"$CLANG_MODULE_CACHE_PATH\""
        printf '%s\n' '-debug-prefix-map' "\"$PKG_SRC=$SOURCE_DIR\""
        printf '%s\n' '-file-prefix-map' "\"$PKG_SRC=$SOURCE_DIR\""
        if [ -n "$rel" ]; then
            printf '%s\n' '-debug-prefix-map' "\"$rel=$SOURCE_DIR\""
            printf '%s\n' '-file-prefix-map' "\"$rel=$SOURCE_DIR\""
        fi
        for flag in $flags; do printf '%s\n' "$flag"; done
        while IFS= read -r file; do printf '"%s"\n' "$file"; done < "$list"
        printf '%s\n' '-o' "\"$BINARY\""
    } > "$rsp"

    note "building with swiftc ($CONFIGURATION, $ARCH)"
    if ! "$SWIFTC" "@$rsp" 2>&1 | tee "$SCRATCH/build.log"; then
        die "build failed — full log: $SCRATCH/build.log"
    fi
    [ -f "$BINARY" ] || die "expected product not found at $BINARY"
    ENGINE_USED="swiftc"
}

if [ "$ENGINE" = "spm" ]; then
    build_spm || die "SwiftPM build failed — full log: $SCRATCH/build.log"
elif [ "$ENGINE" = "swiftc" ]; then
    build_swiftc
else
    if build_spm; then
        :
    elif spm_has_compiler_errors; then
        die "SwiftPM build failed with compiler errors — full log: $SCRATCH/build.log"
    else
        if spm_environment_failure; then
            warn "SwiftPM cannot run in this environment; falling back to swiftc"
        else
            warn "SwiftPM failed for an unexpected reason; falling back to swiftc"
        fi
        warn "the fallback rebuilds every source file (log: $SCRATCH/build.log)"
        build_swiftc
    fi
fi

# ---------------------------------------------------------------------------
# Assemble the .app bundle
# ---------------------------------------------------------------------------

note "assembling $OUTPUT"
rm -rf "$OUTPUT" "$OUTPUT.dSYM"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"

cp "$BINARY" "$OUTPUT/Contents/MacOS/$PRODUCT"

# Debug symbols stay next to the bundle (QuickMD.app.dSYM), not inside it.
# SwiftPM does not always emit a .dSYM, so generate one from the linked binary
# when needed.  lldb finds either the bundle-adjacent dSYM or the one next to
# the executable by itself.
DSYM=""
if [ -d "$BINARY.dSYM" ]; then
    cp -R "$BINARY.dSYM" "$OUTPUT.dSYM"
    DSYM="$OUTPUT.dSYM"
elif [ "$CONFIGURATION" = "debug" ] && command -v dsymutil >/dev/null 2>&1; then
    if dsymutil "$BINARY" -o "$OUTPUT.dSYM" >/dev/null 2>&1; then
        DSYM="$OUTPUT.dSYM"
    else
        warn "could not generate $PRODUCT.dSYM (breakpoints still work from the binary)"
    fi
fi

[ -f "$SOURCE_DIR/Resources/mermaid-template.html" ] \
    || die "missing Resources/mermaid-template.html"
[ -f "$SOURCE_DIR/Resources/mermaid.min.js" ] \
    || die "missing Resources/mermaid.min.js"
[ -d "$SOURCE_DIR/SwiftMath/mathFonts.bundle" ] \
    || die "missing SwiftMath/mathFonts.bundle"

cp "$SOURCE_DIR/Resources/mermaid-template.html" \
   "$SOURCE_DIR/Resources/mermaid.min.js" \
   "$OUTPUT/Contents/Resources/"

# The app renders math with Latin Modern only (MathImage.font defaults to
# .latinModernFont and there is no math-font picker).  Keep just that font,
# its math table and the licences; the repository keeps the full bundle for
# Xcode and the tests.
MATH_FONT_BUNDLE="$SOURCE_DIR/SwiftMath/mathFonts.bundle"
DEST_MATH_BUNDLE="$OUTPUT/Contents/Resources/mathFonts.bundle"
mkdir -p "$DEST_MATH_BUNDLE"
for file in latinmodern-math.otf latinmodern-math.plist \
            LICENSE OFL.txt GUST-FONT-LICENSE.txt; do
    [ -f "$MATH_FONT_BUNDLE/$file" ] \
        || die "missing mathFonts.bundle/$file"
    cp "$MATH_FONT_BUNDLE/$file" "$DEST_MATH_BUNDLE/"
done

# Localizations are optional; copy every .lproj the project happens to have.
for lproj in "$SOURCE_DIR"/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$OUTPUT/Contents/Resources/"
done

# Rebuild AppIcon.icns from the asset catalog's PNGs (no actool needed).  The
# catalog already contains every size an .iconset needs, so a plain copy is
# enough; fall back to resampling the largest image if the names ever change.
make_icon() {
    local catalog="$SOURCE_DIR/Assets.xcassets/$APPICON_NAME.appiconset"
    [ -d "$catalog" ] || return 1
    command -v iconutil >/dev/null 2>&1 || return 1

    local iconset="$SCRATCH/$APPICON_NAME.iconset"
    local name png master="" max=0 width complete=1
    local -a specs=(
        "16:icon_16x16.png"
        "32:icon_16x16@2x.png"
        "32:icon_32x32.png"
        "64:icon_32x32@2x.png"
        "128:icon_128x128.png"
        "256:icon_128x128@2x.png"
        "256:icon_256x256.png"
        "512:icon_256x256@2x.png"
        "512:icon_512x512.png"
        "1024:icon_512x512@2x.png"
    )

    rm -f "$OUTPUT/Contents/Resources/$APPICON_NAME.icns"
    rm -rf "$iconset"
    mkdir -p "$iconset"

    for name in icon_16x16.png icon_16x16@2x.png icon_32x32.png \
                icon_32x32@2x.png icon_128x128.png icon_128x128@2x.png \
                icon_256x256.png icon_256x256@2x.png icon_512x512.png \
                icon_512x512@2x.png; do
        if [ -f "$catalog/$name" ]; then
            cp "$catalog/$name" "$iconset/$name"
        else
            complete=0
        fi
    done

    if [ "$complete" -eq 0 ]; then
        command -v sips >/dev/null 2>&1 || { rm -rf "$iconset"; return 1; }
        for png in "$catalog"/*.png; do
            [ -e "$png" ] || continue
            width="$(sips -g pixelWidth "$png" 2>/dev/null | awk '/pixelWidth/ { print $2 }')"
            [ -n "$width" ] || continue
            if [ "$width" -gt "$max" ]; then
                max="$width"
                master="$png"
            fi
        done
        [ -n "$master" ] || { rm -rf "$iconset"; return 1; }

        rm -rf "$iconset"
        mkdir -p "$iconset"
        local spec size
        for spec in "${specs[@]}"; do
            size="${spec%%:*}"
            name="${spec#*:}"
            sips -z "$size" "$size" "$master" --out "$iconset/$name" >/dev/null 2>&1 \
                || { rm -rf "$iconset"; return 1; }
        done
    fi

    iconutil -c icns "$iconset" -o "$OUTPUT/Contents/Resources/$APPICON_NAME.icns" \
        >/dev/null 2>&1 || { rm -rf "$iconset"; return 1; }
    [ -s "$OUTPUT/Contents/Resources/$APPICON_NAME.icns" ] \
        || { rm -rf "$iconset"; return 1; }

    rm -rf "$iconset"
    printf '%s' "$APPICON_NAME.icns"
}

ICON_FILE="$(make_icon)" || {
    ICON_FILE=""
    warn "could not build $APPICON_NAME.icns from Assets.xcassets — bundling without an icon"
}

# Info.plist: start from the project's plist, then fill in the keys Xcode would
# normally substitute from build settings.
PLIST="$OUTPUT/Contents/Info.plist"
cp "$SOURCE_DIR/Info.plist" "$PLIST"

plist_set() { # <key> <type> <value>
    plutil -replace "$1" "-$2" "$3" "$PLIST" >/dev/null 2>&1 && return 0
    plutil -insert "$1" "-$2" "$3" "$PLIST" >/dev/null 2>&1 && return 0
    die "failed to set $1 in $PLIST"
}

plist_set CFBundleExecutable            string "$PRODUCT"
plist_set CFBundleName                  string "$PRODUCT"
plist_set CFBundleDisplayName           string "$PRODUCT"
plist_set CFBundleIdentifier            string "$BUNDLE_ID"
plist_set CFBundleInfoDictionaryVersion string "6.0"
plist_set CFBundleDevelopmentRegion     string "$DEVELOPMENT_LANGUAGE"
plist_set CFBundlePackageType           string "APPL"
plist_set CFBundleShortVersionString    string "$MARKETING_VERSION"
plist_set CFBundleVersion               string "$BUILD_VERSION"
plist_set LSMinimumSystemVersion        string "$DEPLOYMENT_TARGET"
plist_set NSHighResolutionCapable       bool   true

# The asset catalog is not compiled without actool, so a CFBundleIconName
# pointing at a missing Assets.car would leave the app iconless.  Prefer the
# .icns when it exists; otherwise remove both icon keys.
plutil -remove CFBundleIconName "$PLIST" >/dev/null 2>&1 || true
if [ -n "$ICON_FILE" ]; then
    plist_set CFBundleIconFile string "${ICON_FILE%.icns}"
else
    plutil -remove CFBundleIconFile "$PLIST" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Sign
# ---------------------------------------------------------------------------

if [ "$DO_SIGN" -eq 1 ]; then
    if command -v codesign >/dev/null 2>&1; then
        note "signing (ad-hoc)"
        codesign --force --sign - --timestamp=none "$OUTPUT" >/dev/null 2>&1 \
            || die "ad-hoc code signing failed"
    else
        warn "codesign not available — bundle left unsigned"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

ARCHS="$(lipo -info "$OUTPUT/Contents/MacOS/$PRODUCT" 2>/dev/null | sed 's/.*: //' || true)"
SIZE="$(du -sh "$OUTPUT" 2>/dev/null | awk '{ print $1 }' || true)"

printf '\n'
note "built $OUTPUT"
printf '    configuration : %s (%s)\n' "$CONFIGURATION" "${ARCHS:-unknown}"
printf '    engine        : %s\n' "$ENGINE_USED"
printf '    version       : %s (%s)\n' "$MARKETING_VERSION" "$BUILD_VERSION"
printf '    minimum macOS : %s\n' "$DEPLOYMENT_TARGET"
printf '    bundle id     : %s\n' "$BUNDLE_ID"
printf '    signature     : %s\n' "$([ "$DO_SIGN" -eq 1 ] && printf 'ad-hoc' || printf 'none')"
printf '    app icon      : %s\n' "${ICON_FILE:-none (Assets.xcassets not compiled)}"
printf '    debug symbols : %s\n' "${DSYM:-none}"
printf '    size          : %s\n' "${SIZE:-?}"
printf '\n'

if [ "$ACTION" = "run" ]; then
    note "launching $OUTPUT"
    open -n "$OUTPUT"
fi
