$TitleText = '远程补丁工具 v0.0.0'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# ---------------- 控制台日志 ----------------
function Write-Log([string]$msg, [ConsoleColor]$color = 'Gray') {
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg
  try {
    $prev = [Console]::ForegroundColor
    [Console]::ForegroundColor = $color
    [Console]::WriteLine($line)
    [Console]::ForegroundColor = $prev
  } catch { Write-Host $line }
}

# ---------------- 绘图工具 ----------------
function RGB([int]$r, [int]$g, [int]$b) { [Drawing.Color]::FromArgb($r, $g, $b) }

function New-RoundedPath([int]$x, [int]$y, [int]$w, [int]$h, [int]$radius) {
  $gp = New-Object Drawing.Drawing2D.GraphicsPath
  $d = $radius * 2
  $gp.AddArc($x, $y, $d, $d, 180, 90)
  $gp.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $gp.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $gp.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $gp.CloseFigure()
  return $gp
}

function New-RoundedRegion([int]$w, [int]$h, [int]$r) {
  $gp = New-RoundedPath 0 0 $w $h $r
  $rg = New-Object Drawing.Region($gp)
  $gp.Dispose()
  return $rg
}

function Blend-Color([Drawing.Color]$c1, [Drawing.Color]$c2, [double]$t) {
  [Drawing.Color]::FromArgb(
    [int]($c1.R + ($c2.R - $c1.R) * $t),
    [int]($c1.G + ($c2.G - $c1.G) * $t),
    [int]($c1.B + ($c2.B - $c1.B) * $t))
}

# ---------------- 主题 ----------------
$C = @{
  bg      = (RGB 24 29 38)   ; header     = (RGB 16 19 26)
  chip    = (RGB 33 39 50)   ; chipBorder = (RGB 56 66 82)
  line    = (RGB 45 53 66)
  primary = (RGB 228 234 242); secondary  = (RGB 150 162 180)
  dim     = (RGB 104 116 134); dark       = (RGB 16 19 26)
  cyan    = (RGB 56 182 255) ; amber      = (RGB 240 168 40)
  danger  = (RGB 224 82 92)  ; ok         = (RGB 82 202 148)
  warn    = (RGB 240 190 72)
}
$F = @{
  title = New-Object Drawing.Font('Microsoft YaHei UI', 17, [Drawing.FontStyle]::Bold)
  sub   = New-Object Drawing.Font('Microsoft YaHei UI', 9)
  btn   = New-Object Drawing.Font('Microsoft YaHei UI', 12.5, [Drawing.FontStyle]::Bold)
  mono  = New-Object Drawing.Font('Consolas', 8)
  stat  = New-Object Drawing.Font('Microsoft YaHei UI', 9)
}

# ---------------- 窗体 ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = $TitleText
$form.ClientSize = New-Object Drawing.Size(880, 311)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = $C.bg
$form.ForeColor = $C.primary
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

# --- 标题栏 ---
$pHead = New-Object System.Windows.Forms.Panel
$pHead.Location = New-Object Drawing.Point(0, 0)
$pHead.Size = New-Object Drawing.Size(880, 76)
$pHead.BackColor = $C.header
$form.Controls.Add($pHead)

$bar1 = New-Object System.Windows.Forms.Panel; $bar1.Location = New-Object Drawing.Point(0, 0);  $bar1.Size = New-Object Drawing.Size(5, 38); $bar1.BackColor = $C.cyan
$bar2 = New-Object System.Windows.Forms.Panel; $bar2.Location = New-Object Drawing.Point(0, 38); $bar2.Size = New-Object Drawing.Size(5, 38); $bar2.BackColor = $C.amber
$pHead.Controls.Add($bar1); $pHead.Controls.Add($bar2)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object Drawing.Point(30, 12)
$lblTitle.Font = $F.title
$lblTitle.ForeColor = $C.primary
$lblTitle.Text = $TitleText
$pHead.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.AutoSize = $true
$lblSub.Location = New-Object Drawing.Point(33, 48)
$lblSub.Font = $F.sub
$lblSub.ForeColor = $C.dim
$lblSub.Text = "Remote Patch Toolkit · 脚本目录: $ScriptDir"
$pHead.Controls.Add($lblSub)

