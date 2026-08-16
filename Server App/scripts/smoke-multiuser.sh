#!/usr/bin/env bash
# Proves two accounts on one server can't see each other's messages.
# Run against a throwaway data dir, never your live one:
#
#   DATA_DIR=/tmp/tn-test REGISTRATION_SECRET=test PORT=8799 npm start &
#   ./scripts/smoke-multiuser.sh
#
set -euo pipefail
BASE=${BASE:-http://127.0.0.1:8799}
SECRET=${REGISTRATION_SECRET:-test}

json() { python3 -c "import sys,json;print(json.load(sys.stdin)$1)"; }

signup() {  # email, phone -> token
  local start; start=$(curl -s -X POST "$BASE/auth/start" -H 'content-type: application/json' \
    -d "{\"secret\":\"$SECRET\",\"email\":\"$1\",\"phone\":\"$2\"}")
  local id code
  id=$(echo "$start" | json "['challengeId']")
  code=$(echo "$start" | json "['code']")
  curl -s -X POST "$BASE/auth/verify" -H 'content-type: application/json' \
    -d "{\"challengeId\":\"$id\",\"code\":\"$code\",\"label\":\"test\",\"platform\":\"android\"}" | json "['token']"
}

A=$(signup "a@example.com" "+351911111111")
B=$(signup "b@example.com" "+351922222222")
echo "signed up two accounts"

curl -s -X POST "$BASE/ingest" -H "authorization: Bearer $A" -H 'content-type: application/json' \
  -d '{"messages":[{"direction":"in","address":"+351933333333","body":"only A should see this","ts":1700000000000}]}' > /dev/null

a_sees=$(curl -s "$BASE/delta?since=0" -H "authorization: Bearer $A" | json "['messages'].__len__()")
b_sees=$(curl -s "$BASE/delta?since=0" -H "authorization: Bearer $B" | json "['messages'].__len__()")

echo "A sees $a_sees message(s); B sees $b_sees"
[ "$a_sees" = "1" ] || { echo "FAIL: A should see its own message"; exit 1; }
[ "$b_sees" = "0" ] || { echo "FAIL: B can see A's messages"; exit 1; }

echo "PASS — accounts are isolated"
