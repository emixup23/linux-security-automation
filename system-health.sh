#!/usr/bin/env bash
#
# system-health.sh - Read-only health report for Ubuntu Server / Debian.
#
# Exit codes:
#   0 = healthy
#   1 = warning(s) detected
#   2 = critical condition(s) detected
#   3 = script/runtime error
#
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: this script must be run with bash (e.g. 'bash $0')" >&2
    exit 3
fi

set -uo pipefail
IFS=$'\n\t'
export LC_ALL=C

SCRIPT_NAME="${0##*/}"
DISK_THRESHOLD=85
DISK_CRITICAL=95
RAM_THRESHOLD=85
RAM_CRITICAL=95
CPU_THRESHOLD=90
CPU_CRITICAL=95
OUTPUT_FILE=""
OUTPUT_REAL=""
COLOR_MODE="auto"   # auto | always | never

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Collect a read-only Linux health report covering CPU load, RAM/swap,
disk usage, uptime, and failed systemd services.

Thresholds (all integers, 1..100):
  --disk-threshold PCT   Warn when a filesystem reaches this usage % (default: $DISK_THRESHOLD)
  --disk-critical  PCT   Mark CRITICAL at this usage %                  (default: $DISK_CRITICAL)
  --ram-threshold  PCT   Warn when RAM usage reaches this %             (default: $RAM_THRESHOLD)
  --ram-critical   PCT   Mark CRITICAL at this RAM usage %              (default: $RAM_CRITICAL)
  --cpu-threshold  PCT   Warn when 1-min load / CPU count reaches this %  (default: $CPU_THRESHOLD)
  --cpu-critical   PCT   Mark CRITICAL at this load %                     (default: $CPU_CRITICAL)
                         Critical values must be >= their warning values.

Output:
  --output FILE          Save the report to FILE. Written atomically
                         (temp file + rename); an existing file's mode is kept.
  --color                Force colored output (even when stdout is not a TTY)
  --no-color             Disable colored output
  -h, --help             Show this help

Exit codes:
  0  Healthy; no threshold warnings detected
  1  Warning(s) detected
  2  Critical condition(s) detected
  3  A required command or runtime operation failed

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --disk-threshold 80 --disk-critical 90 --ram-threshold 90
  $SCRIPT_NAME --no-color --output /var/log/system-health/report.txt

Notes:
  - Read-only: this script does not restart services or change configuration.
  - Run with sudo only if you need access to additional service details.
  - Color is auto-detected; override with --color / --no-color (or NO_COLOR=1).
  - Saved reports are always plain text (ANSI codes stripped).
  - --output uses an atomic rename, so concurrent readers never see a
    partial report. A symlinked destination is resolved and written through.
EOF
}

error() {
    printf 'ERROR: %s\n' "$*" >&2
}

is_percent() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 100 ))
}

