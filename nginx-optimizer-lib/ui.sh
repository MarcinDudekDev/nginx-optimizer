#!/bin/bash
################################################################################
# ui.sh - Clean terminal UI rendering for nginx-optimizer
#
# Provides professional-looking output with:
# - Box drawing for warnings/summaries
# - Checkmark steps with optional file paths
# - Color-coded status indicators
################################################################################

# UI Characters (Unicode box drawing)
UI_BOX_TL="┌"
UI_BOX_TR="┐"
UI_BOX_BL="└"
UI_BOX_BR="┘"
UI_BOX_H="─"
UI_BOX_V="│"
UI_CHECK="✓"
UI_BULLET="•"
UI_ARROW="→"

# UI Layout
UI_WIDTH=55
UI_INDENT="  "

# Verbose mode (show detailed [INFO] style output)
UI_VERBOSE="${UI_VERBOSE:-false}"

################################################################################
# Core UI Functions
################################################################################

# Print the header with version
# Usage: ui_header
ui_header() {
    echo ""
    echo -e "${UI_INDENT}${CYAN}nginx-optimizer${NC} v${VERSION}"
    echo ""
}

# Print a blank line
# Usage: ui_blank
ui_blank() {
    echo ""
}

# Print a context line (label: value)
# Usage: ui_context "Label" "Value"
ui_context() {
    local label="$1"
    local value="$2"
    echo -e "${UI_INDENT}${label}: ${value}"
}

# Print a section header
# Usage: ui_section "Preparing..."
ui_section() {
    local text="$1"
    echo ""
    echo -e "${UI_INDENT}${text}"
}

# Print a completed step with checkmark
# Usage: ui_step "Step completed"
# Usage: ui_step "Step completed" "extra info"
ui_step() {
    local text="$1"
    local extra="${2:-}"
    if [ -n "$extra" ]; then
        echo -e "${UI_INDENT}  ${GREEN}${UI_CHECK}${NC} ${text} (${extra})"
    else
        echo -e "${UI_INDENT}  ${GREEN}${UI_CHECK}${NC} ${text}"
    fi
}