# --- 工作流步骤条（自绘）---
$Steps = @(
  @{ N = '1'; T = '创建检测包'  ; A = $C.cyan ; Glow = 'create' }
  @{ N = '2'; T = '发给对方执行'; A = $C.dim  ; Glow = $null    }
  @{ N = '3'; T = '接收检测结果'; A = $C.dim  ; Glow = $null    }
  @{ N = '4'; T = '创建补丁包'  ; A = $C.amber; Glow = 'patch'  }
  @{ N = '5'; T = '发给对方执行'; A = $C.dim  ; Glow = $null    }
)

$wfPanel = New-Object System.Windows.Forms.Panel
$wfPanel.Location = New-Object Drawing.Point(0, 76)
$wfPanel.Size = New-Object Drawing.Size(880, 96)
$wfPanel.BackColor = $C.bg
$wfPanel.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($wfPanel, $true, $null)
$form.Controls.Add($wfPanel)

$wfPanel.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    $chipH = 34
    $minGap = 8
    $sideMargin = 16

    # 自适应步骤字号：逐级缩小直到 5 个胶囊放得下（兼容高 DPI / 大字体）
    $chipFont = $null
    $widths = $null
    $total = 0
    foreach ($fs in (24 .. 16)) {
      $tryFont = New-Object Drawing.Font('Microsoft YaHei UI', ($fs / 2))
      $tryWidths = @()
      $tryTotal = 0
      foreach ($st in $Steps) {
        $tw = [System.Windows.Forms.TextRenderer]::MeasureText($st.T, $tryFont).Width
        $w = 12 + 20 + 8 + $tw + 13
        $tryWidths += $w
        $tryTotal += $w
      }
      if ($null -ne $chipFont) { $chipFont.Dispose() }
      $chipFont = $tryFont
      $widths = $tryWidths
      $total = $tryTotal
      if (($total + $minGap * 4) -le ($sender.Width - $sideMargin * 2)) { break }
    }

    # 间距计算与无箭头版本完全相同 → 整体占位、两侧边距不变
    $gap = [int](($sender.Width - $sideMargin * 2 - $total) / 4)
    if ($gap -lt $minGap) { $gap = $minGap }
    if ($gap -gt 48) { $gap = 48 }

    # 箭头字号自适应：保证箭头宽度不超过间距（塞不进就缩小）
    $arrowFont = $null
    $arrowW = 0
    foreach ($afs in (40 .. 20)) {
      $tryAF = New-Object Drawing.Font('Microsoft YaHei UI', ($afs / 2))
      $tryW = [System.Windows.Forms.TextRenderer]::MeasureText([char]0x2192, $tryAF).Width
      if ($null -ne $arrowFont) { $arrowFont.Dispose() }
      $arrowFont = $tryAF
      $arrowW = $tryW
      if ($arrowW -le $gap) { break }
    }

    $x = [int](($sender.Width - ($total + $gap * 4)) / 2)
    $y = [int](($sender.Height - $chipH) / 2)

    for ($i = 0; $i -lt $Steps.Count; $i++) {
      $st = $Steps[$i]
      $w = $widths[$i]
      $glow = ($null -ne $st.Glow) -and $S[$st.Glow].Running

      # 运行中：呼吸光晕
      if ($glow) {
        $alpha = [int](130 + 80 * [Math]::Sin($glowPhase))
        $halo = [Drawing.Color]::FromArgb($alpha, $st.A)
        $hp = New-RoundedPath ($x - 4) ($y - 4) ($w + 8) ($chipH + 8) 20
        $g.DrawPath((New-Object Drawing.Pen($halo, 2.4)), $hp)
        $hp.Dispose()
      }

      $bgc = if ($glow) { Blend-Color $C.chip $st.A 0.16 } else { $C.chip }
      $cp = New-RoundedPath $x $y $w $chipH 17
      $g.FillPath((New-Object Drawing.SolidBrush($bgc)), $cp)
      $bc = if ($glow) { $st.A } else { $C.chipBorder }
      $g.DrawPath((New-Object Drawing.Pen($bc, $(if ($glow) { 1.6 } else { 1.0 }))), $cp)
      $cp.Dispose()

      # 数字圆徽
      $bx = $x + 12
      $by = $y + [int](($chipH - 20) / 2)
      $g.FillEllipse((New-Object Drawing.SolidBrush($st.A)), $bx, $by, 20, 20)
      $ns = [System.Windows.Forms.TextRenderer]::MeasureText($st.N, $chipFont)
      [System.Windows.Forms.TextRenderer]::DrawText($g, $st.N, $chipFont,
        (New-Object Drawing.Point(($bx + 11.5 - [int]($ns.Width / 2)), (($by + 11.5 - [int]($ns.Height / 2)) - 1))), $C.dark)

      # 步骤文字
      $ts = [System.Windows.Forms.TextRenderer]::MeasureText($st.T, $chipFont)
      [System.Windows.Forms.TextRenderer]::DrawText($g, $st.T, $chipFont,
        (New-Object Drawing.Point(($bx + 28), ($y + [int](($chipH - $ts.Height) / 2)))), $C.primary)

      $x += $w

      # 箭头：画在原间距内居中，不额外增加总宽度
      if ($i -lt $Steps.Count - 1) {
        $asz = [System.Windows.Forms.TextRenderer]::MeasureText([char]0x2192, $arrowFont)
        $ax = $x + [int](($gap - $asz.Width) / 2)
        $ac = if ($glow) { $st.A } else { $C.dim }
        [System.Windows.Forms.TextRenderer]::DrawText($g, [char]0x2192, $arrowFont,
          (New-Object Drawing.Point($ax, ($y + [int](($chipH - $asz.Height) / 2)))), $ac)
        $x += $gap
      }
    }

    $chipFont.Dispose()
    $arrowFont.Dispose()
  })