# --- Argument parsing -----------------------------------------------------
while (($#)); do
    case "$1" in
        --disk-threshold|--disk-critical|--ram-threshold|--ram-critical| \
        --cpu-threshold|--cpu-critical|--output)
            if (($# < 2)); then
                error "Missing value for $1"
                usage >&2
                exit 3
            fi
            option="$1"
            value="$2"
            case "$option" in
                --disk-threshold) is_percent "$value" || { error "Disk threshold must be an integer from 1 to 100";          exit 3; }; DISK_THRESHOLD=$((10#$value)) ;;
                --disk-critical)  is_percent "$value" || { error "Disk critical threshold must be an integer from 1 to 100"; exit 3; }; DISK_CRITICAL=$((10#$value))  ;;
                --ram-threshold)  is_percent "$value" || { error "RAM threshold must be an integer from 1 to 100";           exit 3; }; RAM_THRESHOLD=$((10#$value))  ;;
                --ram-critical)   is_percent "$value" || { error "RAM critical threshold must be an integer from 1 to 100";  exit 3; }; RAM_CRITICAL=$((10#$value))   ;;
                --cpu-threshold)  is_percent "$value" || { error "CPU threshold must be an integer from 1 to 100";           exit 3; }; CPU_THRESHOLD=$((10#$value))  ;;
                --cpu-critical)   is_percent "$value" || { error "CPU critical threshold must be an integer from 1 to 100";  exit 3; }; CPU_CRITICAL=$((10#$value))   ;;
                --output)
                    OUTPUT_FILE="$value"
                    [[ -n "$OUTPUT_FILE" ]] || { error "Output path cannot be empty"; exit 3; }
                    ;;
            esac
            shift 2
            ;;
        --color)    COLOR_MODE="always"; shift ;;
        --no-color) COLOR_MODE="never";  shift ;;
        -h|--help)  usage; exit 0 ;;
        *)
            error "Unknown option: $1"
            usage >&2
            exit 3
            ;;
    esac
done

# --- Cross-option validation ---------------------------------------------
# A critical threshold below its warning threshold is meaningless: the
# warning state could never be reached. Reject it up front.
(( DISK_CRITICAL >= DISK_THRESHOLD )) || {
    error "Disk critical threshold ($DISK_CRITICAL%) must be >= warning threshold ($DISK_THRESHOLD%)"
    exit 3
}
(( RAM_CRITICAL >= RAM_THRESHOLD )) || {
    error "RAM critical threshold ($RAM_CRITICAL%) must be >= warning threshold ($RAM_THRESHOLD%)"
    exit 3
}
(( CPU_CRITICAL >= CPU_THRESHOLD )) || {
    error "CPU critical threshold ($CPU_CRITICAL%) must be >= warning threshold ($CPU_THRESHOLD%)"
    exit 3
}

# --- Required commands ----------------------------------------------------
for command_name in \
    awk basename cat chmod date df dirname hostname \
    mktemp mv nproc readlink rm sed
do
    command -v "$command_name" >/dev/null 2>&1 ||
        { error "Required command not found: $command_name"; exit 3; }
done

# --- Color setup ----------------------------------------------------------
setup_colors() {
    local enable=0
    case "$COLOR_MODE" in
        always) enable=1 ;;
        never)  enable=0 ;;
        auto)
            if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
                enable=1
            fi
            ;;
    esac
    if (( enable )); then
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_CYAN=$'\033[36m'
        C_CYAN_B=$'\033[1;36m'
        C_GREEN_B=$'\033[1;32m'
        C_YELLOW_B=$'\033[1;33m'
        C_RED_B=$'\033[1;31m'
    else
        C_RESET='' C_BOLD='' C_DIM='' C_CYAN='' C_CYAN_B=''
        C_GREEN_B='' C_YELLOW_B='' C_RED_B=''
    fi
}
setup_colors

section() {
    local title="$1"
    local dashes="${title//?/-}"
    printf '%s%s%s\n%s%s%s\n' \
        "$C_BOLD$C_CYAN" "$title"  "$C_RESET" \
        "$C_DIM"         "$dashes" "$C_RESET"
}

status_ok()   { printf 'Status: %sOK%s\n'            "$C_GREEN_B"  "$C_RESET"; }
status_warn() { printf 'Status: %sWARNING%s - %s\n'  "$C_YELLOW_B" "$C_RESET" "$1"; }
status_crit() { printf 'Status: %sCRITICAL%s - %s\n' "$C_RED_B"    "$C_RESET" "$1"; }

strip_ansi() {
    sed -E 's/\x1b\[[0-9;]*m//g'
}

# --- Output destination validation ---------------------------------------
# Resolve symlinks up-front so we atomically replace the *target* of a
# symlinked destination (matching `cp`'s follow-symlink behaviour), rather
# than replacing the link itself.
if [[ -n "$OUTPUT_FILE" ]]; then
    OUTPUT_REAL="$(readlink -m -- "$OUTPUT_FILE")" || {
        error "Cannot resolve output path: $OUTPUT_FILE"
        exit 3
    }
    [[ -n "$OUTPUT_REAL" ]] || { error "Cannot resolve output path: $OUTPUT_FILE"; exit 3; }

    output_dir="$(dirname -- "$OUTPUT_REAL")"
    [[ -d "$output_dir" ]] || {
        error "Output directory does not exist: $output_dir"
        exit 3
    }
    if [[ -e "$OUTPUT_REAL" && ! -f "$OUTPUT_REAL" ]]; then
        error "Output path exists but is not a regular file: $OUTPUT_REAL"
        exit 3
    fi
    if { [[ -e "$OUTPUT_REAL" ]] && [[ ! -w "$OUTPUT_REAL" ]]; } || [[ ! -w "$output_dir" ]]; then
        error "No write permission for output path: $OUTPUT_REAL"
        exit 3
    fi
fi

# --- Report setup --------------------------------------------------------
REPORT=""
OUTPUT_TMP=""
cleanup() {
    if [[ -n "$REPORT" ]];     then rm -f -- "$REPORT";     fi
    if [[ -n "$OUTPUT_TMP" ]]; then rm -f -- "$OUTPUT_TMP"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

REPORT="$(mktemp)" || { error "Unable to create temporary report"; exit 3; }

WARNINGS=0
CRITICALS=0
add_warning()  { WARNINGS=$((WARNINGS + 1)); }
add_critical() { CRITICALS=$((CRITICALS + 1)); }

# --- Gather system facts once --------------------------------------------
now_utc="$(date -u '+%Y-%m-%d %H:%M:%S')"
host_name="$(hostname 2>/dev/null || printf 'unknown')"
kernel_rel="$(uname -r 2>/dev/null || printf 'unknown')"

os_pretty="unknown"
if [[ -r /etc/os-release ]]; then
    os_pretty="$(
        # shellcheck disable=SC1091
        . /etc/os-release 2>/dev/null
        printf '%s' "${PRETTY_NAME:-unknown}"
    )"
fi

# --- Report header -------------------------------------------------------
{
    printf '%sSYSTEM HEALTH REPORT%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
    printf '%s====================%s\n' "$C_DIM" "$C_RESET"
    printf 'Generated: %s UTC\n' "$now_utc"
    printf 'Hostname:  %s\n' "$host_name"
    printf 'OS:        %s\n' "$os_pretty"
    printf 'Kernel:    %s\n' "$kernel_rel"
    printf '\n'
} >> "$REPORT"

# --- Uptime --------------------------------------------------------------
{
    section "UPTIME"
    if [[ -r /proc/uptime ]]; then
        IFS=' ' read -r uptime_seconds _ < /proc/uptime
        uptime_seconds="${uptime_seconds%.*}"
        printf 'Uptime: %d days, %d hours, %d minutes\n' \
            "$((uptime_seconds / 86400))" \
            "$(((uptime_seconds % 86400) / 3600))" \
            "$(((uptime_seconds % 3600) / 60))"
    elif command -v uptime >/dev/null 2>&1; then
        printf 'Uptime: %s\n' "$(uptime -p 2>/dev/null || uptime)"
    else
        printf 'Uptime: unavailable\n'
    fi
    printf '\n'
} >> "$REPORT"

# --- CPU load ------------------------------------------------------------
{
    section "CPU LOAD"
    if [[ -r /proc/loadavg ]]; then
        IFS=' ' read -r load_1m load_5m load_15m _ < /proc/loadavg
        cpu_count="$(nproc 2>/dev/null || printf '1')"
        if [[ ! "$cpu_count" =~ ^[0-9]+$ ]] || (( cpu_count < 1 )); then
            cpu_count=1
        fi
        IFS=' ' read -r load_pct load_pct_int < <(
            awk -v l="$load_1m" -v c="$cpu_count" 'BEGIN {
                x = (l / c) * 100
                printf "%.1f %d\n", x, x
            }'
        )
        printf 'Logical CPUs: %s\n' "$cpu_count"
        printf 'Load average (1/5/15 min): %s / %s / %s\n' "$load_1m" "$load_5m" "$load_15m"
        printf '1-minute load / CPU count: %s%% (warning: %s%%, critical: %s%%)\n' \
            "$load_pct" "$CPU_THRESHOLD" "$CPU_CRITICAL"
        if (( load_pct_int >= CPU_CRITICAL )); then
            status_crit "high CPU load relative to CPU count"
            add_critical
        elif (( load_pct_int >= CPU_THRESHOLD )); then
            status_warn "elevated CPU load relative to CPU count"
            add_warning
        else
            status_ok
        fi
    else
        printf 'CPU load: unavailable (/proc/loadavg not readable)\n'
        add_warning
    fi
    printf '\n'
} >> "$REPORT"

