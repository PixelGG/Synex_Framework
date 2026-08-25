# MariaDB backup and restore

This runbook defines a logical-backup and isolated-restore drill for the documented `synex_core` profile: MariaDB `11.8.8`, InnoDB, UTC, one Core instance, and no non-Core Synex resources. It is operational guidance and the basis for the post-Beta restore certification; it is never permission to overwrite a production database.

> [!CAUTION]
> Never run a restore drill against production or a shared development schema. Use a new schema named exactly `synex_test_restore_drill_YYYYMMDDHHMMSS`, verify the target twice, and retain failed drill data for investigation until an operator deliberately removes it.

## Acceptance boundary

The full exact-candidate encrypted restore drill, historical supported-version upgrade drill, and operator RPO/RTO approval are intentionally scheduled for the post-Beta promotion phase. They do not block the frozen initial Production-Beta scope. Operators must still maintain verified backups before using real server data; deferral of certification is not a recommendation to run without recovery protection.

## Prerequisites

- MariaDB `11.8.8` client tools (`mariadb` and `mariadb-dump`) are installed and available on `PATH`.
- All Synex tables use InnoDB and the database session uses UTC.
- The Core database user, backup user, and restore-drill user follow least privilege. The drill user may create/drop only disposable drill schemas in an isolated database service.
- A MariaDB client option file exists outside the repository on an access-restricted path, for example `C:\SynexSecrets\mariadb-client.ini`:

```ini
[client]
protocol=tcp
host=127.0.0.1
port=3306
user=
password=
```

Populate the last two fields locally. Never commit the option file, print it, attach it to test evidence, or place it in the backup directory.

The commands below use PowerShell and deliberately avoid shell-built SQL identifiers. Replace only the three paths/names in the first block. Database names are restricted to letters, digits, and underscore so the validated identifier can be quoted safely.

## 1. Quiesce Core

From the FXServer console:

```text
synex overview
synex doctor
synex prepare-restart
```

Require the preparation result to report `state = "prepared"`. Leave Core in that fail-closed prepared state and do not run the returned restart command yet. If preparation reports a database-drain timeout or unsafe retry, stop: resolve the documented incident path before taking release evidence. Confirm no external process writes to the schema during the dump.

## 2. Create and hash the logical backup

```powershell
$SynexDb = 'synex_core'
$SynexDbOptions = 'C:\SynexSecrets\mariadb-client.ini'
$SynexBackupDir = 'C:\SynexBackups'

if ($SynexDb -notmatch '^[A-Za-z0-9_]+$') { throw 'Unsafe source database name.' }
if (-not (Test-Path -LiteralPath $SynexDbOptions -PathType Leaf)) { throw 'MariaDB option file missing.' }
New-Item -ItemType Directory -Path $SynexBackupDir -Force | Out-Null

$SynexDumpExe = (Get-Command mariadb-dump -ErrorAction Stop).Source
$SynexStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$SynexBackup = Join-Path $SynexBackupDir "synex-core-$SynexStamp.sql"
$SynexDumpArgs = @(
  "--defaults-extra-file=$SynexDbOptions"
  '--single-transaction'
  '--quick'
  '--skip-lock-tables'
  '--routines'
  '--events'
  '--triggers'
  '--hex-blob'
  '--default-character-set=utf8mb4'
  '--tz-utc'
  "--result-file=$SynexBackup"
  $SynexDb
)

& $SynexDumpExe @SynexDumpArgs
if ($LASTEXITCODE -ne 0) { throw "mariadb-dump failed with exit code $LASTEXITCODE." }
$SynexBackupFile = Get-Item -LiteralPath $SynexBackup
if ($SynexBackupFile.Length -le 0) { throw 'Backup is empty.' }

$SynexBackupHash = Get-FileHash -LiteralPath $SynexBackup -Algorithm SHA256
$SynexBackupHash.Hash | Set-Content -LiteralPath "$SynexBackup.sha256" -Encoding ascii
$SynexBackupHash | Format-List Algorithm, Hash, Path
```

`--single-transaction` provides a consistent snapshot for transactional InnoDB tables. It is not safe evidence if another process performs DDL or writes a nontransactional table during the dump. The explicit `--skip-lock-tables` avoids relying on a global table lock, and `--result-file` avoids PowerShell text-redirection encoding changes.

After the dump and hash succeed, execute the exact restart command returned by `synex prepare-restart`, wait for Core `READY`, and run `synex doctor`. A dump without a successful restore drill is not an accepted backup.

## 3. Restore into a new disposable schema

Start a new PowerShell session or retain the variables above, then run:

