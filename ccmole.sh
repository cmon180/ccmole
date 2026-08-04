#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  ccmole — interactive cleanup tool for Claude Code
#
#  A wrapper around the built-in command
#      claude project purge [path] [--all|--dry-run|-i|-y]
#  extended by the areas purge does not cover (jobs/, cache/, telemetry/ …).
#
#  Driven by the arrow keys. Runs on macOS and Linux.
#  Dependencies: bash (3.2+), POSIX coreutils, the claude CLI.
#  python3 is used when present, but is not required.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

VERSION="2.2.0"

# Claude Code honors CLAUDE_CONFIG_DIR; otherwise ~/.claude.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -f "$CLAUDE_DIR/.claude.json" ]; then
    CONFIG_JSON="$CLAUDE_DIR/.claude.json"
else
    CONFIG_JSON="$HOME/.claude.json"
fi
BACKUP_DIR="${CCMOLE_BACKUP_DIR:-$HOME/.claude-backups}"

# Never offered for deletion.
PROTECTED="settings.json settings.local.json CLAUDE.md credentials.json .credentials.json
           skills commands agents plugins ide hooks memory rules workflows keybindings.json"

# ── Platform abstraction ─────────────────────────────────────────────────────

detect_platform() {
    # mtime of a file: BSD/macOS uses -f, GNU/Linux -c.
    # The exit code alone is not enough — GNU stat reads -f as --file-system and
    # still prints something. So check for a plain number instead.
    local probe
    STAT_FLAVOR="none"
    probe=$(stat -c '%Y' / 2>/dev/null | head -1)
    case "$probe" in
        ''|*[!0-9]*) ;;
        *) STAT_FLAVOR="gnu" ;;
    esac
    if [ "$STAT_FLAVOR" = "none" ]; then
        probe=$(stat -f '%m' / 2>/dev/null | head -1)
        case "$probe" in
            ''|*[!0-9]*) ;;
            *) STAT_FLAVOR="bsd" ;;
        esac
    fi

    # GNU find can print timestamps directly — faster than one stat per file.
    FIND_PRINTF=0
    probe=$(find / -maxdepth 0 -printf '%T@\n' 2>/dev/null | head -1)
    case "$probe" in
        ''|*[!0-9.]*) ;;
        *) FIND_PRINTF=1 ;;
    esac

    term_size
}

term_size() {
    COLS=$( { tput cols; } 2>/dev/null || printf '' )
    ROWS=$( { tput lines; } 2>/dev/null || printf '' )
    case "$COLS" in ''|*[!0-9]*) COLS=80 ;; esac
    case "$ROWS" in ''|*[!0-9]*) ROWS=24 ;; esac
}

file_mtime() {
    case "$STAT_FLAVOR" in
        bsd) stat -f '%m' "$1" 2>/dev/null ;;
        gnu) stat -c '%Y' "$1" 2>/dev/null ;;
        *)   printf '' ;;
    esac
}

# Newest modification time below a path (empty = unknown).
newest_mtime() {
    local p="$1"
    [ -e "$p" ] || return 0
    [ -f "$p" ] && { file_mtime "$p"; return 0; }
    if [ "$FIND_PRINTF" = "1" ]; then
        find "$p" -type f -printf '%T@\n' 2>/dev/null | cut -d. -f1 | sort -rn | head -1
    elif [ "$STAT_FLAVOR" = "bsd" ]; then
        find "$p" -type f -exec stat -f '%m' {} + 2>/dev/null | sort -rn | head -1
    elif [ "$STAT_FLAVOR" = "gnu" ]; then
        find "$p" -type f -exec stat -c '%Y' {} + 2>/dev/null | sort -rn | head -1
    fi
}

make_tempfile() { mktemp "${TMPDIR:-/tmp}/ccmole.XXXXXX"; }

# ── Terminal ─────────────────────────────────────────────────────────────────

TTY_OUT=0
[ -t 1 ] && TTY_OUT=1

hide_cursor() { [ "$TTY_OUT" = 1 ] && printf '\033[?25l' || true; }
show_cursor() { [ "$TTY_OUT" = 1 ] && printf '\033[?25h' || true; }
home()        { [ "$TTY_OUT" = 1 ] && printf '\033[H'    || true; }
clear_eos()   { [ "$TTY_OUT" = 1 ] && printf '\033[J'    || true; }
clear_screen(){ [ "$TTY_OUT" = 1 ] && printf '\033[H\033[2J' || true; }

# Clear to end of line so no leftovers remain when redrawing.
eol() { [ "$TTY_OUT" = 1 ] && printf '\033[K' || true; }

# Alternate screen buffer: after quitting, the terminal shows again what was
# there before — like less or htop.
TUI_ACTIVE=0
enter_tui() {
    [ "$TTY_OUT" = 1 ] || return 0
    [ -n "${CCMOLE_NO_ALTSCREEN:-}" ] || printf '\033[?1049h'
    TUI_ACTIVE=1
    hide_cursor
}
leave_tui() {
    [ "${TUI_ACTIVE:-0}" = 1 ] || { show_cursor; return 0; }
    TUI_ACTIVE=0
    show_cursor
    [ -n "${CCMOLE_NO_ALTSCREEN:-}" ] || printf '\033[?1049l'
}

cleanup() { leave_tui; }
trap cleanup EXIT INT TERM

# Read one key and map it to a name.
# Escape sequences arrive as ESC [ A/B/C/D — the trailing characters are read
# with a timeout so a lone ESC does not block. bash 3.2 only knows whole
# seconds for -t, hence 1 instead of 0.05.
read_key() {
    local k rest junk
    IFS= read -rsn1 k 2>/dev/null || { printf 'quit'; return; }
    case "$k" in
        $'\033')
            rest=""
            IFS= read -rsn2 -t 1 rest 2>/dev/null
            case "$rest" in
                '[A') printf 'up' ;;
                '[B') printf 'down' ;;
                '[C') printf 'right' ;;
                '[D') printf 'left' ;;
                '[H') printf 'home' ;;
                '[F') printf 'end' ;;
                '[5') IFS= read -rsn1 -t 1 junk 2>/dev/null; printf 'pgup' ;;
                '[6') IFS= read -rsn1 -t 1 junk 2>/dev/null; printf 'pgdn' ;;
                *)    printf 'esc' ;;
            esac ;;
        '')     printf 'enter' ;;
        ' ')    printf 'space' ;;
        $'\177'|$'\b') printf 'backspace' ;;
        *)      printf '%s' "$k" ;;
    esac
}

# ── Presentation ─────────────────────────────────────────────────────────────

setup_colors() {
    if [ "$TTY_OUT" = 1 ] && [ -z "${NO_COLOR:-}" ]; then
        C_RESET=$'\033[0m'; C_DIM=$'\033[2m';  C_BOLD=$'\033[1m'
        C_RED=$'\033[31m';  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
        C_BLU=$'\033[34m';  C_MAG=$'\033[35m'; C_CYN=$'\033[36m'
        C_INV=$'\033[7m'
    else
        C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""
        C_BLU=""; C_MAG=""; C_CYN=""; C_INV=""
    fi
}

# Frames and bars need UTF-8, otherwise the alignment falls apart.
setup_charset() {
    local enc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    case "$enc" in
        *[Uu][Tt][Ff]*) UNICODE=1 ;;
        *)              UNICODE=0 ;;
    esac
    if [ "$UNICODE" = "1" ]; then
        CH_TL="╭"; CH_TR="╮"; CH_BL="╰"; CH_BR="╯"; CH_H="─"; CH_V="│"
        CH_FULL="█"; CH_EMPTY="·"; CH_CUR="▸"; CH_UP="↑"; CH_DN="↓"
        CH_ON="●"; CH_OFF="○"
    else
        CH_TL="+"; CH_TR="+"; CH_BL="+"; CH_BR="+"; CH_H="-"; CH_V="|"
        CH_FULL="#"; CH_EMPTY="."; CH_CUR=">"; CH_UP="^"; CH_DN="v"
        CH_ON="x"; CH_OFF=" "
    fi
}

