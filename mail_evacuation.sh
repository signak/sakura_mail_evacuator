#!/usr/bin/env bash

# Maildir形式のメールボックスから30日より古い通常ファイルを年別アーカイブへ退避する。
# ログ出力、排他ロック、入力・ディレクトリ検証を行い、エラー発生時は直ちに処理を中断する。

set -u

# 環境変数
# MAIL_EVACUATOR_TARGET_USER:
#   必須。メール退避の対象ユーザー名。未設定または空文字の場合は標準エラーへ出力して終了コード1で終了する。
#   この値は、以下のパス例にある {USER} の部分に使用する。

# スクリプト内部変数
# MAILBOX_ROOT: 対象メールボックスのルートパス。例: /home/{USER}/MailBox
# STATE_ROOT: ロックとログを保存するルートパス。例: /home/{USER}/MailEvacuator
# SCRIPT_NAME: 実行中のスクリプト名。例: mail_evacuation.sh
# LOCK_DIR: 多重起動を防止するロックディレクトリ。例: /home/{USER}/MailEvacuator/mail_evacuation.sh.lock
# LOG_DIR: 実行ログを保存するディレクトリ。例: /home/{USER}/MailEvacuator/logs
# LOG_FILE: 今回の実行で作成したログファイルのパス。例: /home/{USER}/MailEvacuator/logs/20260902-020000.log
# LOCK_ACQUIRED: ロック取得済みかを示すフラグ。1は取得済み、0は未取得。
# ENSURED_ARCHIVE_YEARS: 作成・検証済みの年別アーカイブを保持する一覧。例: " 2024 2025"
# PROCESS_FOLDER_COUNT: 直近のフォルダ処理で退避したファイル数。
MAILBOX_ROOT=""
STATE_ROOT=""
SCRIPT_NAME="$(basename "$0")"
LOCK_DIR=""
LOG_DIR=""
LOG_FILE=""
LOCK_ACQUIRED=0
ENSURED_ARCHIVE_YEARS=""
PROCESS_FOLDER_COUNT=0

# ログファイルを利用できない初期化失敗を標準エラーとsyslogへ出力する。
write_stderr_and_syslog() {
    local message="$1"

    printf '%s\n' "$message" >&2
    logger -t "$SCRIPT_NAME" "$message" || true
}

# 指定されたログレベルとメッセージを実行ログへ1行追加する。
write_log() {
    local level="$1"
    local message="$2"

    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >> "$LOG_FILE"
}

# ログ初期化前のエラーを出力して終了コード9で終了する。
fail_before_log() {
    write_stderr_and_syslog "$1"
    exit 9
}

# メイン処理のエラーをログへ記録して終了コード1で終了する。
fail_main() {
    write_log "ERROR" "ERROR(main): path='$1': $2"
    exit 1
}

# サブワークフローのエラーをログへ記録して呼び出し元へ失敗を返す。
fail_sub() {
    write_log "ERROR" "ERROR(sub): account='$1' path='$2': $3"
    return 1
}

# パスがシンボリックリンクではない通常ディレクトリかを判定する。
is_regular_directory() {
    local path="$1"

    [[ ! -L "$path" && -d "$path" ]]
}

# ロックとログの親ディレクトリを作成・検証する。
ensure_state_root() {
    if [[ -e "$STATE_ROOT" || -L "$STATE_ROOT" ]]; then
        is_regular_directory "$STATE_ROOT" || fail_before_log "ERROR(main): path='$STATE_ROOT': not a regular directory"
    elif ! mkdir "$STATE_ROOT"; then
        fail_before_log "ERROR(main): path='$STATE_ROOT': failed to create directory"
    fi

    [[ -w "$STATE_ROOT" && -x "$STATE_ROOT" ]] || fail_before_log "ERROR(main): path='$STATE_ROOT': not writable"
}

# 排他的に実行ログファイルを作成し、作成先をLOG_FILEへ設定する。
create_log_file() {
    local timestamp
    local candidate
    local suffix=0

    if [[ -e "$LOG_DIR" || -L "$LOG_DIR" ]]; then
        is_regular_directory "$LOG_DIR" || fail_before_log "ERROR(main): path='$LOG_DIR': not a regular directory"
    elif ! mkdir "$LOG_DIR"; then
        fail_before_log "ERROR(main): path='$LOG_DIR': failed to create directory"
    fi

    [[ -w "$LOG_DIR" && -x "$LOG_DIR" ]] || fail_before_log "ERROR(main): path='$LOG_DIR': not writable"

    timestamp="$(date '+%Y%m%d-%H%M%S')" || fail_before_log "ERROR(main): failed to get current time"
    while :; do
        if [[ "$suffix" -eq 0 ]]; then
            candidate="${LOG_DIR}/${timestamp}.log"
        else
            candidate="${LOG_DIR}/${timestamp}-${$}-${suffix}.log"
        fi

        if (set -o noclobber; : > "$candidate") 2>/dev/null; then
            LOG_FILE="$candidate"
            return
        fi

        suffix=$((suffix + 1))
        if [[ "$suffix" -gt 100 ]]; then
            fail_before_log "ERROR(main): path='$LOG_DIR': failed to create log file"
        fi
    done
}

