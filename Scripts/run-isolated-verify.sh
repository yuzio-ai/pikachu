#!/usr/bin/env bash
set -euo pipefail

# Run isolated candidate verification inside a temporary /tmp sandbox and
# guarantee cleanup via `trap ... EXIT` after exporting requested evidence.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LABEL="verify"
SOURCE_DIR=""
ARCHIVE_PATH=""
EVIDENCE_DIR=""
SCHEME=""
CONFIGURATION=""
VERIFICATION_TOOL=""
SAVE_XCRESULT=0
DISABLE_SANDBOX_MACRO=0
KEEP_ON_FAILURE=0

ACTIONS=()
PATCHES=()
OVERLAYS=()
ONLY_TESTING=()
SKIP_TESTING=()
POSITIONAL_ARGS=()

usage() {
    cat <<'EOF'
Usage: Scripts/run-isolated-verify.sh [options] [-- <custom command...>]

Stage a source snapshot in a single temporary sandbox, run xcodebuild, a
verification tool or a custom command, and remove the sandbox on exit.

Source options (default: current workspace excluding build/.verification-runs/.yuzio):
  --source-dir <dir>         Copy an existing directory instead of the workspace
  --archive <tar|tar.gz>     Extract a candidate archive as the source snapshot
  --patch <file>             Apply patch via `git apply --whitespace=error` (repeatable)
  --overlay <src>:<rel-dst>  Copy file/dir into source/<rel-dst> (repeatable)

Built-in xcodebuild options:
  --scheme <name>            Xcode scheme (e.g. Zivvi)
  --action <act>             build | build-for-testing | test | test-without-building (repeatable)
  --configuration <cfg>      Debug | Release (optional)
  --only-testing <spec>      xcodebuild -only-testing:<spec> (repeatable, applied to test actions)
  --skip-testing <spec>      xcodebuild -skip-testing:<spec> (repeatable, applied to test actions)
  --disable-sandbox-macro    Pass OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'
  --tool <name>              Build and run a verification tool; pass tool arguments after --

Evidence & sandbox options:
  --evidence-dir <new-dir>   Export run.log, tool summaries and $ZIVVI_EVIDENCE_OUT/*
  --save-xcresult            Export validated result bundles from both evidence paths
  --label <name>             Sandbox directory label (default: verify)
  --keep-on-failure          Preserve /tmp sandbox if verification exits non-zero
  -h, --help                 Show this help

Custom command environment variables:
  ZIVVI_SANDBOX_DIR        Root temporary sandbox directory
  ZIVVI_SOURCE_DIR         Staged source snapshot (also cwd for custom command)
  ZIVVI_DERIVED_DATA       Isolated DerivedData path inside the sandbox
  ZIVVI_RESULT_BUNDLE      Isolated result.xcresult path inside the sandbox
  ZIVVI_FIXTURE_DIR        Empty fixture/state directory inside the sandbox
  ZIVVI_EVIDENCE_OUT       Drop files here to persist them into --evidence-dir
EOF
}

die() {
    echo "[isolated-verify] ERROR: $*" >&2
    exit 2
}

require_arg() {
    [[ $# -ge 2 && -n "$2" ]] || die "Missing value for $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir)
            require_arg "$@"
            SOURCE_DIR="$2"
            shift 2
            ;;
        --archive)
            require_arg "$@"
            ARCHIVE_PATH="$2"
            shift 2
            ;;
        --patch)
            require_arg "$@"
            PATCHES+=("$2")
            shift 2
            ;;
        --overlay)
            require_arg "$@"
            OVERLAYS+=("$2")
            shift 2
            ;;
        --evidence-dir)
            require_arg "$@"
            EVIDENCE_DIR="$2"
            shift 2
            ;;
        --scheme)
            require_arg "$@"
            SCHEME="$2"
            shift 2
            ;;
        --action)
            require_arg "$@"
            ACTIONS+=("$2")
            shift 2
            ;;
        --configuration)
            require_arg "$@"
            CONFIGURATION="$2"
            shift 2
            ;;
        --tool)
            require_arg "$@"
            VERIFICATION_TOOL="$2"
            shift 2
            ;;
        --only-testing)
            require_arg "$@"
            ONLY_TESTING+=("$2")
            shift 2
            ;;
        --skip-testing)
            require_arg "$@"
            SKIP_TESTING+=("$2")
            shift 2
            ;;
        --save-xcresult)
            SAVE_XCRESULT=1
            shift
            ;;
        --disable-sandbox-macro)
            DISABLE_SANDBOX_MACRO=1
            shift
            ;;
        --label)
            require_arg "$@"
            LABEL="$2"
            shift 2
            ;;
        --keep-on-failure)
            KEEP_ON_FAILURE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            POSITIONAL_ARGS=("$@")
            break
            ;;
        *)
            die "Unknown option: $1 (use --help for usage)"
            ;;
    esac
done

if [[ -n "$SOURCE_DIR" && -n "$ARCHIVE_PATH" ]]; then
    die "--source-dir and --archive are mutually exclusive"
fi

if [[ -n "$VERIFICATION_TOOL" ]]; then
    case "$VERIFICATION_TOOL" in
        acp-compat-probe|runtime-verify) ;;
        *) die "Unknown verification tool: $VERIFICATION_TOOL" ;;
    esac
    if [[ -n "$SCHEME" || ${#ACTIONS[@]} -gt 0 || ${#ONLY_TESTING[@]} -gt 0 || ${#SKIP_TESTING[@]} -gt 0 ]]; then
        die "Use --tool without --scheme, --action, --only-testing or --skip-testing"
    fi
    SCHEME="$VERIFICATION_TOOL"
    ACTIONS=(build)
    CONFIGURATION="${CONFIGURATION:-Debug}"
elif [[ ${#POSITIONAL_ARGS[@]} -gt 0 ]]; then
    if [[ -n "$SCHEME" || ${#ACTIONS[@]} -gt 0 || ${#ONLY_TESTING[@]} -gt 0 || ${#SKIP_TESTING[@]} -gt 0 ]]; then
        die "Do not combine --scheme/--action/--only-testing/--skip-testing with a custom command after --"
    fi
else
    if [[ -z "$SCHEME" && ${#ACTIONS[@]} -eq 0 ]]; then
        die "Specify --scheme/--action, --tool or a custom command after --"
    fi
    [[ -n "$SCHEME" ]] || SCHEME="Zivvi"
    if [[ ${#ACTIONS[@]} -eq 0 ]]; then
        ACTIONS=("build")
    fi
    for action in "${ACTIONS[@]}"; do
        case "$action" in
            build|build-for-testing|test|test-without-building) ;;
            *) die "Unsupported --action: $action" ;;
        esac
    done
    if [[ "${ACTIONS[0]}" == "test-without-building" ]]; then
        die "test-without-building requires a preceding --action build-for-testing in the same isolated run"
    fi
fi

SAFE_LABEL="$(printf '%s' "$LABEL" | tr -cs 'A-Za-z0-9_-' '-' | sed 's/^-//;s/-$//')"
[[ -n "$SAFE_LABEL" ]] || SAFE_LABEL="verify"

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"

SANDBOX_DIR=""
RUN_LOG=""
RUN_STATUS=0
DEFER_CANCEL=0
ACTIVE_JOB_PID=""
ACTIVE_TERMINAL_GROUP=""
JOB_CONTINUED=0
EVIDENCE_RESERVATION=""

reserve_evidence() {
    [[ -n "$EVIDENCE_DIR" ]] || return 0
    local parent name reservation
    parent="$(dirname -- "$EVIDENCE_DIR")"
    name="$(basename -- "$EVIDENCE_DIR")"
    mkdir -p -- "$parent"
    parent="$(cd -- "$parent" && pwd -P)"
    EVIDENCE_DIR="$parent/$name"
    [[ ! -e "$EVIDENCE_DIR" && ! -L "$EVIDENCE_DIR" ]] || die "Use a new evidence directory: $EVIDENCE_DIR"
    reservation="$parent/.${name}.zivvi-pending"
    DEFER_CANCEL=1
    if mkdir -m 700 -- "$reservation"; then
        EVIDENCE_RESERVATION="$reservation"
    fi
    DEFER_CANCEL=0
    [[ "$RUN_STATUS" -ne 130 ]] || exit 130
    [[ -n "$EVIDENCE_RESERVATION" ]] || die "Evidence directory is reserved: $EVIDENCE_DIR"
    [[ ! -e "$EVIDENCE_DIR" && ! -L "$EVIDENCE_DIR" ]] || die "Use a new evidence directory: $EVIDENCE_DIR"
}

export_result_bundle() {
    local bundle="$1" destination="$2" graph="$SANDBOX_DIR/xcresult-graph"
    # xcresulttool reports missing referenced objects in the graph output even
    # when it exits successfully. Reading only the root misses those objects.
    if ! LC_ALL=C xcrun xcresulttool graph --legacy --path "$bundle" >"$graph" 2>&1 ||
       ! awk '/^[[:space:]]*ERROR:/ { failed = 1 } END { exit (failed || NR == 0) }' "$graph"; then
        echo "[isolated-verify] ERROR: result bundle is incomplete or unreadable: $bundle" >&2
        return 1
    fi
    if [[ -e "$destination" || -L "$destination" ]]; then
        echo "[isolated-verify] ERROR: duplicate result bundle destination: $destination" >&2
        return 1
    fi
    mkdir -p -- "${destination%/*}" && rsync -a "$bundle/" "$destination/"
}

persist_evidence() {
    [[ -n "$EVIDENCE_RESERVATION" && -f "$RUN_LOG" ]] || return 0
    local staged_evidence="$EVIDENCE_RESERVATION/${EVIDENCE_DIR##*/}"
    mkdir -- "$staged_evidence" || return 1
    cp "$RUN_LOG" "$staged_evidence/run.log" || return 1
    rsync -a --exclude='*.[xX][cC][rR][eE][sS][uU][lL][tT]' "$EVIDENCE_OUT/" "$staged_evidence/" || return 1
    if [[ "$SAVE_XCRESULT" -eq 1 && "$RUN_STATUS" -ne 130 && "$RUN_STATUS" -ne 143 ]]; then
        if [[ -d "$RESULT_BUNDLE" ]]; then
            export_result_bundle "$RESULT_BUNDLE" "$staged_evidence/result.xcresult" || return 1
        fi
        local bundle bundle_paths="$SANDBOX_DIR/xcresult-paths"
        find "$EVIDENCE_OUT" -iname '*.xcresult' -prune -type d -print0 >"$bundle_paths" || return 1
        while IFS= read -r -d '' bundle; do
            export_result_bundle "$bundle" "$staged_evidence/${bundle#"$EVIDENCE_OUT/"}" || return 1
        done <"$bundle_paths"
    fi
    # Publish with a same-filesystem rename. Using the parent as the destination
    # prevents mv from placing the staged directory inside an existing target.
    mv -n -- "$staged_evidence" "${EVIDENCE_DIR%/*}/" || return 1
    [[ ! -e "$staged_evidence" ]]
}