say()   { printf '%s\n' "$*"; }
dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
warn()  { printf '%s  ! %s%s\n' "$C_YEL" "$*" "$C_RESET"; }
err()   { printf '%s  x %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
ok()    { printf '%s  + %s%s\n' "$C_GRN" "$*" "$C_RESET"; }

# Waits for any key (not just Enter).
anykey() {
    printf '\n  %s[press any key]%s ' "$C_DIM" "$C_RESET"
    read_key >/dev/null
    printf '\n'
}

repeat() {
    local c="$1" n="${2:-0}" s=""
    while [ "$n" -gt 0 ]; do s="$s$c"; n=$((n-1)); done
    printf '%s' "$s"
}

rule() { printf '%s%s%s' "$C_DIM" "$(repeat "$CH_H" "${1:-58}")" "$C_RESET"; }

# printf '%-Ns' pads by bytes — non-ASCII characters shift the columns that way.
# ${#s} counts characters under a UTF-8 locale, so pad by hand here.
pad_right() {
    local t="$1" w="${2:-0}" n
    n=$(( w - ${#t} ))
    [ "$n" -lt 0 ] && n=0
    printf '%s%s' "$t" "$(repeat ' ' "$n")"
}

# Truncates to n characters. Without this, long lines wrap and shift the whole
# layout on the next redraw.
trunc() {
    local t="$1" w="${2:-0}"
    [ "$w" -lt 2 ] && return 0
    if [ ${#t} -le "$w" ]; then printf '%s' "$t"; return 0; fi
    if [ "$UNICODE" = "1" ]; then printf '%s…' "${t:0:$((w-1))}"
    else printf '%s...' "${t:0:$((w-3))}"; fi
}

bar() {
    local val="$1" max="$2" width="${3:-18}" n=0
    [ "$max" -gt 0 ] && n=$(( val * width / max ))
    [ "$n" -gt "$width" ] && n="$width"
    [ "$n" -lt 0 ] && n=0
    printf '%s%s%s%s%s' "$C_BLU" "$(repeat "$CH_FULL" "$n")" \
        "$C_DIM" "$(repeat "$CH_EMPTY" $((width - n)))" "$C_RESET"
}

# KB → human readable, integers only (no bc, no awk rounding drift).
human() {
    local kb="${1:-0}"
    case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
    if   [ "$kb" -ge 1048576 ]; then printf '%d.%01d GB' $((kb/1048576)) $(( (kb%1048576)*10/1048576 ))
    elif [ "$kb" -ge 1024 ];    then printf '%d MB' $((kb/1024))
    else                             printf '%d KB' "$kb"
    fi
}

size_kb() {
    [ -e "$1" ] || { printf '0'; return; }
    du -sk "$1" 2>/dev/null | awk 'NR==1{print $1; exit}' || printf '0'
}

age_days() {
    local m now
    m=$(newest_mtime "$1")
    [ -z "$m" ] && { printf '0'; return; }
    now=$(date +%s)
    printf '%d' $(( (now - m) / 86400 ))
}

age_minutes() {
    local m now
    m=$(newest_mtime "$1")
    [ -z "$m" ] && { printf '999999'; return; }
    now=$(date +%s)
    printf '%d' $(( (now - m) / 60 ))
}

short_path() {
    local p="$1" max="${2:-30}"
    case "$p" in "$HOME"/*) p="~${p#$HOME}" ;; "$HOME") p="~" ;; esac
    if [ ${#p} -gt "$max" ]; then
        if [ "$UNICODE" = "1" ]; then printf '…%s' "${p: -$((max-1))}"
        else printf '...%s' "${p: -$((max-3))}"; fi
    else
        printf '%s' "$p"
    fi
}

# ── Safety ───────────────────────────────────────────────────────────────────

# Every deletion passes through here. No rm without a passing check.
assert_safe_path() {
    local p="$1" parent real base prot claude_real
    case "$p" in
        *..*)            err "path contains '..': $p"; return 1 ;;
        "$CLAUDE_DIR")   err "refused: that is the Claude directory itself"; return 1 ;;
        "$CLAUDE_DIR"/*) ;;
        *)               err "refused: outside of $CLAUDE_DIR: $p"; return 1 ;;
    esac
    if [ "$p" = "/" ] || [ "$p" = "$HOME" ]; then err "refused: $p"; return 1; fi

    # Symlinks must not lead out of the Claude directory.
    parent=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || { err "path not resolvable: $p"; return 1; }
    base=$(basename "$p")
    real="$parent/$base"
    claude_real=$(cd "$CLAUDE_DIR" 2>/dev/null && pwd -P)
    case "$real" in
        "$claude_real"/*) ;;
        *) err "refused: target lies outside ($real)"; return 1 ;;
    esac

    for prot in $PROTECTED; do
        [ "$base" = "$prot" ] && { err "protected: $prot"; return 1; }
    done
    return 0
}

safe_rm() {
    local p="$1"
    assert_safe_path "$p" || return 1
    [ -e "$p" ] || return 0
    rm -rf -- "$p"
}

make_backup() {
    local label="$1"; shift
    local stamp archive rel p rels=()
    stamp=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$BACKUP_DIR" || { err "cannot create backup directory"; return 1; }
    archive="$BACKUP_DIR/${label}-${stamp}.tar.gz"

    for p in "$@"; do
        [ -e "$p" ] || continue
        case "$p" in "$HOME"/*) rel="${p#$HOME/}" ;; *) rel="$p" ;; esac
        rels+=("$rel")
    done
    [ ${#rels[@]} -eq 0 ] && { warn "nothing to back up."; return 0; }

    printf '  backing up … '
    if tar czf "$archive" -C "$HOME" "${rels[@]}" 2>/dev/null; then
        printf '\r'; ok "backup: $(short_path "$archive" 48) ($(human "$(size_kb "$archive")"))"
        return 0
    fi
    printf '\r'; err "backup failed — aborting"
    rm -f "$archive"
    return 1
}

# ── Project discovery ────────────────────────────────────────────────────────

P_DIR=(); P_PATH=(); P_KB=(); P_AGE=(); P_ORPHAN=(); P_MEM=(); P_LIVE=(); P_SEL=()
CONFIG_PATHS_CACHE=""

# The encoding Claude Code uses for folder names: anything but [A-Za-z0-9] → '-'
encode_path() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

config_paths() {
    [ -f "$CONFIG_JSON" ] || return 0
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$CONFIG_JSON" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k in (d.get('projects') or {}):
    print(k)
PY
    else
        # Without python3: pull the project keys out of the JSON heuristically.
        tr ',' '\n' < "$CONFIG_JSON" \
            | grep -o '"/[^"]*"[[:space:]]*:[[:space:]]*{' \
            | sed 's/^"//; s/"[[:space:]]*:[[:space:]]*{$//'
    fi
}

# Determine the real project path behind a projects/ folder.
# 1. cwd from the transcript (exact)  2. match against the config  3. heuristic
resolve_path() {
    local dir="$1" base f p cp
    base=$(basename "$dir")

    for f in "$dir"/*.jsonl; do
        [ -f "$f" ] || continue
        p=$(head -c 400000 "$f" 2>/dev/null \
            | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
            | sed 's/.*:[[:space:]]*"//; s/"$//')
        if [ -n "$p" ]; then printf '%s' "$p"; return 0; fi
    done

    if [ -n "$CONFIG_PATHS_CACHE" ]; then
        while IFS= read -r cp; do
            [ -z "$cp" ] && continue
            if [ "$(encode_path "$cp")" = "$base" ]; then printf '%s' "$cp"; return 0; fi
        done <<< "$CONFIG_PATHS_CACHE"
    fi

    # Last resort: translate the separators back. Lossy — '_' and ' ' in the
    # original path cannot be recovered at this point.
    printf '%s' "$(printf '%s' "$base" | sed 's/^-/\//; s/-/\//g')"
    return 1
}

scan_projects() {
    P_DIR=(); P_PATH=(); P_KB=(); P_AGE=(); P_ORPHAN=(); P_MEM=(); P_LIVE=(); P_SEL=()
    CONFIG_PATHS_CACHE=$(config_paths)

    [ -d "$CLAUDE_DIR/projects" ] || return 0

    local tmpf d kb path orphan mem live
    tmpf=$(make_tempfile) || return 1
    for d in "$CLAUDE_DIR/projects"/*; do
        [ -d "$d" ] || continue
        printf '%s\t%s\n' "$(size_kb "$d")" "$d" >> "$tmpf"
    done

    while IFS=$'\t' read -r kb d; do
        [ -z "${d:-}" ] && continue
        path=$(resolve_path "$d")
        orphan=0; [ -d "$path" ] || orphan=1
        mem=0
        [ -d "$d/memory" ] && mem=$(find "$d/memory" -type f 2>/dev/null | wc -l | tr -d ' ')
        live=0
        [ "$(age_minutes "$d")" -lt 15 ] && live=1

        P_DIR+=("$d"); P_PATH+=("$path"); P_KB+=("$kb")
        P_AGE+=("$(age_days "$d")"); P_ORPHAN+=("$orphan")
        P_MEM+=("$mem"); P_LIVE+=("$live"); P_SEL+=(0)
    done < <(sort -rn "$tmpf")
    rm -f "$tmpf"
}

# ── Junk: what "claude project purge" does not cover ─────────────────────────

J_PATH=(); J_LABEL=(); J_KB=(); J_NOTE=(); J_RISK=(); J_SEL=()

add_junk() {
    local p="$1" label="$2" note="$3" risk="$4" kb
    [ -e "$p" ] || return 0
    kb=$(size_kb "$p")
    [ "$kb" -lt 1 ] && return 0
    J_PATH+=("$p"); J_LABEL+=("$label"); J_KB+=("$kb")
    J_NOTE+=("$note"); J_RISK+=("$risk"); J_SEL+=(0)
}

scan_junk() {
    J_PATH=(); J_LABEL=(); J_KB=(); J_NOTE=(); J_RISK=(); J_SEL=()

    local j state age
    for j in "$CLAUDE_DIR"/jobs/*; do
        [ -d "$j/tmp" ] || continue
        state="unknown"
        if [ -f "$j/state.json" ]; then
            # state.json is pretty-printed: "state": "done"
            state=$(grep -o '"state"[[:space:]]*:[[:space:]]*"[^"]*"' "$j/state.json" 2>/dev/null \
                    | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')
            [ -z "$state" ] && state="unknown"
        fi
        age=$(age_days "$j")
        if [ "$state" = "done" ]; then
            add_junk "$j/tmp" "jobs/$(basename "$j")/tmp" \
                     "finished, ${age} days old" "low"
        else
            add_junk "$j/tmp" "jobs/$(basename "$j")/tmp" \
                     "state: ${state} — may still be running" "high"
        fi
    done

    add_junk "$CLAUDE_DIR/debug"           "debug/"           "session debug logs"              "low"
    add_junk "$CLAUDE_DIR/telemetry"       "telemetry/"       "telemetry not yet sent"          "low"
    add_junk "$CLAUDE_DIR/paste-cache"     "paste-cache/"     "clipboard leftovers"             "low"
    add_junk "$CLAUDE_DIR/shell-snapshots" "shell-snapshots/" "not project specific"            "low"
    add_junk "$CLAUDE_DIR/cache"           "cache/"           "rebuilt on demand"               "low"
    add_junk "$CLAUDE_DIR/statsig"         "statsig/"         "feature flag cache"              "low"
    add_junk "$CLAUDE_DIR/file-history"    "file-history/"    "undo snapshots will be lost"     "medium"
    add_junk "$CLAUDE_DIR/backups"         "backups/"         ".claude.json snapshots (max. 5)" "medium"
}

# ── Overview ─────────────────────────────────────────────────────────────────

# The overview is computed once and cached. Without the cache, every keypress
# would trigger a du over the whole directory.
OV_TOTAL=0; OV_FILES=0; OV_CATS=""; OV_MAX=0; OV_COUNT=0

scan_overview() {
    local cat kb
    OV_TOTAL=$(size_kb "$CLAUDE_DIR")
    OV_FILES=$(find "$CLAUDE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    OV_CATS=""; OV_MAX=0; OV_COUNT=0
    for cat in projects jobs file-history cache backups telemetry debug shell-snapshots; do
        kb=$(size_kb "$CLAUDE_DIR/$cat")
        [ "$kb" -lt 1024 ] && continue
        OV_CATS="${OV_CATS}${cat} ${kb}
"
        [ "$kb" -gt "$OV_MAX" ] && OV_MAX="$kb"
        OV_COUNT=$((OV_COUNT + 1))
    done
}

overview() {
    local total files cat kb
    local title plain pad dir_s size_s W=56

    total="$OV_TOTAL"
    files="$OV_FILES"

    title="ccmole $VERSION"
    printf '%s%s%s %s %s%s%s' \
        "$C_CYN" "$CH_TL" "$CH_H" "$title" \
        "$(repeat "$CH_H" $(( W - 5 - ${#title} )))" "$CH_TR" "$C_RESET"
    eol; printf '\n'

    # Only the visible text counts for the right margin, not the color codes.
    dir_s=$(short_path "$CLAUDE_DIR" 28)
    size_s=$(human "$total")
    plain="  $dir_s   $size_s   $files files"
    pad=$(( W - 2 - ${#plain} )); [ "$pad" -lt 0 ] && pad=0
    printf '%s%s%s  %s   %s%s%s   %s%s files%s%s%s%s%s' \
        "$C_CYN" "$CH_V" "$C_RESET" "$dir_s" \
        "$C_BOLD" "$size_s" "$C_RESET" "$C_DIM" "$files" "$C_RESET" \
        "$(repeat ' ' "$pad")" "$C_CYN" "$CH_V" "$C_RESET"
    eol; printf '\n'

    printf '%s%s%s%s%s' \
        "$C_CYN" "$CH_BL" "$(repeat "$CH_H" $(( W - 2 )))" "$CH_BR" "$C_RESET"
    eol; printf '\n'
    eol; printf '\n'

    while read -r cat kb; do
        [ -z "${cat:-}" ] && continue
        printf '   %s %s  %9s' "$(pad_right "$cat" 16)" "$(bar "$kb" "$OV_MAX")" "$(human "$kb")"
        eol; printf '\n'
    done <<< "$OV_CATS"
    eol; printf '\n'
}

# ── Navigation ───────────────────────────────────────────────────────────────

CURSOR=0    # highlighted row
TOP=0       # first visible row (scroll offset)

# How many list rows fit on the terminal?
# Head = frame (3) + blank line + category bars + blank line.
# $1 = rows the screen needs on top of that for its table header and footer.
viewport() {
    local extra="${1:-9}" head v
    head=$(( 5 + OV_COUNT ))
    v=$(( ROWS - head - extra ))
    [ "$v" -lt 3 ] && v=3
    printf '%d' "$v"
}

# For screens without the storage overview in the head.
viewport_plain() {
    local v
    v=$(( ROWS - ${1:-16} ))
    [ "$v" -lt 3 ] && v=3
    printf '%d' "$v"
}

# Move the cursor. Returns 0 when the key was handled.
nav() {
    local key="$1" n="$2" vis="$3"
    [ "$n" -le 0 ] && return 1
    case "$key" in
        up|k)     CURSOR=$((CURSOR - 1)); [ "$CURSOR" -lt 0 ] && CURSOR=$((n - 1)) ;;
        down|j)   CURSOR=$((CURSOR + 1)); [ "$CURSOR" -ge "$n" ] && CURSOR=0 ;;
        pgup)     CURSOR=$((CURSOR - vis)); [ "$CURSOR" -lt 0 ] && CURSOR=0 ;;
        pgdn)     CURSOR=$((CURSOR + vis)); [ "$CURSOR" -ge "$n" ] && CURSOR=$((n - 1)) ;;
        home|g)   CURSOR=0 ;;
        end|G)    CURSOR=$((n - 1)) ;;
        *) return 1 ;;
    esac
    # Follow with the viewport
    [ "$CURSOR" -lt "$TOP" ] && TOP="$CURSOR"
    [ "$CURSOR" -ge $((TOP + vis)) ] && TOP=$((CURSOR - vis + 1))
    [ "$TOP" -lt 0 ] && TOP=0
    return 0
}

reset_nav() { CURSOR=0; TOP=0; }

# Shows "↑ 3 more" / "↓ 5 more" above and below the list.
scroll_hint() {
    local pos="$1" n="$2" vis="$3" which="$4" rest
    if [ "$which" = "up" ]; then
        rest="$TOP"
        [ "$rest" -gt 0 ] && printf '   %s%s %d more%s' "$C_DIM" "$CH_UP" "$rest" "$C_RESET"
    else
        rest=$(( n - TOP - vis ))
        [ "$rest" -gt 0 ] && printf '   %s%s %d more%s' "$C_DIM" "$CH_DN" "$rest" "$C_RESET"
    fi
    eol; printf '\n'
}

# ── Screen: projects ─────────────────────────────────────────────────────────

render_projects() {
    local vis="$1" i n=${#P_DIR[@]} last name flags box cur line

    printf '   %s     Project                         Size    Age%s' "$C_DIM" "$C_RESET"
    eol; printf '\n'
    printf '   '; rule 62; eol; printf '\n'

    if [ "$n" -eq 0 ]; then
        printf '   %sno project data found%s' "$C_DIM" "$C_RESET"; eol; printf '\n'
        return
    fi

    scroll_hint "$CURSOR" "$n" "$vis" up

    last=$(( TOP + vis - 1 ))
    [ "$last" -ge "$n" ] && last=$((n - 1))

    for (( i=TOP; i<=last; i++ )); do
        name=$(short_path "${P_PATH[$i]}" 28)

        flags=""
        [ "${P_ORPHAN[$i]}" = "1" ] && flags="$flags ${C_YEL}orphan${C_RESET}"
        [ "${P_MEM[$i]}" -gt 0 ]    && flags="$flags ${C_MAG}${P_MEM[$i]}x memory${C_RESET}"
        [ "${P_LIVE[$i]}" = "1" ]   && flags="$flags ${C_GRN}active${C_RESET}"

        if [ "${P_SEL[$i]}" = "1" ]; then box="${C_GRN}${CH_ON}${C_RESET}"; else box="${C_DIM}${CH_OFF}${C_RESET}"; fi

        if [ "$i" -eq "$CURSOR" ]; then
            cur="${C_CYN}${CH_CUR}${C_RESET}"
            line="${C_BOLD}$(pad_right "$name" 28)${C_RESET}"
        else
            cur=" "
            line="$(pad_right "$name" 28)"
        fi

        printf '  %b %b  %b %9s  %4sd%b' \
            "$cur" "$box" "$line" \
            "$(human "${P_KB[$i]}")" "${P_AGE[$i]}" "$flags"
        eol; printf '\n'
    done

    scroll_hint "$CURSOR" "$n" "$vis" down
}

selected_count() {
    local i c=0
    for (( i=0; i<${#P_SEL[@]}; i++ )); do [ "${P_SEL[$i]}" = "1" ] && c=$((c+1)); done
    printf '%d' "$c"
}

selected_kb() {
    local i kb=0
    for (( i=0; i<${#P_SEL[@]}; i++ )); do
        [ "${P_SEL[$i]}" = "1" ] && kb=$(( kb + ${P_KB[$i]} ))
    done
    printf '%d' "$kb"
}

projects_screen() {
    local key i n vis

    reset_nav
    hide_cursor
    clear_screen

    while :; do
        term_size
        n=${#P_DIR[@]}
        vis=$(viewport 10)
        [ "$vis" -gt "$n" ] && [ "$n" -gt 0 ] && vis="$n"

        home
        overview
        render_projects "$vis"

        eol; printf '\n'
        printf '   %sselected: %s of %s  ·  %s%s' \
            "$C_DIM" "$(selected_count)" "$n" "$(human "$(selected_kb)")" "$C_RESET"
        eol; printf '\n'
        eol; printf '\n'
        printf '   %s%s%s/%s%s%s move  %sSpace%s select  %sa%s all  %sn%s none  %so%s orphans' \
            "$C_BOLD" "$CH_UP" "$C_RESET" "$C_BOLD" "$CH_DN" "$C_RESET" \
            "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
        eol; printf '\n'
        printf '   %st%s delete transcripts %s(memory kept)%s     %sc%s delete all %s(purge)%s' \
            "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET" \
            "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
        eol; printf '\n'
        printf '   %sT%s/%sd%s preview  ·  %sB%s/%sb%s with backup  ·  %sq%s back' \
            "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" \
            "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
        eol; printf '\n'
        clear_eos

        key=$(read_key)
        nav "$key" "$n" "$vis" && continue

        case "$key" in
            q|quit|esc) clear_screen; return ;;
            space|enter|right)
                [ "$n" -gt 0 ] || continue
                if [ "${P_SEL[$CURSOR]}" = "1" ]; then P_SEL[$CURSOR]=0; else P_SEL[$CURSOR]=1; fi
                # Move on one row after selecting — feels more fluid.
                [ "$key" = "space" ] && nav down "$n" "$vis"
                ;;
            a) for (( i=0; i<n; i++ )); do P_SEL[$i]=1; done ;;
            n) for (( i=0; i<n; i++ )); do P_SEL[$i]=0; done ;;
            o) for (( i=0; i<n; i++ )); do P_SEL[$i]="${P_ORPHAN[$i]}"; done ;;
            d) show_cursor; purge_selected "dry";       hide_cursor; clear_screen ;;
            c) show_cursor; purge_selected "real";      hide_cursor; clear_screen ;;
            b) show_cursor; purge_selected "backup";    hide_cursor; clear_screen ;;
            T) show_cursor; purge_transcripts "dry";    hide_cursor; clear_screen ;;
            t) show_cursor; purge_transcripts "real";   hide_cursor; clear_screen ;;
            B) show_cursor; purge_transcripts "backup"; hide_cursor; clear_screen ;;
            *) ;;
        esac
    done
}

# Everything attached to a project's sessions — memory/ excluded.
# A session ID owns: <id>.jsonl, the subfolder <id>/ with
# tool-results/subagents/workflows, file-history/<id>/ and tasks/<id>/.
session_artifacts() {
    local dir="$1" e base id
    for e in "$dir"/*; do
        [ -e "$e" ] || continue
        base=$(basename "$e")
        [ "$base" = "memory" ] && continue
        printf '%s\n' "$e"
        case "$base" in
            *.jsonl) id="${base%.jsonl}" ;;
            *)       id="$base" ;;
        esac
        # Only follow real session UUIDs.
        case "$id" in
            ????????-????-????-????-????????????)
                [ -e "$CLAUDE_DIR/file-history/$id" ] && printf '%s\n' "$CLAUDE_DIR/file-history/$id"
                [ -e "$CLAUDE_DIR/tasks/$id" ]        && printf '%s\n' "$CLAUDE_DIR/tasks/$id"
                ;;
        esac
    done
}

# Deletes transcripts and their belongings, leaves memory/ and the entry in
# ~/.claude.json (trust, MCP servers) untouched. "claude project purge" cannot
# do that — it always takes memory/ along.
purge_transcripts() {
    local mode="$1" i j line kb=0 projs=0 sessions=0 mem=0 live=0 answer
    local items=() labels=() sizes=()

    for (( i=0; i<${#P_SEL[@]}; i++ )); do
        [ "${P_SEL[$i]}" = "1" ] || continue
        local pkb=0 psess=0 first=${#items[@]}
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            items+=("$line")
            pkb=$(( pkb + $(size_kb "$line") ))
            case "$line" in *.jsonl) psess=$((psess + 1)) ;; esac
        done < <(session_artifacts "${P_DIR[$i]}" | sort -u)

        [ "${#items[@]}" -eq "$first" ] && continue
        labels+=("$(short_path "${P_PATH[$i]}" 34)")
        sizes+=("$pkb $psess ${P_MEM[$i]}")
        kb=$(( kb + pkb )); sessions=$(( sessions + psess ))
        mem=$(( mem + ${P_MEM[$i]} )); projs=$((projs + 1))
        [ "${P_LIVE[$i]}" = "1" ] && live=$((live + 1))
    done

    if [ "${#items[@]}" -eq 0 ]; then
        clear_screen
        printf '\n'; warn "nothing selected, or no transcripts present."
        anykey; return
    fi

    clear_screen
    printf '\n  %sDelete transcripts — memory/ is kept%s\n\n' "$C_BOLD" "$C_RESET"
    for (( i=0; i<projs; i++ )); do
        set -- ${sizes[$i]}
        printf '    %s %9s  %s%s session(s)%s' "$(pad_right "${labels[$i]}" 34)" \
            "$(human "$1")" "$C_DIM" "$2" "$C_RESET"
        [ "$3" -gt 0 ] && printf '%s · %s memory kept%s' "$C_MAG" "$3" "$C_RESET"
        printf '\n'
    done
    printf '\n  %s%s object(s), %s session(s), %s%s\n' \
        "$C_BOLD" "${#items[@]}" "$sessions" "$(human "$kb")" "$C_RESET"
    dim   "  affects projects/, file-history/ and tasks/"
    [ "$mem" -gt 0 ] && ok "$mem memory file(s) will be kept"
    dim   "  the entry in ~/.claude.json (trust, MCP) stays in place"
    [ "$live" -gt 0 ] && warn "$live project(s) used less than 15 minutes ago"

    if [ "$mode" = "dry" ]; then
        printf '\n  %sIn detail:%s\n' "$C_DIM" "$C_RESET"
        for (( i=0; i<${#items[@]} && i<25; i++ )); do
            printf '    %s\n' "$(short_path "${items[$i]}" 66)"
        done
        [ "${#items[@]}" -gt 25 ] && dim "    … and $(( ${#items[@]} - 25 )) more"
        anykey; return
    fi

    printf '\n  Type %sDELETE%s to confirm: ' "$C_RED" "$C_RESET"
    read -r answer || return
    [ "$answer" = "DELETE" ] || { warn "aborted."; anykey; return; }

    if [ "$mode" = "backup" ]; then
        make_backup "transcripts" "${items[@]}" || { anykey; return; }
    fi

    printf '\n'
    local failed=0
    for (( i=0; i<${#items[@]}; i++ )); do
        safe_rm "${items[$i]}" || failed=$((failed + 1))
    done
    if [ "$failed" -gt 0 ]; then
        warn "$failed object(s) skipped (see messages above)"
    fi
    ok "$(human "$kb") freed, $mem memory file(s) untouched."

    scan_projects
    scan_overview
    reset_nav
    anykey
}

purge_selected() {
    local mode="$1" i n=0 total_kb live=0 mem=0 answer
    local paths=() dirs=()

    for (( i=0; i<${#P_SEL[@]}; i++ )); do
        [ "${P_SEL[$i]}" = "1" ] || continue
        paths+=("${P_PATH[$i]}"); dirs+=("${P_DIR[$i]}")
        n=$((n+1))
        [ "${P_LIVE[$i]}" = "1" ] && live=$((live+1))
        mem=$(( mem + ${P_MEM[$i]} ))
    done
    if [ "$n" -eq 0 ]; then
        clear_screen
        printf '\n'; warn "nothing selected — mark entries with the space bar."
        anykey; return
    fi
    total_kb=$(selected_kb)

    clear_screen
    if [ "$mode" = "dry" ]; then
        printf '\n  %sPreview — nothing will be deleted%s\n\n' "$C_BOLD" "$C_RESET"
    else
        printf '\n  %sDeletion plan%s\n\n' "$C_BOLD" "$C_RESET"
    fi

    for (( i=0; i<n; i++ )); do
        printf '  %s%s %s%s\n' "$C_CYN" "$CH_H" "${paths[$i]}" "$C_RESET"
        claude project purge "${paths[$i]}" --dry-run 2>&1 \
            | grep -v '^Shell cwd was reset' \
            | sed 's/^/    /'
        printf '\n'
    done

    [ "$mem" -gt 0 ]  && warn "$mem memory file(s) will be deleted too (purge removes projects/*/memory/)"
    [ "$live" -gt 0 ] && warn "$live project(s) used within the last 15 minutes — session may be open"

    if [ "$mode" = "dry" ]; then anykey; return; fi

    printf '\n  %s%d project(s), %s%s\n' "$C_BOLD" "$n" "$(human "$total_kb")" "$C_RESET"
    printf '  Type %sDELETE%s to confirm: ' "$C_RED" "$C_RESET"
    read -r answer || return
    [ "$answer" = "DELETE" ] || { warn "aborted."; anykey; return; }

    if [ "$mode" = "backup" ]; then
        make_backup "projects" "${dirs[@]}" || { anykey; return; }
    fi

    printf '\n'
    for (( i=0; i<n; i++ )); do
        printf '  %s … ' "$(short_path "${paths[$i]}" 40)"
        if claude project purge "${paths[$i]}" -y >/dev/null 2>&1; then
            printf '%sdone%s\n' "$C_GRN" "$C_RESET"
        else
            printf '%sfailed%s\n' "$C_RED" "$C_RESET"
        fi
        # purge does not always find orphaned projects by their path —
        # remove the transcript folder directly in that case.
        if [ -d "${dirs[$i]}" ]; then
            warn "folder remained: $(basename "${dirs[$i]}")"
            safe_rm "${dirs[$i]}" && ok "removed directly"
        fi
    done

    printf '\n'; ok "finished."
    scan_projects
    scan_overview
    reset_nav
    anykey
}

# ── Screen: junk ─────────────────────────────────────────────────────────────

render_junk() {
    local vis="$1" i n=${#J_PATH[@]} last risk_color box cur label

    printf '   %s     Area                         Size   Risk     Note%s' "$C_DIM" "$C_RESET"
    eol; printf '\n'
    printf '   '; rule 72; eol; printf '\n'

    if [ "$n" -eq 0 ]; then
        printf '   %sno leftovers found%s' "$C_GRN" "$C_RESET"; eol; printf '\n'
        return
    fi

    scroll_hint "$CURSOR" "$n" "$vis" up

    last=$(( TOP + vis - 1 ))
    [ "$last" -ge "$n" ] && last=$((n - 1))

    for (( i=TOP; i<=last; i++ )); do
        case "${J_RISK[$i]}" in
            low)    risk_color="$C_GRN" ;;
            medium) risk_color="$C_YEL" ;;
            *)      risk_color="$C_RED" ;;
        esac
        if [ "${J_SEL[$i]}" = "1" ]; then box="${C_GRN}${CH_ON}${C_RESET}"; else box="${C_DIM}${CH_OFF}${C_RESET}"; fi

        label=$(pad_right "${J_LABEL[$i]}" 26)
        if [ "$i" -eq "$CURSOR" ]; then
            cur="${C_CYN}${CH_CUR}${C_RESET}"
            label="${C_BOLD}${label}${C_RESET}"
        else
            cur=" "
        fi

        # Remaining width for the note, so the line does not wrap.
        local nw=$(( COLS - 57 ))
        printf '  %b %b  %b %8s  %s%s%s %s%s%s' \
            "$cur" "$box" "$label" "$(human "${J_KB[$i]}")" \
            "$risk_color" "$(pad_right "${J_RISK[$i]}" 7)" "$C_RESET" \
            "$C_DIM" "$(trunc "${J_NOTE[$i]}" "$nw")" "$C_RESET"
        eol; printf '\n'
    done

    scroll_hint "$CURSOR" "$n" "$vis" down
}

junk_screen() {
    local key i n vis kb

    reset_nav
    hide_cursor
    clear_screen

    while :; do
        term_size
        n=${#J_PATH[@]}
        vis=$(viewport 11)
        [ "$vis" -gt "$n" ] && [ "$n" -gt 0 ] && vis="$n"

        home
        overview
        printf '   %sAreas outside of "claude project purge"%s' "$C_DIM" "$C_RESET"
        eol; printf '\n'; eol; printf '\n'
        render_junk "$vis"

        kb=0
        for (( i=0; i<n; i++ )); do [ "${J_SEL[$i]}" = "1" ] && kb=$(( kb + ${J_KB[$i]} )); done
        eol; printf '\n'
        printf '   %sselected: %s%s' "$C_DIM" "$(human "$kb")" "$C_RESET"
        eol; printf '\n'; eol; printf '\n'
        printf '   %s%s%s/%s%s%s move  %sSpace%s select  %ss%s everything "low"  %sn%s none' \
            "$C_BOLD" "$CH_UP" "$C_RESET" "$C_BOLD" "$CH_DN" "$C_RESET" \
            "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
        eol; printf '\n'
        printf '   %sc%s delete  %sb%s back up + delete  %sq%s back' \
            "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
        eol; printf '\n'
        clear_eos

        key=$(read_key)
        nav "$key" "$n" "$vis" && continue

        case "$key" in
            q|quit|esc) clear_screen; return ;;
            space|enter|right)
                [ "$n" -gt 0 ] || continue
                if [ "${J_SEL[$CURSOR]}" = "1" ]; then J_SEL[$CURSOR]=0; else J_SEL[$CURSOR]=1; fi
                [ "$key" = "space" ] && nav down "$n" "$vis"
                ;;
            s) for (( i=0; i<n; i++ )); do
                   if [ "${J_RISK[$i]}" = "low" ]; then J_SEL[$i]=1; else J_SEL[$i]=0; fi
               done ;;
            n) for (( i=0; i<n; i++ )); do J_SEL[$i]=0; done ;;
            c) show_cursor; clean_junk "real";   hide_cursor; clear_screen ;;
            b) show_cursor; clean_junk "backup"; hide_cursor; clear_screen ;;
            *) ;;
        esac
    done
}