# 終了時にロックを解放し、処理本体の終了コードを維持する。
cleanup_lock() {
    local exit_code=$?

    if [[ "$LOCK_ACQUIRED" -eq 1 ]] && ! rmdir "$LOCK_DIR"; then
        write_log "ERROR" "ERROR(main): path='$LOCK_DIR': failed to remove lock directory"
        if [[ "$exit_code" -eq 0 ]]; then
            exit_code=1
        fi
    fi

    trap - EXIT
    exit "$exit_code"
}

# 割り込みシグナルを受けた場合にエラー終了を開始する。
handle_signal() {
    exit 1
}

# mkdirを用いて原子的にロックを取得し、既存ロックの経過時間を確認する。
acquire_lock() {
    if mkdir "$LOCK_DIR"; then
        LOCK_ACQUIRED=1
        trap cleanup_lock EXIT
        trap handle_signal INT TERM
        return
    fi

    if [[ -d "$LOCK_DIR" ]]; then
        local lock_mtime
        local now_epoch

        lock_mtime="$(stat -f %m "$LOCK_DIR")" || fail_main "$LOCK_DIR" "failed to read lock directory modification time"
        now_epoch="$(date '+%s')" || fail_main "$LOCK_DIR" "failed to get current time"
        if [[ "$lock_mtime" -le $((now_epoch - 86400)) ]]; then
            write_log "ERROR" "ERROR(main): path='$LOCK_DIR': lock directory is at least 24 hours old"
            write_stderr_and_syslog "ERROR(main): path='$LOCK_DIR': lock directory is at least 24 hours old"
            exit 8
        fi
    fi

    write_log "ERROR" "ERROR(main): path='$LOCK_DIR': failed to acquire lock"
    write_stderr_and_syslog "ERROR(main): path='$LOCK_DIR': failed to acquire lock"
    exit 5
}

# 指定年のアーカイブディレクトリと退避先curを作成・検証する。
ensure_archive_directories() {
    local maildir="$1"
    local year="$2"
    local archive_root="${maildir}/.${year}"
    local archive_cur="${archive_root}/cur"
    local directory

    for directory in "$archive_root" "$archive_cur"; do
        if [[ -e "$directory" || -L "$directory" ]]; then
            is_regular_directory "$directory" || return 1
        elif ! mkdir "$directory"; then
            return 1
        fi
    done

    [[ -w "$archive_root" && -x "$archive_root" && -w "$archive_cur" && -x "$archive_cur" ]]
}

# 今回参照した年のアーカイブが空であればディレクトリを削除する。
prune_empty_archive() {
    local maildir="$1"
    local year="$2"
    local archive_root="${maildir}/.${year}"

    [[ -d "$archive_root/cur" ]] || return
    rmdir "$archive_root/cur" 2>/dev/null || return
    rmdir "$archive_root" 2>/dev/null || true
}

# curまたはnew配下の対象メールを年別アーカイブのcurへ移動して件数を返す。
process_folder() {
    local account_name="$1"
    local maildir="$2"
    local folder_name="$3"
    local cutoff_epoch="$4"
    local source_dir="${maildir}/${folder_name}"
    local file
    local mtime
    local year
    local destination
    local moved_count=0
    local touched_years=""

    # 対象フォルダ直下の通常ファイルだけを走査し、隠しファイルも対象に含める。
    for file in "$source_dir"/* "$source_dir"/.[!.]* "$source_dir"/..?*; do
        [[ -f "$file" && ! -L "$file" ]] || continue

        # 更新日時を取得し、実行開始時に固定した退避境界より前のファイルだけを対象にする。
        mtime="$(stat -f %m "$file")" || {
            fail_sub "$account_name" "$file" "failed to read modification time"
            return 1
        }
        [[ "$mtime" -lt "$cutoff_epoch" ]] || continue

        # ファイルの更新年を求め、その年の退避先ディレクトリを初回だけ作成・検証する。
        year="$(date -r "$mtime" '+%Y')" || {
            fail_sub "$account_name" "$file" "failed to get archive year"
            return 1
        }
        case " $ENSURED_ARCHIVE_YEARS " in
            *" $year "*) ;;
            *)
                if ! ensure_archive_directories "$maildir" "$year"; then
                    fail_sub "$account_name" "${maildir}/.${year}" "failed to create or validate archive directories"
                    return 1
                fi
                ENSURED_ARCHIVE_YEARS="${ENSURED_ARCHIVE_YEARS} ${year}"
                ;;
        esac

        # 同名ファイルによる上書きを防止してから、年別アーカイブのcurへ移動する。
        destination="${maildir}/.${year}/cur/${file##*/}"
        if [[ -e "$destination" || -L "$destination" ]]; then
            fail_sub "$account_name" "$file" "destination already exists: $destination"
            return 1
        fi
        if ! mv "$file" "$destination"; then
            fail_sub "$account_name" "$file" "failed to move file to $destination"
            return 1
        fi

        moved_count=$((moved_count + 1))
        case " $touched_years " in
            *" $year "*) ;;
            *) touched_years="${touched_years} ${year}" ;;
        esac
    done

    # 今回参照した年のうち空のアーカイブディレクトリを削除する。
    for year in $touched_years; do
        prune_empty_archive "$maildir" "$year"
    done

    PROCESS_FOLDER_COUNT="$moved_count"
}