# --- 分隔线 ---
$divider = New-Object System.Windows.Forms.Panel
$divider.Location = New-Object Drawing.Point(0, 172)
$divider.Size = New-Object Drawing.Size(880, 1)
$divider.BackColor = $C.line
$form.Controls.Add($divider)

# --- 中部操作区（带点阵背景）---
$pCenter = New-Object System.Windows.Forms.Panel
$pCenter.Location = New-Object Drawing.Point(0, 173)
$pCenter.Size = New-Object Drawing.Size(880, 102)
$pCenter.BackColor = $C.bg
$pCenter.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($pCenter, $true, $null)
$form.Controls.Add($pCenter)

$pCenter.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $dot = New-Object Drawing.SolidBrush((RGB 34 40 52))
    for ($dx = 16; $dx -lt $sender.Width; $dx += 26) {
      for ($dy = 14; $dy -lt $sender.Height; $dy += 26) { $g.FillEllipse($dot, $dx, $dy, 2, 2) }
    }
    $dot.Dispose()
  })

# --- 按钮 ---
$runPal = @{ Base = (RGB 194 64 76); Hover = (RGB 212 84 94); Down = (RGB 170 50 60); Fore = [Drawing.Color]::White; Text = '停止运行' }
$BtnPalette = @{
  create = @{ idle = @{ Base = (RGB 26 122 214); Hover = (RGB 46 142 235); Down = (RGB 18 100 180); Fore = [Drawing.Color]::White; Text = '创建检测包' }; run = $runPal }
  patch  = @{ idle = @{ Base = (RGB 236 166 36); Hover = (RGB 248 182 64); Down = (RGB 214 148 22); Fore = (RGB 34 28 16); Text = '创建补丁包' }; run = $runPal }
}

function Set-ButtonState([System.Windows.Forms.Button]$btn, [string]$key, [string]$mode) {
  $pal = $BtnPalette[$key][$mode]
  $btn.BackColor = $pal.Base
  $btn.ForeColor = $pal.Fore
  $btn.Text = $pal.Text
  $btn.FlatAppearance.MouseOverBackColor = $pal.Hover
  $btn.FlatAppearance.MouseDownBackColor = $pal.Down
}