clean_junk() {
    local mode="$1" i n=${#J_PATH[@]} kb=0 high=0 answer
    local sel=() paths=()

    for (( i=0; i<n; i++ )); do
        [ "${J_SEL[$i]}" = "1" ] || continue
        sel+=("$i"); paths+=("${J_PATH[$i]}")
        kb=$(( kb + ${J_KB[$i]} ))
        [ "${J_RISK[$i]}" = "high" ] && high=$((high+1))
    done
    if [ ${#sel[@]} -eq 0 ]; then
        clear_screen
        printf '\n'; warn "nothing selected — mark entries with the space bar."
        anykey; return
    fi

    clear_screen
    printf '\n  %sThe following will be deleted:%s\n\n' "$C_BOLD" "$C_RESET"
    for i in "${sel[@]}"; do
        printf '    %s %9s  %s\n' "$(pad_right "${J_LABEL[$i]}" 28)" \
            "$(human "${J_KB[$i]}")" "$(short_path "${J_PATH[$i]}" 40)"
    done
    printf '\n  Total: %s%s%s\n' "$C_BOLD" "$(human "$kb")" "$C_RESET"
    [ "$high" -gt 0 ] && warn "$high entry/entries with risk \"high\" — a job may still be running"

    printf '\n  Type %sDELETE%s to confirm: ' "$C_RED" "$C_RESET"
    read -r answer || return
    [ "$answer" = "DELETE" ] || { warn "aborted."; anykey; return; }

    if [ "$mode" = "backup" ]; then
        make_backup "junk" "${paths[@]}" || { anykey; return; }
    fi

    printf '\n'
    for i in "${sel[@]}"; do
        printf '  %s … ' "${J_LABEL[$i]}"
        if safe_rm "${J_PATH[$i]}"; then printf '%sremoved%s\n' "$C_GRN" "$C_RESET"
        else printf '%sskipped%s\n' "$C_YEL" "$C_RESET"; fi
    done

    printf '\n'; ok "$(human "$kb") freed."
    scan_junk
    scan_overview
    reset_nav
    anykey
}

# ── Privacy ──────────────────────────────────────────────────────────────────
#
# Shows the current state from settings.json as check marks. Space toggles the
# target state, w writes the difference. Anything not ticked here is removed
# from settings.json when writing.

SETTINGS_JSON="$CLAUDE_DIR/settings.json"

V_KEY=(); V_LABEL=(); V_NOTE=(); V_TYPE=(); V_VAL=(); V_WARN=(); V_CUR=(); V_SEL=()
RC_RAW=""

add_opt() {
    V_KEY+=("$1"); V_LABEL+=("$2"); V_NOTE+=("$3")
    V_TYPE+=("$4"); V_VAL+=("$5"); V_WARN+=("$6")
    V_CUR+=(0); V_SEL+=(0)
}

privacy_defs() {
    V_KEY=(); V_LABEL=(); V_NOTE=(); V_TYPE=(); V_VAL=(); V_WARN=(); V_CUR=(); V_SEL=()

    # Without side effects
    add_opt "env.DISABLE_ERROR_REPORTING" "error reporting off" \
            "stack traces to a third-party service" str "1" ""
    add_opt "env.DISABLE_FEEDBACK_COMMAND" "/feedback, /bug, /share off" \
            "send the transcript incl. code · kept for 5 years" str "1" ""
    add_opt "feedbackSurveyRate" "session surveys off" \
            "rating prompt; yes uploads the transcript" int "0" ""
    add_opt "disableClaudeAiConnectors" "claude.ai connectors off" \
            "MCP connections into the cloud" bool "true" ""
    add_opt "enableArtifact" "artifacts off" \
            "creates web pages on claude.ai" boolfalse "false" ""
    add_opt "remoteControlAtStartup" "remote control off" \
            "otherwise keeps the transcript on Anthropic servers" boolfalse "false" ""
    add_opt "cleanupPeriodDays" "limit retention" \
            "transcripts in projects/ · ←/→ changes the value" days "14" ""

    # With side effects
    add_opt "skipWebFetchPreflight" "WebFetch preflight off" \
            "sends host names to api.anthropic.com" bool "true" \
            "no blocklist check any more"
    add_opt "env.DISABLE_TELEMETRY" "telemetry off" \
            "metrics without code, prompts or paths" str "1" \
            "breaks remote control"
    add_opt "env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "all non-essential traffic off" \
            "telemetry + surveys + feature flags" str "1" \
            "breaks remote control"
    add_opt "env.CLAUDE_CODE_SKIP_PROMPT_HISTORY" "record nothing locally" \
            "since 2.1.77 this covers all transcripts too" str "1" \
            "no more /resume, ccmole becomes useless"
}

have_python() { command -v python3 >/dev/null 2>&1; }

# Reads the affected keys in one go: "key<TAB>value" per line.
read_privacy() {
    local line key val i
    privacy_defs
    have_python || return 1

    RC_RAW=""
    while IFS=$'\t' read -r key val; do
        [ -z "${key:-}" ] && continue
        [ "$key" = "remoteControlAtStartup" ] && RC_RAW="$val"
        for (( i=0; i<${#V_KEY[@]}; i++ )); do
            [ "${V_KEY[$i]}" = "$key" ] || continue
            case "${V_TYPE[$i]}" in
                days)  # counts as active as soon as any value is set at all
                    if [ -n "$val" ]; then V_CUR[$i]=1; V_VAL[$i]="$val"; fi ;;
                *)
                    [ "$val" = "${V_VAL[$i]}" ] && V_CUR[$i]=1 ;;
            esac
            V_SEL[$i]="${V_CUR[$i]}"
        done
    done < <(python3 - "$SETTINGS_JSON" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
env = d.get('env') or {}
def emit(k, v):
    if v is True:  v = 'true'
    elif v is False: v = 'false'
    elif v is None:  v = ''
    print(f"{k}\t{v}")
for k in ('DISABLE_ERROR_REPORTING', 'DISABLE_FEEDBACK_COMMAND', 'DISABLE_TELEMETRY',
          'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC', 'CLAUDE_CODE_SKIP_PROMPT_HISTORY'):
    emit('env.' + k, env.get(k))
for k in ('feedbackSurveyRate', 'cleanupPeriodDays', 'disableClaudeAiConnectors',
          'enableArtifact', 'skipWebFetchPreflight', 'remoteControlAtStartup'):
    emit(k, d.get(k))
PY
    )

    # The telemetry switches also silence the feature flag evaluation that
    # remote control depends on. Anyone who never turns remote control on has
    # no side effect from them — the warning is then dropped.
    if [ "$RC_RAW" != "true" ]; then
        for (( i=0; i<${#V_KEY[@]}; i++ )); do
            [ "${V_WARN[$i]}" = "breaks remote control" ] && V_WARN[$i]=""
        done
    fi
    return 0
}

# Writes the difference atomically; all other keys stay untouched.
write_privacy() {
    local plan="$1" bak
    bak="$BACKUP_DIR/settings-$(date +%Y%m%d-%H%M%S).json"
    mkdir -p "$BACKUP_DIR" || { err "cannot create backup directory"; return 1; }
    if [ -f "$SETTINGS_JSON" ]; then
        cp "$SETTINGS_JSON" "$bak" || { err "backup failed"; return 1; }
        ok "settings.json backed up: $(short_path "$bak" 46)"
    fi

    # The plan travels through a file, not through stdin: "python3 -" reads the
    # program itself from stdin, so a second pipe would never arrive there.
    local planfile result
    planfile=$(make_tempfile) || { err "cannot create temporary file"; return 1; }
    printf '%s' "$plan" > "$planfile"

    result=$(python3 - "$SETTINGS_JSON" "$planfile" <<'PY' 2>&1
import json, os, sys, tempfile

path = sys.argv[1]
try:
    with open(path) as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {}
except Exception as e:
    print(f"settings.json is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

def cast(t, v):
    if t == 'int':  return int(v)
    if t == 'bool': return v == 'true'
    if t == 'boolfalse': return v == 'true'
    if t == 'days': return int(v)
    return v

for line in open(sys.argv[2]):
    parts = line.rstrip('\n').split('\t')
    if len(parts) < 2:
        continue
    action, key = parts[0], parts[1]
    env_key = key[4:] if key.startswith('env.') else None
    if action == 'set':
        value = cast(parts[2], parts[3])
        if env_key:
            data.setdefault('env', {})[env_key] = str(value)
        else:
            data[key] = value
    elif action == 'del':
        if env_key:
            (data.get('env') or {}).pop(env_key, None)
            if data.get('env') == {}:
                data.pop('env', None)
        else:
            data.pop(key, None)

# Replace atomically, so an interrupted write cannot tear the file apart.
d = os.path.dirname(path) or '.'
fd, tmp = tempfile.mkstemp(dir=d, prefix='.settings-', suffix='.json')
try:
    with os.fdopen(fd, 'w') as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write('\n')
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise
print("ok")
PY
    )
    rm -f "$planfile"
    [ "$result" = "ok" ] && return 0
    err "${result:-unknown error while writing}"
    return 1
}

# The list stays narrow; effect and key are shown below it for the highlighted
# entry. That way no row can run past the edge.
render_privacy() {
    local vis="$1" i n=${#V_KEY[@]} last box cur label state mark lw

    lw=$(( COLS - 24 ))
    [ "$lw" -gt 38 ] && lw=38
    [ "$lw" -lt 12 ] && lw=12

    printf '   %s     %s  State%s' "$C_DIM" "$(pad_right "Setting" "$lw")" "$C_RESET"
    eol; printf '\n'
    printf '   '; rule $(( lw + 18 )); eol; printf '\n'

    scroll_hint "$CURSOR" "$n" "$vis" up
    last=$(( TOP + vis - 1 ))
    [ "$last" -ge "$n" ] && last=$((n - 1))

    for (( i=TOP; i<=last; i++ )); do
        if [ "${V_SEL[$i]}" = "1" ]; then box="${C_GRN}${CH_ON}${C_RESET}"; else box="${C_DIM}${CH_OFF}${C_RESET}"; fi

        # State: set / staged / dropped / untouched
        if [ "${V_CUR[$i]}" = "1" ] && [ "${V_SEL[$i]}" = "1" ]; then
            state="${C_GRN}$(pad_right "active" 9)${C_RESET}"
        elif [ "${V_CUR[$i]}" = "0" ] && [ "${V_SEL[$i]}" = "1" ]; then
            state="${C_YEL}$(pad_right "new" 9)${C_RESET}"
        elif [ "${V_CUR[$i]}" = "1" ] && [ "${V_SEL[$i]}" = "0" ]; then
            state="${C_RED}$(pad_right "dropped" 9)${C_RESET}"
        else
            state="${C_DIM}$(pad_right "unset" 9)${C_RESET}"
        fi

        label="${V_LABEL[$i]}"
        [ "${V_TYPE[$i]}" = "days" ] && label="$label (${V_VAL[$i]}d)"
        label=$(pad_right "$(trunc "$label" "$lw")" "$lw")
        if [ "$i" -eq "$CURSOR" ]; then
            cur="${C_CYN}${CH_CUR}${C_RESET}"; label="${C_BOLD}${label}${C_RESET}"
        else
            cur=" "
        fi

        # The ! marks side effects; those are exactly the entries S leaves out.
        mark=" "
        [ -n "${V_WARN[$i]}" ] && mark="${C_YEL}!${C_RESET}"

        printf '  %b %b  %b %b %b' "$cur" "$box" "$label" "$state" "$mark"
        eol; printf '\n'
    done

    scroll_hint "$CURSOR" "$n" "$vis" down
}

# Detail lines for the highlighted entry.
render_privacy_detail() {
    local w=$(( COLS - 6 )) lw
    [ "$w" -lt 20 ] && w=20

    # same width as the rule above the list
    lw=$(( COLS - 24 ))
    [ "$lw" -gt 38 ] && lw=38
    [ "$lw" -lt 12 ] && lw=12

    printf '   %s%s%s' "$C_DIM" "$(repeat "$CH_H" $(( lw + 18 )))" "$C_RESET"
    eol; printf '\n'
    printf '   %s' "$(trunc "${V_NOTE[$CURSOR]}" "$w")"
    eol; printf '\n'
    if [ -n "${V_WARN[$CURSOR]}" ]; then
        printf '   %s! %s%s' "$C_YEL" "$(trunc "${V_WARN[$CURSOR]}" $(( w - 2 )))" "$C_RESET"
    else
        printf '   %s%s%s' "$C_DIM" \
            "$(trunc "${V_KEY[$CURSOR]} = ${V_VAL[$CURSOR]}" "$w")" "$C_RESET"
    fi
    eol; printf '\n'
}

privacy_screen() {
    local key i n vis changes

    if ! have_python; then
        clear_screen
        printf '\n'; err "This screen needs python3 (to read and write JSON safely)."
        dim "  Debian: apt install python3   ·   Arch: pacman -S python"
        anykey; return
    fi

    read_privacy
    reset_nav
    clear_screen

    while :; do
        term_size
        n=${#V_KEY[@]}
        vis=$(viewport_plain 16)
        [ "$vis" -gt "$n" ] && vis="$n"

        home
        # No storage overview here — the space belongs to the list.
        printf '  %sccmole %s · privacy%s' "$C_BOLD" "$VERSION" "$C_RESET"
        eol; printf '\n'
        printf '  %s%s%s' "$C_DIM" \
            "$(trunc "current state from $(short_path "$SETTINGS_JSON" 44)" $(( COLS - 4 )))" "$C_RESET"
        eol; printf '\n'; eol; printf '\n'

        render_privacy "$vis"
        render_privacy_detail

        changes=0
        for (( i=0; i<n; i++ )); do [ "${V_SEL[$i]}" != "${V_CUR[$i]}" ] && changes=$((changes+1)); done

        eol; printf '\n'
        if [ "$changes" -gt 0 ]; then
            printf '   %s%s change(s) staged%s' "$C_YEL" "$changes" "$C_RESET"
        else
            printf '   %sno changes staged · training opt-out only on claude.ai%s' \
                "$C_DIM" "$C_RESET"
        fi
        eol; printf '\n'; eol; printf '\n'
        printf '   %sSpace%s toggle · %sS%s all without %s!%s · %sn%s none · %s←/→%s days' \
            "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_YEL" "$C_RESET" \
            "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
        eol; printf '\n'
        printf '   %sw%s write · %sq%s back' \
            "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
        eol; printf '\n'
        clear_eos

        key=$(read_key)
        case "$key" in
            left|right)
                if [ "${V_TYPE[$CURSOR]}" = "days" ]; then
                    privacy_days "$key"
                    continue
                fi ;;
        esac
        nav "$key" "$n" "$vis" && continue

        case "$key" in
            q|quit|esc) clear_screen; return ;;
            space|enter)
                if [ "${V_SEL[$CURSOR]}" = "1" ]; then V_SEL[$CURSOR]=0; else V_SEL[$CURSOR]=1; fi
                [ "$key" = "space" ] && nav down "$n" "$vis" ;;
            S) for (( i=0; i<n; i++ )); do
                   [ -z "${V_WARN[$i]}" ] && V_SEL[$i]=1
               done ;;
            n) for (( i=0; i<n; i++ )); do V_SEL[$i]=0; done ;;
            w) show_cursor; privacy_apply; hide_cursor; clear_screen ;;
            *) ;;
        esac
    done
}

# ←/→ moves the value of cleanupPeriodDays along a fixed ladder.
privacy_days() {
    local dir="$1" steps="7 14 30 60 90 180 365" cur="${V_VAL[$CURSOR]}" prev="" s pick=""
    if [ "$dir" = "right" ]; then
        for s in $steps; do
            if [ "$s" -gt "$cur" ]; then pick="$s"; break; fi
        done
    else
        for s in $steps; do
            if [ "$s" -lt "$cur" ]; then prev="$s"; fi
        done
        pick="$prev"
    fi
    [ -n "$pick" ] && V_VAL[$CURSOR]="$pick"
    V_SEL[$CURSOR]=1
}

privacy_apply() {
    local i n=${#V_KEY[@]} plan="" changes=0 answer breaks_rc=0 rc_on=0

    for (( i=0; i<n; i++ )); do
        if [ "${V_SEL[$i]}" = "1" ]; then
            # write even when the tick is unchanged — the day value may have moved
            plan="${plan}set	${V_KEY[$i]}	${V_TYPE[$i]}	${V_VAL[$i]}
"
        elif [ "${V_CUR[$i]}" = "1" ]; then
            plan="${plan}del	${V_KEY[$i]}
"
        fi
        [ "${V_SEL[$i]}" != "${V_CUR[$i]}" ] && changes=$((changes+1))
        if [ "${V_SEL[$i]}" = "1" ]; then
            case "${V_KEY[$i]}" in
                env.DISABLE_TELEMETRY|env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) breaks_rc=1 ;;
            esac
        fi
        [ "${V_KEY[$i]}" = "remoteControlAtStartup" ] && rc_on="${V_SEL[$i]}"
    done

    if [ "$changes" -eq 0 ]; then
        clear_screen; printf '\n'; warn "nothing changed."; anykey; return
    fi

    clear_screen
    printf '\n  %sChanges to %s%s\n\n' "$C_BOLD" "$(short_path "$SETTINGS_JSON" 44)" "$C_RESET"
    for (( i=0; i<n; i++ )); do
        [ "${V_SEL[$i]}" = "${V_CUR[$i]}" ] && continue
        if [ "${V_SEL[$i]}" = "1" ]; then
            printf '    %s+%s %s %s= %s%s\n' "$C_GRN" "$C_RESET" \
                "$(pad_right "${V_KEY[$i]}" 44)" "$C_DIM" "${V_VAL[$i]}" "$C_RESET"
        else
            printf '    %s-%s %s %sremoved%s\n' "$C_RED" "$C_RESET" \
                "$(pad_right "${V_KEY[$i]}" 44)" "$C_DIM" "$C_RESET"
        fi
    done

    # Only warn when remote control stays active after these changes:
    # rc_on = 1 means the switch "remote control off" is set.
    if [ "$breaks_rc" = "1" ] && [ "$RC_RAW" = "true" ] && [ "$rc_on" = "0" ]; then
        printf '\n'
        warn "remoteControlAtStartup stays active — remote control becomes unusable"
    fi

    printf '\n  Apply? [y/N] '
    read -r answer || return
    case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
        y|yes) ;;
        *) warn "aborted."; anykey; return ;;
    esac

    printf '\n'
    if write_privacy "$plan"; then
        ok "settings.json written — takes effect the next time Claude Code starts."
        read_privacy
        reset_nav
    else
        err "write failed — settings.json is unchanged."
    fi
    anykey
}

# ── Full reset ───────────────────────────────────────────────────────────────

full_reset() {
    local answer
    clear_screen
    printf '\n  %s%sFull reset%s\n\n' "$C_BOLD" "$C_RED" "$C_RESET"
    say "  Runs 'claude project purge --all'. On top of every project it also"
    say "  deletes globally:"
    dim "    history.jsonl · tasks/ · debug/ · file-history/ · every memory/"
    printf '\n'

    claude project purge --all --dry-run 2>&1 \
        | grep -v '^Shell cwd was reset' | sed 's/^/    /'

    printf '\n'
    warn "Cannot be undone. /resume will find nothing afterwards."
    printf '\n  Back up first? [Y/n] '
    read -r answer || return
    case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
        n) ;;
        *) make_backup "full" "$CLAUDE_DIR/projects" "$CLAUDE_DIR/file-history" \
                       "$CLAUDE_DIR/tasks" "$CLAUDE_DIR/history.jsonl" || { anykey; return; } ;;
    esac

    printf '\n  Type %sDELETE ALL%s to confirm: ' "$C_RED" "$C_RESET"
    read -r answer || return
    [ "$answer" = "DELETE ALL" ] || { warn "aborted."; anykey; return; }

    claude project purge --all -y 2>&1 | sed 's/^/  /'
    ok "reset complete."
    scan_projects; scan_junk; scan_overview
    reset_nav
    anykey
}

