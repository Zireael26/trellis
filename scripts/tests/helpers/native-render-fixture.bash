# T34 option B: a release source that renders native hook registrations.
#
# native_render_fixture_source <source>
#   Copies the production (native-shaped) templates and the shipped native
#   manifest and adapter into <source>, and installs this host's shipped
#   companion under $TRELLIS_HOME the way release install does. Skips on a host
#   with no shipped asset (x86_64 macOS renders the legacy surface there).
#   Sets NATIVE_TARGET, NATIVE_OTHER_TARGET and NATIVE_COMPANION.
native_render_fixture_source() {
  local source="$1" repo manifest digest version
  repo="${REPO_ROOT:?}"
  manifest="$repo/core-rules/native/artifacts.json"
  # shellcheck disable=SC2034  # Out-parameters: attach-fastpath.bats reads NATIVE_OTHER_TARGET.
  case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) NATIVE_TARGET=aarch64-apple-darwin NATIVE_OTHER_TARGET=x86_64-unknown-linux-musl ;;
    Linux/x86_64) NATIVE_TARGET=x86_64-unknown-linux-musl NATIVE_OTHER_TARGET=aarch64-apple-darwin ;;
    *) skip 'no shipped native asset for this host' ;;
  esac
  cp "$repo/core-rules/templates/claude-settings.local.json" "$repo/core-rules/templates/codex-hooks.local.json" \
    "$source/core-rules/templates/" || return 1
  mkdir -p "$source/core-rules/native" || return 1
  cp "$manifest" "$repo/core-rules/native/hook-adapter.sh" "$source/core-rules/native/" || return 1
  digest="$(jq -r --arg target "$NATIVE_TARGET" '.assets[$target].sha256' "$manifest")" || return 1
  version="$(jq -r '.version' "$manifest")" || return 1
  NATIVE_COMPANION="$TRELLIS_HOME/bin/native/$version/$NATIVE_TARGET/$digest/trellis-hooks"
  mkdir -p "${NATIVE_COMPANION%/*}" || return 1
  cp "$repo/core-rules/native/$NATIVE_TARGET/trellis-hooks" "$NATIVE_COMPANION" || return 1
  chmod 500 "$NATIVE_COMPANION" || return 1
}

# native_render_fixture_rewrite <owner> <root> <destination> <mutation> [FROM TO]
#   Rewrites a donor's rendered JSON and keeps the owner record self-consistent
#   (artifact digest and render pair), so only the render check can tell it
#   from an exact donor. Mutations:
#     timeout  - one native registration's timeout changes (a tampered donor)
#     replace  - every string has FROM replaced by TO (another root or target)
#     legacy   - every registration naming a companion is dropped
native_render_fixture_rewrite() {
  python3 -I - "$@" <<'PY'
import base64, hashlib, json, os, sys
owner, root, destination, mutation = sys.argv[1:5]
path = os.path.join(root, destination)
doc = json.load(open(path))
def native(hook):
    return '/bin/native/' in json.dumps(hook)
if mutation == 'timeout':
    hook = next(h for blocks in doc['hooks'].values() for b in blocks for h in b['hooks'] if native(h))
    hook['timeout'] += 1
elif mutation == 'replace':
    old, new = sys.argv[5:7]
    doc = json.loads(json.dumps(doc).replace(json.dumps(old)[1:-1], json.dumps(new)[1:-1]))
elif mutation == 'legacy':
    for event in list(doc['hooks']):
        blocks = [dict(b, hooks=[h for h in b['hooks'] if not native(h)]) for b in doc['hooks'][event]]
        doc['hooks'][event] = [b for b in blocks if b['hooks']]
        if not doc['hooks'][event]:
            del doc['hooks'][event]
else:
    raise SystemExit('unknown mutation ' + mutation)
data = (json.dumps(doc, sort_keys=True, indent=2) + '\n').encode()
os.chmod(path, 0o600)
open(path, 'wb').write(data)
os.chmod(path, 0o600)
digest = hashlib.sha256(data).hexdigest()
record = json.load(open(owner))
for artifact in record['artifacts']:
    if artifact['path'] == destination:
        artifact['sha256'] = digest
def at(value, keys):
    for key in keys:
        value = value[key]
    return value
for render in record.get('renders', []):
    if render['path'] == destination:
        render['after_sha256'] = digest
        render['after_base64'] = base64.b64encode(data).decode()
        owned = []
        for key in render['owned_keys']:
            try:
                owned.append({'path': key['path'], 'value': at(doc, key['path'])})
            except (KeyError, IndexError):
                pass  # a dropped registration is no longer owned
        render['owned_keys'] = owned
os.chmod(owner, 0o600)
open(owner, 'w').write(json.dumps(record, sort_keys=True, separators=(',', ':')) + '\n')
os.chmod(owner, 0o600)
PY
}

# native_render_fixture_strings <file>: every JSON string in <file>, one per line.
native_render_fixture_strings() {
  jq -r '.. | strings' "$1"
}
