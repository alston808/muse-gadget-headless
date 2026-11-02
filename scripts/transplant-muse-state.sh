#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 alston808
#
# transplant-muse-state.sh — move a paired Muse gadget identity to another Linux host.
#
# Unofficial helper: not affiliated with or endorsed by Meta. See LICENSE.
#
# The Muse Gadget SDK needs Bluetooth only while pairing. Once
# /var/lib/musegadget/pairing.json exists, the daemon talks to Muse over the
# network (wss://<noise_host>/v1/noise, then a Noise XX session). A host with no
# radio can therefore become the gadget by adopting the identity from a host
# that paired.
#
# Usage:
#   sudo bash scripts/transplant-muse-state.sh --host pi@muse.local
#   sudo bash scripts/transplant-muse-state.sh --host pi@muse.local --restart
#   bash scripts/transplant-muse-state.sh --host pi@muse.local --dry-run
#
# The target must already have musegadget installed, or be installed afterwards
# with: bash install.sh --no-pair --yes
#
# Refuses to overwrite a different identity already on the target. The SDK token
# is never printed, never placed on a command line, and only ever written inside
# a 0700 directory.

set -euo pipefail

PROG=${0##*/}
DEFAULT_DIR=/var/lib/musegadget
STATE_FILES=(identity.json pairing.json sdk_token)
TOKEN_RE='^mgst_[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$'
SAFE_PATH_RE='^/[A-Za-z0-9._/-]+$'

HOST=""
SOURCE_DIR=$DEFAULT_DIR
REMOTE_DIR=$DEFAULT_DIR
DRY_RUN=0
RESTART=0
SSH_ARGS=()
[[ -n ${MUSE_SSH_OPTS:-} ]] && read -r -a SSH_ARGS <<<"$MUSE_SSH_OPTS"

# ssh must run as the invoking user. Under sudo it would run as uid 0, expand ~
# to /root, and never see the keys, ~/.ssh/config or known_hosts of the account
# that can log in to the target.
SSH_BIN=(ssh)
if ((EUID == 0)) && [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then
  if command -v runuser >/dev/null 2>&1; then
    SSH_BIN=(runuser -u "$SUDO_USER" -- ssh)
  elif command -v sudo >/dev/null 2>&1; then
    SSH_BIN=(sudo -u "$SUDO_USER" ssh)
  fi
fi

say() { printf '==> %s\n' "$*"; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Move a paired Muse gadget identity to another host over SSH.

The identity is three root-only files in $DEFAULT_DIR: identity.json,
pairing.json and sdk_token. Bluetooth is only used while pairing, so a host
without a radio can take over an existing pairing this way.

Usage: sudo $PROG --host TARGET [options]

  --host TARGET        SSH destination, e.g. pi@muse.local or 192.0.2.10 (required)
  --source-dir DIR     Paired state on this host (default: $DEFAULT_DIR)
  --remote-dir DIR     State directory on the target (default: $DEFAULT_DIR)
  --restart            Restart musegadget on the target after installing
  --dry-run            Print the plan; read-only, works without root
  -h, --help           Show this help

The target needs sudo; a terminal is allocated for its password prompt when
one is available. Set MUSE_SSH_OPTS to pass extra ssh options, e.g. '-p 2222'.

Under sudo, ssh is re-run as the invoking user so your keys and known_hosts are
used. Keys must be on disk: an agent socket is not inherited by root.
EOF
}

while (($#)); do
  case $1 in
    --host) HOST=${2:?--host needs a value}; shift 2 ;;
    --source-dir) SOURCE_DIR=${2:?--source-dir needs a value}; shift 2 ;;
    --remote-dir) REMOTE_DIR=${2:?--remote-dir needs a value}; shift 2 ;;
    --restart) RESTART=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

[[ -n $HOST ]] || { usage >&2; die "--host is required"; }
[[ $SOURCE_DIR =~ $SAFE_PATH_RE ]] || die "--source-dir must be an absolute path without spaces or quotes"
[[ $REMOTE_DIR =~ $SAFE_PATH_RE ]] || die "--remote-dir must be an absolute path without spaces or quotes"

# The real transfer reads root-only files, so it must run as root. A dry run
# only inspects what it can and is deliberately usable unprivileged.
if ((DRY_RUN == 0)) && ((EUID != 0)); then
  die "run with sudo: $SOURCE_DIR holds root-only files (or use --dry-run)"
fi

# --- Local preflight ---------------------------------------------------------
for f in "${STATE_FILES[@]}"; do
  [[ -f $SOURCE_DIR/$f ]] || die "missing $SOURCE_DIR/$f"
done

if ((DRY_RUN == 0)); then
  for f in "${STATE_FILES[@]}"; do
    owner=$(stat -c '%u' -- "$SOURCE_DIR/$f")
    [[ $owner == 0 ]] || die "$SOURCE_DIR/$f is not root-owned; run: sudo chown root:root ${STATE_FILES[*]}"
  done
fi

token=$(tr -d '[:space:]' <"$SOURCE_DIR/sdk_token")
[[ $token =~ $TOKEN_RE ]] || die "sdk_token is not a valid mgst_ token; copy it again from gadgets.muse.ai"
unset token