# 1アカウントのmaildirを検証し、curとnewの退避処理を実行する。
process_account() {
    local account_path="$1"
    local account_name
    local maildir
    local cutoff_epoch="$2"
    local cur_count
    local new_count
    local total_count

    account_name="$(basename "$account_path")"
    maildir="${account_path}/maildir"

    # Maildirの構造とアクセス権を確認し、異常時はこのアカウントで処理を止める。
    if ! is_regular_directory "$maildir"; then
        fail_sub "$account_name" "$maildir" "maildir is not a regular directory"
        return 1
    fi
    if ! is_regular_directory "${maildir}/cur" || ! is_regular_directory "${maildir}/new"; then
        fail_sub "$account_name" "$maildir" "cur or new is not a regular directory"
        return 1
    fi
    if [[ ! -r "$maildir" || ! -w "$maildir" || ! -x "$maildir" || ! -r "${maildir}/cur" || ! -w "${maildir}/cur" || ! -x "${maildir}/cur" || ! -r "${maildir}/new" || ! -w "${maildir}/new" || ! -x "${maildir}/new" ]]; then
        fail_sub "$account_name" "$maildir" "required directory is not accessible"
        return 1
    fi

    # 同一アカウント内では年別アーカイブの作成・検証を年ごとに一度だけ行う。
    ENSURED_ARCHIVE_YEARS=""

    # curとnewを順に走査し、退避件数を合算する。
    process_folder "$account_name" "$maildir" "cur" "$cutoff_epoch" || return 1
    cur_count="$PROCESS_FOLDER_COUNT"
    process_folder "$account_name" "$maildir" "new" "$cutoff_epoch" || return 1
    new_count="$PROCESS_FOLDER_COUNT"
    total_count=$((cur_count + new_count))

    # 1件以上を退避したアカウントだけ、合計件数をログへ記録する。
    if [[ "$total_count" -gt 0 ]]; then
        write_log "INFO" "EVACUATED: '$account_name' - $total_count files was evacuated."
    fi
}

# 初期化、対象アカウントの選択、各アカウントの退避処理を制御する。
main() {
    local cutoff_epoch
    local account_path
    local target_account_name="${1:-}"

    # 対象ユーザーの未指定を、ログ初期化前の入力エラーとして明示的に処理する。
    if [[ -z "${MAIL_EVACUATOR_TARGET_USER:-}" ]]; then
        printf 'ERROR(main): environment variable MAIL_EVACUATOR_TARGET_USER is not set\n' >&2
        exit 1
    fi
    MAILBOX_ROOT="/home/${MAIL_EVACUATOR_TARGET_USER}/MailBox"
    STATE_ROOT="/home/${MAIL_EVACUATOR_TARGET_USER}/MailEvacuator"
    LOCK_DIR="${STATE_ROOT}/${SCRIPT_NAME}.lock"
    LOG_DIR="${STATE_ROOT}/logs"

    if [[ "$#" -gt 1 ]]; then
        printf 'Usage: %s [account_name]\n' "$SCRIPT_NAME" >&2
        exit 1
    fi
    if [[ -n "$target_account_name" && ( "$target_account_name" == "." || "$target_account_name" == ".." || "$target_account_name" == */* ) ]]; then
        printf 'ERROR(main): invalid account name: %s\n' "$target_account_name" >&2
        exit 1
    fi

    # ログ出力先を準備して実行ログを作成してから、メールボックスを操作する。
    ensure_state_root
    create_log_file
    write_log "INFO" "start mail evacuation."

    if ! is_regular_directory "$MAILBOX_ROOT" || [[ ! -r "$MAILBOX_ROOT" || ! -x "$MAILBOX_ROOT" ]]; then
        fail_main "$MAILBOX_ROOT" "mailbox root is not an accessible regular directory"
    fi
    cd "$MAILBOX_ROOT" || fail_main "$MAILBOX_ROOT" "failed to change directory"

    # 実行開始時刻を基準に退避境界を固定し、その後の多重起動を防止する。
    cutoff_epoch="$(date -v -30d '+%s')" || fail_main "$MAILBOX_ROOT" "failed to calculate cutoff time"
    acquire_lock

    # 指定アカウントがある場合はそのアカウントだけを検証して処理する。
    if [[ -n "$target_account_name" ]]; then
        account_path="${MAILBOX_ROOT}/${target_account_name}"
        if ! is_regular_directory "$account_path"; then
            fail_main "$account_path" "specified account is not a regular directory"
        fi
        process_account "$account_path" "$cutoff_epoch" || exit 1
        return
    fi

    # 引数なしの場合はルート直下の通常ディレクトリを全アカウントとして処理する。
    for account_path in "$MAILBOX_ROOT"/*; do
        [[ -d "$account_path" && ! -L "$account_path" ]] || continue
        process_account "$account_path" "$cutoff_epoch" || exit 1
    done
}

main "$@"