# ── Backups ──────────────────────────────────────────────────────────────────

backups_screen() {
    local f
    clear_screen
    printf '\n  %sBackups in %s%s\n\n' "$C_BOLD" "$(short_path "$BACKUP_DIR" 50)" "$C_RESET"
    if [ -d "$BACKUP_DIR" ] && [ -n "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        for f in "$BACKUP_DIR"/*.tar.gz; do
            [ -f "$f" ] || continue
            printf '    %s %9s\n' "$(pad_right "$(basename "$f")" 42)" "$(human "$(size_kb "$f")")"
        done
        printf '\n  Total: %s\n' "$(human "$(size_kb "$BACKUP_DIR")")"
        printf '\n  %sRestore:%s tar xzf <archive> -C "$HOME"\n' "$C_DIM" "$C_RESET"
    else
        dim "    no backups yet"
    fi
    anykey
}

# ── Main menu ────────────────────────────────────────────────────────────────

M_KEY=();  M_LABEL=(); M_HINT=()

build_menu() {
    M_KEY=();  M_LABEL=(); M_HINT=()
    M_KEY+=("p"); M_LABEL+=("clean up projects");   M_HINT+=("${#P_DIR[@]} found")
    M_KEY+=("j"); M_LABEL+=("junk & caches");       M_HINT+=("${#J_PATH[@]} areas")
    M_KEY+=("d"); M_LABEL+=("privacy");             M_HINT+=("$(privacy_hint)")
    M_KEY+=("k"); M_LABEL+=("view backups");        M_HINT+=("")
    M_KEY+=("r"); M_LABEL+=("rescan");              M_HINT+=("")
    M_KEY+=("X"); M_LABEL+=("full reset");          M_HINT+=("purge --all")
    M_KEY+=("q"); M_LABEL+=("quit");                M_HINT+=("")
}

# "3 of 10 active" for the main menu — without python3 just a note.
privacy_hint() {
    local i on=0
    have_python || { printf 'needs python3'; return; }
    read_privacy >/dev/null 2>&1
    for (( i=0; i<${#V_CUR[@]}; i++ )); do [ "${V_CUR[$i]}" = "1" ] && on=$((on+1)); done
    printf '%d of %d active' "$on" "${#V_CUR[@]}"
}

run_menu_item() {
    case "${M_KEY[$1]}" in
        p) projects_screen ;;
        j) junk_screen ;;
        d) privacy_screen ;;
        k) show_cursor; backups_screen; hide_cursor; clear_screen ;;
        r) printf '   rescanning …'; eol; printf '\r'
           scan_projects; scan_junk; scan_overview; build_menu ;;
        X) show_cursor; full_reset; hide_cursor; clear_screen; build_menu ;;
        q) return 1 ;;
    esac
    return 0
}