$btnCreate = New-Object System.Windows.Forms.Button
$btnCreate.Location = New-Object Drawing.Point(32, 22)
$btnCreate.Size = New-Object Drawing.Size(396, 58)
$btnCreate.FlatStyle = 'Flat'
$btnCreate.FlatAppearance.BorderSize = 0
$btnCreate.Font = $F.btn
$btnCreate.Cursor = 'Hand'
$btnCreate.Region = New-RoundedRegion 396 58 12
$pCenter.Controls.Add($btnCreate)

$btnPatch = New-Object System.Windows.Forms.Button
$btnPatch.Location = New-Object Drawing.Point(452, 22)
$btnPatch.Size = New-Object Drawing.Size(396, 58)
$btnPatch.FlatStyle = 'Flat'
$btnPatch.FlatAppearance.BorderSize = 0
$btnPatch.Font = $F.btn
$btnPatch.Cursor = 'Hand'
$btnPatch.Region = New-RoundedRegion 396 58 12
$pCenter.Controls.Add($btnPatch)

# --- 状态栏 ---
$pStatus = New-Object System.Windows.Forms.Panel
$pStatus.Location = New-Object Drawing.Point(0, 275)
$pStatus.Size = New-Object Drawing.Size(880, 36)
$pStatus.BackColor = $C.header
$form.Controls.Add($pStatus)

$stCreate = New-Object System.Windows.Forms.Label
$stCreate.Location = New-Object Drawing.Point(24, 10); $stCreate.AutoSize = $true
$stCreate.Font = $F.stat
$stCreate.ForeColor = $C.secondary
$stCreate.Text = '● 检测包：未运行'
$pStatus.Controls.Add($stCreate)

$stPatch = New-Object System.Windows.Forms.Label
$stPatch.Location = New-Object Drawing.Point(556, 10)
$stPatch.Size = New-Object Drawing.Size(300, 18)
$stPatch.Font = $F.stat
$stPatch.ForeColor = $C.secondary
$stPatch.TextAlign = 'MiddleRight'
$stPatch.Text = '● 补丁包：未运行'
$pStatus.Controls.Add($stPatch)

# ---------------- 任务状态 ----------------
$S = @{
  create = @{
    Script  = 'create.ps1'
    Tag     = '检测'
    Label   = '检测包'
    Button  = $btnCreate
    Status  = $stCreate
    Accent  = $C.cyan
    Running = $false
    Process = $null
  }

  patch = @{
    Script  = 'patch.ps1'
    Tag     = '补丁'
    Label   = '补丁包'
    Button  = $btnPatch
    Status  = $stPatch
    Accent  = $C.amber
    Running = $false
    Process = $null
  }
}

Set-ButtonState $btnCreate 'create' 'idle'
Set-ButtonState $btnPatch  'patch'  'idle'

# ---------------- 子进程管理 ----------------
function Start-Job([string]$key) {
  $j = $S[$key]
  $full = Join-Path $ScriptDir $j.Script

  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    $j.Status.ForeColor = $C.danger
    $j.Status.Text = "● $($j.Label)：未找到脚本"
    Write-Log "[$($j.Tag)] 未找到脚本文件: $full" 'Red'
    return
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $j.Script + '"'
  $psi.WorkingDirectory = $ScriptDir
  $psi.UseShellExecute = $false

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi

  [void]$p.Start()
  $cpid = $p.Id

  $j.Process = $p
  $j.Running = $true

  Set-ButtonState $j.Button $key 'run'
  $j.Status.ForeColor = $j.Accent
  $j.Status.Text = "● $($j.Label)：运行中 · PID $cpid"

  Write-Log "[$($j.Tag)] 已启动: powershell -NoProfile -ExecutionPolicy Bypass -File $($j.Script) (PID $cpid)" 'Cyan'
  $wfPanel.Invalidate()
}

