#!/usr/bin/env bash
# ==============================================================================
# Script: compress_logs.sh
# Description: Pure Bash-native tool to compress log and dump files across
#              multiple directories and wildcard paths with unique archive
#              naming, active lock detection, configurable retention cleanup,
#              and a Bash-native TSV undo manifest.
# Dependencies: bash, coreutils (find, stat, date, touch, sha256sum), gzip/zip
#               Zero Python, zero jq, zero external scripting dependencies.
# Compatible with: Ubuntu, SUSE (SLES/openSUSE), Debian, RHEL/CentOS, Rocky Linux
# ==============================================================================

set -o pipefail

# -----------------------------
# Color Codes for Output
# -----------------------------
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# -----------------------------
# Default Parameter Values
# -----------------------------
LOG_ROOTS=("/var/log" "/tmp" "/var/crash")
FILE_FILTERS=("*.log")
OLDER_THAN_DAYS=0
DELETE_ORIGINAL=true
PURGE_OLD_ARCHIVE_DAYS=0
UNIQUE_NAMING="TimestampHash" # TimestampHash | Hash | Timestamp | None
HASH_LENGTH=9
OVERWRITE_ARCHIVE=false
ARCHIVE_FORMAT="gz"           # gz | zip
DRY_RUN=false
DISABLE_LOG=false
LOG_PATH=""
SKIP_ROOT_CHECK=false

# -----------------------------
# Help / Usage Function
# -----------------------------
show_help() {
    cat << 'EOF'
Usage: compress_logs.sh [OPTIONS]

Compresses log and dump files across multiple directories with unique archive naming.
100% Bash-native: zero python or jq requirements.

Options:
  -p, --paths PATHS          Comma-separated or repeated directory paths to scan.
                             Supports wildcards, e.g. "/var/log,/home/*/logs".
                             (Default: "/var/log", "/tmp", "/var/crash")
  -f, --filters FILTERS      Comma-separated or repeated file patterns to match.
                             (Default: "*.log", e.g. "*.log,*.dmp,*.out")
  -o, --older-than DAYS      Process files older than DAYS days. (Default: 0 - all files)
  --purge-old-archive-days N Purge existing archives older than N days. (Default: 0 - disabled)
  --format FORMAT            Compression format: 'gz' (default) or 'zip'.
  --naming SCHEME            Archive naming: 'TimestampHash' (default), 'Hash', 'Timestamp', 'None'.
  --hash-length N            Length of SHA-256 hash prefix in archive name (default: 9, min 4, max 32).
  --no-delete                Keep original uncompressed files intact.
  --overwrite                Overwrite existing archives if name collision occurs.
  -n, --dry-run              Simulate execution without modifying or deleting any files.
  --log-path PATH            Path to TSV undo manifest file or directory.
  --disable-log              Disable writing undo log manifest.
  --skip-root-check          Bypass root/sudo privilege check.
  -h, --help                 Display this help message and exit.

Examples:
  # Run with defaults on standard log directories:
  sudo ./compress_logs.sh

  # Target specific paths, filter logs and core dumps older than 7 days:
  sudo ./compress_logs.sh -p "/var/log/nginx,/var/crash" -f "*.log,*.dmp" -o 7

  # Dry-run preview without touching disk:
  sudo ./compress_logs.sh -p "/var/log" -n

  # Keep originals, use zip format, and purge archives older than 60 days:
  sudo ./compress_logs.sh -p "/var/log/app" --format zip --no-delete --purge-old-archive-days 60
EOF
}

