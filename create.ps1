param(
  [string]$Path,
  [string]$OutputPath
)
$ErrorActionPreference = "Stop"

function Get-RequireFile {
  param([string]$Name)
  $Path = Join-Path $PSScriptRoot $Name
  if (Test-Path $Path) { return $Path }
  $Path = (Get-Command $Name -ErrorAction SilentlyContinue).Path
  if ($Path) { return $Path }
  Write-Warning "未找到文件 $Name"
  exit 1
}

$xxhsumExe = Get-RequireFile xxhsum.exe
$7zExe = Get-RequireFile 7z.exe
$7zDll = Get-RequireFile 7z.dll
$7zSfx = Get-RequireFile 7zSD.sfx
$HSyncMExe = Get-RequireFile hsync_make.exe

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
[void](New-Item -Force -ItemType Directory $TempDir)
# 退出时清理临时文件
[void](Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action ([ScriptBlock]::Create("Remove-Item -Force -Recurse '$($TempDir.Replace("'", "''"))'")))

if (-not $Path) {
  Add-Type -AssemblyName System.Windows.Forms
  $FolderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
  $FolderBrowser.Description = "请选择目标文件夹"
  $FolderBrowser.RootFolder = [System.Environment+SpecialFolder]::MyComputer
  $FolderBrowser.ShowNewFolderButton = $false

  if ($FolderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::Cancel) {
    Write-Warning "操作已取消"
    exit 1
  }
  $Path = $FolderBrowser.SelectedPath
}

$OutputPath = if ($OutputPath) {
  if (Split-Path -IsAbsolute $OutputPath) {
    $OutputPath
  }
  else { Join-Path $PWD $OutputPath }
}
else { "TRSS-Check.exe" }

try {
  Set-Location $Path
  [System.IO.Directory]::SetCurrentDirectory($Path)
  Write-Host "切换到文件夹: $PWD" -ForegroundColor Green
}
catch {
  Write-Warning "无法进入 $Path 详情: $_"
  exit 1
}

Write-Host "正在扫描文件，计算文件哈希值..." -ForegroundColor Cyan

$CsvData = [System.Collections.Generic.List[object]]::new()
$CsvPath = "TRSS-FileHash.csv"
foreach ($file in ($CsvPath, $OutputPath, "TRSS-Patch.exe")) {
  if (Test-Path $file) { Remove-Item -Force -Recurse $file }
}

# 扫描文件
$files = Get-ChildItem -Force -Recurse -File
$fileList = Join-Path $TempDir ([System.IO.Path]::GetRandomFileName())
$paths = $files | ForEach-Object {
  Resolve-Path -Relative -LiteralPath $_.FullName
}
[System.IO.File]::WriteAllLines(
  $fileList,
  $paths,
  [System.Text.UTF8Encoding]::new($false)
)

$hashMap = @{}
& $xxhsumExe -H2 --filelist $fileList | ForEach-Object {
  if ([string]::IsNullOrWhiteSpace($_)) { return }
  if ($_ -match "^\\?([0-9a-f]+)\s+(.*)$") {
    $relPath = $Matches[2].Replace("\\", "\")
    $hashMap[$relPath] = $Matches[1]
  } else {
    Write-Warning "无法解析 xxhsum 输出行: $_"
  }
}
if ($LASTEXITCODE -ne 0) {
  Write-Warning "xxhsum 退出码：$LASTEXITCODE，部分文件可能未计算成功"
}

foreach ($file in $files) {
  $relPath = Resolve-Path -Relative -LiteralPath $file.FullName
  try {
    $hash = $hashMap[$relPath]
    if (-not $hash) {
      Write-Warning "未找到文件哈希: $relPath"
      $hash = ((& $xxhsumExe -H2 $relPath).TrimStart("\").Split(" ", 2))[0]
    }
    $CsvData.Add([PSCustomObject]@{
        Path   = $relPath
        Hash   = $hash
        Length = $file.Length
        Time   = ([DateTimeOffset]$file.LastWriteTime).ToUnixTimeSeconds()
      })
  }
  catch {
    Write-Warning "无法处理文件: $relPath 详情: $_"
  }
}
$CsvData | Export-Csv -Encoding UTF8 -NoTypeInformation $CsvPath
Write-Host "哈希值已保存至: $CsvPath" -ForegroundColor Green

# 定义临时打包阶段文件夹
$PakDir = Join-Path $TempDir ([System.IO.Path]::GetRandomFileName())
[void](New-Item -Force -ItemType Directory $PakDir)

# 1. 复制
foreach ($target in ($CsvPath, $xxhsumExe, $7zExe, $7zDll, $HSyncMExe)) {
  Copy-Item -Force -LiteralPath $target -Destination $PakDir
}

(@'
param(
  [string]$Path,
  [string]$OutputPath
)
$ErrorActionPreference = "Stop"

$OutputPath = if ($OutputPath) {
  if (Split-Path -IsAbsolute $OutputPath) {
    $OutputPath
  } else { Join-Path $PWD $OutputPath }
} else { "TRSS-Check.7z" }

# 将 CSV 数据导入并转换为 HashTable (以 Path 为 Key)
try {
  $newData = @{}
  Import-Csv (Join-Path $PSScriptRoot "TRSS-FileHash.csv") | ForEach-Object {
    $newData[$_.Path] = $_
  }
} catch {
  Write-Warning "无法加载 CSV 数据 详情: $_"
  Exit 1
}

$xxhsumExe = Join-Path $PSScriptRoot "xxhsum.exe"
$7zExe = Join-Path $PSScriptRoot "7z.exe"
$HSyncMExe = Join-Path $PSScriptRoot "hsync_make.exe"

if (-not $Path) {
  Add-Type -AssemblyName System.Windows.Forms
  $FolderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
  $FolderBrowser.Description = '请选择【
'@ + (Get-Item -LiteralPath $PWD).Name.Replace("'", "''") + @'
】文件夹'
  $FolderBrowser.RootFolder = [System.Environment+SpecialFolder]::MyComputer
  $FolderBrowser.ShowNewFolderButton = $false

  if ($FolderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::Cancel) {
    Write-Warning "操作已取消"
    Exit 1
  }
  $Path = $FolderBrowser.SelectedPath
}

try {
  Set-Location $Path
  [System.IO.Directory]::SetCurrentDirectory($Path)
  Write-Host "切换到文件夹: $PWD" -ForegroundColor Green
} catch {
  Write-Warning "无法进入 $Path 详情: $_"
  Exit 1
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
[void](New-Item -Force -ItemType Directory $TempDir)
# 退出时清理临时文件
[void](Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action ([ScriptBlock]::Create("Remove-Item -Force -Recurse '$($TempDir.Replace("'", "''"))'")))

# 定义临时打包阶段文件夹
$PakDir = Join-Path $TempDir ([System.IO.Path]::GetRandomFileName())
[void](New-Item -Force -ItemType Directory $PakDir)

Write-Host "正在扫描文件，计算文件哈希值..." -ForegroundColor Cyan

$CsvData = [System.Collections.Generic.List[object]]::new()
$CsvPath = Join-Path $PakDir "TRSS-FileHash.csv"
if (Test-Path $OutputPath) { Remove-Item -Force -Recurse $OutputPath }

# 扫描文件
$files = Get-ChildItem -Force -Recurse -File
$fileList = Join-Path $TempDir ([System.IO.Path]::GetRandomFileName())
$paths = $files | ForEach-Object {
  Resolve-Path -Relative -LiteralPath $_.FullName
}
[System.IO.File]::WriteAllLines(
  $fileList,
  $paths,
  [System.Text.UTF8Encoding]::new($false)
)

$hashMap = @{}
& $xxhsumExe -H2 --filelist $fileList | ForEach-Object {
  if ([string]::IsNullOrWhiteSpace($_)) { return }
  if ($_ -match "^\\?([0-9a-f]+)\s+(.*)$") {
    $relPath = $Matches[2].Replace("\\", "\")
    $hashMap[$relPath] = $Matches[1]
  } else {
    Write-Warning "无法解析 xxhsum 输出行: $_"
  }
}
if ($LASTEXITCODE -ne 0) {
  Write-Warning "xxhsum 退出码：$LASTEXITCODE，部分文件可能未计算成功"
}

foreach ($file in $files) {
  $relPath = Resolve-Path -Relative -LiteralPath $file.FullName
  try {
    $hash = $hashMap[$relPath]
    if (-not $hash) {
      Write-Warning "未找到文件哈希: $relPath"
      $hash = ((& $xxhsumExe -H2 $relPath).TrimStart("\").Split(" ", 2))[0]
    }
    $CsvData.Add([PSCustomObject]@{
        Path   = $relPath
        Hash   = $hash
        Length = $file.Length
        Time   = ([DateTimeOffset]$file.LastWriteTime).ToUnixTimeSeconds()
      })

    if ((-not $newData[$relPath]) -or (
      ($newData[$relPath].Length -eq $file.Length) -and
      ($hash -ieq $newData[$relPath].Hash)
    )) { continue }

    $dstPath = Join-Path $PakDir "$relPath.hsyni"
    $dstDir  = Split-Path -Parent $dstPath
    if (-not (Test-Path $dstDir)) {
      [void](New-Item -Force -ItemType Directory $dstDir)
    }
    & $HSyncMExe $relPath $dstPath >$null
    if ($LASTEXITCODE -ne 0) { Throw $LASTEXITCODE }
  } catch { Write-Warning "[错误] $file.FullName 详情: $_" }
}
Write-Progress -Activity "正在处理文件" -Completed
$CsvData | Export-Csv -Encoding UTF8 -NoTypeInformation $CsvPath
Write-Host "哈希值已保存至: $CsvPath" -ForegroundColor Green

# 8. 使用 7-Zip 打包
Write-Host "正在使用 7-Zip 压缩包..." -ForegroundColor Cyan
& $7zExe -m0=zstd a $OutputPath "$PakDir\*"
if ($LASTEXITCODE -ne 0) { Throw $LASTEXITCODE }

if ($FolderBrowser) {
  Start-Process explorer.exe -ArgumentList "/select,`"$OutputPath`""
}
Read-Host "检测结果已生成，按回车键退出"
'@) -split "`n" | Where-Object { $_ -notmatch '^\s*$' -and $_ -notmatch '^\s*#' } |
  Set-Content -Encoding UTF8 (Join-Path $PakDir "check.ps1")

# 7. 生成 7-Zip SFX 配置文件
$ConfigFile = Join-Path $TempDir ([System.IO.Path]::GetRandomFileName())
(@'
;!@Install@!UTF-8!
ExecuteFile="powershell.exe"
ExecuteParameters="-NoProfile -ExecutionPolicy Bypass -File .\check.ps1"
;!@InstallEnd@!
'@) | Set-Content -Encoding UTF8 $ConfigFile

# 8. 使用 7-Zip 打包并生成自解压 EXE
Write-Host "正在使用 7-Zip 封装自解压包..." -ForegroundColor Cyan
$7zFile = Join-Path $TempDir ([System.IO.Path]::GetRandomFileName() + ".7z")
& $7zExe -m0=zstd a $7zFile "$PakDir\*"
if ($LASTEXITCODE -ne 0) { throw $LASTEXITCODE }
$outStream = [System.IO.File]::Create($OutputPath)
try {
  foreach ($f in ($7zSfx, $ConfigFile, $7zFile)) {
    $inStream = [System.IO.File]::OpenRead($f)
    try {
      $inStream.CopyTo($outStream)
    }
    finally { $inStream.Close() }
  }
}
finally { $outStream.Close() }

if ($FolderBrowser) {
  Start-Process explorer.exe -ArgumentList "/select,`"$OutputPath`""
}
Write-Host "检测包已生成: $OutputPath" -ForegroundColor Green