function Finish-Job([string]$key, [bool]$stopped) {
  $j = $S[$key]

  if (-not $j.Running) { return }

  $p = $j.Process
  $code = 0

  try {
    $code = $p.ExitCode
  } catch {}

  $j.Running = $false
  $j.Process = $null

  try {
    $p.Dispose()
  } catch {}

  Set-ButtonState $j.Button $key 'idle'
  $j.Button.Enabled = $true

  if ($stopped) {
    $j.Status.ForeColor = $C.warn
    $j.Status.Text = "● $($j.Label)：已手动停止"
    Write-Log "[$($j.Tag)] 子进程树已终止" 'Yellow'
  } elseif ($code -eq 0) {
    $j.Status.ForeColor = $C.ok
    $j.Status.Text = "● $($j.Label)：运行完成"
    Write-Log "[$($j.Tag)] 子进程退出 (ExitCode=0)" 'Green'
  } else {
    $j.Status.ForeColor = $C.danger
    $j.Status.Text = "● $($j.Label)：异常退出 ($code)"
    Write-Log "[$($j.Tag)] 子进程退出 (ExitCode=$code)" 'Red'
  }

  $wfPanel.Invalidate()
}

function Stop-Job([string]$key) {
  $j = $S[$key]
  $p = $j.Process
  if (-not $p) { return }
  $cp = 0
  try { $cp = $p.Id } catch {}

  $ans = [System.Windows.Forms.MessageBox]::Show($form,
    "确定要停止创建$($j.Label)吗？`n将强制终止进程树 (PID $cp)",
    '确认停止', 'OKCancel', 'Warning', 'Button2')
  if ($ans -ne 'OK' -or -not $j.Running) { return }

  $j.Button.Enabled = $false
  $j.Button.Text = '正在停止…'
  Write-Log "[$($j.Tag)] 正在停止：taskkill /F /T /PID $cp" 'Yellow'
  Write-Log "[$($j.Tag)] $(& taskkill.exe /F /T /PID $cp 2>&1)"

  $done = $false
  try { $done = $p.WaitForExit(8000) } catch {}   # 等待子进程退出
  if (-not $done) {
    try { $p.Kill() } catch {}
    try { $p.WaitForExit(3000) } catch {}
  }
  Finish-Job $key $true
}

$btnCreate.Add_Click({ if ($S.create.Running) { Stop-Job 'create' } else { Start-Job 'create' } })
$btnPatch.Add_Click({ if ($S.patch.Running) { Stop-Job 'patch' } else { Start-Job 'patch' } })

# 关窗时清理仍在运行的子进程
$form.Add_FormClosing({
    foreach ($k in 'create', 'patch') {
      $j = $S[$k]
      if ($j.Running -and $j.Process) {
        $cp = 0; try { $cp = $j.Process.Id } catch {}
        if ($cp -gt 0) { & taskkill.exe /F /T /PID $cp }
        try { $j.Process.WaitForExit(3000) } catch {}
      }
    }
  })

# ---------------- UI 心跳：检测退出 + 步骤呼吸灯 ----------------
$glowPhase = 0.0
$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 90
$uiTimer.Add_Tick({
    $script:glowPhase += 0.16
    foreach ($k in 'create', 'patch') {
      $j = $S[$k]
      if ($j.Running -and $null -ne $j.Process) {
        $exited = $false
        try { $exited = $j.Process.HasExited } catch {}
        if ($exited) { Finish-Job $k $false }   # 脚本自然跑完也自动复原按钮
      }
    }
    if ($S.create.Running -or $S.patch.Running) { $wfPanel.Invalidate() }
  })
$uiTimer.Start()

# ---------------- 启动 ----------------
[Console]::WriteLine()
Write-Log '远程补丁工具已启动 —— 子进程日志将实时输出到本控制台' 'Cyan'
Write-Log "脚本目录: $ScriptDir" 'Gray'
[Console]::WriteLine()

[System.Windows.Forms.Application]::Run($form)

$uiTimer.Stop()
$uiTimer.Dispose()
$form.Dispose()