# --- Memory --------------------------------------------------------------
{
    section "MEMORY"
    if [[ -r /proc/meminfo ]]; then
        IFS=' ' read -r mem_total_kb mem_available_kb swap_total_kb swap_free_kb < <(
            awk '/^MemTotal:/     {mt=$2}
                 /^MemAvailable:/ {ma=$2}
                 /^SwapTotal:/    {st=$2}
                 /^SwapFree:/     {sf=$2}
                 END {printf "%d %d %d %d\n", mt, ma, st, sf}' /proc/meminfo
        )
        if (( mem_total_kb > 0 )); then
            mem_used_kb=$((mem_total_kb - mem_available_kb))
            mem_pct=$((mem_used_kb * 100 / mem_total_kb))
            printf 'RAM: %s MiB used / %s MiB total (%s%%)\n' \
                "$((mem_used_kb / 1024))" "$((mem_total_kb / 1024))" "$mem_pct"
            printf 'RAM thresholds: warning %s%%, critical %s%%\n' \
                "$RAM_THRESHOLD" "$RAM_CRITICAL"
            if (( mem_pct >= RAM_CRITICAL )); then
                status_crit "RAM usage is very high"
                add_critical
            elif (( mem_pct >= RAM_THRESHOLD )); then
                status_warn "RAM usage is elevated"
                add_warning
            else
                status_ok
            fi
        else
            printf 'RAM: unable to determine total memory\n'
            add_warning
        fi

        if (( swap_total_kb > 0 )); then
            swap_used_kb=$((swap_total_kb - swap_free_kb))
            swap_pct=$((swap_used_kb * 100 / swap_total_kb))
            printf 'Swap: %s MiB used / %s MiB total (%s%%)\n' \
                "$((swap_used_kb / 1024))" "$((swap_total_kb / 1024))" "$swap_pct"
            if (( swap_pct >= 90 )); then
                printf 'Swap status: %sWARNING%s - swap usage is high\n' "$C_YELLOW_B" "$C_RESET"
                add_warning
            else
                printf 'Swap status: %sOK%s\n' "$C_GREEN_B" "$C_RESET"
            fi
        else
            printf 'Swap: not configured\n'
        fi
    else
        printf 'Memory: unavailable (/proc/meminfo not readable)\n'
        add_warning
    fi
    printf '\n'
} >> "$REPORT"

