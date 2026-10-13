#!/bin/bash
# Repository lint: dashes, secrets, env dumping, team id, plist/json validity, string catalogs.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
fail() { echo "lint: $*" >&2; status=1; }

# Files a person reads or that ship. design/ and PLAN.md are read-only inputs.
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(
  git ls-files -z --cached --others --exclude-standard -- \
    AGENTS.md README.md LICENSE Makefile project.yml Config App Helpers Packages UITests scripts
)

# 1. No em dash (U+2014) or en dash (U+2013).
emdash=$(printf '\xe2\x80\x94'); endash=$(printf '\xe2\x80\x93')
if hits=$(grep -n -I -e "$emdash" -e "$endash" -- "${files[@]}" 2>/dev/null); then
  fail "em or en dash found:"; echo "$hits" >&2
fi

# 2. Secrets (patterns assembled so this script does not match itself; PLAN.md lists them as text).
p_key="sk-""ant-"; p_pem="BEGIN [A-Z ]*PRIV""ATE KEY"; p_env="ANTHROPIC_API""_KEY="
if hits=$(git ls-files -z -- . ":!PLAN.md" | xargs -0 grep -n -I -E -e "$p_key" -e "$p_pem" -e "$p_env" -- 2>/dev/null); then
  fail "possible secret:"; echo "$hits" | cut -c1-160 >&2
fi

# 3. Environment dumping or nonce printing.
p_dump='(^|[^A-Za-z_])printenv([^A-Za-z_]|$)|(^|[;&|[:space:]])env[[:space:]]*($|\|)|print\(.*(environment|[Nn]once)|NSLog\(.*(environment|[Nn]once)|echo .*\$\{?LIGHTWELL_MCP_NONCE|set -x'
if hits=$(grep -n -I -E -e "$p_dump" -- "${files[@]}" 2>/dev/null | grep -v '^scripts/lint.sh:'); then
  fail "environment or nonce output:"; echo "$hits" >&2
fi

# 4. Team-specific values only in the .example file.
team="AP2V8""UN6K5"
if hits=$(git ls-files -z | xargs -0 grep -l -I -e "$team" -- 2>/dev/null | grep -v -e '^Config/Signing.local.xcconfig.example$'); then
  fail "team id committed outside the .example file:"; echo "$hits" >&2
fi

# 5. Property lists and JSON resources parse.
for f in App/Info.plist Config/*.entitlements; do
  plutil -lint -s "$f" >/dev/null || fail "invalid plist: $f"
done
while IFS= read -r -d '' f; do
  python3 -I -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$f" 2>/dev/null || fail "invalid JSON: $f"
done < <(git ls-files -z --cached --others --exclude-standard -- '*.xcstrings' '*.json' ':!design')

# 6. Literal UI strings in App/ are String Catalog keys.
python3 -I scripts/lint_strings.py . || fail "UI strings missing from App/Resources/*.xcstrings"

if [ "$status" -eq 0 ]; then echo "lint: OK"; fi
exit "$status"
