#!/bin/sh
set -e

REPO="akito19/fuzzy-jump"
BINARY_NAME="fj"
INSTALL_DIR="${FJ_INSTALL_DIR:-$HOME/.local/bin}"

main() {
    detect_platform
    check_dependencies
    download_binary
    install_binary
    print_success
}

detect_platform() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "$OS" in
        Linux)  OS="linux" ;;
        Darwin) OS="darwin" ;;
        *)
            echo "Error: Unsupported OS: $OS" >&2
            exit 1
            ;;
    esac

    case "$ARCH" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            echo "Error: Unsupported architecture: $ARCH" >&2
            exit 1
            ;;
    esac

    PLATFORM="${OS}-${ARCH}"
    echo "Detected platform: $PLATFORM"
}

check_dependencies() {
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo "Error: curl or wget is required" >&2
        exit 1
    fi
}

get_latest_release() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
    else
        wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
    fi
}

download_binary() {
    VERSION="${FJ_VERSION:-$(get_latest_release)}"
    if [ -z "$VERSION" ]; then
        echo "Error: Could not determine latest version" >&2
        exit 1
    fi

    ARCHIVE_NAME="${BINARY_NAME}-${VERSION#v}-${PLATFORM}.tar.gz"
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ARCHIVE_NAME}"

    echo "Downloading $BINARY_NAME $VERSION..."

    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$DOWNLOAD_URL" -o "$TMPDIR/$ARCHIVE_NAME"
    else
        wget -q "$DOWNLOAD_URL" -O "$TMPDIR/$ARCHIVE_NAME"
    fi

    tar -xzf "$TMPDIR/$ARCHIVE_NAME" -C "$TMPDIR"
    DOWNLOADED_BINARY="$TMPDIR/$BINARY_NAME"
}

install_binary() {
    echo "Installing to $INSTALL_DIR..."

    mkdir -p "$INSTALL_DIR"
    mv "$DOWNLOADED_BINARY" "$INSTALL_DIR/$BINARY_NAME"
    chmod +x "$INSTALL_DIR/$BINARY_NAME"
}

print_success() {
    echo ""
    echo "Successfully installed $BINARY_NAME to $INSTALL_DIR/$BINARY_NAME"
    echo ""

    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
        echo "Add the following to your shell profile:"
        echo ""
        echo "  export PATH=\"\$PATH:$INSTALL_DIR\""
        echo ""
    fi

    echo "Shell integration (add to ~/.zshrc or ~/.bashrc):"
    echo ""
    echo "  fj() {"
    echo "      local dir"
    echo "      dir=\$(command fj \"\$@\") || return 1"
    echo "      [ -n \"\$dir\" ] && cd -- \"\$dir\""
    echo "  }"
    echo ""
}

main "$@"