# --- Disk usage ----------------------------------------------------------
{
    section "DISK USAGE"
    printf 'Thresholds: warning %s%%, critical %s%%\n' "$DISK_THRESHOLD" "$DISK_CRITICAL"
    printf '%-7s %-7s %-7s %-7s %s\n' 'Usage' 'Size' 'Used' 'Avail' 'Mount'
    disk_found=0
    # mountpoint is the LAST field so `read` preserves embedded spaces.
    while IFS=' ' read -r filesystem size used avail percent mountpoint; do
        [[ -n "${mountpoint:-}" ]] || continue
        disk_found=1
        percent_num="${percent%%%}"
        printf '%-7s %-7s %-7s %-7s %s\n' "$percent" "$size" "$used" "$avail" "$mountpoint"
        if [[ "$percent_num" =~ ^[0-9]+$ ]]; then
            if (( percent_num >= DISK_CRITICAL )); then
                printf '  %sCRITICAL%s: %s is at %s usage\n' \
                    "$C_RED_B" "$C_RESET" "$mountpoint" "$percent"
                add_critical
            elif (( percent_num >= DISK_THRESHOLD )); then
                printf '  %sWARNING%s: %s is at %s usage\n' \
                    "$C_YELLOW_B" "$C_RESET" "$mountpoint" "$percent"
                add_warning
            fi
        fi
    done < <(df -Ph -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2)
    if (( disk_found == 0 )); then
        printf 'Disk usage: unable to read filesystem data\n'
        add_warning
    fi
    printf '\n'
} >> "$REPORT"