main_menu() {
    local key i n cur label hint idx

    reset_nav
    build_menu
    enter_tui
    clear_screen

    while :; do
        term_size
        n=${#M_KEY[@]}

        home
        overview

        for (( i=0; i<n; i++ )); do
            label=$(pad_right "${M_LABEL[$i]}" 26)
            hint="${M_HINT[$i]}"
            if [ "$i" -eq "$CURSOR" ]; then
                cur="${C_CYN}${CH_CUR}${C_RESET}"
                label="${C_BOLD}${label}${C_RESET}"
            else
                cur=" "
            fi
            if [ "${M_KEY[$i]}" = "X" ]; then
                printf '  %b %s%s%s  %b %s%s%s' "$cur" "$C_DIM" "${M_KEY[$i]}" "$C_RESET" \
                    "${C_RED}${label}${C_RESET}" "$C_DIM" "$hint" "$C_RESET"
            else
                printf '  %b %s%s%s  %b %s%s%s' "$cur" "$C_DIM" "${M_KEY[$i]}" "$C_RESET" \
                    "$label" "$C_DIM" "$hint" "$C_RESET"
            fi
            eol; printf '\n'
        done

        eol; printf '\n'
        printf '   %s%s/%s move · Enter select · letter as shortcut · q quit%s' \
            "$C_DIM" "$CH_UP" "$CH_DN" "$C_RESET"
        eol; printf '\n'
        clear_eos

        key=$(read_key)

        # Check the shortcuts first: j and k are menu entries here and would
        # otherwise be swallowed by the vim navigation.
        idx=-1
        for (( i=0; i<n; i++ )); do
            if [ "${M_KEY[$i]}" = "$key" ]; then idx=$i; break; fi
        done
        if [ "$idx" -ge 0 ]; then
            CURSOR="$idx"
            run_menu_item "$idx" || break
            reset_nav; clear_screen
            continue
        fi

        nav "$key" "$n" "$n" && continue

        case "$key" in
            enter|right|space)
                run_menu_item "$CURSOR" || break
                reset_nav; clear_screen ;;
            quit|esc) break ;;
            *) ;;
        esac
    done

    leave_tui
}

