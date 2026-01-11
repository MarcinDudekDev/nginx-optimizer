#!/bin/bash

################################################################################
# registry.sh - Feature Registration System
################################################################################
# Provides a declarative way to register and query nginx optimization features.
# Bash 3.2 compatible (no associative arrays).
#
# Storage Format:
# REGISTERED_FEATURES contains pipe-separated feature entries.
# Each entry is semicolon-separated fields:
#   id;display;pattern;scope;template;context;aliases;min_version;prereq;custom_detect;custom_apply
#
# Example:
#   "http3;HTTP/3 QUIC;listen.*quic;per-site;http3-quic.conf;server;quic;1.25;;0;0"
################################################################################

# Storage for registered features (pipe-separated list of semicolon-separated fields)
REGISTERED_FEATURES=""

# Field indices for parsing
readonly FIELD_ID=1
readonly FIELD_DISPLAY=2
readonly FIELD_PATTERN=3
readonly FIELD_SCOPE=4
readonly FIELD_TEMPLATE=5
readonly FIELD_CONTEXT=6
readonly FIELD_ALIASES=7
readonly FIELD_MIN_VERSION=8
readonly FIELD_PREREQ=9
readonly FIELD_CUSTOM_DETECT=10
readonly FIELD_CUSTOM_APPLY=11

################################################################################
# Feature Registration
################################################################################

# feature_register - Register current feature module
# Called by feature modules after setting FEATURE_* variables
# Returns: 0 on success, 1 on error
feature_register() {
    # Validate required fields
    if [[ -z "${FEATURE_ID:-}" ]]; then
        echo "ERROR: FEATURE_ID is required" >&2
        return 1
    fi
    if [[ -z "${FEATURE_DISPLAY:-}" ]]; then
        echo "ERROR: FEATURE_DISPLAY is required for $FEATURE_ID" >&2
        return 1
    fi
    if [[ -z "${FEATURE_DETECT_PATTERN:-}" ]]; then
        echo "ERROR: FEATURE_DETECT_PATTERN is required for $FEATURE_ID" >&2
        return 1
    fi
    if [[ -z "${FEATURE_SCOPE:-}" ]]; then
        echo "ERROR: FEATURE_SCOPE is required for $FEATURE_ID" >&2
        return 1
    fi

    # Check if already registered
    if feature_exists "$FEATURE_ID"; then
        echo "ERROR: Feature '$FEATURE_ID' already registered" >&2
        return 1
    fi

    # Determine custom function flags (normalize hyphens to underscores for function names)
    local has_custom_detect=0
    local has_custom_apply=0
    local func_id
    func_id=$(_normalize_id_for_func "$FEATURE_ID")
    if declare -f "feature_detect_custom_${func_id}" &>/dev/null; then
        has_custom_detect=1
    fi
    if declare -f "feature_apply_custom_${func_id}" &>/dev/null; then
        has_custom_apply=1
    fi

    # Build feature entry (semicolon-separated)
    local entry="${FEATURE_ID}"
    entry="${entry};${FEATURE_DISPLAY}"
    entry="${entry};${FEATURE_DETECT_PATTERN}"
    entry="${entry};${FEATURE_SCOPE}"
    entry="${entry};${FEATURE_TEMPLATE:-}"
    entry="${entry};${FEATURE_TEMPLATE_CONTEXT:-server}"
    entry="${entry};${FEATURE_ALIASES:-}"
    entry="${entry};${FEATURE_NGINX_MIN_VERSION:-}"
    entry="${entry};${FEATURE_PREREQ_CHECK:-}"
    entry="${entry};${has_custom_detect}"
    entry="${entry};${has_custom_apply}"

    # Append to registry
    if [[ -z "$REGISTERED_FEATURES" ]]; then
        REGISTERED_FEATURES="$entry"
    else
        REGISTERED_FEATURES="${REGISTERED_FEATURES}|${entry}"
    fi

    # Clear feature variables to prevent pollution
    unset FEATURE_ID FEATURE_DISPLAY FEATURE_DETECT_PATTERN FEATURE_SCOPE
    unset FEATURE_TEMPLATE FEATURE_TEMPLATE_CONTEXT FEATURE_ALIASES
    unset FEATURE_NGINX_MIN_VERSION FEATURE_PREREQ_CHECK

    return 0
}

