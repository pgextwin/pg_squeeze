[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PgRoot,
    [Parameter(Mandatory = $true)][string]$UpstreamDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = (Resolve-Path $UpstreamDir).Path
$manifest = Get-Content (Join-Path $PSScriptRoot '../../config/extension.json') -Raw | ConvertFrom-Json
$actual = (& git -C $source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actual -cne $manifest.upstream.commit) {
    throw 'Upstream identity mismatch'
}

$pgVersion = & (Join-Path $PgRoot 'bin/pg_config.exe') --version
if ($LASTEXITCODE -ne 0 -or $pgVersion -notmatch '^PostgreSQL (\d+)') {
    throw "Could not determine PostgreSQL major from pg_config: $pgVersion"
}
$pgMajor = [int]$Matches[1]

# The upstream Makefile generates pgstatapprox.c from the server-specific source.
$pgstatSource = 'pgstatapprox.in.old.c'
$clStdLine = ''
if ($pgMajor -ge 19) {
    $pgstatSource = 'pgstatapprox.in.c'
    $clStdLine = 'set "CL=/std:c11"'
}
Copy-Item (Join-Path $source $pgstatSource) (Join-Path $source 'pgstatapprox.c') -Force

$patch = Join-Path $PSScriptRoot 'pg_squeeze-win32.patch'
& git -C $source apply --check $patch
if ($LASTEXITCODE -ne 0) { throw 'Windows adapter does not apply to the pinned source' }
& git -C $source apply $patch
if ($LASTEXITCODE -ne 0) { throw 'Could not apply the Windows adapter' }

$vswhere = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'MSVC discovery tool missing' }
$vs = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath |
    Select-Object -First 1)
if (-not $vs -or -not $vs[0].Trim()) { throw 'MSVC x64 toolchain missing' }
$devCmd = Join-Path $vs[0].Trim() 'Common7/Tools/VsDevCmd.bat'
if (-not (Test-Path $devCmd)) { throw 'VsDevCmd unavailable' }

@(
    'LIBRARY pg_squeeze'
    'EXPORTS'
    '    _PG_init'
    '    _PG_output_plugin_init'
    '    squeeze_table'
    '    squeeze_table_new'
    '    squeeze_start_worker'
    '    squeeze_stop_worker'
    '    squeeze_get_active_workers'
    '    squeeze_pgstattuple_approx'
    '    get_heap_fillfactor'
    '    get_heap_freespace'
) |
    Set-Content -Path (Join-Path $source 'pg_squeeze.def') -Encoding ascii

$buildCmd = Join-Path $env:RUNNER_TEMP 'pg-squeeze-build.cmd'
@"
@echo off
call "$devCmd" -arch=x64 -host_arch=x64 >nul
if errorlevel 1 exit /b %errorlevel%
$clStdLine
pushd "$source"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /MD /DWIN32 /DWIN32_NO_STATUS /D_CRT_SECURE_NO_WARNINGS ^
 /I"$PgRoot\include\server\port\win32_msvc" ^
 /I"$PgRoot\include\server\port\win32" ^
 /I"$PgRoot\include\server" /I"$PgRoot\include" ^
 /c pg_squeeze.c concurrent.c worker.c pgstatapprox.c
if errorlevel 1 exit /b %errorlevel%
link /nologo /DLL /OUT:pg_squeeze.dll /DEF:pg_squeeze.def ^
 pg_squeeze.obj concurrent.obj worker.obj pgstatapprox.obj "$PgRoot\lib\postgres.lib" "$PgRoot\lib\libintl.lib"
if errorlevel 1 exit /b %errorlevel%
dumpbin /nologo /exports pg_squeeze.dll
"@ | Set-Content -Path $buildCmd -Encoding ascii

$buildLog = @(& cmd.exe /d /c $buildCmd 2>&1)
$buildLog | ForEach-Object { Write-Host "$_" }
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $source 'pg_squeeze.dll'))) {
    throw 'Pinned native MSVC DLL compile/link failed'
}