# Print a completed step with file path
# Usage: ui_step_path "Created config" "conf.d/file.conf"
ui_step_path() {
    local text="$1"
    local path="$2"
    local text_len=${#text}
    local max_text=28
    local padding=""

    # Pad text to align paths
    if (( text_len < max_text )); then
        padding=$(printf '%*s' $((max_text - text_len)) '')
    fi

    echo -e "${UI_INDENT}  ${GREEN}${UI_CHECK}${NC} ${text}${padding} ${UI_ARROW} ${CYAN}${path}${NC}"
}

# Print a pending/in-progress step
# Usage: ui_step_pending "Working on..."
ui_step_pending() {
    local text="$1"
    echo -e "${UI_INDENT}  ${YELLOW}○${NC} ${text}"
}

# Print a failed step
# Usage: ui_step_fail "Step failed"
ui_step_fail() {
    local text="$1"
    local reason="${2:-}"
    if [ -n "$reason" ]; then
        echo -e "${UI_INDENT}  ${RED}✗${NC} ${text} (${reason})"
    else
        echo -e "${UI_INDENT}  ${RED}✗${NC} ${text}"
    fi
}

# Print a bullet point
# Usage: ui_bullet "Item text"
ui_bullet() {
    local text="$1"
    echo -e "${UI_INDENT}  ${UI_BULLET} ${text}"
}

################################################################################
# Box Drawing Functions
################################################################################

# Draw horizontal line for box
_ui_box_line() {
    local left="$1"
    local right="$2"
    local width=$((UI_WIDTH - 2))
    local line=""
    for ((i=0; i<width; i++)); do
        line+="${UI_BOX_H}"
    done
    echo -e "${UI_INDENT}${left}${line}${right}"
}

# Draw a generic box with content
# Usage: ui_box "line1" "line2" ...
ui_box() {
    local color="${NC}"
    _ui_box_line "${UI_BOX_TL}" "${UI_BOX_TR}"

    for line in "$@"; do
        local text_len=${#line}
        local padding=$((UI_WIDTH - 4 - text_len))
        if (( padding < 0 )); then padding=0; fi
        local pad_str=$(printf '%*s' "$padding" '')
        echo -e "${UI_INDENT}${UI_BOX_V}  ${line}${pad_str}${UI_BOX_V}"
    done

    _ui_box_line "${UI_BOX_BL}" "${UI_BOX_BR}"
}

# Draw a warning box (yellow)
# Usage: ui_warn_box "Warning message"
ui_warn_box() {
    local message="$1"
    local text_len=${#message}
    local padding=$((UI_WIDTH - 4 - text_len))
    if (( padding < 0 )); then padding=0; fi
    local pad_str=$(printf '%*s' "$padding" '')

    echo -e "${UI_INDENT}${YELLOW}${UI_BOX_TL}$(printf '%*s' $((UI_WIDTH-2)) '' | tr ' ' "${UI_BOX_H}")${UI_BOX_TR}${NC}"
    echo -e "${UI_INDENT}${YELLOW}${UI_BOX_V}${NC}  ${YELLOW}${message}${NC}${pad_str}${YELLOW}${UI_BOX_V}${NC}"
    echo -e "${UI_INDENT}${YELLOW}${UI_BOX_BL}$(printf '%*s' $((UI_WIDTH-2)) '' | tr ' ' "${UI_BOX_H}")${UI_BOX_BR}${NC}"
}

# Draw a success box (green)
# Usage: ui_success_box "title" "line1" "line2" ...
ui_success_box() {
    local title="$1"
    shift
    local lines=("$@")

    # Top border
    echo -e "${UI_INDENT}${GREEN}${UI_BOX_TL}$(printf '%*s' $((UI_WIDTH-2)) '' | tr ' ' "${UI_BOX_H}")${UI_BOX_TR}${NC}"

    # Title with checkmark
    local title_with_check="${UI_CHECK} ${title}"
    local title_len=${#title_with_check}
    local padding=$((UI_WIDTH - 4 - title_len))
    if (( padding < 0 )); then padding=0; fi
    local pad_str=$(printf '%*s' "$padding" '')
    echo -e "${UI_INDENT}${GREEN}${UI_BOX_V}${NC}  ${GREEN}${title_with_check}${NC}${pad_str}${GREEN}${UI_BOX_V}${NC}"

    # Empty line after title if there's content
    if [ ${#lines[@]} -gt 0 ]; then
        echo -e "${UI_INDENT}${GREEN}${UI_BOX_V}${NC}$(printf '%*s' $((UI_WIDTH-2)) '')${GREEN}${UI_BOX_V}${NC}"
    fi

    # Content lines
    for line in "${lines[@]}"; do
        local line_len=${#line}
        local line_padding=$((UI_WIDTH - 4 - line_len))
        if (( line_padding < 0 )); then line_padding=0; fi
        local line_pad=$(printf '%*s' "$line_padding" '')
        echo -e "${UI_INDENT}${GREEN}${UI_BOX_V}${NC}  ${line}${line_pad}${GREEN}${UI_BOX_V}${NC}"
    done

    # Bottom border
    echo -e "${UI_INDENT}${GREEN}${UI_BOX_BL}$(printf '%*s' $((UI_WIDTH-2)) '' | tr ' ' "${UI_BOX_H}")${UI_BOX_BR}${NC}"
}

# Draw an error box (red)
# Usage: ui_error_box "Error message"
ui_error_box() {
    local message="$1"
    local text_len=${#message}
    local padding=$((UI_WIDTH - 4 - text_len))
    if (( padding < 0 )); then padding=0; fi
    local pad_str=$(printf '%*s' "$padding" '')

    echo -e "${UI_INDENT}${RED}${UI_BOX_TL}$(printf '%*s' $((UI_WIDTH-2)) '' | tr ' ' "${UI_BOX_H}")${UI_BOX_TR}${NC}"
    echo -e "${UI_INDENT}${RED}${UI_BOX_V}${NC}  ${RED}${message}${NC}${pad_str}${RED}${UI_BOX_V}${NC}"
    echo -e "${UI_INDENT}${RED}${UI_BOX_BL}$(printf '%*s' $((UI_WIDTH-2)) '' | tr ' ' "${UI_BOX_H}")${UI_BOX_BR}${NC}"
}

################################################################################
# Confirmation Prompts
################################################################################

# Display confirmation prompt
# Usage: ui_confirm "Apply these changes?" (returns 0 for yes, 1 for no, 2 for quit)
ui_confirm() {
    local prompt="${1:-Continue?}"
    echo ""
    read -r -p "  ${prompt} [y/N/q]: " response
    case "$response" in
        y|Y|yes|Yes|YES)
            return 0
            ;;
        q|Q|quit|Quit|QUIT|exit)
            return 2
            ;;
        *)
            return 1
            ;;
    esac
}

################################################################################
# Verbose/Debug Output (respects UI_VERBOSE)
################################################################################

# Print debug info only in verbose mode
# Usage: ui_debug "Detailed message"
ui_debug() {
    if [ "$UI_VERBOSE" = true ]; then
        echo -e "${UI_INDENT}${BLUE}[DEBUG]${NC} $*"
    fi
}

################################################################################
# Summary Helpers
################################################################################

# Build a site list for summary
# Usage: ui_site_list "site1" "site2" "site3"
ui_site_list() {
    local prefix="${1:-Sites:}"
    shift
    local sites=("$@")

    echo "${prefix}"
    for site in "${sites[@]}"; do
        echo "  ${UI_BULLET} ${site}"
    done
}