```powershell
$SynexClientExe = (Get-Command mariadb -ErrorAction Stop).Source
$SynexDrillDb = 'synex_test_restore_drill_20260824120000'

if ($SynexDrillDb -notmatch '^synex_test_restore_drill_[0-9]{14}$') { throw 'Unsafe drill database name.' }
if ($SynexDrillDb -eq $SynexDb) { throw 'Drill target must not equal the source database.' }
if (-not (Test-Path -LiteralPath $SynexBackup -PathType Leaf)) { throw 'Backup file missing.' }

$SynexRecordedHash = (Get-Content -LiteralPath "$SynexBackup.sha256" -Raw).Trim()
$SynexCurrentHash = (Get-FileHash -LiteralPath $SynexBackup -Algorithm SHA256).Hash
if ($SynexRecordedHash -notmatch '^[A-Fa-f0-9]{64}$' -or $SynexCurrentHash -ne $SynexRecordedHash) {
  throw 'Backup SHA-256 verification failed.'
}

$SynexClientArgs = @(
  "--defaults-extra-file=$SynexDbOptions"
  '--batch'
  '--skip-column-names'
)
$SynexExistsSql = "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$SynexDrillDb'"
$SynexExisting = @(& $SynexClientExe @SynexClientArgs "--execute=$SynexExistsSql")
if ($LASTEXITCODE -ne 0) { throw 'Could not verify the drill target.' }
if ($SynexExisting.Count -ne 0) { throw 'Drill target already exists; refusing to overwrite it.' }

$SynexQuotedDrillDb = ([char]96) + $SynexDrillDb + ([char]96)
& $SynexClientExe @SynexClientArgs "--execute=CREATE DATABASE $SynexQuotedDrillDb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
if ($LASTEXITCODE -ne 0) { throw 'Could not create the drill database.' }

$SynexRestoreArgs = @(
  "--defaults-extra-file=$SynexDbOptions"
  "--database=$SynexDrillDb"
)
$SynexRestore = Start-Process -FilePath $SynexClientExe -ArgumentList $SynexRestoreArgs -RedirectStandardInput $SynexBackup -NoNewWindow -Wait -PassThru
if ($SynexRestore.ExitCode -ne 0) { throw "Restore failed with exit code $($SynexRestore.ExitCode)." }
```

The guard refuses an existing schema. It never drops, truncates, or overwrites the source database.

## 4. Verify the restored copy

```powershell
$SynexVerifySql = @'
SELECT COUNT(*) AS core_migrations
FROM synex_schema_migrations
WHERE resource_name = 'synex_core';
SELECT COUNT(*) AS non_applied_attempts
FROM synex_schema_migration_attempts
WHERE state <> 'applied';
SELECT COUNT(*) AS non_applied_fences
FROM synex_schema_migration_fences
WHERE state <> 'applied';
'@

& $SynexClientExe @SynexClientArgs "--database=$SynexDrillDb" '--table' "--execute=$SynexVerifySql"
if ($LASTEXITCODE -ne 0) { throw 'Restored-schema verification query failed.' }
```

Require exactly `26` Core migrations and zero non-applied attempts/fences for the current candidate. Then point an isolated FXServer profile—not the normal server—at the drill schema, give it a distinct stable `synex_instance_id`, start only `oxmysql` and the exact candidate `synex_core`, and require:

```text
Core lifecycle: READY
synex migrations: 26 Core migrations applied, no nonterminal state
synex doctor: all mandatory checks pass
sessions: no unexpected active session
```

Record the commit, versions, UTC time, backup SHA-256, schema counts, and stable command results. Do not retain the connection string or raw dump in the report.

## 5. Controlled cleanup

Stop the isolated drill FXServer first. Delete the drill schema only after evidence is accepted and the exact name has been re-read from MariaDB:

```powershell
if ($SynexDrillDb -notmatch '^synex_test_restore_drill_[0-9]{14}$') { throw 'Unsafe drill database name.' }
if ($SynexDrillDb -eq $SynexDb) { throw 'Refusing to remove the source database.' }

$SynexExisting = @(& $SynexClientExe @SynexClientArgs "--execute=$SynexExistsSql")
if ($LASTEXITCODE -ne 0) { throw 'Could not re-verify the drill target.' }
if ($SynexExisting.Count -ne 1 -or $SynexExisting[0] -ne $SynexDrillDb) {
  throw 'Exact drill target verification failed.'
}

& $SynexClientExe @SynexClientArgs "--execute=DROP DATABASE $SynexQuotedDrillDb"
if ($LASTEXITCODE -ne 0) { throw 'Drill database cleanup failed.' }
```

Keep backup files outside the repository, encrypt them at rest, restrict access, replicate them according to the operator's recovery policy, and test them on a schedule. Removal of expired backup files is an operator-controlled destructive action and is intentionally not automated by this runbook.

## Production recovery boundary

An actual production restore requires a declared outage, verified backup hash, empty or separately preserved target, exact compatible Core revision, reviewed database privileges, and an operator-approved rollback plan. Never import this logical dump over a populated schema. Restore to a new database first, validate it with the isolated Core, then change the operator-owned connection configuration during a controlled maintenance window.

Synex migrations are forward-only. There is no supported in-place downgrade and no reverse migration for `026`. To back out, stop the candidate and point the compatible older Core only at an untouched pre-upgrade schema or a separately restored and verified pre-upgrade backup. Never start older code on the 26-migration candidate schema, delete migration markers, or manually undo DDL. Preserve the failed candidate schema for investigation until the operator deliberately retires it.

Normal database failures that oxmysql returns to Core may reconcile automatically after two consecutive successful health probes. The five-second watchdog cannot cancel an outstanding Lua `Await`. If oxmysql `2.14.1` loses the callback for a rejected pool `getConnection()`, Core remains fail-closed after MariaDB returns; a successful independent query does not release that probe. Verify the restored database first, then perform one controlled restart of the complete FXServer process. Do not use a raw Core restart, an oxmysql-only restart, or any restart loop as recovery.
