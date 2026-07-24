#!/bin/bash
# Corpus coverage assertions for tests/configs/
#
# tests/test-with-nginx.sh proves every corpus config PARSES. This script proves
# the corpus is actually diverse — that the count was not reached by adding forty
# near-identical WordPress vhosts, and that every shape the checklist calls
# required is genuinely present.
#
# Enforces, against tests/configs/SHAPES.md:
#   1. every valid config declares  # Shape: <id>  and  # Provenance: ...
#   2. every shape id in a config appears in SHAPES.md (no undeclared shapes)
#   3. every required shape id in SHAPES.md is matched by >= 1 config
#   4. every shape directory is non-empty
#   5. >= MIN_CONFIGS valid configs
#   6. no two configs are near-duplicates by directive-name set
#
# Run with --write-manifest to regenerate tests/configs/MANIFEST.tsv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/configs"
SHAPES_FILE="${CONFIGS_DIR}/SHAPES.md"
MANIFEST="${CONFIGS_DIR}/MANIFEST.tsv"

MIN_CONFIGS=30
# Jaccard similarity over each config's set of directive names. Two files above
# this are structurally the same config wearing a different hostname.
DUP_THRESHOLD=0.92

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
log_info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

echo "=========================================="
echo "  Config Corpus Coverage"
echo "=========================================="

WRITE_MANIFEST=0
[ "${1:-}" = "--write-manifest" ] && WRITE_MANIFEST=1

################################################################################
# Collect the valid corpus (everything except the negative fixtures in invalid/)
################################################################################

# `find` rather than a glob: the corpus is two levels deep and bash here has no
# globstar, so `**/*.conf` would silently mean the same as `*/*.conf`.
# No mapfile and no `declare -A` anywhere in this file: run-tests.sh asserts the
# tree stays bash 3.2 compatible, which is what macOS ships.
CONFIGS=()
while IFS= read -r line; do CONFIGS+=("$line"); done < <(find "$CONFIGS_DIR" -name '*.conf' -not -path '*/invalid/*' | sort)
INVALID=()
while IFS= read -r line; do INVALID+=("$line"); done < <(find "$CONFIGS_DIR" -path '*/invalid/*' -name '*.conf' | sort)

echo ""
echo "Valid configs: ${#CONFIGS[@]}   Negative fixtures: ${#INVALID[@]}"
echo ""

################################################################################
# 1 + 2. Headers: every config declares a shape and a provenance
################################################################################

# bash 3.2 has no associative arrays, so the file->shape mapping is a TSV in a
# temp file and lookups are greps against it.
SHAPE_MAP=$(mktemp)
trap 'rm -f "$SHAPE_MAP"' EXIT
missing_header=""
undeclared=""

for conf in "${CONFIGS[@]}" "${INVALID[@]}"; do
    rel="${conf#"$CONFIGS_DIR"/}"

    # `tr -d '\r'`: edge-cases/crlf-line-endings.conf is CRLF on purpose, and a
    # trailing \r would otherwise end up inside the captured shape id.
    head_txt=$(head -12 "$conf" | tr -d '\r')

    shape=$(printf '%s' "$head_txt" | grep -m1 -oE '^#[[:space:]]*Shape:[[:space:]]*[a-z0-9-]+' | awk '{print $NF}' || true)
    prov=$(printf '%s' "$head_txt" | grep -cE '^#[[:space:]]*Provenance:' || true)

    if [ -z "$shape" ]; then
        missing_header="${missing_header}\n    $rel — no '# Shape:' header"
        continue
    fi
    if [ "$prov" -eq 0 ]; then
        missing_header="${missing_header}\n    $rel — no '# Provenance:' header"
        continue
    fi

    printf '%s\t%s\n' "$rel" "$shape" >> "$SHAPE_MAP"
    if ! grep -qE "\`${shape}\`" "$SHAPES_FILE"; then
        undeclared="${undeclared}\n    $rel — shape '$shape' is not listed in SHAPES.md"
    fi
done

if [ -n "$missing_header" ]; then
    log_fail "configs missing a Shape/Provenance header:$(echo -e "$missing_header")"
else
    log_pass "all $(( ${#CONFIGS[@]} + ${#INVALID[@]} )) configs declare a shape and a provenance"
fi

if [ -n "$undeclared" ]; then
    log_fail "shapes used but not listed in SHAPES.md:$(echo -e "$undeclared")"
else
    log_pass "every declared shape appears in SHAPES.md"
fi

################################################################################
# 3. Every required shape in SHAPES.md is covered by a config
#
# Required shapes are the backtick-quoted ids in the tables ABOVE the backlog
# heading. Backlog rows are deliberately not enforced — see SHAPES.md.
################################################################################

REQUIRED=()
while IFS= read -r line; do REQUIRED+=("$line"); done < <(
    awk '/^## Backlog/ { exit } /^\| `/ { print }' "$SHAPES_FILE" \
    | sed -E 's/^\| `([a-z0-9-]+)`.*/\1/' | sort -u
)

uncovered=""
for shape in "${REQUIRED[@]}"; do
    cut -f2 "$SHAPE_MAP" | grep -qx "$shape" || uncovered="${uncovered}\n    $shape"
done

if [ -n "$uncovered" ]; then
    log_fail "required shapes with no config:$(echo -e "$uncovered")"
else
    log_pass "all ${#REQUIRED[@]} required shapes have at least one config"
fi

################################################################################
# 4. Every shape directory is non-empty
################################################################################

empty_dirs=""
while IFS= read -r d; do
    [ "$d" = "$CONFIGS_DIR" ] && continue
    n=$(find "$d" -maxdepth 1 -name '*.conf' | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] || empty_dirs="${empty_dirs}\n    ${d#"$CONFIGS_DIR"/}"
