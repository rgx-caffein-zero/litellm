#!/usr/bin/env bash
#
# Tests for scripts/certs/. Each case runs against a fresh temporary directory.
# Usage: tests/certs.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREATE_CA="$ROOT/scripts/certs/create-ca.sh"
ISSUE_CERT="$ROOT/scripts/certs/issue-server-cert.sh"
# shellcheck source=tests/lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=scripts/certs/lib.sh
source "$ROOT/scripts/certs/lib.sh"

# Wrappers that always pass the output directories, so tests never fall back to
# the repository's own certs/ directory.
create_ca() {
  "$CREATE_CA" "$@" certs/ca
}

issue_cert() {
  "$ISSUE_CERT" "$@" certs/ca certs
}

# Signs a certificate with the CA key directly, bypassing issue-server-cert.sh,
# to simulate misuse of a leaked CA key. Extra extension lines are appended as-is.
sign_with_ca() {
  local out="$1" extensions="$2"
  printf 'basicConstraints=critical,CA:FALSE\n%s\n' "$extensions" >"$out.ext"
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$out.key" -out "$out.csr" -subj "/O=Forged Corporation" 2>/dev/null
  openssl x509 -req -in "$out.csr" -CA certs/ca/ca.crt -CAkey certs/ca/ca.key \
    -CAcreateserial -out "$out.crt" -days 1 -extfile "$out.ext" 2>/dev/null
}

test_ca_range_to_ip_mask_converts_prefix() {
  [[ "$(certs::ca_range_to_ip_mask 10.1.2.3/32)" == "10.1.2.3/255.255.255.255" ]]
  [[ "$(certs::ca_range_to_ip_mask 10.1.2.0/24)" == "10.1.2.0/255.255.255.0" ]]
  [[ "$(certs::ca_range_to_ip_mask 172.16.0.0/12)" == "172.16.0.0/255.240.0.0" ]]
  [[ "$(certs::ca_range_to_ip_mask 10.0.0.0/8)" == "10.0.0.0/255.0.0.0" ]]
}

test_ca_range_to_ip_mask_rejects_invalid_ranges() {
  expect_fail certs::ca_range_to_ip_mask 10.1.2.3
  expect_fail certs::ca_range_to_ip_mask 10.1.2.0/33
  expect_fail certs::ca_range_to_ip_mask 10.1.256.0/24
  expect_fail certs::ca_range_to_ip_mask 0.0.0.0/0
  expect_fail certs::ca_range_to_ip_mask 10.0.0.0/7
  expect_fail certs::ca_range_to_ip_mask 10.1.2.3/24
  # Leading zeros are ambiguous (some parsers read them as octal).
  expect_fail certs::ca_range_to_ip_mask 10.0.0.0/08
  expect_fail certs::ca_range_to_ip_mask 010.0.0.0/8
}

test_is_ipv4_rejects_leading_zeros() {
  certs::is_ipv4 10.0.0.1
  certs::is_ipv4 0.0.0.0
  expect_fail certs::is_ipv4 010.1.2.3
  expect_fail certs::is_ipv4 10.01.2.3
}

test_leaked_ca_control_certificate_verifies() {
  # Control for the test_leaked_ca_* cases: a certificate that satisfies every
  # CA constraint, signed the same way, must verify. Otherwise those tests could
  # pass because sign_with_ca itself produces broken certificates.
  create_ca 10.1.2.3/32
  sign_with_ca allowed $'extendedKeyUsage=serverAuth\nsubjectAltName=IP:10.1.2.3'
  openssl verify -CAfile certs/ca/ca.crt -purpose sslserver -verify_ip 10.1.2.3 allowed.crt
}

test_issued_cert_verifies_for_server_ip() {
  create_ca 10.1.2.0/24
  issue_cert 10.1.2.3
  openssl verify -CAfile certs/ca/ca.crt -purpose sslserver -verify_ip 10.1.2.3 certs/server.crt
  openssl x509 -in certs/server.crt -noout -ext subjectAltName | grep -q 'IP Address:10.1.2.3'
}

