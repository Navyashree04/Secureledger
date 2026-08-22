#!/usr/bin/env bash
#
# End-to-end verification of a running SecureLedger instance.
# Mirrors scripts/verify.ps1 for Linux/macOS/Git-Bash users. Requires curl + jq.
#
# Usage:
#   # In one terminal:
#   mvn spring-boot:run
#   # Once you see "Started SecureLedgerApplication", in another terminal:
#   ./scripts/verify.sh
#
set -uo pipefail

BASE_URL="${1:-http://localhost:8080}"
PASS=0
FAIL=0

step() {
    local name="$1"; shift
    if "$@"; then
        echo -e "\033[32m[PASS]\033[0m $name"
        PASS=$((PASS+1))
    else
        echo -e "\033[31m[FAIL]\033[0m $name"
        FAIL=$((FAIL+1))
    fi
}

command -v jq >/dev/null 2>&1 || { echo "jq is required (apt install jq / brew install jq)"; exit 1; }

echo -e "\033[36m=== SecureLedger verification against $BASE_URL ===\033[0m"

SUFFIX=$(date +%Y%m%d%H%M%S)
USERNAME="verifyuser_${SUFFIX}"
PASSWORD="correct horse battery staple ${SUFFIX}"
TOKEN=""
ACCT1_ID=""
ACCT2_ID=""
IDEMP_KEY=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')

register() {
    local resp
    resp=$(curl -s -X POST "$BASE_URL/auth/register" -H 'Content-Type: application/json' \
        -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}")
    TOKEN=$(echo "$resp" | jq -r '.token // empty')
    [ -n "$TOKEN" ]
}

login() {
    local resp
    resp=$(curl -s -X POST "$BASE_URL/auth/login" -H 'Content-Type: application/json' \
        -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}")
    TOKEN=$(echo "$resp" | jq -r '.token // empty')
    [ -n "$TOKEN" ]
}

reject_unauthenticated() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/accounts")
    [ "$code" = "401" ]
}

create_account() {
    local type="$1" var="$2"
    local resp id
    resp=$(curl -s -X POST "$BASE_URL/accounts" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -d "{\"accountType\":\"$type\"}")
    id=$(echo "$resp" | jq -r '.id // empty')
    [ -n "$id" ] || return 1
    printf -v "$var" '%s' "$id"
    export "$var"
}

deposit() {
    local acct="$1" amount="$2" expected="$3"
    local resp bal
    resp=$(curl -s -X POST "$BASE_URL/accounts/$acct/deposit" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -d "{\"amount\":\"$amount\"}")
    bal=$(echo "$resp" | jq -r '.balanceAfter // empty')
    [ "$bal" = "$expected" ]
}

withdraw() {
    local acct="$1" amount="$2" expected="$3"
    local resp bal
    resp=$(curl -s -X POST "$BASE_URL/accounts/$acct/withdraw" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -d "{\"amount\":\"$amount\"}")
    bal=$(echo "$resp" | jq -r '.balanceAfter // empty')
    [ "$bal" = "$expected" ]
}

reject_over_withdrawal() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/accounts/$ACCT1_ID/withdraw" \
        -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"amount":"999999.00"}')
    [[ "$code" == "400" || "$code" == "409" || "$code" == "422" ]]
}

transfer() {
    curl -s -X POST "$BASE_URL/transfers" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -H "Idempotency-Key: $IDEMP_KEY" \
        -d "{\"fromAccountId\":$ACCT1_ID,\"toAccountId\":$ACCT2_ID,\"amount\":\"3000.00\"}" >/dev/null
}

replay_transfer_is_safe() {
    curl -s -X POST "$BASE_URL/transfers" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -H "Idempotency-Key: $IDEMP_KEY" \
        -d "{\"fromAccountId\":$ACCT1_ID,\"toAccountId\":$ACCT2_ID,\"amount\":\"3000.00\"}" >/dev/null
    local bal
    bal=$(curl -s "$BASE_URL/accounts/$ACCT1_ID" -H "Authorization: Bearer $TOKEN" | jq -r '.balance')
    [ "$bal" = "5000.0000" ]
}

history_has_entries() {
    local count
    count=$(curl -s "$BASE_URL/accounts/$ACCT1_ID/transactions?page=0&size=20" -H "Authorization: Bearer $TOKEN" \
        | jq '(.content // .) | length')
    [ "$count" -ge 3 ]
}

freeze_unfreeze() {
    curl -s -X PATCH "$BASE_URL/accounts/$ACCT1_ID/freeze" -H "Authorization: Bearer $TOKEN" >/dev/null
    local status
    status=$(curl -s "$BASE_URL/accounts/$ACCT1_ID" -H "Authorization: Bearer $TOKEN" | jq -r '.status')
    curl -s -X PATCH "$BASE_URL/accounts/$ACCT1_ID/unfreeze" -H "Authorization: Bearer $TOKEN" >/dev/null
    [ "$status" = "FROZEN" ]
}

final_balances_correct() {
    local b1 b2
    b1=$(curl -s "$BASE_URL/accounts/$ACCT1_ID" -H "Authorization: Bearer $TOKEN" | jq -r '.balance')
    b2=$(curl -s "$BASE_URL/accounts/$ACCT2_ID" -H "Authorization: Bearer $TOKEN" | jq -r '.balance')
    echo "        account $ACCT1_ID balance: $b1 (expect 5000.0000)"
    echo "        account $ACCT2_ID balance: $b2 (expect 3000.0000)"
    [ "$b1" = "5000.0000" ] && [ "$b2" = "3000.0000" ]
}

step "Register new user ($USERNAME)"          register
step "Login"                                   login
step "Reject request with no token (401)"      reject_unauthenticated
step "Create SAVINGS account"                  create_account SAVINGS ACCT1_ID
step "Create CURRENT account"                  create_account CURRENT ACCT2_ID
step "Deposit 10000"                           deposit "$ACCT1_ID" "10000.00" "10000.0000"
step "Withdraw 2000"                           withdraw "$ACCT1_ID" "2000.00" "8000.0000"
step "Reject over-withdrawal"                  reject_over_withdrawal
step "Transfer 3000 (account $ACCT1_ID -> $ACCT2_ID)" transfer
step "Replay Idempotency-Key is safe"          replay_transfer_is_safe
step "Transaction history has entries"         history_has_entries
step "Freeze / unfreeze account"               freeze_unfreeze
step "Final balances match expected math"      final_balances_correct

echo -e "\n\033[36m=== Summary: $PASS passed, $FAIL failed ===\033[0m"
[ "$FAIL" -eq 0 ]