################################################################################
# Query Functions
################################################################################

# feature_exists - Check if feature is registered
# Args: $1 = feature_id
# Returns: 0 if exists, 1 if not
feature_exists() {
    local id="$1"
    [[ -z "$id" ]] && return 1

    local entry
    entry=$(_find_feature "$id")
    [[ -n "$entry" ]]
}

# feature_get - Get feature data by ID
# Args: $1 = feature_id, $2 = field name (id|display|pattern|scope|template|context|aliases|min_version|prereq|custom_detect|custom_apply)
# Prints: field value
# Returns: 0 if found, 1 if not
feature_get() {
    local id="$1"
    local field_name="$2"

    [[ -z "$id" ]] && return 1
    [[ -z "$field_name" ]] && return 1

    local entry
    entry=$(_find_feature "$id")
    [[ -z "$entry" ]] && return 1

    # Map field name to index
    local field_idx
    case "$field_name" in
        id) field_idx=$FIELD_ID ;;
        display) field_idx=$FIELD_DISPLAY ;;
        pattern) field_idx=$FIELD_PATTERN ;;
        scope) field_idx=$FIELD_SCOPE ;;
        template) field_idx=$FIELD_TEMPLATE ;;
        context) field_idx=$FIELD_CONTEXT ;;
        aliases) field_idx=$FIELD_ALIASES ;;
        min_version) field_idx=$FIELD_MIN_VERSION ;;
        prereq) field_idx=$FIELD_PREREQ ;;
        custom_detect) field_idx=$FIELD_CUSTOM_DETECT ;;
        custom_apply) field_idx=$FIELD_CUSTOM_APPLY ;;
        *)
            echo "ERROR: Unknown field '$field_name'" >&2
            return 1
            ;;
    esac

    _get_field "$entry" "$field_idx"
    return 0
}

