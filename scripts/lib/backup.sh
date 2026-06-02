#!/usr/bin/env bash
# backup.sh — timestamped, reversible backups of Pegasus config/metadata.
#
# Backups live in a predictable place so the user (and restore.sh) can find
# them: $PBC_STATE_DIR/backups/<timestamp>/. We copy the *existing* file
# before it is overwritten, preserving a relative layout that records where it
# came from, plus a manifest mapping backup -> original path for restore.

: "${PBC_BACKUP_DIR:=}"   # set by backup_begin() for this run

# backup_root — base directory holding all backup runs.
backup_root() { printf '%s/backups' "$PBC_STATE_DIR"; }

# backup_begin — allocate (lazily) ONE timestamped backup dir for this run,
# storing it in the global PBC_BACKUP_DIR. Idempotent within a run.
#
# IMPORTANT: this sets a global, so callers must invoke it directly (not via
# command substitution `$(...)`, which would set the variable in a subshell
# only). Read the result from $PBC_BACKUP_DIR afterwards.
backup_begin() {
    [[ -n "$PBC_BACKUP_DIR" ]] && return 0
    PBC_BACKUP_DIR="$(backup_root)/$(_timestamp)"
}

# backup_file PATH — copy PATH into the run's backup dir if it exists.
# A no-op (success) if the file does not exist or backups are disabled.
# Records the original absolute path in a manifest for restore.
backup_file() {
    local src="$1"
    [[ -e "$src" ]] || return 0
    cfg_is_yes "$CFG_BACKUP" || { log_debug "backup disabled; not backing up $src"; return 0; }
    backup_begin
    local root="$PBC_BACKUP_DIR"
    # Mirror the absolute path under the backup dir (strip leading slash).
    local rel="${src#/}"
    local dest="$root/files/$rel"
    if is_dry_run; then
        printf '%s[dry-run]%s backup %s -> %s\n' "$C_DIM" "$C_RESET" "$src" "$dest"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$dest")" || { log_error "backup: cannot create $dest"; return 1; }
    cp -a -- "$src" "$dest" || { log_error "backup: failed to copy $src"; return 1; }
    printf '%s\t%s\n' "$rel" "$src" >>"$root/manifest.tsv"
    log_debug "backed up $src"
    PBC_BACKUP_MADE=1
}

# backup_finalize — write a small README into the backup dir if anything was
# stored, and report the location.
backup_finalize() {
    [[ "${PBC_BACKUP_MADE:-0}" == 1 ]] || { log_debug "no files needed backup"; return 0; }
    local root="$PBC_BACKUP_DIR"
    is_dry_run && return 0
    cat >"$root/README.txt" <<EOF
Pegasus-Bazzite-Configurator backup
Created: $(_iso_now)
Host OS: $(os_summary_line 2>/dev/null || echo unknown)

This directory contains copies of files that existed BEFORE this run modified
them. 'manifest.tsv' maps each saved file (under files/) to its original path.

Restore everything with:
    scripts/restore.sh "$root"

Or restore the most recent backup with:
    scripts/restore.sh
EOF
    log_ok "backup created: $root"
}

# backup_latest — echo the newest backup dir, or empty if none.
backup_latest() {
    local root; root="$(backup_root)"
    [[ -d "$root" ]] || return 0
    # Timestamped names sort lexically == chronologically.
    local d; d="$(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1)"
    printf '%s' "$d"
}

# backup_restore DIR — restore files recorded in DIR/manifest.tsv to their
# original locations. Dry-run aware. Returns non-zero on any failure.
backup_restore() {
    local dir="$1"
    [[ -n "$dir" ]] || dir="$(backup_latest)"
    [[ -n "$dir" && -d "$dir" ]] || { log_error "no backup found to restore"; return 1; }
    local manifest="$dir/manifest.tsv"
    [[ -r "$manifest" ]] || { log_error "backup manifest missing: $manifest"; return 1; }
    log_step "Restoring from $dir"
    local rel orig src rc=0
    while IFS=$'\t' read -r rel orig; do
        [[ -n "$rel" && -n "$orig" ]] || continue
        src="$dir/files/$rel"
        if [[ ! -e "$src" ]]; then log_warn "restore: missing saved file $src"; continue; fi
        if is_dry_run; then
            printf '%s[dry-run]%s restore %s -> %s\n' "$C_DIM" "$C_RESET" "$src" "$orig"
            continue
        fi
        mkdir -p -- "$(dirname -- "$orig")" || { log_error "restore: cannot create dir for $orig"; rc=1; continue; }
        if cp -a -- "$src" "$orig"; then log_ok "restored $orig"; else log_error "restore: failed $orig"; rc=1; fi
    done <"$manifest"
    return $rc
}