# ── Static output (--status) ─────────────────────────────────────────────────

print_status() {
    local i n=${#P_DIR[@]} name flags
    overview
    printf '   %sProject                           Size    Age%s\n' "$C_DIM" "$C_RESET"
    printf '   '; rule 62; printf '\n'
    for (( i=0; i<n; i++ )); do
        name=$(short_path "${P_PATH[$i]}" 30)
        flags=""
        [ "${P_ORPHAN[$i]}" = "1" ] && flags="$flags orphan"
        [ "${P_MEM[$i]}" -gt 0 ]    && flags="$flags ${P_MEM[$i]}x-memory"
        [ "${P_LIVE[$i]}" = "1" ]   && flags="$flags active"
        printf '   %s %9s  %4sd %s%s%s\n' "$(pad_right "$name" 30)" \
            "$(human "${P_KB[$i]}")" "${P_AGE[$i]}" "$C_DIM" "$flags" "$C_RESET"
    done
    printf '\n'
    n=${#J_PATH[@]}
    if [ "$n" -gt 0 ]; then
        printf '   %sJunk%s\n' "$C_DIM" "$C_RESET"
        printf '   '; rule 62; printf '\n'
        for (( i=0; i<n; i++ )); do
            printf '   %s %9s  %s%s%s\n' "$(pad_right "${J_LABEL[$i]}" 30)" \
                "$(human "${J_KB[$i]}")" "$C_DIM" "${J_RISK[$i]}" "$C_RESET"
        done
        printf '\n'
    fi
}

# ── Installation ─────────────────────────────────────────────────────────────

install_self() {
    local src target dir shell_name
    src=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
    dir="$HOME/.local/bin"
    target="$dir/ccmole"

    mkdir -p "$dir" || { err "cannot create $dir"; return 1; }
    if [ "$src" = "$target" ]; then
        ok "already running from $target"
    else
        cp "$src" "$target" || { err "copy failed"; return 1; }
        chmod +x "$target"
        ok "installed: $target"
    fi

    case ":$PATH:" in
        *":$dir:"*) ok "$dir is in PATH"; return 0 ;;
    esac

    shell_name=$(basename "${SHELL:-sh}")
    warn "$dir is not in PATH. Add it with:"
    printf '\n'
    case "$shell_name" in
        fish)
            printf '    fish_add_path %s\n' "$dir"
            printf '  %s(persistent, writes to ~/.config/fish/fish_variables)%s\n' "$C_DIM" "$C_RESET" ;;
        zsh)
            printf '    echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.zshrc\n' ;;
        bash)
            printf '    echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.bashrc\n' ;;
        *)
            printf '    PATH="$HOME/.local/bin:$PATH"   # in your shell startup file\n' ;;
    esac
    printf '\n'
}

