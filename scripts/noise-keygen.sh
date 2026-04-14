#!/usr/bin/env bash
set -euo pipefail

out_dir="${1:-}"

need() { command -v "$1" >/dev/null || { echo "error: missing dependency: $1" >&2; exit 1; }; }
hex_block() {
  local label="$1" pem="$2"
  openssl pkey -in "$pem" -text -noout | awk -v label="$label" '
    $0 ~ ("^" label ":$") { on=1; next }
    on && /^[a-z]+:$/ { on=0 }
    on {
      gsub(/[:[:space:]]/, "", $0)
      printf "%s", $0
    }
    END { print "" }
  '
}

emit_keypair() {
  local name="$1" pem="$2"
  local priv pub
  priv="$(hex_block priv "$pem")"
  pub="$(hex_block pub "$pem")"
  [ "${#priv}" = 64 ] || { echo "error: failed to extract $name private key" >&2; exit 1; }
  [ "${#pub}" = 64 ] || { echo "error: failed to extract $name public key" >&2; exit 1; }

  cat <<EOF
${name}_PRIVATE_KEY=$priv
${name}_PUBLIC_KEY=$pub
EOF
}

need openssl

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

openssl genpkey -algorithm X25519 -out "$tmp/client.pem" >/dev/null 2>&1
openssl genpkey -algorithm X25519 -out "$tmp/server.pem" >/dev/null 2>&1

client_vars="$(emit_keypair CLI "$tmp/client.pem")"
server_vars="$(emit_keypair SERVER "$tmp/server.pem")"

eval "$client_vars"
eval "$server_vars"

cat <<EOF
# Generated X25519 keypairs for sandbox-manager Noise
# Client env
NOISE_ADDR=127.0.0.1:9001
NOISE_LOCAL_PRIVATE_KEY=$CLI_PRIVATE_KEY
NOISE_REMOTE_PUBLIC_KEY=$SERVER_PUBLIC_KEY

# Server env
NOISE_BIND_ADDR=0.0.0.0:9001
NOISE_LOCAL_PRIVATE_KEY=$SERVER_PRIVATE_KEY
NOISE_REMOTE_PUBLIC_KEY=$CLI_PUBLIC_KEY
EOF

if [ -n "$out_dir" ]; then
  mkdir -p "$out_dir"
  cat > "$out_dir/client.env" <<EOF
NOISE_ADDR=127.0.0.1:9001
NOISE_LOCAL_PRIVATE_KEY=$CLI_PRIVATE_KEY
NOISE_REMOTE_PUBLIC_KEY=$SERVER_PUBLIC_KEY
EOF
  cat > "$out_dir/server.env" <<EOF
NOISE_BIND_ADDR=0.0.0.0:9001
NOISE_LOCAL_PRIVATE_KEY=$SERVER_PRIVATE_KEY
NOISE_REMOTE_PUBLIC_KEY=$CLI_PUBLIC_KEY
EOF
  echo
  echo "wrote $out_dir/client.env"
  echo "wrote $out_dir/server.env"
fi
