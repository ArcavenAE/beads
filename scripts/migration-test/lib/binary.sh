#!/bin/bash
# Binary management — download old releases, build candidate.
# Extracted from cross-version-smoke-test.sh for reuse.

CACHE_DIR="${HOME}/.cache/beads-regression"
mkdir -p "$CACHE_DIR"

DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-60}"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
esac

download_binary() {
    local version="$1"
    local ver_bare="${version#v}"

    if ${STRICT_MODE:-false}; then
        download_verified_release_binary "$version"
        return
    fi

    local cached="$CACHE_DIR/bd-${ver_bare}"

    if [ -x "$cached" ]; then
        # Verify the cached binary actually runs (shared lib deps satisfied)
        if "$cached" version >/dev/null 2>&1; then
            echo "$cached"
            return
        fi
        echo -e "  ${YELLOW:-}cached binary broken (missing libs?), rebuilding...${NC:-}" >&2
        rm -f "$cached"
    fi

    # Try downloading the release binary first
    local asset="beads_${ver_bare}_${OS}_${ARCH}.tar.gz"
    local url="https://github.com/gastownhall/beads/releases/download/${version}/${asset}"

    echo -e "  ${YELLOW:-}downloading ${version}...${NC:-}" >&2
    local tmpdir
    tmpdir=$(mktemp -d)
    if curl -fsSL --max-time "$DOWNLOAD_TIMEOUT" "$url" -o "$tmpdir/archive.tar.gz" 2>/dev/null; then
        tar -xzf "$tmpdir/archive.tar.gz" -C "$tmpdir"
        local bd_path
        bd_path=$(find "$tmpdir" -name bd -type f | head -1)
        if [ -n "$bd_path" ]; then
            cp -f "$bd_path" "$cached"
            chmod +x "$cached"
            rm -rf "$tmpdir"
            # Verify it actually runs
            if "$cached" version >/dev/null 2>&1; then
                echo "$cached"
                return
            fi
            echo -e "  ${YELLOW:-}downloaded binary unusable (missing shared libs), building from source...${NC:-}" >&2
            rm -f "$cached"
        else
            rm -rf "$tmpdir"
        fi
    else
        rm -rf "$tmpdir"
    fi

    # Fallback: build from source at the given tag
    build_from_source "$version" "$cached"
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
        return
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
        return
    fi
    echo "ERROR: no SHA-256 utility is available" >&2
    return 1
}

verify_release_archive() {
    local version="$1"
    local archive="$2"
    local expected actual
    expected=$(strict_release_sha256 "$version" "$OS" "$ARCH") || {
        echo "ERROR: no pinned release checksum for $version ($OS/$ARCH)" >&2
        return 1
    }
    actual=$(sha256_file "$archive") || return 1
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: checksum mismatch for $version: got $actual, want $expected" >&2
        return 1
    fi
}

verify_release_binary_version() {
    local version="$1"
    local binary="$2"
    local bare="${version#v}"
    local output
    output=$("$binary" version 2>&1) || {
        echo "ERROR: verified $version binary does not run" >&2
        return 1
    }
    if [[ " $output " != *" $bare "* ]]; then
        echo "ERROR: release binary reports unexpected version: $output" >&2
        return 1
    fi
}

download_verified_release_binary() {
    local version="$1"
    local asset expected release_dir archive binary
    asset=$(strict_release_asset "$version" "$OS" "$ARCH") || {
        echo "ERROR: no strict release manifest for $version ($OS/$ARCH)" >&2
        return 1
    }
    expected=$(strict_release_sha256 "$version" "$OS" "$ARCH") || return 1
    release_dir="$CACHE_DIR/verified/${version}-${OS}-${ARCH}-${expected}"
    archive="$release_dir/$asset"
    binary="$release_dir/bd"
    mkdir -p "$release_dir"

    if [ ! -f "$archive" ]; then
        local url tmp
        url="https://github.com/gastownhall/beads/releases/download/${version}/${asset}"
        tmp="$archive.tmp.$$"
        echo -e "  ${YELLOW:-}downloading verified ${version}...${NC:-}" >&2
        if ! curl -fsSL --max-time "$DOWNLOAD_TIMEOUT" "$url" -o "$tmp"; then
            rm -f "$tmp"
            echo "ERROR: could not download pinned release asset for $version" >&2
            return 1
        fi
        if ! verify_release_archive "$version" "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        mv -f "$tmp" "$archive"
    fi
    verify_release_archive "$version" "$archive" || return 1

    local extract_dir extracted
    extract_dir=$(mktemp -d)
    if ! tar -xzf "$archive" -C "$extract_dir"; then
        rm -rf "$extract_dir"
        echo "ERROR: could not extract pinned release asset for $version" >&2
        return 1
    fi
    extracted=$(find "$extract_dir" -name bd -type f | head -1)
    if [ -z "$extracted" ]; then
        rm -rf "$extract_dir"
        echo "ERROR: pinned release asset for $version contains no bd binary" >&2
        return 1
    fi
    cp -f "$extracted" "$binary"
    chmod +x "$binary"
    rm -rf "$extract_dir"
    verify_release_binary_version "$version" "$binary" || return 1
    printf '%s\n' "$binary"
}

# Build a specific version from source by checking out its tag in a temp dir.
build_from_source() {
    local version="$1"
    local output="$2"

    echo -e "  ${YELLOW:-}building ${version} from source...${NC:-}" >&2
    local srcdir
    srcdir=$(mktemp -d)
    if ! git clone --depth 1 --branch "$version" "$PROJECT_ROOT" "$srcdir" 2>/dev/null; then
        # Tag might not exist locally; try the remote
        if ! git clone --depth 1 --branch "$version" \
            "https://github.com/gastownhall/beads.git" "$srcdir" 2>/dev/null; then
            rm -rf "$srcdir"
            echo -e "  ${RED:-}ERROR: cannot clone tag ${version}${NC:-}" >&2
            return 1
        fi
    fi

    # Use gms_pure_go to avoid ICU header dependency; fall back to plain build
    if ! (cd "$srcdir" && go build -tags gms_pure_go -o "$output" ./cmd/bd) 2>&1 | tail -5 >&2; then
        rm -rf "$srcdir"
        return 1
    fi

    chmod +x "$output"
    rm -rf "$srcdir"
    echo "$output"
}

build_candidate() {
    if [ -n "${CANDIDATE_BIN:-}" ] && [ -x "${CANDIDATE_BIN}" ]; then
        echo "$(cd "$(dirname "$CANDIDATE_BIN")" && pwd)/$(basename "$CANDIDATE_BIN")"
        return
    fi

    local candidate="$CACHE_DIR/bd-candidate-$$"
    echo -e "${YELLOW:-}Building candidate binary...${NC:-}" >&2
    (cd "$PROJECT_ROOT" && go build -tags gms_pure_go -o "$candidate" ./cmd/bd) >&2
    echo "$candidate"
}