# ── Self-test ────────────────────────────────────────────────────────────────

selftest() {
    local fails=0 probe tmpd c missing=""

    check() {   # $1 = description, $2 = ok/fail, $3 = detail
        if [ "$2" = "ok" ]; then
            printf '  %s+%s %s %s%s%s\n' "$C_GRN" "$C_RESET" \
                "$(pad_right "$1" 32)" "$C_DIM" "${3:-}" "$C_RESET"
        else
            printf '  %sx%s %s %s%s%s\n' "$C_RED" "$C_RESET" \
                "$(pad_right "$1" 32)" "$C_YEL" "${3:-}" "$C_RESET"
            fails=$((fails+1))
        fi
    }

    printf '\n  %sccmole %s — self-test%s\n\n' "$C_BOLD" "$VERSION" "$C_RESET"
    printf '  %sSystem:%s %s / bash %s / %s / %sx%s\n\n' "$C_DIM" "$C_RESET" \
        "$(uname -s)" "${BASH_VERSION:-?}" "$(basename "${SHELL:-?}")" "$COLS" "$ROWS"

    [ "${BASH_VERSINFO[0]:-0}" -ge 3 ] \
        && check "bash >= 3.2" ok "${BASH_VERSION}" \
        || check "bash >= 3.2" fail "too old"

    case "$STAT_FLAVOR" in
        gnu|bsd) check "stat flavor detected" ok "$STAT_FLAVOR" ;;
        *)       check "stat flavor detected" fail "none — ages stay at 0" ;;
    esac
    check "find -printf" ok "$([ "$FIND_PRINTF" = 1 ] && echo 'yes (GNU)' || echo 'no, using stat')"

    for c in du sort head tr wc sed grep find date mktemp tar awk cut; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    [ -z "$missing" ] \
        && check "POSIX commands" ok "complete" \
        || check "POSIX commands" fail "missing:$missing"

    # Key capture — without it the tool cannot be operated at all.
    if printf '' | { IFS= read -rsn1 _ 2>/dev/null; [ $? -le 1 ]; }; then
        check "read -rsn1 (keys)" ok "supported"
    else
        check "read -rsn1 (keys)" fail "shell too old"
    fi
    [ -t 0 ] \
        && check "stdin is a terminal" ok "" \
        || check "stdin is a terminal" ok "no (pipe) — not usable interactively"

    command -v claude >/dev/null 2>&1 \
        && check "claude CLI" ok "$(claude --version 2>/dev/null | head -1)" \
        || check "claude CLI" fail "not in PATH"

    if command -v claude >/dev/null 2>&1; then
        claude project purge --help 2>&1 | grep -q -- '--dry-run' \
            && check "claude project purge" ok "supports --dry-run" \
            || check "claude project purge" fail "version too old (needs 2.1.124+)"
    fi

    command -v python3 >/dev/null 2>&1 \
        && check "python3 (JSON)" ok "$(python3 --version 2>&1)" \
        || check "python3 (JSON)" ok "missing — privacy screen locked, grep fallback elsewhere"

    tmpd=$(mktemp -d "${TMPDIR:-/tmp}/ccmole-test.XXXXXX") || { err "mktemp -d failed"; return 1; }
    printf 'x' > "$tmpd/probe"
    probe=$(newest_mtime "$tmpd")
    case "$probe" in
        ''|*[!0-9]*) check "mtime readable" fail "result: '${probe}'" ;;
        *)           check "mtime readable" ok "$probe" ;;
    esac
    probe=$(size_kb "$tmpd")
    case "$probe" in
        ''|*[!0-9]*) check "du -sk readable" fail "result: '${probe}'" ;;
        *)           check "du -sk readable" ok "${probe} KB" ;;
    esac
    if tar czf "$tmpd/t.tar.gz" -C "$tmpd" probe 2>/dev/null && [ -s "$tmpd/t.tar.gz" ]; then
        check "tar czf (backups)" ok ""
    else
        check "tar czf (backups)" fail "backup feature unusable"
    fi
    rm -rf "$tmpd"

    # The safety net has to hold
    if ( assert_safe_path "/etc" ) >/dev/null 2>&1; then
        check "path guard (outside)" fail "ACCEPTED /etc — do not use!"
    else
        check "path guard (outside)" ok "/etc refused"
    fi
    if ( assert_safe_path "$CLAUDE_DIR" ) >/dev/null 2>&1; then
        check "path guard (root)" fail "ACCEPTED $CLAUDE_DIR"
    else
        check "path guard (root)" ok "root refused"
    fi
    if ( assert_safe_path "$CLAUDE_DIR/skills" ) >/dev/null 2>&1; then
        check "path guard (protected)" fail "ACCEPTED skills/"
    else
        check "path guard (protected)" ok "skills/ refused"
    fi

    check "character set" ok "$([ "$UNICODE" = 1 ] && echo 'UTF-8' || echo 'ASCII fallback')"

    printf '\n'
    if [ "$fails" -eq 0 ]; then
        ok "all set."
        return 0
    fi
    err "$fails check(s) failed."
    return 1
}