# feature_get_by_alias - Resolve alias to feature ID
# Args: $1 = alias or id
# Prints: feature_id
# Returns: 0 if found, 1 if not
feature_get_by_alias() {
    local alias="$1"
    [[ -z "$alias" ]] && return 1

    # First check if it's a direct ID match
    if feature_exists "$alias"; then
        echo "$alias"
        return 0
    fi

    # Search through all features for alias match
    local entry
    while IFS='|' read -r entry; do
        [[ -z "$entry" ]] && continue

        local aliases
        aliases=$(_get_field "$entry" "$FIELD_ALIASES")

        # Check if alias is in comma-separated list
        if [[ -n "$aliases" ]]; then
            local a
            for a in ${aliases//,/ }; do
                if [[ "$a" == "$alias" ]]; then
                    _get_field "$entry" "$FIELD_ID"
                    return 0
                fi
            done
        fi
    done <<< "$(echo "$REGISTERED_FEATURES" | tr '|' '\n')"

    return 1
}

# feature_list - List all registered features
# Prints: One feature_id per line
feature_list() {
    [[ -z "$REGISTERED_FEATURES" ]] && return 0

    local entry
    while IFS='|' read -r entry; do
        [[ -z "$entry" ]] && continue
        _get_field "$entry" "$FIELD_ID"
    done <<< "$(echo "$REGISTERED_FEATURES" | tr '|' '\n')"
}

# feature_list_all - List features with display names
# Prints: "id|display_name" per line
feature_list_all() {
    [[ -z "$REGISTERED_FEATURES" ]] && return 0

    local entry
    while IFS='|' read -r entry; do
        [[ -z "$entry" ]] && continue
        local id display
        id=$(_get_field "$entry" "$FIELD_ID")
        display=$(_get_field "$entry" "$FIELD_DISPLAY")
        echo "${id}|${display}"
    done <<< "$(echo "$REGISTERED_FEATURES" | tr '|' '\n')"
}

################################################################################
# Detection and Application
################################################################################

# feature_detect - Run detection for a feature
# Args: $1 = feature_id, $2 = config_file, $3 = site_name (optional)
# Returns: 0 if feature is enabled, 1 if not
# Sets: LAST_DIRECTIVE_SOURCE (if feature found)
feature_detect() {
    local id="$1"
    local config_file="$2"
    local site_name="${3:-}"

    [[ -z "$id" ]] || [[ -z "$config_file" ]] && return 1

    # Get feature data
    local entry
    entry=$(_find_feature "$id")
    [[ -z "$entry" ]] && {
        echo "ERROR: Feature '$id' not registered" >&2
        return 1
    }

    local has_custom_detect
    has_custom_detect=$(_get_field "$entry" "$FIELD_CUSTOM_DETECT")

    # Use custom detection if available (normalize hyphens to underscores)
    if [[ "$has_custom_detect" == "1" ]]; then
        local func_id
        func_id=$(_normalize_id_for_func "$id")
        if declare -f "feature_detect_custom_${func_id}" &>/dev/null; then
            "feature_detect_custom_${func_id}" "$config_file" "$site_name"
            return $?
        fi
    fi

    # Fall back to pattern matching
    local pattern
    pattern=$(_get_field "$entry" "$FIELD_PATTERN")

    if [[ -f "$config_file" ]] && grep -qE "$pattern" "$config_file" 2>/dev/null; then
        LAST_DIRECTIVE_SOURCE="$config_file"
        return 0
    fi

    # Also check for include directives with our template names
    local template_names
    template_names=$(_get_field "$entry" "$FIELD_TEMPLATE")
    if [[ -n "$template_names" ]]; then
        # Split comma-separated template names and check for includes
        local IFS=','
        for tmpl in $template_names; do
            if grep -qE "include.*${tmpl}" "$config_file" 2>/dev/null; then
                LAST_DIRECTIVE_SOURCE="$config_file (via include)"
                return 0
            fi
        done
    fi

    return 1
}

# feature_apply - Apply optimization for a feature
# Args: $1 = feature_id, $2 = target_site (optional)
# Returns: 0 on success, 1 on error
feature_apply() {
    local id="$1"
    local target_site="${2:-}"

    [[ -z "$id" ]] && return 1

    # Get feature data
    local entry
    entry=$(_find_feature "$id")
    [[ -z "$entry" ]] && {
        echo "ERROR: Feature '$id' not registered" >&2
        return 1
    }

    local has_custom_apply
    has_custom_apply=$(_get_field "$entry" "$FIELD_CUSTOM_APPLY")

    # Use custom application if available (normalize hyphens to underscores)
    if [[ "$has_custom_apply" == "1" ]]; then
        local func_id
        func_id=$(_normalize_id_for_func "$id")
        if declare -f "feature_apply_custom_${func_id}" &>/dev/null; then
            "feature_apply_custom_${func_id}" "$target_site"
            return $?
        fi
    fi

    # Fall back to generic template deployment
    local template scope context
    template=$(_get_field "$entry" "$FIELD_TEMPLATE")
    scope=$(_get_field "$entry" "$FIELD_SCOPE")
    context=$(_get_field "$entry" "$FIELD_CONTEXT")

    if [[ -z "$template" ]]; then
        echo "ERROR: Feature '$id' has no template and no custom apply function" >&2
        return 1
    fi

    # This is a simplified fallback - in production, this would call
    # the actual template deployment logic from optimizer.sh
    echo "Would apply template: $template (scope: $scope, context: $context)" >&2
    return 0
}

################################################################################
# Helper Functions
################################################################################

# Helper: Parse field from feature entry
# Args: $1 = feature_entry (semicolon-separated), $2 = field_index
_get_field() {
    local entry="$1"
    local field_idx="$2"
    echo "$entry" | cut -d';' -f"$field_idx"
}

# Helper: Normalize feature ID for function names (hyphens to underscores)
# Args: $1 = feature_id
# Prints: normalized ID safe for use in function names
_normalize_id_for_func() {
    echo "${1//-/_}"
}

# Helper: Find feature entry by ID
# Args: $1 = feature_id
# Prints: full feature entry or empty
_find_feature() {
    local id="$1"
    [[ -z "$id" ]] && return 1

    # Search for entry starting with "id;"
    echo "$REGISTERED_FEATURES" | tr '|' '\n' | grep "^${id};"
}
