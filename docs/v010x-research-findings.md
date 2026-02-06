# v0.10.x Research Findings

Reference document from explore agent analysis (Feb 2025).
Covers implementation details for all 5 planned features.

---

## 1. State Tracking (Foundation)

**Current state:** No persistent tracking. Only runtime `APPLIED_OPTIMIZATIONS` array in `optimizer.sh` that resets each run. Detection relies on runtime `feature_detect()` which greps config files.

**Proposed:** `~/.nginx-optimizer/applied-features.json` (or `.state` file)

**What to track per feature per site:**
- Feature ID, site name, timestamp applied
- Template files deployed, config lines injected
- Backup reference (which backup contains the pre-state)

**Implementation notes:**
- `jq` is already checked as optional dependency in `cmd_check()`
- Fallback to grep/sed for JSON if jq unavailable (keep Bash 3.2 compatible)
- Write state on `transaction_commit()`, clear on rollback/remove
- State file enables: remove, verify, full JSON output

---

## 2. `--no-color` Flag

**Current color system:**
- Colors defined in `nginx-optimizer.sh` globals: `RED`, `GREEN`, `YELLOW`, `BLUE`, `CYAN`, `NC`
- Used via `${GREEN}text${NC}` in echo -e statements throughout
- `ui.sh` uses these variables for all UI output functions

**Implementation:**
- Add `NO_COLOR=false` global + `--no-color` flag in parser
- Also respect `NO_COLOR` env var (standard: https://no-color.org/)
- After color variable definitions, add:
  ```bash
  if [[ "$NO_COLOR" == "true" ]] || [[ -n "${NO_COLOR:-}" ]]; then
      RED="" GREEN="" YELLOW="" BLUE="" CYAN="" NC=""
  fi
  ```
- This automatically disables color everywhere since all output uses these variables
- Also check `! -t 1` (stdout not a terminal) for automatic detection

**Files to modify:** `nginx-optimizer.sh` only (color vars + flag parsing)

---

## 3. `diff` Command

**Current backup system (`backup.sh`):**
- `create_backup()` → rsync to `~/.nginx-optimizer/backups/YYYYMMDD-HHMMSS/`
- Stores: nginx configs, wp-test configs, metadata JSON
- `CURRENT_BACKUP_DIR` global set during optimization
- `list_backups()` shows available backups

**Implementation approach:**
- `cmd_diff()` function in `nginx-optimizer.sh`
- Two modes:
  1. `diff [timestamp]` — compare current config vs specific backup
  2. `diff` (no args) — compare current config vs most recent backup
- Use `diff -u` (unified format) with color support
- For dry-run preview: run optimize in dry-run, capture what would change, show diff
- Can reuse backup paths from `list_backups()` output

**Key paths to diff:**
- `/etc/nginx/` (system nginx)
- `~/.wp-test/nginx/` (wp-test configs)
- Template files in site-specific dirs

---

## 4. Full JSON Output

**Current JSON:** `--json` flag exists but output is minimal/placeholder in some commands.

**What needs JSON:**
- `analyze` — per-site feature detection results
- `status` — applied features, health, last optimization time
- `list` — detected instances with types/paths
- `check` — prerequisites, feature readiness, issues

**Implementation:**
- Create `json_output()` helper that builds JSON incrementally
- Use `jq` if available, fall back to printf-based JSON construction
- State tracking file provides the data source for status/list
- Each command function gets a JSON output path when `--json` is set

---

## 5. `remove` Command

**Current state:** No remove/uninstall capability. Rollback restores entire backup.

**Implementation approach:**
- `cmd_remove()` function
- Two modes:
  1. `remove [site]` — remove all optimizations for a site
  2. `remove --feature <name> [site]` — remove specific feature
- Requires state tracking to know what was applied
- For template-based features: delete the included conf files
- For injected directives: use awk to remove include lines
- Always run `nginx -t` before reloading
- Create backup before removing (safety net)

**Complexity:** Medium-high. Needs state tracking + reverse of each feature's apply logic.
Feature modules could implement `feature_remove_custom_<id>()` callbacks.

---

## 6. Rollback Verification

**Current rollback (`backup.sh`):**
- `restore_backup()` uses rsync to restore from timestamped backup
- No verification that restored config matches original

**Implementation:**
- After `restore_backup()`, compare restored files against backup (checksum)
- Verify `nginx -t` passes after restore
- Optional: `verify` subcommand to check current state matches last known good
- State tracking enables: "are all features that should be applied actually detected?"

---

## Recommended Implementation Order

1. **State tracking** — foundation for remove/verify/json
2. **`--no-color`** — easiest, self-contained, no dependencies
3. **`diff` command** — leverages existing backup system
4. **Full JSON output** — requires state tracking
5. **`remove` command** — requires state tracking + feature removal logic
6. **Rollback verification** — requires state tracking

This order minimizes rework and builds each feature on the previous foundation.