# ── Start ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
ccmole $VERSION — interactive cleanup tool for Claude Code

  ccmole              start interactively (arrow keys)
  ccmole --status     print an overview and exit
  ccmole --dry-run    show the deletion plan for all projects (deletes nothing)
  ccmole --install    install to ~/.local/bin/ccmole
  ccmole --selftest   check the platform assumptions (deletes nothing)
  ccmole --version    version
  ccmole --help       this help

Keys
  ↑ ↓ / k j    move             Space        select
  PgUp PgDn    page             Enter        select / open
  g / G        start / end      q            back, then quit

Deleting projects — two levels
  t   transcripts only: .jsonl, tool-results/, subagents/, workflows/,
      file-history/ and tasks/. Kept: memory/ and the entry in
      ~/.claude.json (trust, MCP servers).
  c   everything, through 'claude project purge' — takes memory/ along.
  Preview with T or d, with a preceding backup B or b.

Environment variables
  CLAUDE_CONFIG_DIR   Claude directory (default: ~/.claude)
  CCMOLE_BACKUP_DIR   where backups are stored (default: ~/.claude-backups)
  NO_COLOR            disable colors
EOF
}

main() {
    detect_platform
    setup_colors
    setup_charset

    case "${1:-}" in
        -h|--help)  usage; exit 0 ;;
        --version)  printf 'ccmole %s\n' "$VERSION"; exit 0 ;;
        --install)  install_self; exit $? ;;
        --selftest) selftest; exit $? ;;
    esac

    if ! command -v claude >/dev/null 2>&1; then
        err "claude CLI not found in PATH."
        exit 1
    fi
    if [ ! -d "$CLAUDE_DIR" ]; then
        err "$CLAUDE_DIR does not exist."
        exit 1
    fi
    if [ "$STAT_FLAVOR" = "none" ]; then
        warn "stat unusable — ages will stay at 0."
    fi

    case "${1:-}" in
        --status)  scan_projects; scan_junk; scan_overview; print_status; exit 0 ;;
        --dry-run) claude project purge --all --dry-run; exit $? ;;
        "")        ;;
        *)         err "unknown option: $1"; usage; exit 1 ;;
    esac

    printf '  reading %s …\r' "$(short_path "$CLAUDE_DIR" 30)"
    scan_projects
    scan_junk
    scan_overview
    main_menu
}

main "$@"