if ! grep -qE '"mac"[[:space:]]*:[[:space:]]*"([0-9a-f]{2}:){5}[0-9a-f]{2}"' -- "$SOURCE_DIR/identity.json"; then
  warn "identity.json has no \"mac\" field; the target SDK would generate a new identity"
fi

identity_sha=$(sha256sum -- "$SOURCE_DIR/identity.json" | cut -d' ' -f1)
[[ $identity_sha =~ ^[0-9a-f]{64}$ ]] || die "could not hash $SOURCE_DIR/identity.json"

# --- Remote helper ----------------------------------------------------------
# The helper travels with the state so check-and-install happens as one root
# operation on the target, instead of quoting a long command through ssh.
stage=$(mktemp -d)
remote_stage=""

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n $remote_stage ]]; then
    "${SSH_BIN[@]}" "${SSH_ARGS[@]}" "$HOST" "rm -rf '$remote_stage'" </dev/null >/dev/null 2>&1 || true
  fi
  rm -rf -- "$stage"
  exit "$status"
}
trap cleanup EXIT

cat >"$stage/apply.sh" <<'HELPER'
#!/usr/bin/env bash
# Shipped by transplant-muse-state.sh; runs only as root on the target.
set -euo pipefail

target_dir=${1:?target directory}
expected_sha=${2:?expected identity sha256}
here=$(cd -- "$(dirname -- "$0")" && pwd)

((EUID == 0)) || { printf 'apply: must run as root\n' >&2; exit 5; }

if [[ -e $target_dir/identity.json ]]; then
  actual_sha=$(sha256sum -- "$target_dir/identity.json" | cut -d' ' -f1)
  if [[ $actual_sha != "$expected_sha" ]]; then
    printf 'apply: %s already holds a different gadget identity\n' "$target_dir" >&2
    printf 'apply: refusing to overwrite it. If you mean to replace that device, remove it first:\n' >&2
    printf '         sudo rm -rf %q\n' "$target_dir" >&2
    exit 3
  fi
fi

install -d -m 0700 -- "$target_dir"
chmod 0700 -- "$target_dir"

for f in identity.json pairing.json sdk_token; do
  [[ -f $here/$f ]] || { printf 'apply: missing %s\n' "$here/$f" >&2; exit 4; }
  install -m 0600 -o root -g root -- "$here/$f" "$target_dir/$f"
done

printf 'installed:\n'
for f in identity.json pairing.json sdk_token; do
  stat -c '  %a %U:%G %n' -- "$target_dir/$f"
done
HELPER
chmod 0700 "$stage/apply.sh"

if ((DRY_RUN == 1)); then
  say "identity sha256: $identity_sha"
  say "would upload to $HOST (via $stage): ${STATE_FILES[*]} apply.sh"
  say "would run on $HOST: sudo bash <staging>/apply.sh $REMOTE_DIR $identity_sha"
  say "dry run only; nothing was transferred"
  exit 0
fi

# --- Upload ----------------------------------------------------------------
say "staging on $HOST"
remote_stage=$("${SSH_BIN[@]}" "${SSH_ARGS[@]}" "$HOST" 'mktemp -d /tmp/muse-state.XXXXXX') ||
  die "cannot run mktemp on $HOST (ssh used the ${SUDO_USER:-$(id -un)} account; set MUSE_SSH_OPTS to pass -i/-F if that is wrong)"
[[ $remote_stage =~ ^/tmp/muse-state\.[A-Za-z0-9]+$ ]] ||
  die "unexpected staging path from $HOST: $remote_stage"

say "uploading identity"
tar --numeric-owner -czf - -C "$SOURCE_DIR" "${STATE_FILES[@]}" -C "$stage" apply.sh |
  "${SSH_BIN[@]}" "${SSH_ARGS[@]}" "$HOST" "tar -xzf - -C '$remote_stage'"

# --- Install ---------------------------------------------------------------
say "installing on $HOST (sudo may ask for a password)"
if [[ -t 0 ]]; then
  "${SSH_BIN[@]}" -t "${SSH_ARGS[@]}" "$HOST" "sudo bash '$remote_stage/apply.sh' '$REMOTE_DIR' '$identity_sha'"
else
  "${SSH_BIN[@]}" "${SSH_ARGS[@]}" "$HOST" "sudo bash '$remote_stage/apply.sh' '$REMOTE_DIR' '$identity_sha'"
fi

if ((RESTART == 1)); then
  say "restarting musegadget"
  if [[ -t 0 ]]; then
    "${SSH_BIN[@]}" -t "${SSH_ARGS[@]}" "$HOST" 'sudo systemctl restart musegadget'
  else
    "${SSH_BIN[@]}" "${SSH_ARGS[@]}" "$HOST" 'sudo systemctl restart musegadget'
  fi
fi

say "done: $REMOTE_DIR on $HOST now holds this gadget identity ($identity_sha)"
cat <<EOF

Next, on the target:
  ssh $HOST 'sudo musegadget doctor'
  ssh $HOST 'sudo journalctl -u musegadget -f'   # look for: registered with the Muse

If musegadget is not installed there yet, install it before pairing state is
used: bash install.sh --from . --sdk-token mgst_... --no-pair --yes
EOF
