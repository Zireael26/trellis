#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <pi-coding-agent-package-root>\n' "${0##*/}" >&2
  exit 64
fi

package_root=$1
package_json="$package_root/package.json"
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ ! -f "$package_json" ]]; then
  printf 'error: %s is not an @earendil-works/pi-coding-agent package root\n' "$package_root" >&2
  exit 66
fi

identity=$(node -e 'const { resolve } = require("node:path"); const p = require(resolve(process.argv[1])); process.stdout.write([p.name ?? "", p.version ?? ""].join("@"))' "$package_json")
patch_file=
bundle_file=
case "$identity" in
  '@earendil-works/pi-coding-agent@0.85.0')
    patch_file="$script_dir/pi-coding-agent-0.85.0-compaction-integrity.patch"
    bundle_file="$package_root/dist/bundle/chunks/chunk-WZB2R5YO.js"
    ;;
  '@earendil-works/pi-coding-agent@0.85.1')
    patch_file="$script_dir/pi-coding-agent-0.85.1-compaction-integrity.patch"
    bundle_file="$package_root/dist/bundle/chunks/chunk-JVUZSMYM.js"
    ;;
  *)
    printf 'error: unsupported @earendil-works/pi-coding-agent identity, found %s\n' "$identity" >&2
    exit 65
    ;;
esac

if [[ ! -f "$package_root/dist/core/compaction/compaction.js" || ! -f "$package_root/dist/core/compaction/utils.js" || ! -f "$bundle_file" ]]; then
  printf 'error: package %s is missing the exact SDK or bundle files for %s\n' "$package_root" "$identity" >&2
  exit 66
fi

check_bundle() {
# shellcheck disable=SC2016
node -e '
const fs = require("node:fs");
const [file, mode] = process.argv.slice(1);
let source = fs.readFileSync(file, "utf8");
const replacements = [
  ["if(response.stopReason===\"length\")return`${label} failed: generation hit the token cap and the summary is incomplete`}", "if(response.stopReason===\"length\")return`${label} failed: generation hit the token cap and the summary is incomplete`;if(response.stopReason===\"aborted\")return`${label} failed: generation was aborted`;if(!contentText(response.content).trim())return`${label} failed: response was empty`}"],
  ["let historyText=\"No prior history.\",historyUsage;if(messagesToSummarize.length>0){let historyResult=await generateSummaryWithUsage(", "let historyText=previousSummary??\"No prior history.\",historyUsage;if(messagesToSummarize.length>0){let historyResult=await generateSummaryWithUsage("],
  ["function truncateForSummary(text,maxChars){if(text.length<=maxChars)return text;let truncatedChars=text.length-maxChars;return`${text.slice(0,maxChars)}\n\n[... ${truncatedChars} more characters truncated]`}", "function truncateForSummary(text,maxChars){if(text.length<=maxChars)return text;let truncatedChars=text.length-maxChars,marker,retainedChars;for(;;){marker=`\n\n[... ${truncatedChars} middle characters truncated ...]\n\n`,retainedChars=maxChars-marker.length;let nextTruncatedChars=text.length-retainedChars;if(nextTruncatedChars===truncatedChars)break;truncatedChars=nextTruncatedChars}let headChars=Math.ceil(retainedChars/2),tailChars=retainedChars-headChars;return`${text.slice(0,headChars)}${marker}${text.slice(-tailChars)}`}"],
];
let state;
if (replacements.every(([before]) => source.split(before).length === 2) && replacements.every(([, after]) => !source.includes(after))) state = "original";
else if (replacements.every(([before]) => !source.includes(before)) && replacements.every(([, after]) => source.split(after).length === 2)) state = "applied";
else state = "drift";
if (mode === "apply") {
  if (state !== "original") throw new Error(`refusing bundle apply in ${state} state`);
  for (const [before, after] of replacements) {
    if (source.split(before).length !== 2) throw new Error("bundle replacement was not unique");
    source = source.replace(before, after);
  }
  fs.writeFileSync(file, source);
}
process.stdout.write(state);
' "$bundle_file" "$1"
}
bundle_state=drift
if ! bundle_state=$(check_bundle check); then
  printf 'error: exact bundle preflight failed for %s; refusing to apply\n' "$bundle_file" >&2
  exit 1
fi

patch_state=drift
if patch -d "$package_root" -p1 --fuzz=0 -f -R -s --dry-run -i "$patch_file" >/dev/null 2>&1; then
  patch_state=applied
elif patch -d "$package_root" -p1 --fuzz=0 -f -s --dry-run -i "$patch_file" >/dev/null 2>&1; then
  patch_state=original
fi

if [[ "$patch_state" == applied && "$bundle_state" == applied ]]; then
  printf 'already applied: %s\n' "$patch_file"
  exit 0
fi
if [[ "$patch_state" != original || "$bundle_state" != original ]]; then
  printf 'error: package source drifted; refusing to apply %s\n' "$patch_file" >&2
  exit 1
fi

if ! patch -d "$package_root" -p1 --fuzz=0 -f -s -i "$patch_file"; then
  printf 'error: apply failed for %s; package may be partially patched and was not rolled back\n' "$patch_file" >&2
  exit 1
fi
if ! check_bundle apply >/dev/null; then
  printf 'error: bundled apply failed for %s; package may be partially patched and was not rolled back\n' "$bundle_file" >&2
  exit 1
fi
if ! patch -d "$package_root" -p1 --fuzz=0 -f -R -s --dry-run -i "$patch_file" >/dev/null 2>&1; then
  printf 'error: final SDK verification failed for %s; package may be partially patched and was not rolled back\n' "$patch_file" >&2
  exit 1
fi
final_bundle_state=drift
if ! final_bundle_state=$(check_bundle check); then
  printf 'error: final bundle verification failed for %s; package may be partially patched and was not rolled back\n' "$bundle_file" >&2
  exit 1
fi
if [[ "$final_bundle_state" != applied ]]; then
  printf 'error: final bundle verification failed for %s; package may be partially patched and was not rolled back\n' "$bundle_file" >&2
  exit 1
fi
printf 'applied: %s\n' "$patch_file"
