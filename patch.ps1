param(
  [string]$Path,
  [string]$CsvPath,
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
  Exit 1
}

# 1. 环境检查
$7zExe = Get-RequireFile 7z.exe
$7zSfx = Get-RequireFile 7zSD.sfx
$HDiffSExe = Get-RequireFile hsign_diff.exe
$HDiffZExe = Get-RequireFile hdiffz.exe
$HPatchZExe = Get-RequireFile hpatchz.exe

if (-not $Path) {
  Add-Type -AssemblyName System.Windows.Forms
  $FolderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
  $FolderBrowser.Description = "请选择目标文件夹"
  $FolderBrowser.RootFolder = [System.Environment+SpecialFolder]::MyComputer
  $FolderBrowser.ShowNewFolderButton = $false

  if ($FolderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::Cancel) {
    Write-Warning "操作已取消"
    Exit 1
  }
  $Path = $FolderBrowser.SelectedPath
}

$CsvPath = if ($CsvPath) {
  if (Split-Path -IsAbsolute $CsvPath) {
    $CsvPath
  } else { Join-Path $PWD $CsvPath }
} else {
  Add-Type -AssemblyName System.Windows.Forms
  $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
  $fileDialog.Title = "请选择哈希文件或文件包"
  $fileDialog.Filter = "支持的文件 (*.csv;*.7z)|*.csv;*.7z|CSV 文件 (*.csv)|*.csv|压缩包 (*.7z)|*.7z"

  if ($fileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::Cancel) {
    Write-Host "操作已取消" -ForegroundColor Yellow
    Exit 1
  }

  $fileDialog.FileName
}

$OutputPath = if ($OutputPath) {
  if (Split-Path -IsAbsolute $OutputPath) {
    $OutputPath
  } else { Join-Path $PWD $OutputPath }
} else { "TRSS-Patch.exe" }