# -----------------------------
# Parse Command Line Arguments
# -----------------------------
CUSTOM_PATHS=()
CUSTOM_FILTERS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--path|--paths)
            IFS=',' read -ra ADDR <<< "$2"
            for p in "${ADDR[@]}"; do CUSTOM_PATHS+=("$(echo "$p" | xargs)"); done
            shift 2
            ;;
        -f|--filter|--filters)
            IFS=',' read -ra ADDR <<< "$2"
            for f in "${ADDR[@]}"; do CUSTOM_FILTERS+=("$(echo "$f" | xargs)"); done
            shift 2
            ;;
        -o|--older-than|--older-than-days)
            OLDER_THAN_DAYS="$2"
            shift 2
            ;;
        --purge-old-archive-days|--purge-old-zip-days)
            PURGE_OLD_ARCHIVE_DAYS="$2"
            shift 2
            ;;
        --format)
            ARCHIVE_FORMAT="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
            if [[ "$ARCHIVE_FORMAT" != "gz" && "$ARCHIVE_FORMAT" != "zip" ]]; then
                echo -e "${RED}Error: Unsupported format '$ARCHIVE_FORMAT'. Supported: 'gz', 'zip'.${NC}" >&2
                exit 1
            fi
            shift 2
            ;;
        --naming|--unique-naming)
            UNIQUE_NAMING="$2"
            case "$UNIQUE_NAMING" in
                TimestampHash|Hash|Timestamp|None) ;;
                *)
                    echo -e "${RED}Error: Unsupported naming mode '$UNIQUE_NAMING'. Choose from: TimestampHash, Hash, Timestamp, None.${NC}" >&2
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --hash-length)
            HASH_LENGTH="$2"
            if (( HASH_LENGTH < 4 || HASH_LENGTH > 32 )); then
                echo -e "${RED}Error: Hash length must be between 4 and 32.${NC}" >&2
                exit 1
            fi
            shift 2
            ;;
        --no-delete)
            DELETE_ORIGINAL=false
            shift
            ;;
        --overwrite)
            OVERWRITE_ARCHIVE=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        --log-path|--manifest-path)
            LOG_PATH="$2"
            shift 2
            ;;
        --disable-log)
            DISABLE_LOG=true
            shift
            ;;
        --skip-root-check)
            SKIP_ROOT_CHECK=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option '$1'${NC}" >&2
            echo "Use -h or --help for usage information." >&2
            exit 1
            ;;
    esac
done

