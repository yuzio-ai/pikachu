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
SAVE_XCRESULT=0
DISABLE_SANDBOX_MACRO=0
KEEP_ON_FAILURE=0

ACTIONS=()
PATCHES=()
OVERLAYS=()
ONLY_TESTING=()
CUSTOM_CMD=()

usage() {
    cat <<'EOF'
Usage: Scripts/run-isolated-verify.sh [options] [-- <custom command...>]

Stage a source snapshot in a single /tmp sandbox, run xcodebuild or a custom
command, copy logs and collected artifacts to --evidence-dir, and remove the
temporary sandbox automatically on exit.

Source options (default: current workspace excluding build/.verification-runs/.yuzio):
  --source-dir <dir>         Copy an existing directory instead of the workspace
  --archive <tar|tar.gz>     Extract a candidate archive as the source snapshot
  --patch <file>             Apply patch via `git apply --whitespace=error` (repeatable)
  --overlay <src>:<rel-dst>  Copy file/dir into source/<rel-dst> (repeatable)

Built-in xcodebuild options (used when no `-- <cmd...>` is given):
  --scheme <name>            Xcode scheme (e.g. Pikachu)
  --action <act>             build | build-for-testing | test | test-without-building (repeatable)
  --configuration <cfg>      Debug | Release (optional)
  --only-testing <spec>      xcodebuild -only-testing:<spec> (repeatable, applied to test actions)
  --disable-sandbox-macro    Pass OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'

Evidence & sandbox options:
  --evidence-dir <dir>       Persist run.log and $PIKACHU_EVIDENCE_OUT/* here before cleanup
  --save-xcresult            Also copy generated result.xcresult into --evidence-dir
  --label <name>             Sandbox directory label (default: verify)
  --keep-on-failure          Preserve /tmp sandbox if verification exits non-zero
  -h, --help                 Show this help

Custom command environment variables:
  PIKACHU_SANDBOX_DIR        Root temporary sandbox directory
  PIKACHU_SOURCE_DIR         Staged source snapshot (also cwd for custom command)
  PIKACHU_DERIVED_DATA       Isolated DerivedData path inside the sandbox
  PIKACHU_RESULT_BUNDLE      Isolated result.xcresult path inside the sandbox
  PIKACHU_FIXTURE_DIR        Empty fixture/state directory inside the sandbox
  PIKACHU_EVIDENCE_OUT       Drop files here to persist them into --evidence-dir
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
        --only-testing)
            require_arg "$@"
            ONLY_TESTING+=("$2")
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
            CUSTOM_CMD=("$@")
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

if [[ ${#CUSTOM_CMD[@]} -eq 0 && -z "$SCHEME" && ${#ACTIONS[@]} -eq 0 ]]; then
    die "Specify --scheme/--action for xcodebuild or provide a custom command after --"
fi

if [[ ${#CUSTOM_CMD[@]} -gt 0 && ( -n "$SCHEME" || ${#ACTIONS[@]} -gt 0 ) ]]; then
    die "Do not combine --scheme/--action with a custom command after --"
fi

if [[ ${#CUSTOM_CMD[@]} -eq 0 ]]; then
    [[ -n "$SCHEME" ]] || SCHEME="Pikachu"
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

if [[ -n "$EVIDENCE_DIR" ]]; then
    mkdir -p "$EVIDENCE_DIR"
    EVIDENCE_DIR="$(cd "$EVIDENCE_DIR" && pwd)"
fi

SAFE_LABEL="$(printf '%s' "$LABEL" | tr -cs 'A-Za-z0-9_-' '-' | sed 's/^-//;s/-$//')"
[[ -n "$SAFE_LABEL" ]] || SAFE_LABEL="verify"

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
SANDBOX_DIR="$(mktemp -d "${TMP_BASE}/pikachu-${SAFE_LABEL}-XXXXXX")"

STAGED_SOURCE="${SANDBOX_DIR}/source"
DERIVED_DATA="${SANDBOX_DIR}/DerivedData"
RESULT_BUNDLE="${SANDBOX_DIR}/result.xcresult"
FIXTURE_DIR="${SANDBOX_DIR}/fixture"
EVIDENCE_OUT="${SANDBOX_DIR}/evidence"
SANDBOX_TMP="${SANDBOX_DIR}/tmp"
RUN_LOG="${SANDBOX_DIR}/run.log"

mkdir -p "$STAGED_SOURCE" "$DERIVED_DATA" "$FIXTURE_DIR" "$EVIDENCE_OUT" "$SANDBOX_TMP"

RUN_STATUS=0

persist_evidence() {
    [[ -n "$EVIDENCE_DIR" ]] || return 0
    mkdir -p "$EVIDENCE_DIR"
    if [[ -f "$RUN_LOG" ]]; then
        cp -f "$RUN_LOG" "${EVIDENCE_DIR}/run.log"
    fi
    if [[ -d "$EVIDENCE_OUT" ]] && [[ -n "$(ls -A "$EVIDENCE_OUT" 2>/dev/null || true)" ]]; then
        rsync -a "$EVIDENCE_OUT/" "$EVIDENCE_DIR/"
    fi
    if [[ "$SAVE_XCRESULT" -eq 1 && -d "$RESULT_BUNDLE" ]]; then
        rm -rf "${EVIDENCE_DIR}/result.xcresult"
        rsync -a "$RESULT_BUNDLE" "$EVIDENCE_DIR/"
    fi
}

cleanup() {
    local exit_code=$?
    if [[ "$RUN_STATUS" -ne 0 ]]; then
        exit_code="$RUN_STATUS"
    fi
    set +e
    persist_evidence
    if [[ "$exit_code" -ne 0 && -z "$EVIDENCE_DIR" && -s "$RUN_LOG" ]]; then
        echo "[isolated-verify] last 40 lines of run.log before cleanup:" >&2
        tail -n 40 "$RUN_LOG" >&2
    fi
    if [[ "$KEEP_ON_FAILURE" -eq 1 && "$exit_code" -ne 0 ]]; then
        echo "[isolated-verify] keeping failed sandbox per --keep-on-failure: $SANDBOX_DIR" >&2
    else
        rm -rf "$SANDBOX_DIR"
        echo "[isolated-verify] cleaned up sandbox: $SANDBOX_DIR" >&2
    fi
    exit "$exit_code"
}

on_signal() {
    RUN_STATUS=130
    exit 130
}

trap cleanup EXIT
trap on_signal INT TERM

stage_source() {
    if [[ -n "$ARCHIVE_PATH" ]]; then
        [[ -f "$ARCHIVE_PATH" ]] || die "Archive not found: $ARCHIVE_PATH"
        tar -xf "$ARCHIVE_PATH" -C "$STAGED_SOURCE"
        return 0
    fi

    local src="${SOURCE_DIR:-$REPO_ROOT}"
    [[ -d "$src" ]] || die "Source directory not found: $src"
    rsync -a \
        --exclude='/.git/' \
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
        (cd "$STAGED_SOURCE" && git apply --whitespace=error "$abs_patch")
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
            rsync -a "$src/" "$dst_path/"
        else
            cp -f "$src" "$dst_path"
        fi
    done
}

run_xcodebuild() {
    local action
    for action in "${ACTIONS[@]}"; do
        local cmd=(
            xcodebuild
            -project "${STAGED_SOURCE}/Pikachu.xcodeproj"
            -scheme "$SCHEME"
            -derivedDataPath "$DERIVED_DATA"
        )
        if [[ -n "$CONFIGURATION" ]]; then
            cmd+=(-configuration "$CONFIGURATION")
        fi
        if [[ "$action" == "test" || "$action" == "test-without-building" ]]; then
            rm -rf "$RESULT_BUNDLE"
            cmd+=(-resultBundlePath "$RESULT_BUNDLE")
            if [[ ${#ONLY_TESTING[@]} -gt 0 ]]; then
                local spec
                for spec in "${ONLY_TESTING[@]}"; do
                    cmd+=("-only-testing:${spec}")
                done
            fi
        fi
        if [[ "$DISABLE_SANDBOX_MACRO" -eq 1 ]]; then
            cmd+=("OTHER_SWIFT_FLAGS=\$(inherited) -Xfrontend -disable-sandbox")
        fi
        cmd+=("$action")

        echo "[isolated-verify] running: ${cmd[*]}" >>"$RUN_LOG"
        if ! (cd "$STAGED_SOURCE" && TMPDIR="$SANDBOX_TMP" "${cmd[@]}") >>"$RUN_LOG" 2>&1; then
            RUN_STATUS=$?
            break
        fi
    done
}

run_custom_cmd() {
    (
        cd "$STAGED_SOURCE"
        export PIKACHU_SANDBOX_DIR="$SANDBOX_DIR"
        export PIKACHU_SOURCE_DIR="$STAGED_SOURCE"
        export PIKACHU_DERIVED_DATA="$DERIVED_DATA"
        export PIKACHU_RESULT_BUNDLE="$RESULT_BUNDLE"
        export PIKACHU_FIXTURE_DIR="$FIXTURE_DIR"
        export PIKACHU_EVIDENCE_OUT="$EVIDENCE_OUT"
        export TMPDIR="$SANDBOX_TMP"
        "${CUSTOM_CMD[@]}"
    ) >"$RUN_LOG" 2>&1 || RUN_STATUS=$?
}

echo "[isolated-verify] sandbox: $SANDBOX_DIR" >&2
stage_source
apply_patches
apply_overlays

if [[ ${#CUSTOM_CMD[@]} -gt 0 ]]; then
    run_custom_cmd
else
    run_xcodebuild
fi

exit "$RUN_STATUS"
