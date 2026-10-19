#!/usr/bin/env bash
# safe-run.sh -- the SAFE_RUN wrapper for name-sync: runs ONE safe command (the single argument) on the
# Blacksmith VM against the broker's OWN Vault (127.0.0.1:8200 on that VM, not the env Vault).
#   cp migrate/example/safe-run.sh runs/<env>/safe-run.sh
#   printf 'SAFE_RUN="bash runs/<env>/safe-run.sh"\n' > runs/<env>/vault.conf      # BLACKSMITH_ENV=<genesis env> if not sbx-us
#   bash runs/<env>/safe-run.sh "safe get secret/<a redis guid>:instance_name"       # the live check: prints the name
# How it works: safe honours VAULT_ADDR / VAULT_TOKEN from the environment (safe main.go:66,94), so no
# `safe target` and no `safe auth` are needed; the root token is in /var/vcap/store/blacksmith/.vault/creds
# (root-owned JSON {seal_key, root_token} -- primer state-loops-vault.md), hence sudo; the bosh ssh user has it.
# Output comes back as `blacksmith/<id>: stdout | <line>` -- migrate.sh strips that prefix and looks for the
# exact value on a line (the read-back is the check, not the exit code).
ENV="${BLACKSMITH_ENV:-sbx-us}"
[ -n "${1:-}" ] || { echo "usage: safe-run.sh '<safe command>'" >&2; exit 2; }
exec genesis "@$ENV:blacksmith" bosh ssh blacksmith/0 -c "export PATH=/var/vcap/packages/safe/bin:\$PATH VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=\$(sudo sed -n 's/.*\"root_token\" *: *\"\([^\"]*\)\".*/\1/p' /var/vcap/store/blacksmith/.vault/creds); $1"