if [ ${#CUSTOM_PATHS[@]} -gt 0 ]; then
    LOG_ROOTS=("${CUSTOM_PATHS[@]}")
fi

if [ ${#CUSTOM_FILTERS[@]} -gt 0 ]; then
    FILE_FILTERS=("${CUSTOM_FILTERS[@]}")
fi

# -----------------------------
# Check Prerequisites & Privileges
# -----------------------------
if [ "$SKIP_ROOT_CHECK" = false ] && [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script requires elevated root privileges to inspect locked files and access system logs.${NC}" >&2
    echo -e "${YELLOW}Please re-run with 'sudo $0' or specify '--skip-root-check' if operating within your user space.${NC}" >&2
    exit 1
fi

if [[ "$ARCHIVE_FORMAT" == "zip" ]] && ! command -v zip &>/dev/null; then
    echo -e "${RED}Error: 'zip' utility is not installed. Please install it ('apt install zip' on Ubuntu or 'zypper install zip' on SUSE) or use default '--format gz'.${NC}" >&2
    exit 1
fi

# -----------------------------
# Helper Functions (100% Bash & Coreutils)
# -----------------------------
format_bytes() {
    local bytes="$1"
    if (( bytes >= 1073741824 )); then
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
    elif (( bytes >= 1024 )); then
        awk "BEGIN {printf \"%.2f KB\", $bytes/1024}"
    else
        echo "${bytes} Bytes"
    fi
}

# Test if file is currently open by any active process (daemon protection)
is_file_locked() {
    local target="$1"
    if command -v fuser &>/dev/null; then
        if fuser -s "$target" 2>/dev/null; then
            return 0 # locked
        fi
        return 1     # not locked
    fi

    if command -v lsof &>/dev/null; then
        if lsof "$target" &>/dev/null; then
            return 0 # locked
        fi
        return 1
    fi

    # Fallback inspecting /proc/*/fd
    if [ -d "/proc" ]; then
        if grep -qs "$target" /proc/[0-9]*/fd/* 2>/dev/null; then
            return 0
        fi
    fi

    return 1 # not locked
}

# Generate unique archive name based on naming mode
generate_archive_name() {
    local file_path="$1"
    local base_name
    local dir_name
    local full_name
    local ext_suffix

    base_name="$(basename "$file_path")"
    full_name="$base_name"
    base_name="${base_name%.*}"
    dir_name="$(dirname "$file_path")"

    if [[ "$ARCHIVE_FORMAT" == "gz" ]]; then
        ext_suffix=".gz"
    else
        ext_suffix=".zip"
    fi

    local mtime_ts
    mtime_ts="$(date -r "$file_path" +"%Y%m%d_%H%M%S" 2>/dev/null || date +"%Y%m%d_%H%M%S")"

    local hash_val=""
    if [[ "$UNIQUE_NAMING" == "TimestampHash" || "$UNIQUE_NAMING" == "Hash" ]]; then
        if command -v sha256sum &>/dev/null; then
            hash_val="$(sha256sum "$file_path" 2>/dev/null | awk '{print $1}' | cut -c 1-"$HASH_LENGTH")"
        elif command -v shasum &>/dev/null; then
            hash_val="$(shasum -a 256 "$file_path" 2>/dev/null | awk '{print $1}' | cut -c 1-"$HASH_LENGTH")"
        else
            hash_val="$(date +%s%N | md5sum | cut -c 1-"$HASH_LENGTH")"
        fi
    fi

    case "$UNIQUE_NAMING" in
        TimestampHash)
            echo "${base_name}_${mtime_ts}_${hash_val}${ext_suffix}"
            ;;
        Hash)
            echo "${base_name}_${hash_val}${ext_suffix}"
            ;;
        Timestamp)
            echo "${base_name}_${mtime_ts}${ext_suffix}"
            ;;
        *)
            echo "${full_name}${ext_suffix}"
            ;;
    esac
}

# -----------------------------
# Normalize and Expand Target Directories
# -----------------------------
EXPANDED_DIRS=()
for pattern in "${LOG_ROOTS[@]}"; do
    shopt -s nullglob
    matches=( $pattern )
    shopt -u nullglob

    if [ ${#matches[@]} -eq 0 ]; then
        if [ -d "$pattern" ]; then
            EXPANDED_DIRS+=("$(cd "$pattern" && pwd -P)")
        else
            echo -e "${YELLOW}Warning: Directory or pattern does not exist: '$pattern'${NC}" >&2
        fi
    else
        for m in "${matches[@]}"; do
            if [ -d "$m" ]; then
                EXPANDED_DIRS+=("$(cd "$m" && pwd -P)")
            fi
        done
    fi
done

UNIQUE_DIRS=($(printf "%s\n" "${EXPANDED_DIRS[@]}" 2>/dev/null | sort -u))

if [ ${#UNIQUE_DIRS[@]} -eq 0 ]; then
    echo -e "${YELLOW}Warning: No valid target directories found to scan. Exiting.${NC}"
    exit 0
fi

# -----------------------------
# Initialize TSV Undo Manifest
# -----------------------------
RUN_START_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
RUN_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOSTNAME_VAL="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "linux-server")"
USER_VAL="${SUDO_USER:-$USER}"

if [ "$DISABLE_LOG" = false ]; then
    TIMESTAMP_STR="$(date +"%Y%m%d_%H%M%S")"
    if [ -z "$LOG_PATH" ]; then
        LOG_PATH="${SCRIPT_DIR}/compress_manifest_${TIMESTAMP_STR}.manifest"
    elif [ -d "$LOG_PATH" ] || [[ "$LOG_PATH" == */ ]]; then
        mkdir -p "$LOG_PATH"
        LOG_PATH="${LOG_PATH%/}/compress_manifest_${TIMESTAMP_STR}.manifest"
    fi

    # Initialize manifest file with metadata headers
    mkdir -p "$(dirname "$LOG_PATH")" 2>/dev/null
    cat > "$LOG_PATH" << EOF
# ==============================================================================
# Linux Log Compression Undo Manifest (Bash-Native TSV)
# ==============================================================================
# RunId: $RUN_ID
# Hostname: $HOSTNAME_VAL
# User: $USER_VAL
# StartTime: $RUN_START_TIME
# ArchiveFormat: $ARCHIVE_FORMAT
# DeleteOriginal: $DELETE_ORIGINAL
# TargetDirectories: $(IFS=, ; echo "${UNIQUE_DIRS[*]}")
# FileFilters: $(IFS=, ; echo "${FILE_FILTERS[*]}")
# ==============================================================================
# FIELDS (Tab-Separated):
# ACTION	STATUS	ORIGINAL_PATH	ORIGINAL_DIR	ORIGINAL_MTIME_EPOCH	ARCHIVE_PATH	ARCHIVE_NAME	ORIGINAL_DELETED	NOTE
# ==============================================================================
EOF
fi

# -----------------------------
# Print Configuration Banner
# -----------------------------
echo -e "${CYAN}==========================================================${NC}"
echo -e "${CYAN} Linux Log & Dump File Compression Tool (Bash-Native)${NC}"
echo -e " Target Directories (${#UNIQUE_DIRS[@]}):"
for d in "${UNIQUE_DIRS[@]}"; do
    echo -e "${GRAY}   - $d${NC}"
done
echo -e " Target Filters    : $(IFS=, ; echo "${FILE_FILTERS[*]}")"
echo -e " Compression Format: $ARCHIVE_FORMAT"
echo -e " Naming Scheme     : $UNIQUE_NAMING (Hash Length: $HASH_LENGTH)"
if (( OLDER_THAN_DAYS > 0 )); then
    echo -e " Age Filter        : Older than $OLDER_THAN_DAYS days"
else
    echo -e " Age Filter        : All ages (0+ days)"
fi
if (( PURGE_OLD_ARCHIVE_DAYS > 0 )); then
    echo -e " Purge Old Archives: ${YELLOW}Yes (Older than $PURGE_OLD_ARCHIVE_DAYS days)${NC}"
else
    echo -e " Purge Old Archives: Disabled (0 days)"
fi
echo -e " Remove Source     : $DELETE_ORIGINAL"
echo -e " Overwrite Archive : $OVERWRITE_ARCHIVE"
if [ "$DRY_RUN" = true ]; then
    echo -e " Dry Run Mode      : ${YELLOW}Enabled (Simulate only, no changes)${NC}"
fi
if [ "$DISABLE_LOG" = false ]; then
    echo -e " Undo Log Manifest : $LOG_PATH"
else
    echo -e " Undo Log Manifest : ${GRAY}Disabled${NC}"
fi
echo -e "${CYAN}==========================================================${NC}"

# -----------------------------
# Optional: Purge Old Archives
# -----------------------------
PURGED_COUNT=0
PURGED_BYTES=0

if (( PURGE_OLD_ARCHIVE_DAYS > 0 )); then
    echo -e "\n${CYAN}Scanning for existing archives older than $PURGE_OLD_ARCHIVE_DAYS days to purge...${NC}"
    for dir in "${UNIQUE_DIRS[@]}"; do
        while IFS= read -r -d '' old_archive; do
            [ -f "$old_archive" ] || continue
            arc_size="$(stat -c %s "$old_archive" 2>/dev/null || wc -c < "$old_archive")"
            if [ "$DRY_RUN" = true ]; then
                echo -e "${YELLOW}[WhatIf - Purge Archive] Would remove '$old_archive' ($(format_bytes "$arc_size"))${NC}"
                (( PURGED_COUNT++ ))
                (( PURGED_BYTES += arc_size ))
            else
                if rm -f "$old_archive"; then
                    echo -e "${YELLOW}[Purged Old Archive] $old_archive ($(format_bytes "$arc_size"))${NC}"
                    (( PURGED_COUNT++ ))
                    (( PURGED_BYTES += arc_size ))

                    if [ "$DISABLE_LOG" = false ]; then
                        printf "PURGE\tSUCCESS\t-\t-\t-\t%s\t%s\t0\tPre-existing archive purged by retention\n" \
                            "$old_archive" "$(basename "$old_archive")" >> "$LOG_PATH"
                    fi
                else
                    echo -e "${RED}Warning: Failed to delete old archive '$old_archive'${NC}" >&2
                fi
            fi
        done < <(find "$dir" -type f \( -name "*.gz" -o -name "*.zip" -o -name "*.xz" -o -name "*.bz2" \) -mtime +"$PURGE_OLD_ARCHIVE_DAYS" -print0 2>/dev/null)
    done

    if (( PURGED_COUNT > 0 )); then
        echo -e "${GREEN}Purged $PURGED_COUNT old archive(s) freeing $(format_bytes "$PURGED_BYTES").${NC}\n"
    else
        echo -e "${GRAY}No old archives found older than $PURGE_OLD_ARCHIVE_DAYS days.${NC}\n"
    fi
fi

# -----------------------------
# Discover Candidate Files
# -----------------------------
CANDIDATE_FILES=()

FIND_NAME_ARGS=()
first=true
for f in "${FILE_FILTERS[@]}"; do
    clean_f="$f"
    if [[ "$clean_f" != \** && "$clean_f" != *\** && "$clean_f" != *\?* ]]; then
        if [[ "$clean_f" == .* ]]; then
            clean_f="*$clean_f"
        else
            clean_f="*.$clean_f"
        fi
    fi

    if [ "$first" = true ]; then
        FIND_NAME_ARGS+=("-name" "$clean_f")
        first=false
    else
        FIND_NAME_ARGS+=("-o" "-name" "$clean_f")
    fi
done

for dir in "${UNIQUE_DIRS[@]}"; do
    FIND_CMD=(find "$dir" -type f)

    if (( OLDER_THAN_DAYS > 0 )); then
        FIND_CMD+=("-mtime" "+$OLDER_THAN_DAYS")
    fi

    # Exclude already compressed archives
    FIND_CMD+=("!" "(" -name "*.gz" -o -name "*.zip" -o -name "*.bz2" -o -name "*.xz" -o -name "*.zst" -o -name "*.tar.*" ")")

    # Include filter group
    FIND_CMD+=("(" "${FIND_NAME_ARGS[@]}" ")")

    while IFS= read -r -d '' matched_file; do
        CANDIDATE_FILES+=("$matched_file")
    done < <("${FIND_CMD[@]}" -print0 2>/dev/null)
done

if [ ${#CANDIDATE_FILES[@]} -eq 0 ]; then
    echo -e "${YELLOW}No matching files found across target directories.${NC}"
    exit 0
fi

echo -e "${GREEN}Found ${#CANDIDATE_FILES[@]} file(s) matching criteria.${NC}\n"

# -----------------------------
# Process Files
# -----------------------------
TOTAL_ORIG_BYTES=0
TOTAL_COMP_BYTES=0
PROCESSED_COUNT=0
SKIPPED_LOCKED_COUNT=0
SKIPPED_EXISTING_COUNT=0
FAILED_COUNT=0

for file_path in "${CANDIDATE_FILES[@]}"; do
    [ -f "$file_path" ] || continue
    file_size="$(stat -c %s "$file_path" 2>/dev/null || wc -c < "$file_path")"
    file_mtime_epoch="$(stat -c %Y "$file_path" 2>/dev/null || date +%s)"
    (( TOTAL_ORIG_BYTES += file_size ))

    echo -ne "${CYAN}[Processing]${NC} $file_path ${GRAY}($(format_bytes "$file_size"))${NC} ... "

    # 1. Lock check
    if is_file_locked "$file_path"; then
        echo -e "${YELLOW}SKIPPED: File is active / currently open by another process.${NC}"
        (( SKIPPED_LOCKED_COUNT++ ))
        continue
    fi

    # 2. Generate archive destination
    archive_name="$(generate_archive_name "$file_path")"
    archive_dir="$(dirname "$file_path")"
    archive_path="${archive_dir}/${archive_name}"

    # 3. Collision check
    if [ -f "$archive_path" ] && [ "$OVERWRITE_ARCHIVE" = false ]; then
        echo -e "${YELLOW}SKIPPED: Archive '$archive_name' already exists. Use --overwrite to replace.${NC}"
        (( SKIPPED_EXISTING_COUNT++ ))
        continue
    fi

    # 4. Dry-run handling
    if [ "$DRY_RUN" = true ]; then
        echo -e "${GREEN}[WhatIf] Would compress to '$archive_name' $(if [ "$DELETE_ORIGINAL" = true ]; then echo "and delete source"; else echo "and preserve source"; fi)${NC}"
        (( PROCESSED_COUNT++ ))
        continue
    fi

    # 5. Compress file
    comp_success=false
    if [[ "$ARCHIVE_FORMAT" == "gz" ]]; then
        if gzip -c "$file_path" > "$archive_path" 2>/dev/null && gzip -t "$archive_path" 2>/dev/null; then
            comp_success=true
        fi
    elif [[ "$ARCHIVE_FORMAT" == "zip" ]]; then
        if (cd "$archive_dir" && zip -q -j "$archive_path" "$file_path" 2>/dev/null); then
            comp_success=true
        fi
    fi

    if [ "$comp_success" = true ] && [ -f "$archive_path" ]; then
        comp_size="$(stat -c %s "$archive_path" 2>/dev/null || wc -c < "$archive_path")"
        (( TOTAL_COMP_BYTES += comp_size ))

        savings_pct=0
        if (( file_size > 0 )); then
            savings_pct=$(awk "BEGIN {printf \"%.1f\", (1 - ($comp_size / $file_size)) * 100}")
        fi

        echo -e "${GREEN}Created: $archive_name ($(format_bytes "$comp_size"), ${savings_pct}% reduction)${NC}"

        del_status=0
        if [ "$DELETE_ORIGINAL" = true ]; then
            if rm -f "$file_path"; then
                del_status=1
                echo -e "  ${GRAY}└─ Removed original uncompressed file.${NC}"
            else
                echo -e "  ${RED}└─ Warning: Failed to remove original file '$file_path'${NC}" >&2
            fi
        fi
        (( PROCESSED_COUNT++ ))

        if [ "$DISABLE_LOG" = false ]; then
            printf "COMPRESS\tSUCCESS\t%s\t%s\t%s\t%s\t%s\t%d\tCompressed successfully\n" \
                "$file_path" "$archive_dir" "$file_mtime_epoch" "$archive_path" "$archive_name" "$del_status" >> "$LOG_PATH"
        fi
    else
        echo -e "${RED}FAILED: Compression failed for '$file_path'${NC}" >&2
        rm -f "$archive_path" 2>/dev/null
        (( FAILED_COUNT++ ))

        if [ "$DISABLE_LOG" = false ]; then
            printf "COMPRESS\tFAILED\t%s\t%s\t%s\t%s\t%s\t0\tCompression or verification failed\n" \
                "$file_path" "$archive_dir" "$file_mtime_epoch" "$archive_path" "$archive_name" >> "$LOG_PATH"
        fi
    fi
done

# -----------------------------
# Calculate Totals & Summary
# -----------------------------
RECLAIMED_BYTES=0
if (( TOTAL_ORIG_BYTES > TOTAL_COMP_BYTES )); then
    RECLAIMED_BYTES=$(( (TOTAL_ORIG_BYTES - TOTAL_COMP_BYTES) + PURGED_BYTES ))
else
    RECLAIMED_BYTES=$PURGED_BYTES
fi

RUN_END_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [ "$DISABLE_LOG" = false ] && [ "$DRY_RUN" = false ]; then
    cat >> "$LOG_PATH" << EOF
# ==============================================================================
# SUMMARY:
# EndTime: $RUN_END_TIME
# TotalEvaluated: ${#CANDIDATE_FILES[@]}
# SuccessfullyCompressed: $PROCESSED_COUNT
# PurgedOldArchives: $PURGED_COUNT
# SkippedLocked: $SKIPPED_LOCKED_COUNT
# SkippedExisting: $SKIPPED_EXISTING_COUNT
# Failed: $FAILED_COUNT
# ReclaimedBytes: $RECLAIMED_BYTES
# ==============================================================================
EOF
fi

# -----------------------------
# Display Summary Report
# -----------------------------
echo -e "\n${CYAN}======================= SUMMARY ==========================${NC}"
echo -e "Directories scanned          : ${#UNIQUE_DIRS[@]}"
echo -e "Total files evaluated        : ${#CANDIDATE_FILES[@]}"
echo -e "Successfully compressed      : ${GREEN}$PROCESSED_COUNT${NC}"
if (( PURGE_OLD_ARCHIVE_DAYS > 0 )); then
    echo -e "Old archives purged          : $(if (( PURGED_COUNT > 0 )); then echo -e "${GREEN}$PURGED_COUNT ($(format_bytes "$PURGED_BYTES"))${NC}"; else echo -e "$PURGED_COUNT (0 Bytes)"; fi)"
fi
echo -e "Skipped (active / in-use)    : $(if (( SKIPPED_LOCKED_COUNT > 0 )); then echo -e "${YELLOW}$SKIPPED_LOCKED_COUNT${NC}"; else echo -e "$SKIPPED_LOCKED_COUNT"; fi)"
echo -e "Skipped (archive exists)     : $(if (( SKIPPED_EXISTING_COUNT > 0 )); then echo -e "${YELLOW}$SKIPPED_EXISTING_COUNT${NC}"; else echo -e "$SKIPPED_EXISTING_COUNT"; fi)"
echo -e "Failed operations            : $(if (( FAILED_COUNT > 0 )); then echo -e "${RED}$FAILED_COUNT${NC}"; else echo -e "$FAILED_COUNT"; fi)"
if (( PROCESSED_COUNT > 0 || PURGED_BYTES > 0 )); then
    if (( PROCESSED_COUNT > 0 )); then
        echo -e "Original Total Size          : $(format_bytes "$TOTAL_ORIG_BYTES")"
        echo -e "Compressed Total Size        : $(format_bytes "$TOTAL_COMP_BYTES")"
    fi
    echo -e "Total Reclaimed Disk Space   : ${GREEN}$(format_bytes "$RECLAIMED_BYTES")${NC}"
fi

if [ "$DISABLE_LOG" = false ] && [ "$DRY_RUN" = false ]; then
    echo -e "\nUndo Log Manifest            : ${CYAN}$LOG_PATH${NC}"
    if (( PROCESSED_COUNT > 0 )); then
        echo -e "${GRAY}To undo operations recorded in this run, execute:${NC}"
        echo -e "  ${YELLOW}sudo ./undo_compress_logs.sh -m \"$LOG_PATH\"${NC}"
    fi
fi
echo -e "${CYAN}==========================================================${NC}"