finish_active_job() {
    [[ -n "$ACTIVE_JOB_PID" ]] || return 0
    local group="-$ACTIVE_JOB_PID" attempt terminal_status=0
    kill -TERM -- "$group" 2>/dev/null || true
    kill -CONT -- "$group" 2>/dev/null || true
    for ((attempt = 0; attempt < 20; attempt++)); do
        kill -0 -- "$group" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 -- "$group" 2>/dev/null; then
        kill -KILL -- "$group" 2>/dev/null || true
    fi
    wait "$ACTIVE_JOB_PID" 2>/dev/null || true
    if [[ -n "$ACTIVE_TERMINAL_GROUP" ]]; then
        python3 "$REPO_ROOT/Scripts/verify-terminal.py" restore "$ACTIVE_TERMINAL_GROUP" "$ACTIVE_JOB_PID" || terminal_status=$?
    fi
    ACTIVE_JOB_PID=""
    ACTIVE_TERMINAL_GROUP=""
    return "$terminal_status"
}

cleanup() {
    local exit_code=$?
    if [[ "$RUN_STATUS" -ne 0 ]]; then
        exit_code="$RUN_STATUS"
    fi
    trap '' INT TERM CONT
    set +e
    if ! finish_active_job; then
        [[ "$exit_code" -ne 0 ]] || exit_code=1
    fi
    if ! persist_evidence; then
        echo "[isolated-verify] ERROR: could not export evidence to $EVIDENCE_DIR" >&2
        [[ "$exit_code" -ne 0 ]] || exit_code=1
    fi
    if [[ -n "$EVIDENCE_RESERVATION" ]] && ! rm -rf -- "$EVIDENCE_RESERVATION"; then
        echo "[isolated-verify] ERROR: could not remove staged evidence: $EVIDENCE_RESERVATION" >&2
        [[ "$exit_code" -ne 0 ]] || exit_code=1
    fi
    if [[ "$exit_code" -ne 0 && -z "$EVIDENCE_DIR" && -s "$RUN_LOG" ]]; then
        echo "[isolated-verify] last 40 lines of run.log before cleanup:" >&2
        tail -n 40 "$RUN_LOG" >&2
    fi
    if [[ -z "$SANDBOX_DIR" ]]; then
        exit "$exit_code"
    elif [[ "$KEEP_ON_FAILURE" -eq 1 && "$exit_code" -ne 0 ]]; then
        echo "[isolated-verify] keeping failed sandbox per --keep-on-failure: $SANDBOX_DIR" >&2
    elif rm -rf "$SANDBOX_DIR"; then
        echo "[isolated-verify] cleaned up sandbox: $SANDBOX_DIR" >&2
    else
        echo "[isolated-verify] ERROR: could not remove sandbox: $SANDBOX_DIR" >&2
        [[ "$exit_code" -ne 0 ]] || exit_code=1
    fi
    exit "$exit_code"
}