test_issued_cert_rejected_for_other_ip() {
  create_ca 10.1.2.0/24
  issue_cert 10.1.2.3
  expect_fail openssl verify -CAfile certs/ca/ca.crt -verify_ip 10.1.2.4 certs/server.crt
}

test_private_keys_are_owner_only() {
  # stat -c is GNU coreutils; the project targets Linux servers.
  create_ca 10.1.2.3/32
  issue_cert 10.1.2.3
  [[ "$(stat -c %a certs/ca)" == "700" ]]
  [[ "$(stat -c %a certs/ca/ca.key)" == "600" ]]
  [[ "$(stat -c %a certs/server.key)" == "600" ]]
}

test_issue_fails_outside_ca_range() {
  create_ca 10.1.2.3/32
  expect_fail issue_cert 10.9.9.9
  [[ ! -e certs/server.crt ]]
}

test_leaked_ca_cannot_sign_other_ip() {
  create_ca 10.1.2.3/32
  sign_with_ca forged $'extendedKeyUsage=serverAuth\nsubjectAltName=IP:192.168.0.1'
  expect_fail openssl verify -CAfile certs/ca/ca.crt forged.crt
}

test_leaked_ca_cannot_sign_dns_name() {
  create_ca 10.1.2.3/32
  sign_with_ca forged $'extendedKeyUsage=serverAuth\nsubjectAltName=DNS:www.example.com'
  expect_fail openssl verify -CAfile certs/ca/ca.crt forged.crt
}

test_leaked_ca_cannot_sign_email_cert() {
  create_ca 10.1.2.3/32
  sign_with_ca forged $'extendedKeyUsage=emailProtection\nsubjectAltName=email:ceo@example.com'
  expect_fail openssl verify -CAfile certs/ca/ca.crt forged.crt
  expect_fail openssl verify -CAfile certs/ca/ca.crt -purpose smimesign forged.crt
}

test_leaked_ca_cannot_sign_client_auth_cert() {
  # No SAN, so only the CA's extendedKeyUsage restriction can reject it.
  create_ca 10.1.2.3/32
  sign_with_ca forged 'extendedKeyUsage=clientAuth'
  expect_fail openssl verify -CAfile certs/ca/ca.crt -purpose sslclient forged.crt
}

test_ca_extended_key_usage_is_server_auth_only() {
  # Windows applies the CA's EKU to every certificate below it, so code signing
  # and S/MIME certificates signed with a leaked key are rejected. OpenSSL before
  # 3.2 has no codesign purpose; test_leaked_ca_cannot_sign_client_auth_cert
  # exercises the same EKU check.
  create_ca 10.1.2.3/32
  [[ "$(openssl x509 -in certs/ca/ca.crt -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' ')" == "TLSWebServerAuthentication" ]]
}

test_create_ca_does_not_overwrite() {
  create_ca 10.1.2.3/32
  local before
  before="$(openssl x509 -in certs/ca/ca.crt -noout -fingerprint -sha256)"
  expect_fail create_ca 10.1.2.3/32
  [[ "$(openssl x509 -in certs/ca/ca.crt -noout -fingerprint -sha256)" == "$before" ]]
}

test_create_ca_rejects_invalid_arguments() {
  expect_fail "$CREATE_CA"
  expect_fail create_ca 10.1.2.3
  expect_fail create_ca 0.0.0.0/0
  [[ ! -e certs ]]
}

test_issue_rejects_invalid_arguments() {
  create_ca 10.1.2.3/32
  expect_fail "$ISSUE_CERT"
  expect_fail issue_cert not-an-ip
  [[ ! -e certs/server.crt ]]
}

test_issue_fails_when_output_path_is_a_directory() {
  create_ca 10.1.2.3/32 >/dev/null
  mkdir -p certs/server.key
  expect_fail issue_cert 10.1.2.3 2>err.log
  grep -q 'ディレクトリになっています' err.log
  [[ ! -e certs/.server.key.tmp && -z "$(ls -A certs/server.key)" ]]
}

test_issue_fails_without_ca() {
  expect_fail issue_cert 10.1.2.3
}

run_all_tests
