[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PgRoot,
    [Parameter(Mandatory = $true)][int]$PgPort,
    [Parameter(Mandatory = $true)][int]$PostgreSqlMajor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$data = Join-Path $env:RUNNER_TEMP "pg_squeeze-$PostgreSqlMajor-data"
$log = Join-Path $env:RUNNER_TEMP "pg_squeeze-$PostgreSqlMajor.log"
$pgCtl = Join-Path $PgRoot 'bin/pg_ctl.exe'
$psql = Join-Path $PgRoot 'bin/psql.exe'
$psqlArgs = @('-h', '127.0.0.1', '-p', $PgPort, '-U', 'postgres', '-d', 'postgres',
    '-X', '-v', 'ON_ERROR_STOP=1', '-c', 'SET statement_timeout = 30000')
$serverOptions = "-p $PgPort -c listen_addresses=127.0.0.1 -c shared_preload_libraries=pg_squeeze -c wal_level=logical"
$workerQuery = @'
SELECT EXISTS (
    SELECT FROM pg_stat_activity
    WHERE backend_type = 'squeeze worker' AND datname = 'postgres'
);
'@

function Wait-SqueezeWorker {
    param([bool]$Present, [int]$TimeoutSeconds)

    $expected = if ($Present) { 't' } else { 'f' }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 2
        $result = & $psql @psqlArgs -A -t -q -c $workerQuery
        if ($LASTEXITCODE -ne 0) { throw 'Could not query pg_stat_activity for the squeeze worker' }
        if ($result -ceq $expected) { return $true }
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    return $false
}

$startAttempted = $false
$passed = $false
try {
    & "$PgRoot/bin/initdb.exe" -D $data -U postgres -A trust --encoding=UTF8 --no-locale
    if ($LASTEXITCODE -ne 0) { throw 'initdb failed' }

    $startAttempted = $true
    & $pgCtl -D $data -l $log -o $serverOptions -w start
    if ($LASTEXITCODE -ne 0) { throw 'Preload startup failed' }

    # The table, clustering-index, and TOAST cases come from upstream sql/squeeze.sql.
    @'
CREATE EXTENSION pg_squeeze;
DO $$
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_squeeze')
        IS DISTINCT FROM '1.9' THEN
        RAISE EXCEPTION 'Expected pg_squeeze SQL version 1.9';
    END IF;
END
$$;

CREATE TABLE a(i int PRIMARY KEY, j int);
INSERT INTO a(i, j) SELECT x, x FROM generate_series(1, 10) AS g(x);
SELECT squeeze.squeeze_table('public', 'a', NULL);

CREATE INDEX a_i_idx_desc ON a(i DESC);
SELECT squeeze.squeeze_table('public', 'a', 'a_i_idx_desc');
DO $$
BEGIN
    IF (SELECT count(*) = 10 AND bool_and(i BETWEEN 1 AND 10 AND j IS NOT DISTINCT FROM i) FROM a)
        IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Squeezing table a changed its data';
    END IF;
END
$$;

CREATE TABLE b(i int PRIMARY KEY, t text);
-- Store the data out of line even though the repeated strings compress well.
ALTER TABLE b ALTER COLUMN t SET STORAGE EXTERNAL;
INSERT INTO b(i, t) SELECT x, repeat(x::text, 4096) FROM generate_series(1, 10) AS g(x);
CREATE TABLE b_copy (LIKE b INCLUDING ALL);
INSERT INTO b_copy(i, t) SELECT i, t FROM b;
SELECT squeeze.squeeze_table('public', 'b', NULL);
DO $$
BEGIN
    IF EXISTS (
        SELECT FROM b FULL JOIN b_copy USING (i)
        WHERE b.i IS NULL OR b_copy.i IS NULL OR b.t IS DISTINCT FROM b_copy.t
    ) THEN
        RAISE EXCEPTION 'Squeezing table b changed its TOAST data';
    END IF;
END
$$;
'@ | & $psql @psqlArgs -f -
    if ($LASTEXITCODE -ne 0) { throw 'pg_squeeze table and TOAST smoke failed' }

    & $pgCtl -D $data -m fast -w stop
    if ($LASTEXITCODE -ne 0) { throw 'Could not stop the server before the autostart test' }

    $autostartOptions = "$serverOptions -c squeeze.worker_autostart=postgres -c squeeze.worker_role=postgres"
    & $pgCtl -D $data -l $log -o $autostartOptions -w start
    if ($LASTEXITCODE -ne 0) { throw 'Autostart server startup failed' }

    if (-not (Wait-SqueezeWorker -Present $true -TimeoutSeconds 90)) {
        throw 'The autostart squeeze worker was not visible in pg_stat_activity'
    }

    & $psql @psqlArgs -c 'SELECT squeeze.stop_worker();'
    if ($LASTEXITCODE -ne 0) { throw 'squeeze.stop_worker() failed' }
    if (-not (Wait-SqueezeWorker -Present $false -TimeoutSeconds 60)) {
        throw 'The autostart squeeze worker was still visible after squeeze.stop_worker()'
    }
    $passed = $true
} finally {
    try {
        if ($startAttempted -and (Test-Path (Join-Path $data 'postmaster.pid'))) {
            & $pgCtl -D $data -m immediate -w stop
            if ($LASTEXITCODE -ne 0 -and $passed) {
                $passed = $false
                throw 'Could not stop the smoke test server'
            }
        }
    } finally {
        if (-not $passed -and (Test-Path $log)) { Get-Content $log -Tail 80 }
    }
}

Write-Host "PASS: pg_squeeze PG$PostgreSqlMajor functional smoke test"