on_signal() {
    RUN_STATUS=130
    # Allow acquisition to record ownership before the exit trap releases it.
    if [[ "$DEFER_CANCEL" -eq 0 ]]; then
        exit 130
    fi
}

on_continue() {
    JOB_CONTINUED=1
    if [[ -n "$ACTIVE_TERMINAL_GROUP" && -n "$ACTIVE_JOB_PID" && -f "$SANDBOX_DIR/terminal-suspended" ]]; then
        rm -f -- "$SANDBOX_DIR/terminal-suspended"
        python3 "$REPO_ROOT/Scripts/verify-terminal.py" resume "$ACTIVE_TERMINAL_GROUP" "$ACTIVE_JOB_PID" || exit 1
        kill -CONT -- "-$ACTIVE_JOB_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap on_signal INT TERM

run_in_job() {
    local working_directory="$1" status=0
    shift
    # Start a separate job group so cancellation also reaches the job's pipeline
    # and children. An explicit wait lets Bash handle INT and TERM immediately.
    DEFER_CANCEL=1
    set -m
    (
        set +m
        cd -- "$working_directory" || exit 1
        if [[ -n "$ACTIVE_TERMINAL_GROUP" ]]; then
            exec "$@"
        fi
        "$@"
    ) &
    ACTIVE_JOB_PID=$!
    set +m
    DEFER_CANCEL=0
    [[ "$RUN_STATUS" -ne 130 ]] || exit 130
    while true; do
        JOB_CONTINUED=0
        status=0
        wait "$ACTIVE_JOB_PID" || status=$?
        [[ "$JOB_CONTINUED" -eq 1 && "$status" -gt 128 ]] || break
    done
    if ! finish_active_job && [[ "$status" -eq 0 ]]; then
        status=1
    fi
    return "$status"
}

stage_source() {
    if [[ -n "$ARCHIVE_PATH" ]]; then
        [[ -f "$ARCHIVE_PATH" ]] || die "Archive not found: $ARCHIVE_PATH"
        run_in_job "$PWD" tar -xf "$ARCHIVE_PATH" -C "$STAGED_SOURCE"
        return 0
    fi

    local src="${SOURCE_DIR:-$REPO_ROOT}"
    [[ -d "$src" ]] || die "Source directory not found: $src"
    run_in_job "$PWD" rsync -a \
        --exclude='/.git' \
        --exclude='/build/' \
        --exclude='/.verification-runs/' \
        --exclude='/.yuzio/' \
        --exclude='/.DS_Store' \
        --exclude='xcuserdata/' \
        --exclude='*.xcuserstate' \
        "$src/" "$STAGED_SOURCE/"
}

apply_patches() {
    [[ ${#PATCHES[@]} -gt 0 ]] || return 0
    local patch_file
    for patch_file in "${PATCHES[@]}"; do
        [[ -f "$patch_file" ]] || die "Patch not found: $patch_file"
        local abs_patch
        abs_patch="$(cd "$(dirname "$patch_file")" && pwd)/$(basename "$patch_file")"
        run_in_job "$STAGED_SOURCE" git apply --whitespace=error "$abs_patch"
    done
}

apply_overlays() {
    [[ ${#OVERLAYS[@]} -gt 0 ]] || return 0
    local spec src rel_dst dst_path
    for spec in "${OVERLAYS[@]}"; do
        [[ "$spec" == *:* ]] || die "Invalid --overlay (expected <src>:<rel-dst>): $spec"
        src="${spec%%:*}"
        rel_dst="${spec#*:}"
        [[ -n "$src" && -n "$rel_dst" ]] || die "Invalid --overlay: $spec"
        [[ "$rel_dst" != /* ]] || die "Overlay destination must be relative: $rel_dst"
        case "/$rel_dst/" in
            */../*) die "Overlay destination must not contain '..': $rel_dst" ;;
        esac
        [[ -e "$src" ]] || die "Overlay source not found: $src"
        dst_path="${STAGED_SOURCE}/${rel_dst}"
        mkdir -p "$(dirname "$dst_path")"
        if [[ -d "$src" ]]; then
            mkdir -p "$dst_path"
            run_in_job "$PWD" rsync -a "$src/" "$dst_path/"
        else
            run_in_job "$PWD" cp -f "$src" "$dst_path"
        fi
    done
}

run_xcodebuild() {
    local action
    for action in "${ACTIONS[@]}"; do
        local cmd=(
            xcodebuild
            -project "${STAGED_SOURCE}/Zivvi.xcodeproj"
            -scheme "$SCHEME"
            -derivedDataPath "$DERIVED_DATA"
        )
        if [[ -n "$CONFIGURATION" ]]; then
            cmd+=(-configuration "$CONFIGURATION")
        fi
        if [[ "$action" == "test" || "$action" == "test-without-building" ]]; then
            local spec
            rm -rf "$RESULT_BUNDLE"
            cmd+=(-resultBundlePath "$RESULT_BUNDLE")
            if [[ ${#ONLY_TESTING[@]} -gt 0 ]]; then
                for spec in "${ONLY_TESTING[@]}"; do
                    cmd+=("-only-testing:${spec}")
                done
            fi
            if [[ ${#SKIP_TESTING[@]} -gt 0 ]]; then
                for spec in "${SKIP_TESTING[@]}"; do
                    cmd+=("-skip-testing:${spec}")
                done
            fi
        fi
        if [[ "$DISABLE_SANDBOX_MACRO" -eq 1 ]]; then
            cmd+=("OTHER_SWIFT_FLAGS=\$(inherited) -Xfrontend -disable-sandbox")
        fi
        cmd+=("$action")

        echo "[isolated-verify] running: ${cmd[*]}" >>"$RUN_LOG"
        run_in_job "$STAGED_SOURCE" env TMPDIR="$SANDBOX_TMP" "${cmd[@]}" >>"$RUN_LOG" 2>&1 || {
            RUN_STATUS=$?
            break
        }
    done
}

log_verification_tool() {
    TMPDIR="$SANDBOX_TMP" "$@" 2>&1 | tee -a "$RUN_LOG"
}

run_verification_tool() {
    local cmd=("${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${VERIFICATION_TOOL}")
    if [[ ${#POSITIONAL_ARGS[@]} -gt 0 ]]; then
        cmd+=("${POSITIONAL_ARGS[@]}")
    fi
    run_in_job "$PWD" log_verification_tool "${cmd[@]}" || RUN_STATUS=$?
    if [[ -n "$EVIDENCE_DIR" ]]; then
        local summary
        for summary in "$STAGED_SOURCE/.verification-runs/$VERIFICATION_TOOL"/*/{results,run,projection,local-probe-observed}.json; do
            [[ -f "$summary" ]] || continue
            cp "$summary" "$EVIDENCE_OUT/"
        done
    fi
}

run_custom_cmd() {
    local cmd=("${POSITIONAL_ARGS[@]}")
    if [[ -t 0 ]]; then
        ACTIVE_TERMINAL_GROUP="$(python3 "$REPO_ROOT/Scripts/verify-terminal.py" owner)" || return 1
        if [[ -n "$ACTIVE_TERMINAL_GROUP" ]]; then
            trap on_continue CONT
            cmd=(python3 "$REPO_ROOT/Scripts/verify-terminal.py" run "$ACTIVE_TERMINAL_GROUP"
                "$SANDBOX_DIR/terminal-suspended" "${cmd[@]}")
        fi
    fi
    run_in_job "$STAGED_SOURCE" env \
        ZIVVI_SANDBOX_DIR="$SANDBOX_DIR" \
        ZIVVI_SOURCE_DIR="$STAGED_SOURCE" \
        ZIVVI_DERIVED_DATA="$DERIVED_DATA" \
        ZIVVI_RESULT_BUNDLE="$RESULT_BUNDLE" \
        ZIVVI_FIXTURE_DIR="$FIXTURE_DIR" \
        ZIVVI_EVIDENCE_OUT="$EVIDENCE_OUT" \
        TMPDIR="$SANDBOX_TMP" \
        "${cmd[@]}" >"$RUN_LOG" 2>&1 || RUN_STATUS=$?
}

reserve_evidence
DEFER_CANCEL=1
SANDBOX_DIR="$(mktemp -d "${TMP_BASE}/zivvi-${SAFE_LABEL}-XXXXXX")"
DEFER_CANCEL=0
[[ "$RUN_STATUS" -ne 130 ]] || exit 130

STAGED_SOURCE="${SANDBOX_DIR}/source"
DERIVED_DATA="${SANDBOX_DIR}/DerivedData"
RESULT_BUNDLE="${SANDBOX_DIR}/result.xcresult"
FIXTURE_DIR="${SANDBOX_DIR}/fixture"
EVIDENCE_OUT="${SANDBOX_DIR}/evidence"
SANDBOX_TMP="${SANDBOX_DIR}/tmp"
RUN_LOG="${SANDBOX_DIR}/run.log"

echo "[isolated-verify] sandbox: $SANDBOX_DIR" >&2
mkdir -p "$STAGED_SOURCE" "$DERIVED_DATA" "$FIXTURE_DIR" "$EVIDENCE_OUT" "$SANDBOX_TMP"
stage_source
apply_patches
apply_overlays

if [[ -n "$VERIFICATION_TOOL" ]]; then
    run_xcodebuild
    if [[ "$RUN_STATUS" -eq 0 ]]; then
        # An archive or overlay may contain older output with the same report names.
        run_in_job "$PWD" rm -rf -- "$STAGED_SOURCE/.verification-runs"
        run_verification_tool
    fi
elif [[ ${#POSITIONAL_ARGS[@]} -gt 0 ]]; then
    run_custom_cmd
else
    run_xcodebuild
fi

exit "$RUN_STATUS"