try {
  Set-Location $Path
  [System.IO.Directory]::SetCurrentDirectory($Path)
  Write-Host "切换到文件夹: $PWD" -ForegroundColor Green
} catch {
  Write-Warning "无法进入 $Path 详情: $_"
  Exit 1
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
# 退出时清理临时文件
[void](Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action ([ScriptBlock]::Create("Remove-Item -Force -Recurse '$($TempDir.Replace("'", "''"))'")))

# 判断用户选择的是否是 7-Zip 压缩包
if ($CsvPath -like "*.7z") {
  try {
    Write-Host "检测到 7-Zip 压缩包，正在解压..." -ForegroundColor Cyan

    # 创建唯一的临时解压文件夹
    $UncompressDir = Join-Path $TempDir ([System.IO.Path]::GetRandomFileName())
    & $7zExe x -y "-o$UncompressDir" $CsvPath
    if ($LASTEXITCODE -ne 0) { Throw $LASTEXITCODE }

    $CsvPath = Join-Path $UncompressDir "TRSS-FileHash.csv"
    if (-not (Test-Path $CsvPath)) {
      Write-Warning "未找到 CSV 文件"
      Exit 1
    }
  } catch {
    Write-Warning "解压错误 详情: $_"
    Exit 1
  }
}

# 将 CSV 数据导入并转换为 HashTable (以 Path 为 Key)
try {
  $oldData = @{}
  Import-Csv $CsvPath | ForEach-Object { $oldData[$_.Path] = $_ }

  $newData = @{}
  if (Test-Path "TRSS-FileHash.csv") {
    Import-Csv "TRSS-FileHash.csv" | ForEach-Object { $newData[$_.Path] = $_ }
  }
} catch {
  Write-Warning "无法加载 CSV 数据 详情: $_"
  Exit 1
}

Write-Host "正在扫描新文件夹并进行差异分析..." -ForegroundColor Cyan

foreach ($file in ("TRSS-FileHash.csv", "TRSS-Check.exe", $OutputPath)) {
  if (Test-Path $file) { Remove-Item -Force -Recurse $file }
}

# 新增的文件
$filesToCopy = [System.Collections.Generic.List[string]]::new()
# 修改的文件
$filesToDiff = [System.Collections.Generic.List[object]]::new()

# 找出新增和修改的文件
$files = Get-ChildItem -Force -Recurse -File
$i = 0
foreach ($file in $files) {
  $i++
  $relPath = Resolve-Path -Relative -LiteralPath $file.FullName
  Write-Progress -Activity "正在处理文件" -Status "($i / $($files.Count)) $relPath" -PercentComplete (($i / $files.Count) * 100)

  $oldFile = $oldData[$relPath]
  $oldData.Remove($relPath)

  if (-not $oldFile) {
    # 旧 CSV 中没有 -> 新增
    $filesToCopy.Add($relPath)
  } elseif ($oldFile.Length -ne $file.Length) {
    # 对比大小判断是否修改
    $filesToDiff.Add([PSCustomObject]@{
        Path = $relPath
        Hash = $oldFile.Hash
      })
  } else {
    # 检查哈希缓存有效性
    $newFile = $newData[$relPath]
    $hash = if ($newFile.Hash -and
      ($newFile.Length -eq $file.Length) -and
      ($newFile.Time -eq ([DateTimeOffset]$file.LastWriteTime).ToUnixTimeSeconds())
    ) { $newFile.Hash } else {
      (Get-FileHash -Algorithm SHA512 $file.FullName).Hash
    }
    # 对比哈希判断是否修改
    if ($hash -ine $oldFile.Hash) {
      $filesToDiff.Add([PSCustomObject]@{
          Path = $relPath
          Hash = $oldFile.Hash
          Length = $newFile.Length
        })
    }
  }
}
Write-Progress -Activity "正在处理文件" -Completed

# 剩下删除的文件
$filesToDelete = $oldData.Keys

Write-Host "分析完成: 新增 $($filesToCopy.Count) 个，修改 $($filesToDiff.Count) 个，删除 $($filesToDelete.Count) 个。" -ForegroundColor Yellow

$filesCount = $filesToDelete.Count + $filesToCopy.Count + $filesToDiff.Count
if ($filesCount -eq 0) {
  Write-Host "没有检测到任何文件变化，无需打包。" -ForegroundColor Green
  Exit
}

# 5. 提取文件：新增文件复制全量，修改文件利用 rdiff 生成 delta
Write-Host "正在提取并处理补丁文件..." -ForegroundColor Cyan

# 定义临时打包阶段文件夹
$PakDir = Join-Path $TempDir ([System.IO.Path]::GetRandomFileName())
[void](New-Item -Force -ItemType Directory $PakDir)

$i = 0
$total = $filesToCopy.Count + $filesToDiff.Count

# 处理新增文件 (全量复制)
foreach ($relPath in $filesToCopy) {
  $i++
  Write-Progress -Activity "正在处理文件" -Status "($i / $total) $relPath" -PercentComplete (($i / $total) * 100)

  $dstPath = Join-Path (Join-Path $PakDir "new") $relPath
  $dstDir = Split-Path -Parent $dstPath
  if (-not (Test-Path $dstDir)) {
    [void](New-Item -Force -ItemType Directory $dstDir)
  }
  Copy-Item -Force -LiteralPath $relPath -Destination $dstPath
}

# 处理修改的文件 (rdiff 或 hdiff 增量化)
$oldPathDir = Split-Path -Parent $CsvPath
foreach ($oldFile in $filesToDiff) {
  $i++
  $relPath = $oldFile.Path
  Write-Progress -Activity "正在处理文件" -Status "($i / $total) $relPath" -PercentComplete (($i / $total) * 100)

  # hsign_diff 需要老文件签名；hdiff 需要老文件本身，压缩率高优先使用
  # 先对老文件所在路径寻找，假设老文件就在执行 patch 时弹出的 CSV 同级文件夹下
  $oldPath = Join-Path $oldPathDir $relPath
  $dstPath  = Join-Path (Join-Path $PakDir "hdiff") $relPath
  $tmpPath = Join-Path $PSScriptRoot ([System.IO.Path]::GetRandomFileName())

  if (Test-Path $oldPath) {
    # 通过老文件对新文件生成 hdiff 增量补丁
    & $HDiffZExe -SD $oldPath $relPath $tmpPath >$null
  } elseif (Test-Path "$oldPath.hsyni") {
    # 通过老文件签名对新文件生成 hdiff 增量补丁
    & $HDiffSExe "$oldPath.hsyni" $relPath $tmpPath >$null
  }

  if (-not (Test-Path $tmpPath) -or (Get-Item $tmpPath).Length >= $oldFile.Length) {
    # 未找到老文件或增量文件≥新文件，退回到全量复制
    Remove-Item -Force $tmpPath -ErrorAction SilentlyContinue
    $dstPath = Join-Path (Join-Path $PakDir "new") $relPath
    $dstDir  = Split-Path -Parent $dstPath
    if (-not (Test-Path $dstDir)) {
      [void](New-Item -Force -ItemType Directory $dstDir)
    }
    Copy-Item -Force -LiteralPath $relPath -Destination $dstPath
    continue
  }

  $dstDir  = Split-Path -Parent $dstPath
  if (-not (Test-Path $dstDir)) {
    [void](New-Item -Force -ItemType Directory $dstDir)
  }
  Move-Item -Force -LiteralPath $tmpPath -Destination $dstPath
  if ($LASTEXITCODE -ne 0) { Throw $LASTEXITCODE }
  # 写入哈希值
  $hashBytes = [byte[]](0 .. (($oldFile.Hash.Length / 2) - 1) | ForEach-Object { [System.Convert]::ToByte($oldFile.Hash.Substring(($_ * 2), 2), 16) })
  $stream = [System.IO.File]::OpenWrite($dstPath)
  try {
    [void]$stream.Seek(0, [System.IO.SeekOrigin]::End)
    $stream.Write($hashBytes, 0, $hashBytes.Length)
  } finally { $stream.Close() }
}
Write-Progress -Activity "正在处理文件" -Completed

# 6. 生成客户端应用脚本
Write-Host "正在生成补丁脚本..." -ForegroundColor Cyan
$ScriptContent = @'
param([string]$Path)
$ErrorActionPreference = "Stop"
if (-not $Path) {
  Add-Type -AssemblyName System.Windows.Forms
  $FolderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
  $FolderBrowser.Description = '请选择【
'@ + (Get-Item -LiteralPath $PWD).Name.Replace("'", "''") + @'
】文件夹'
  $FolderBrowser.RootFolder = [System.Environment+SpecialFolder]::MyComputer
  $FolderBrowser.ShowNewFolderButton = $false
  $Result = $FolderBrowser.ShowDialog()
  if ($Result -eq [System.Windows.Forms.DialogResult]::Cancel) {
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
Write-Host "开始应用更新补丁..." -ForegroundColor Cyan
$i = 0
$total = 
'@ + "$filesCount

"

# 1. 删除文件
if ($filesToDelete.Count -ne 0) {
  $deleteListString = ($filesToDelete | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ","
  $ScriptContent += "`$deleteFiles = @($deleteListString)" + @'

$deleteDirs = [System.Collections.Generic.HashSet[string]]::new()
foreach ($relPath in $deleteFiles) {
  $i++
  Write-Progress -Activity "正在处理文件" -Status "($i / $total) [删除] $relPath" -PercentComplete (($i / $total) * 100)
  try {
    Remove-Item -Force -Recurse $relPath
    $dir = Split-Path -Parent $relPath
    while ($dir -and ($dir -ne ".")) {
      [void]$deleteDirs.Add($dir)
      $dir = Split-Path -Parent $dir
    }
  } catch { Write-Warning "$relPath 详情: $_" }
}

'@
}

# 2. 合并 hdiff 增量文件
if (Test-Path (Join-Path $PakDir "hdiff")) {
  # 将 hpatchz 复制到临时文件夹中，打包进自解压文件
  Copy-Item -Force -LiteralPath $HPatchZExe -Destination $PakDir

  $ScriptContent += @'
$HPatchZExe = Join-Path $PSScriptRoot "hpatchz.exe"
$dstDir = Join-Path $PSScriptRoot "hdiff"
Get-ChildItem -Force -Recurse -File -LiteralPath $dstDir | ForEach-Object {
  $i++
  $dstPath = $_.FullName
  $relPath = $dstPath.Replace($dstDir, ".")
  Write-Progress -Activity "正在处理文件" -Status "($i / $total) [更新] $relPath" -PercentComplete (($i / $total) * 100)

  try {
    if (-not (Test-Path $relPath)) { Throw "文件不存在，无法应用" }

    $stream = [System.IO.File]::Open($dstPath, "Open", "ReadWrite")
    $hashBytes = New-Object byte[] 64
    try {
      [void]$stream.Seek(-64, [System.IO.SeekOrigin]::End)
      $bytesRead = 0
      while ($bytesRead -lt 64) {
        $n = $stream.Read($hashBytes, $bytesRead, 64 - $bytesRead)
        if ($n -eq 0) { Throw "补丁文件读取错误" }
        $bytesRead += $n
      }
      $stream.SetLength($stream.Length - 64)
    } finally { $stream.Close() }
    $hash = [System.BitConverter]::ToString($hashBytes).Replace("-", "")
    if ($hash -ine (Get-FileHash -Algorithm SHA512 $relPath).Hash) { Throw "文件已修改，无法应用" }

    $tmpPath = Join-Path $PSScriptRoot ([System.IO.Path]::GetRandomFileName())
    & $HPatchZExe $relPath $dstPath $tmpFile >$null
    if ($LASTEXITCODE -ne 0) { Throw $LASTEXITCODE }
    Move-Item -Force -LiteralPath $tmpPath -Destination $relPath
  } catch { Write-Warning "$relPath 详情: $_" }
}

'@
}

# 3. 移动新增文件
if (Test-Path (Join-Path $PakDir "new")) {
  $ScriptContent += @'
$dstDir = Join-Path $PSScriptRoot "new"
Get-ChildItem -Force -Recurse -File -LiteralPath $dstDir | ForEach-Object {
  $i++
  $dstPath = $_.FullName
  $relPath = $dstPath.Replace($dstDir, ".")
  $relDir = Split-Path -Parent $relPath

  try {
    if (Test-Path $relPath) {
      Write-Progress -Activity "正在处理文件" -Status "($i / $total) [更新] $relPath" -PercentComplete (($i / $total) * 100)
      Remove-Item -Force -Recurse $relPath
    } else {
      Write-Progress -Activity "正在处理文件" -Status "($i / $total) [新增] $relPath" -PercentComplete (($i / $total) * 100)
      if (-not (Test-Path $relDir)) {
        [void](New-Item -Force -ItemType Directory $relDir)
      }
    }
    Move-Item -Force -LiteralPath $dstPath -Destination $relPath
  } catch { Write-Warning "$relPath 详情: $_" }
}

'@
}

# 4. 清理残留的空文件夹
$ScriptContent += @'
$i = 0
$deleteDirs | Sort-Object { $_.Length } -Descending | ForEach-Object {
  $i++
  if ((Get-ChildItem -Force -LiteralPath $_ -ErrorAction SilentlyContinue).Count -eq 0) {
    Write-Progress -Activity "正在处理文件" -Status "[删除] ($i / $($deleteDirs.Count)) $_" -PercentComplete (($i / $deleteDirs.Count) * 100)
    Remove-Item -Force $_ -ErrorAction SilentlyContinue
  }
}
Write-Progress -Activity "正在处理文件" -Completed
Read-Host "更新完成，按回车键退出"
'@

$ScriptContent | Set-Content -Encoding UTF8 (Join-Path $PakDir "patch.ps1")

# 7. 生成 7-Zip SFX 配置文件
$ConfigFile = Join-Path $TempDir ([System.IO.Path]::GetRandomFileName())
(@'
;!@Install@!UTF-8!
ExecuteFile="powershell.exe"
ExecuteParameters="-NoProfile -ExecutionPolicy Bypass -File .\patch.ps1"
;!@InstallEnd@!
'@) | Set-Content -Encoding UTF8 $ConfigFile

# 8. 使用 7-Zip 打包并生成自解压 EXE
Write-Host "正在使用 7-Zip 封装自解压包..." -ForegroundColor Cyan
$7zFile = Join-Path $TempDir ([System.IO.Path]::GetRandomFileName()+".7z")
& $7zExe a -m0=zstd $7zFile "$PakDir\*"
if ($LASTEXITCODE -ne 0) { Throw $LASTEXITCODE }
$outStream = [System.IO.File]::Create($OutputPath)
try {
  foreach ($f in ($7zSfx, $ConfigFile, $7zFile)) {
    $inStream = [System.IO.File]::OpenRead($f)
    try {
      $inStream.CopyTo($outStream)
    } finally { $inStream.Close() }
  }
} finally { $outStream.Close() }

if ($FolderBrowser) {
  Start-Process explorer.exe -ArgumentList "/select,`"$OutputPath`""
}
Write-Host "补丁包已生成: $OutputPath" -ForegroundColor Green
