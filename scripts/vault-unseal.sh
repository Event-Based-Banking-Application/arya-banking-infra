#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_FILE="${1:-$SCRIPT_DIR/vault/init/keys.txt}"
UNSEAL_THRESHOLD="${UNSEAL_THRESHOLD:-3}"

VAULT_CONTAINER="vault"
VAULT_API="http://localhost:8091"

die() { printf '\033[0;31m%s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[0;36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m%s\033[0m\n' "$*"; }

get_seal_status() {
  curl -sS "$VAULT_API/v1/sys/seal-status" 2>/dev/null || true
}

unseal_shard() {
  curl -sS -X PUT -H "Content-Type: application/json" \
    -d "{\"key\":\"$1\"}" "$VAULT_API/v1/sys/unseal" 2>/dev/null || true
}

initialize_vault() {
  curl -sS -X PUT -H "Content-Type: application/json" \
    -d "{\"secret_shares\":5,\"secret_threshold\":$UNSEAL_THRESHOLD}" \
    "$VAULT_API/v1/sys/init" 2>/dev/null || true
}

# ─── Check container ───────────────────────────────────────────────────
if ! docker ps --filter "name=$VAULT_CONTAINER" --format "{{.Names}}" 2>/dev/null | grep -q "$VAULT_CONTAINER"; then
  die "Vault container '$VAULT_CONTAINER' is not running. Start it first:
  docker compose -f compose/vault.yml up -d"
fi

# ─── Check seal status ─────────────────────────────────────────────────
STATUS="$(get_seal_status)"
if [[ -z "$STATUS" ]]; then
  die "Could not get Vault status. Is Vault running?"
fi

SEALED="$(printf '%s' "$STATUS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["sealed"])' 2>/dev/null || true)"
if [[ "$SEALED" == "False" ]]; then
  ok "Vault is already unsealed."
  info "  Cluster: $(printf '%s' "$STATUS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["cluster_name"])')"
  info "  Version: $(printf '%s' "$STATUS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])')"
  exit 0
fi

PROGRESS="$(printf '%s' "$STATUS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["progress"])')"
TOTAL="$(printf '%s' "$STATUS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["t"])')"
warn "Vault is sealed. Progress: $PROGRESS/$TOTAL"

# ─── Check keys file ───────────────────────────────────────────────────
if [[ ! -f "$KEYS_FILE" ]]; then
  warn "No keys file found at: $KEYS_FILE"
  printf "Initialize Vault for the first time? (y/N) "
  read -r CHOICE
  if [[ "$CHOICE" != "y" ]]; then exit 0; fi

  INIT="$(initialize_vault)"
  if [[ -z "$INIT" ]]; then
    die "Initialization failed."
  fi

  ROOT_TOKEN="$(printf '%s' "$INIT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["root_token"])')"
  KEYS_LIST="$(printf '%s' "$INIT" | python3 -c 'import sys,json;print("\n".join(json.load(sys.stdin)["unseal_keys_b64"]))')"

  mkdir -p "$(dirname "$KEYS_FILE")"
  {
    echo "Vault initialized at: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "----------------------------------------------------------"
    echo "Unseal Keys (save these securely — cannot be recovered):"
    echo "$KEYS_LIST"
    echo "----------------------------------------------------------"
    echo "Root Token: $ROOT_TOKEN"
  } > "$KEYS_FILE"

  ok "Keys saved to: $KEYS_FILE"
  mapfile -t KEYS <<< "$KEYS_LIST"
else
  # Ensure keys file is UTF-8 (handle UTF-16 BOM/LE/BE + CRLF from the PowerShell script)
  ENCODING="$(file -b --mime-encoding "$KEYS_FILE" 2>/dev/null || echo us-ascii)"
  case "$ENCODING" in
    utf-16le|utf-16be) ICONV_FROM=utf-16 ;;
    us-ascii) ICONV_FROM="" ;;
    *) ICONV_FROM="$(printf '%s' "$ENCODING" | sed 's/-/./g')" ;;
  esac
  if [[ -n "$ICONV_FROM" ]]; then
    CONV_CMD="iconv -f $ICONV_FROM -t UTF-8 $KEYS_FILE"
  else
    CONV_CMD="cat $KEYS_FILE"
  fi
  if ! eval "$CONV_CMD" 2>/dev/null | tr -d '\r' | grep -aE '^[A-Za-z0-9+/=]+$' > /tmp/vault-keys.$$; then
    die "No valid unseal keys found in: $KEYS_FILE
Add one base64-encoded key per line."
  fi
  mapfile -t KEYS < /tmp/vault-keys.$$
  rm -f /tmp/vault-keys.$$
fi

# ─── Unseal via API ────────────────────────────────────────────────────
COUNT=0
for KEY in "${KEYS[@]}"; do
  [[ -z "$KEY" ]] && continue
  RESULT=""
  for ATTEMPT in 1 2 3; do
    RESULT="$(unseal_shard "$KEY")"
    [[ -n "$RESULT" ]] && break
    sleep 1
  done
  if [[ -z "$RESULT" ]]; then
    warn "  Unseal API call failed for a key (no response from $VAULT_API)."
    continue
  fi
  if [[ "$(printf '%s' "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("sealed",""))' 2>/dev/null)" == "False" ]]; then
    ok "Vault successfully unsealed!"
    break
  fi
  P="$(printf '%s' "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("progress",""))' 2>/dev/null)"
  T="$(printf '%s' "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("t",""))' 2>/dev/null)"
  info "  Unseal progress: $P/$T"
  COUNT=$((COUNT + 1))
done

FINAL="$(get_seal_status)"
if [[ "$(printf '%s' "$FINAL" | python3 -c 'import sys,json;print(json.load(sys.stdin)["sealed"])')" == "False" ]]; then
  ok "Vault successfully unsealed!"
  info "  Cluster: $(printf '%s' "$FINAL" | python3 -c 'import sys,json;print(json.load(sys.stdin)["cluster_name"])')"
  info "  Version: $(printf '%s' "$FINAL" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])')"
else
  FINAL_PROG="$(printf '%s' "$FINAL" | python3 -c 'import sys,json;print(json.load(sys.stdin)["progress"])')"
  FINAL_TOT="$(printf '%s' "$FINAL" | python3 -c 'import sys,json;print(json.load(sys.stdin)["t"])')"
  REMAINING=$((FINAL_TOT - FINAL_PROG))
  die "Still sealed - need $REMAINING more key(s)."
fi
