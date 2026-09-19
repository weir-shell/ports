#!/bin/sh
# Generate deterministic-shape test keys for the JWS/thumbprint tests.
# (Key VALUES are random; the tests cross-check weir vs openssl, not fixed KATs.)
set -e
d="$(dirname "$0")"
[ -f "$d/ec.key" ] || openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$d/ec.key" 2>/dev/null
[ -f "$d/rsa.key" ] || openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$d/rsa.key" 2>/dev/null
echo "keys ready in $d"