done < <(find "$CONFIGS_DIR" -type d)

if [ -n "$empty_dirs" ]; then
    log_fail "shape directories with no configs:$(echo -e "$empty_dirs")"
else
    log_pass "every shape directory contains at least one config"
fi

################################################################################
# 5. Hard floor on count
################################################################################

if [ "${#CONFIGS[@]}" -ge "$MIN_CONFIGS" ]; then
    log_pass "corpus size ${#CONFIGS[@]} >= floor of $MIN_CONFIGS"
else
    log_fail "corpus size ${#CONFIGS[@]} is below the floor of $MIN_CONFIGS"
fi

################################################################################
# 6. Near-duplicate detection
#
# Fingerprint = the set of distinct directive names in a file (first token of
# each non-comment, non-blank line, closing braces dropped). Two configs whose
# fingerprints overlap above DUP_THRESHOLD are the same config with the
# hostnames changed, and inflate the count without adding coverage.
################################################################################

fingerprints=$(
    for conf in "${CONFIGS[@]}"; do
        rel="${conf#"$CONFIGS_DIR"/}"
        names=$(tr -d '\r' < "$conf" \
            | awk '{ sub(/#.*/, ""); gsub(/^[ \t]+/, ""); if ($1 == "" || $1 == "}" || $1 == "{") next; d=$1; sub(/[;{]$/, "", d); if (d != "") print d }' \
            | sort -u | tr '\n' ' ')
        printf '%s\t%s\n' "$rel" "$names"
    done
)

dupes=$(printf '%s\n' "$fingerprints" | awk -F'\t' -v thr="$DUP_THRESHOLD" '
{ file[NR] = $1; set[NR] = $2; n = NR }
END {
    for (i = 1; i <= n; i++) {
        for (j = i + 1; j <= n; j++) {
            delete a; delete seen
            ca = split(set[i], A, " ")
            cb = split(set[j], B, " ")
            ua = 0; ub = 0; inter = 0
            for (k = 1; k <= ca; k++) if (A[k] != "" && !(A[k] in a)) { a[A[k]] = 1; ua++ }
            for (k = 1; k <= cb; k++) if (B[k] != "" && !(B[k] in seen)) {
                seen[B[k]] = 1; ub++
                if (B[k] in a) inter++
            }
            union = ua + ub - inter
            if (union == 0) continue
            jac = inter / union
            if (jac >= thr) printf "    %.3f  %s  ~=  %s\n", jac, file[i], file[j]
        }
    }
}')

if [ -n "$dupes" ]; then
    log_fail "near-duplicate configs (Jaccard >= $DUP_THRESHOLD over directive names):"
    printf '%s\n' "$dupes"
else
    log_pass "no two configs exceed the $DUP_THRESHOLD near-duplicate threshold"
fi

################################################################################
# Manifest
################################################################################

generate_manifest() {
    printf '# Generated by tests/test-corpus.sh --write-manifest. Do not hand-edit.\n'
    printf '# path\tshape\tprovenance_type\tsource\n'
    for conf in "${CONFIGS[@]}" "${INVALID[@]}"; do
        rel="${conf#"$CONFIGS_DIR"/}"
        head_txt=$(head -12 "$conf" | tr -d '\r')
        shape=$(awk -F'\t' -v f="$rel" '$1 == f { print $2; exit }' "$SHAPE_MAP")
        [ -n "$shape" ] || shape=UNKNOWN
        # A provenance can wrap onto indented continuation lines; take the whole
        # block, or a URL sitting on line two is lost and the row misclassifies.
        src=$(printf '%s\n' "$head_txt" | awk '
            /^#[[:space:]]*Provenance:/ { on = 1; sub(/^#[[:space:]]*Provenance:[[:space:]]*/, ""); print; next }
            on && /^#[[:space:]][[:space:]][[:space:]]+/ { sub(/^#[[:space:]]+/, ""); print; next }
            on { exit }' | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')
        case "$src" in
            *DERIVED*|derived*)      ptype=derived ;;
            crafted*)                ptype=crafted ;;
            http*|*github.com*|*nginx.org*|*wordpress.org*|*mozilla*) ptype=upstream ;;
            *:/etc/*|*:/*)           ptype=fleet ;;
            *)                       ptype=other ;;
        esac
        printf '%s\t%s\t%s\t%s\n' "$rel" "$shape" "$ptype" "$src"
    done
}

if [ "$WRITE_MANIFEST" -eq 1 ]; then
    generate_manifest > "$MANIFEST"
    log_info "wrote $MANIFEST"
else
    if [ ! -f "$MANIFEST" ]; then
        log_fail "$MANIFEST is missing — run: ./tests/test-corpus.sh --write-manifest"
    elif diff -q <(generate_manifest) "$MANIFEST" >/dev/null 2>&1; then
        log_pass "MANIFEST.tsv is in sync with the corpus"
    else
        log_fail "MANIFEST.tsv is stale — run: ./tests/test-corpus.sh --write-manifest"
        diff <(generate_manifest) "$MANIFEST" | head -20 || true
    fi
fi

################################################################################
# Backlog report — informational, never fails the suite
################################################################################

echo ""
echo "Backlog (wanted shapes not yet sourced — see SHAPES.md):"
awk '/^## Backlog/ { on = 1 } on && /^\| / && $0 !~ /^\|[ -]*\|[ -]*\|$/ && $0 !~ /^\| Shape \|/ { print "    " $0 }' "$SHAPES_FILE"

echo ""
echo "=========================================="
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "=========================================="

[ "$FAIL" -eq 0 ] || exit 1
