#!/usr/bin/env bash
# safe-run.sh -- the SAFE_RUN wrapper for name-sync: runs ONE safe command (the single argument) on the
# Blacksmith VM against the broker's OWN Vault (127.0.0.1:8200 on that VM, not the env Vault).
#   cp migrate/example/safe-run.sh runs/<env>/safe-run.sh
#   printf 'SAFE_RUN="bash runs/<env>/safe-run.sh"\n' > runs/<env>/vault.conf      # BLACKSMITH_ENV=<genesis env> if not sbx-us
#   bash runs/<env>/safe-run.sh "safe get secret/<a redis guid>:instance_name"       # the live check: prints the name
# How: (1) the director connection comes from `genesis @env:blacksmith bosh --connect`, eval'ed INSIDE this
# process only (the caller's shell is untouched -- the rule against eval'ing it interactively stands);
# (2) `bosh ssh -c` is then called directly, so the remote command reaches the VM untouched. It cannot go
# through `genesis ... bosh ssh -c`: genesis versions before 2026-07-22 (033b94ec) re-parse the whole bosh
# command inside single quotes (`script -q f -c '...'`), so any ' in it fails locally with "unexpected EOF
# while looking for matching `''", and every version rewrites `$NAME`/`$(` in arguments (lib/Genesis.pm:677).
# (3) On the VM: safe honours VAULT_ADDR / VAULT_TOKEN from the environment (safe main.go:66,94), so no
# `safe target`/`safe auth`; the root token is in /var/vcap/store/blacksmith/.vault/creds (root-owned JSON
# {seal_key, root_token} -- primer state-loops-vault.md), hence sudo; the bosh ssh user has it.
# Output comes back as `blacksmith/<id>: stdout | <line>` -- migrate.sh strips that prefix and looks for the
# exact value on a line (the read-back is the check, not the exit code).
ENV="${BLACKSMITH_ENV:-sbx-us}"
[ -n "${1:-}" ] || { echo "usage: safe-run.sh '<safe command>'" >&2; exit 2; }
command -v bosh >/dev/null 2>&1 || { echo "safe-run.sh: bosh CLI not on PATH" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "safe-run.sh: jq not on PATH" >&2; exit 2; }
conn=$(genesis "@$ENV:blacksmith" bosh --connect) || { echo "safe-run.sh: 'genesis @$ENV:blacksmith bosh --connect' failed" >&2; exit 2; }
eval "$conn"
[ -n "${BOSH_ENVIRONMENT:-}" ] || { echo "safe-run.sh: --connect did not export BOSH_ENVIRONMENT" >&2; exit 2; }
# the blacksmith deployment on that director: BLACKSMITH_DEPLOYMENT, or the single *-blacksmith deployment
DEP="${BLACKSMITH_DEPLOYMENT:-}"
if [ -z "$DEP" ]; then
  deps=$(bosh deployments --json | jq -r '.Tables[0].Rows[].name' | grep -E -- '-blacksmith$') || { echo "safe-run.sh: no *-blacksmith deployment on $BOSH_ENVIRONMENT (set BLACKSMITH_DEPLOYMENT)" >&2; exit 2; }
  [ "$(printf '%s\n' "$deps" | wc -l | tr -d ' ')" = 1 ] || { echo "safe-run.sh: several blacksmith deployments: $(printf '%s' "$deps" | tr '\n' ' ') -- set BLACKSMITH_DEPLOYMENT" >&2; exit 2; }
  DEP="$deps"
fi
exec bosh -d "$DEP" ssh blacksmith/0 -c "export PATH=/var/vcap/packages/safe/bin:\$PATH VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=\$(sudo sed -n 's/.*\"root_token\" *: *\"\([^\"]*\)\".*/\1/p' /var/vcap/store/blacksmith/.vault/creds); $1"