# --- Failed systemd services ---------------------------------------------
{
    section "FAILED SYSTEMD SERVICES"
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        failed_services="$(systemctl --failed --type=service --no-legend --plain 2>/dev/null || true)"
        if [[ -n "$failed_services" ]]; then
            printf '%s\n' "$failed_services"
            status_crit "failed systemd service(s) detected"
            add_critical
        else
            printf 'No failed systemd services reported.\n'
            status_ok
        fi
    else
        printf 'systemd is not running or systemctl is unavailable; service check skipped.\n'
        add_warning
    fi
    printf '\n'
} >> "$REPORT"

# --- Overall result ------------------------------------------------------
REPORT_STATUS="HEALTHY"
if (( CRITICALS > 0 )); then
    REPORT_STATUS="CRITICAL"
elif (( WARNINGS > 0 )); then
    REPORT_STATUS="WARNING"
fi

{
    section "OVERALL RESULT"
    case "$REPORT_STATUS" in
        CRITICAL) status_color="$C_RED_B" ;;
        WARNING)  status_color="$C_YELLOW_B" ;;
        *)        status_color="$C_GREEN_B" ;;
    esac
    if (( WARNINGS > 0 ));  then warn_color="$C_YELLOW_B"; else warn_color="$C_GREEN_B"; fi
    if (( CRITICALS > 0 )); then crit_color="$C_RED_B";    else crit_color="$C_GREEN_B"; fi
    printf 'Status: %s%s%s\n'            "$status_color" "$REPORT_STATUS" "$C_RESET"
    printf 'Warnings: %s%d%s\n'          "$warn_color"   "$WARNINGS"      "$C_RESET"
    printf 'Critical findings: %s%d%s\n' "$crit_color"   "$CRITICALS"     "$C_RESET"
    printf '\n'
    printf '%sInterpretation:%s CPU is based on 1-minute load divided by logical CPU count; it is not a direct CPU utilization measurement.\n' \
        "$C_DIM" "$C_RESET"
} >> "$REPORT"

# --- Display -------------------------------------------------------------
if ! cat -- "$REPORT"; then
    error "Unable to display report"
    exit 3
fi

# --- Atomic save ---------------------------------------------------------
# Strategy: write plain text to a tempfile in the SAME directory as the
# destination, fsync it, then rename over the target. On POSIX filesystems
# rename(2) is atomic, so a concurrent reader sees either the old file or
# the new one — never a partially-written report. This also preserves the
# destination's inode replacement semantics (hard links not followed, which
# is the standard "safe write" idiom).
if [[ -n "$OUTPUT_FILE" ]]; then
    output_base="$(basename -- "$OUTPUT_REAL")"
    OUTPUT_TMP="$(mktemp --tmpdir="$output_dir" ".${output_base}.XXXXXX")" || {
        error "Unable to create temporary file in: $output_dir"
        exit 3
    }
    # Preserve existing permissions; otherwise use a conventional default.
    if [[ -e "$OUTPUT_REAL" ]]; then
        chmod --reference="$OUTPUT_REAL" -- "$OUTPUT_TMP" 2>/dev/null || true
    else
        chmod 0644 -- "$OUTPUT_TMP" 2>/dev/null || true
    fi
    if ! strip_ansi < "$REPORT" > "$OUTPUT_TMP"; then
        error "Unable to write report to temporary file: $OUTPUT_TMP"
        exit 3
    fi
    # Flush before the rename so a crash right after won't leave an empty file.
    sync -- "$OUTPUT_TMP" 2>/dev/null || true
    # -T: never treat destination as a directory (the earlier -f check
    # already guards this, but -T defends against a race).
    if ! mv -fT -- "$OUTPUT_TMP" "$OUTPUT_REAL"; then
        error "Unable to move report into place: $OUTPUT_REAL"
        exit 3
    fi
    OUTPUT_TMP=""   # rename succeeded; nothing left for the trap to clean
    printf '\nReport saved to: %s%s%s\n' "$C_CYAN" "$OUTPUT_FILE" "$C_RESET"
fi

if   (( CRITICALS > 0 )); then exit 2
elif (( WARNINGS  > 0 )); then exit 1
else                          exit 0
fi