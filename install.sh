#!/usr/bin/env bash
set -euo pipefail

REPO_BIN="$(dirname "$(realpath "$0")")/bin"
MODE="link"
DEST="${HOME}/.local/bin"

usage() {
    cat <<EOF
Usage: ./install.sh [--copy] [DEST]

Puts the wt-box scripts into DEST (default: ~/.local/bin).

  (default)  symlink DEST/<script> -> ${REPO_BIN}/<script>
  --copy     copy the scripts instead, e.g. into a root-owned directory:
             sudo ./install.sh --copy /usr/local/bin
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --copy)    MODE="copy"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)        echo "unknown flag '$1'" >&2; usage >&2; exit 1 ;;
        *)         DEST="$1"; shift ;;
    esac
done

DEST="$(realpath -m "${DEST}")"
mkdir -p "${DEST}"

for src in "${REPO_BIN}"/*; do
    target="${DEST}/$(basename "${src}")"
    if [[ "${MODE}" == "copy" ]]; then
        install -m 755 "${src}" "${target}"
        echo "copied   ${target}"
    elif [[ -e "${target}" && ! -L "${target}" ]]; then
        echo "skipped  ${target} (exists and is not a symlink)" >&2
    else
        ln -sfn "${src}" "${target}"
        echo "linked   ${target} -> ${src}"
    fi
done

if [[ "${MODE}" == "copy" ]]; then
    ENSURE_BOX="${DEST}/ensure-box"
else
    ENSURE_BOX="${REPO_BIN}/ensure-box"
fi

cat <<EOF

Next steps (see README.md):

  sudo ensure-macvlan
  sudo ensure-wt-dns

  wt-box and box-lite run ensure-box through 'sudo -n', so it needs a
  NOPASSWD rule. Read "Security" in README.md first, then add it with
  'sudo visudo -f /etc/sudoers.d/ensure-box':

    ${SUDO_USER:-$(id -un)} ALL=(root) NOPASSWD: ${ENSURE_BOX}
EOF

case ":${PATH}:" in
    *":${DEST}:"*) ;;
    *) printf '\n  %s is not on your PATH yet.\n' "${DEST}" ;;
esac
