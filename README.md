# Sakura Mail Evacuator

Maildir形式のメールボックスから、実行開始時刻の30日前より古いメールを年別アーカイブへ退避するFreeBSD向けBashスクリプトです。

## 目次

- [動作概要](#動作概要)
- [動作環境](#動作環境)
- [配置と事前準備](#配置と事前準備)
- [手動実行](#手動実行)
- [CRONへの登録](#cronへの登録)
- [ログと終了コード](#ログと終了コード)
- [仕様](#仕様)

## 動作概要

- `/home/calm/MailBox` 配下の各アカウントの `maildir/cur` と `maildir/new` を処理します。
- 最終更新日時が実行開始時刻の30日前より前の通常ファイルを対象にします。境界時刻と同一のファイルは残します。
- 退避対象のメールは、最終更新日時の年に対応する `maildir/.yyyy/cur` へ移動します。送信元が `cur` と `new` のどちらであっても退避先は `cur` です。
- 退避先に同名ファイルがある場合は上書きせず、エラー終了します。
- 多重起動を防止するロックディレクトリを作成します。24時間以上残ったロックは自動削除せず、手動復旧が必要です。

## 動作環境

- FreeBSD 13.0-RELEASE-p14 amd64
- Bash
- 実行ユーザーがメールボックスおよび `/home/calm/MailEvacuator` を読み書きできること

このスクリプトはFreeBSDの `date` と `stat` のオプションを使用します。Windows PowerShellでは実行できません。

## 配置と事前準備

スクリプトをサーバーへ配置し、実行権限を設定します。

```sh
mkdir -p /home/calm/MailEvacuator
cp mail_evacuation.sh /home/calm/MailEvacuator/
chmod 755 /home/calm/MailEvacuator/mail_evacuation.sh
```

スクリプト内の次の定数は、環境に応じて変更してください。

```sh
MAILBOX_ROOT="/home/calm/MailBox"
STATE_ROOT="/home/calm/MailEvacuator"
```

`STATE_ROOT` 配下には、実行時に次のディレクトリ・ファイルが自動作成されます。

```text
/home/calm/MailEvacuator/
├── logs/
│   └── yyyymmdd-HHMMSS.log
└── mail_evacuation.sh.lock/
```

## 手動実行

全アカウントを処理する場合は、引数を付けずに実行します。

```sh
/usr/local/bin/bash /home/calm/MailEvacuator/mail_evacuation.sh
```

特定のアカウントだけを処理する場合は、アカウントディレクトリ名を1件だけ指定します。たとえば `foobar` を指定すると、`/home/calm/MailBox/foobar/maildir` だけを処理します。

```sh
/usr/local/bin/bash /home/calm/MailEvacuator/mail_evacuation.sh foobar
```

引数に `/`、`.`、`..` を含めること、および2件以上の引数指定はできません。

## CRONへの登録

実行ユーザーのcrontabを編集します。

```sh
crontab -e
```

毎日午前2時に全アカウントを処理する例です。CRONの最小環境でもBashを見つけられるよう、`PATH` とBashの絶対パスを指定します。

```cron
PATH=/usr/local/bin:/bin:/usr/bin
0 2 * * * /usr/local/bin/bash /home/calm/MailEvacuator/mail_evacuation.sh
```

特定アカウントだけを定期実行する場合は、末尾にアカウント名を追加します。

```cron
PATH=/usr/local/bin:/bin:/usr/bin
0 2 * * * /usr/local/bin/bash /home/calm/MailEvacuator/mail_evacuation.sh foobar
```

登録内容は次のコマンドで確認できます。

```sh
crontab -l
```

スクリプト内部の実行ログは `/home/calm/MailEvacuator/logs/` に作成されます。標準エラー出力も別途保存する必要がある場合は、CRONの行末へ `>> /home/calm/MailEvacuator/cron.log 2>&1` を追加してください。

## ログと終了コード

ログは実行ごとに `/home/calm/MailEvacuator/logs/yyyymmdd-HHMMSS.log` として作成されます。ログファイルを作成できない場合、エラーは標準エラー出力とsyslogへ出力されます。

| 終了コード | 意味                     |
| ----- | ---------------------- |
| `0`   | 正常終了                   |
| `1`   | 一般エラー、入力エラー、またはロック削除失敗 |
| `5`   | ロック取得失敗（他の実行が処理中）      |
| `8`   | 24時間以上前のロックディレクトリを検出   |
| `9`   | ログ出力先またはログファイルの初期化失敗   |

## 仕様

詳細な要件とエラー時の挙動は、[メール退避仕様](specs/メール退避仕様.md) を参照してください。
