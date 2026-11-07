<#
    Lichii Builds - tray app
    ------------------------
    Lives in the taskbar tray as a gradient "L" icon and runs LichiiChecker.ps1
    every 30 minutes (CheckEveryMinutes in config.json). Nothing is downloaded
    unless you say yes.

      icon dot:  none = up to date   orange = new build   blue (spinning) = working
                 red = problem       gray = couldn't reach GitHub

      left-click  -> Lichii Builds panel (what's installed, what's on GitHub, Download)
      right-click -> menu

    When a new build shows up, a card slides in at the bottom right with
    "Download & install" / "Later". It waits while a fullscreen game or app is
    up, so it never jumps in front of your game. Saying yes turns the card into
    a progress bar.

      LichiiTray.ps1 -Setup    remove the old hourly task, start with Windows, (re)start the tray app
#>
param(
    [switch]$Setup,
    [switch]$Startup,
    [switch]$Background,
    [int]$AfterPid = 0
)

$ErrorActionPreference = 'Continue'
$UiVersion    = 2
$ScriptDir    = $PSScriptRoot
$TrayScript   = $PSCommandPath
$UiDir        = Join-Path $ScriptDir 'ui'
$Checker      = Join-Path $ScriptDir 'LichiiChecker.ps1'
$ConfigPath   = Join-Path $ScriptDir 'config.json'
$StatePath    = Join-Path $ScriptDir 'state.json'
$LogPath      = Join-Path $ScriptDir 'log.txt'
$TrayPath     = Join-Path $ScriptDir 'tray.json'
$ProgressPath = Join-Path $ScriptDir 'progress.json'
$QuitFlag     = Join-Path $ScriptDir 'quit.flag'
$RestartFlag  = Join-Path $ScriptDir 'restart.flag'
$PsExe        = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Conhost      = Join-Path $env:WINDIR 'System32\conhost.exe'
$MutexName    = 'Local\LichiiCheckerTray'
$OldTaskName  = 'Lichii Build Checker'
$StartupLnk   = Join-Path ([Environment]::GetFolderPath('Startup')) 'Lichii Checker.lnk'

$VersionPath  = Join-Path $ScriptDir 'VERSION'
$AppVersion   = '0.0.0'
try { if (Test-Path -LiteralPath $VersionPath) { $AppVersion = (Get-Content -LiteralPath $VersionPath -Raw).Trim() } } catch {}

$Dot  = ' ' + [string][char]0x00B7 + ' '
$Dots = [string][char]0x2026

# ================================================================ helpers (no UI)

function Write-TrayLog([string]$Message) {
    $line = '{0} [tray] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    for ($i = 0; $i -lt 3; $i++) {
        try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 150 }
    }
}

function Test-TrayRunning {
    try { $m = [System.Threading.Mutex]::OpenExisting($MutexName); $m.Dispose(); return $true } catch { return $false }
}

function Get-LaunchArgs([string]$Extra = '-Startup') {
    # conhost --headless = no console window at all (not even a flash)
    return ('--headless "{0}" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{1}" {2}' -f $PsExe, $TrayScript, $Extra)
}

function Test-StartWithWindows { return (Test-Path -LiteralPath $StartupLnk) }

function Set-StartWithWindows([bool]$On) {
    if ($On) {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($StartupLnk)
        if (Test-Path -LiteralPath $Conhost) {
            $sc.TargetPath = $Conhost
            $sc.Arguments  = Get-LaunchArgs '-Startup'
        } else {
            $sc.TargetPath = $PsExe
            $sc.Arguments  = ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Startup' -f $TrayScript)
        }
        $sc.WorkingDirectory = $ScriptDir
        $sc.WindowStyle      = 7
        $sc.Description      = 'Lichii Builds (tray icon)'
        $sc.IconLocation     = "$PsExe,0"
        $sc.Save()
    } elseif (Test-Path -LiteralPath $StartupLnk) {
        Remove-Item -LiteralPath $StartupLnk -Force
    }
}

function Start-TrayProcess([string]$Extra = '-Background') {
    if (Test-Path -LiteralPath $Conhost) {
        Start-Process -FilePath $Conhost -ArgumentList (Get-LaunchArgs $Extra) -WorkingDirectory $ScriptDir -WindowStyle Hidden
    } else {
        Start-Process -FilePath $PsExe -WorkingDirectory $ScriptDir -WindowStyle Hidden `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" {1}' -f $TrayScript, $Extra)
    }
}

function Remove-OldHourlyTask {
    try {
        if (Get-ScheduledTask -TaskName $OldTaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $OldTaskName -Confirm:$false -ErrorAction Stop
            Write-TrayLog "Removed the old hourly scheduled task '$OldTaskName' (the tray app does the checking now)"
            return $true
        }
    } catch { Write-TrayLog "Couldn't remove the old scheduled task: $($_.Exception.Message)" }
    return $false
}

function Stop-RunningTray {
    if (-not (Test-TrayRunning)) { return $true }
    try { Set-Content -LiteralPath $QuitFlag -Value 'quit' -Encoding ASCII } catch {}
    for ($i = 0; $i -lt 10; $i++) { Start-Sleep -Milliseconds 400; if (-not (Test-TrayRunning)) { return $true } }
    # Older versions don't know about quit.flag: end them directly.
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop)) {
            if ($p.ProcessId -eq $PID) { continue }
            $cl = [string]$p.CommandLine
            if ($cl -like '*LichiiTray.ps1*' -and $cl -notlike '*-Setup*') { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        }
    } catch {}
    for ($i = 0; $i -lt 10; $i++) { Start-Sleep -Milliseconds 300; if (-not (Test-TrayRunning)) { break } }
    try { if (Test-Path -LiteralPath $QuitFlag) { Remove-Item -LiteralPath $QuitFlag -Force } } catch {}
    return (-not (Test-TrayRunning))
}

function Initialize-UiAssemblies {
    # Sharp text on high-DPI screens: must happen before any window exists.
    $script:NativeOk = $false
    try {
        if (-not ('LichiiTray.Native' -as [type])) { Add-Type -Path (Join-Path $UiDir 'Native.cs') -ErrorAction Stop }
        [LichiiTray.Native]::MakeDpiAware()
        $script:NativeOk = $true
    } catch { Write-TrayLog "Native helpers unavailable: $($_.Exception.Message)" }
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    try { Add-Type -AssemblyName WindowsFormsIntegration } catch {}
}

. (Join-Path $UiDir 'SetupWindow.ps1')

# ================================================================ -Setup ("Start Lichii Builds.bat")

if ($Setup) {
    # files from a downloaded zip are "blocked"; unblock them so Windows doesn't nag every time
    try { Get-ChildItem -LiteralPath $ScriptDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue } catch {}
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Host '  Opening setup...'
        Initialize-UiAssemblies
        if (-not (Show-SetupWindow -FirstRun)) { Write-Host '  Setup was closed, nothing changed.'; exit 0 }
    }
    Write-Host ''
    Write-Host '  Lichii Builds'
    Write-Host '  -------------'
    if (Remove-OldHourlyTask) { Write-Host '  - Removed the old hourly task (it auto-installed; this asks first).' }
    try { Set-StartWithWindows $true; Write-Host '  - Starts with Windows.' }
    catch { Write-Host "  - Couldn't add the Startup shortcut: $($_.Exception.Message)" }
    if (Test-TrayRunning) {
        if (Stop-RunningTray) { Write-Host '  - Closed the running tray app so the new version can start.' }
        else { Write-Host "  - Couldn't close the running tray app. Right-click its icon > Exit, then run this again."; exit 1 }
    }
    Start-TrayProcess '-Background'
    Write-Host '  - Started. Click the "L" icon by the clock.'
    Write-TrayLog 'Setup done'
    exit 0
}

# ================================================================ start-up

if ($AfterPid -gt 0) {   # restarting: let the old copy exit first
    try { Wait-Process -Id $AfterPid -Timeout 15 -ErrorAction SilentlyContinue } catch {}
}

Initialize-UiAssemblies
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::EnableVisualStyles()

try {
    $gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    Write-TrayLog ('Screen scale {0}%, tray icon {1}px' -f [int]($gfx.DpiX / 96 * 100), [System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
    $gfx.Dispose()
} catch {}

$createdNew = $false
$TrayMutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
if (-not $createdNew) {
    if (-not $Startup -and -not $Background) {
        [void][System.Windows.Forms.MessageBox]::Show('Lichii Builds is already running. Click the "L" icon by the clock (or the ^ arrow if it is hidden).', 'Lichii Builds')
    }
    exit 0
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    if (-not (Show-SetupWindow -FirstRun)) { Write-TrayLog 'Setup closed without saving; not starting.'; exit 0 }
}
foreach ($f in @($QuitFlag, $RestartFlag)) { try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } } catch {} }

[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Write-TrayLog "Error: $($e.Exception.Message)"
})

$script:DarkMenuOk = $false
try {
    Add-Type -Path (Join-Path $UiDir 'DarkMenu.cs') -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
    $script:DarkMenuOk = $true
} catch { Write-TrayLog "Dark menu unavailable, using the plain one: $($_.Exception.Message)" }

function Test-UserFree {
    # Only pop the new-build card when no fullscreen game/app is up (5 = nothing fullscreen, 6 = quiet time)
    if (-not $script:NativeOk) { return $true }
    $s = [LichiiTray.Native]::NotificationState()
    return ($s -eq 5 -or $s -eq 6)
}

# ================================================================ tray icon (drawn at the real tray size)

$Palette = @{
    Green  = '#6CCB5F'; GreenBg  = '#2A6CCB5F'
    Orange = '#FFB454'; OrangeBg = '#2AFFB454'
    Blue   = '#60CDFF'; BlueBg   = '#2A60CDFF'
    Red    = '#FF99A4'; RedBg    = '#2AFF99A4'
    Gray   = '#ABABAB'; GrayBg   = '#1AFFFFFF'
    Text   = '#F2F2F2'
}

function New-RoundRect([System.Drawing.RectangleF]$R, [single]$Radius) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $p.AddArc($R.X, $R.Y, $d, $d, 180, 90)
    $p.AddArc($R.Right - $d, $R.Y, $d, $d, 270, 90)
    $p.AddArc($R.Right - $d, $R.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($R.X, $R.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-TrayIcon([string]$BadgeHex = '', [int]$Spin = -1) {
    $sz = 16
    try { $sz = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width } catch {}
    if ($sz -lt 16) { $sz = 16 }
    $bmp = New-Object System.Drawing.Bitmap($sz, $sz, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # gradient rounded square
    $m = [single][math]::Max(0.5, $sz * 0.03)
    $box = New-Object System.Drawing.RectangleF($m, $m, ([single]($sz - 2 * $m)), ([single]($sz - 2 * $m)))
    $path = New-RoundRect $box ([single]($box.Width * 0.26))
    $c1 = [System.Drawing.Color]::FromArgb(255, 139, 108, 255)
    $c2 = [System.Drawing.Color]::FromArgb(255, 44, 198, 240)
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($box, $c1, $c2, [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal)
    $g.FillPath($lg, $path)

    # white "L", centered
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $ff = New-Object System.Drawing.FontFamily('Segoe UI')
    $gp.AddString('L', $ff, [int][System.Drawing.FontStyle]::Bold, [single]($sz * 0.72), (New-Object System.Drawing.PointF(0, 0)), [System.Drawing.StringFormat]::GenericTypographic)
    $b = $gp.GetBounds()
    $mx = New-Object System.Drawing.Drawing2D.Matrix
    $mx.Translate([single](($sz - $b.Width) / 2 - $b.X + $sz * 0.02), [single](($sz - $b.Height) / 2 - $b.Y))
    $gp.Transform($mx)
    $g.FillPath([System.Drawing.Brushes]::White, $gp)

    # status dot, bottom-right, with a dark ring so it reads on any taskbar
    if ($BadgeHex) {
        $d = [single]($sz * 0.44)
        $ring = [single][math]::Max(1.0, $sz * 0.07)
        $x = [single]($sz - $d - $ring * 0.6)
        $y = [single]($sz - $d - $ring * 0.6)
        $rb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 30, 30, 30))
        $g.FillEllipse($rb, [single]($x - $ring), [single]($y - $ring), [single]($d + 2 * $ring), [single]($d + 2 * $ring))
        $cb = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($BadgeHex))
        $g.FillEllipse($cb, $x, $y, $d, $d)
        if ($Spin -ge 0) {
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 20, 40, 60), [single][math]::Max(1.0, $sz * 0.065))
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $in = [single]($d * 0.24)
            $g.DrawArc($pen, [single]($x + $in), [single]($y + $in), [single]($d - 2 * $in), [single]($d - 2 * $in), [single]($Spin * 30), [single]250)
            $pen.Dispose()
        }
        $rb.Dispose(); $cb.Dispose()
    }
    $g.Dispose(); $lg.Dispose(); $path.Dispose(); $gp.Dispose(); $ff.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$Icons = @{
    ok      = New-TrayIcon ''
    new     = New-TrayIcon '#FFB454'
    bad     = New-TrayIcon '#FF6B6B'
    offline = New-TrayIcon '#9A9A9A'
    spin    = @(0..11 | ForEach-Object { New-TrayIcon '#60CDFF' $_ })
}

# ================================================================ settings / config / state

function Read-TraySettings {
    if (Test-Path -LiteralPath $TrayPath) {
        try { return (Get-Content -LiteralPath $TrayPath -Raw | ConvertFrom-Json) } catch {}
    }
    return (New-Object psobject)
}
function Get-TrayValue([string]$Key) {
    $p = $script:TraySet.PSObject.Properties[$Key]
    if ($p) { return $p.Value }
    return $null
}
function Set-TrayValue([string]$Key, $Value) {
    if ($script:TraySet.PSObject.Properties[$Key]) { $script:TraySet.$Key = $Value }
    else { $script:TraySet | Add-Member -NotePropertyName $Key -NotePropertyValue $Value }
    try { $script:TraySet | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $TrayPath -Encoding UTF8 } catch {}
}

function Resolve-Setting([string]$Value) {
    if (-not $Value) { return $null }
    $v = $Value.Replace('%DESKTOP%', [Environment]::GetFolderPath('Desktop'))
    $v = [Environment]::ExpandEnvironmentVariables($v)
    if (-not [IO.Path]::IsPathRooted($v)) { $v = Join-Path $ScriptDir $v }
    return [IO.Path]::GetFullPath($v)
}

function Read-Config {
    try { $c = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }
    catch { Write-TrayLog "config.json unreadable: $($_.Exception.Message)"; return }
    $script:Interval = 30
    $m = 0
    try { $m = [int]$c.CheckEveryMinutes } catch {}
    if ($m -ge 5) { $script:Interval = $m }
    $list = @()
    foreach ($s in @($c.Sources)) {
        if ($null -eq $s -or $s.Enabled -eq $false) { continue }
        $label = [string]$s.Label
        if (-not $label) { $label = [string]$s.Name }
        $list += [pscustomobject]@{ Name = [string]$s.Name; Label = $label; Repo = [string]$s.Repo; Folder = (Resolve-Setting $s.InstallFolder) }
    }
    $script:Sources = $list
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath)) { $script:State = New-Object psobject; return }
    try {
        $script:State = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        $script:StateStamp = (Get-Item -LiteralPath $StatePath).LastWriteTimeUtc
    } catch { Write-TrayLog "state.json unreadable right now: $($_.Exception.Message)" }
}

function Get-S([string]$Name, [string]$Field) {
    if ($null -eq $script:State) { return $null }
    $s = $script:State.PSObject.Properties[$Name]
    if (-not $s -or $null -eq $s.Value) { return $null }
    $p = $s.Value.PSObject.Properties[$Field]
    if ($p) { return $p.Value }
    return $null
}

function Get-Label([string]$Name) {
    if ($Name -eq '_app') { return 'Lichii Builds' }
    foreach ($s in $script:Sources) { if ($s.Name -eq $Name) { return $s.Label } }
    return $Name
}

function Get-Updates {
    return @($script:Sources | Where-Object { (Get-S $_.Name 'UpdateAvailable') -eq $true -and (Get-S $_.Name 'LatestTag') })
}

function Format-When($Value, [string]$Fmt = 'MMM d, h:mm tt') {
    if (-not $Value) { return '' }
    try {
        if ($Value -is [datetime]) {
            if ($Value.Kind -eq [DateTimeKind]::Utc) { return $Value.ToLocalTime().ToString($Fmt) }
            return $Value.ToString($Fmt)
        }
        return ([DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime.ToString($Fmt)
    } catch { return [string]$Value }
}

# "Lichii nx2 build 93 (09b78bd)" -> "Build 93 (09b78bd)";  "Frizti v3" stays "Frizti v3"
function Format-Version([string]$Title) {
    if (-not $Title) { return '' }
    $v = ($Title -replace '^(?i)lichii\s+', '') -replace '^(?i)nx2\s+', ''
    if ($v.Length -gt 0) { $v = $v.Substring(0, 1).ToUpper() + $v.Substring(1) }
    return $v
}
# "Frizti v4" / "Main build 95"
function Get-Nice([string]$Name, [string]$Title) {
    $label = Get-Label $Name
    if ($Title -like 'Test build *') { return ('{0} test build {1}' -f $label, ($Title -replace '^Test build\s*', '')) }
    $raw = ($Title -replace '^(?i)lichii\s+', '') -replace '^(?i)nx2\s+', ''
    $raw = ($raw -replace '\s*\([0-9a-f]{6,}\)\s*$', '').Trim()
    if ($raw -match ('^(?i)' + [regex]::Escape($label) + '\b')) { return $raw }
    return ('{0} {1}' -f $label, $raw).Trim()
}

# ================================================================ running the checker

function Start-Checker([string[]]$CheckerArgs, [string]$Kind, [string]$Name, [string]$BusyText) {
    if ($script:Proc) { return $false }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Quiet -NoNotify {1}' -f $Checker, ($CheckerArgs -join ' ')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PsExe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $ScriptDir
    try { $script:Proc = [System.Diagnostics.Process]::Start($psi) }
    catch { Write-TrayLog "Couldn't start the checker: $($_.Exception.Message)"; $script:Proc = $null; return $false }
    $script:ProcKind = $Kind
    $script:ProcName = $Name
    $script:ProcStart = Get-Date
    $script:Busy = $true
    $script:BusyText = $BusyText
    $script:Fast.Start()
    Update-Look
    Update-Flyout
    return $true
}

function Start-Check([switch]$Manual) {
    $script:NextCheck = (Get-Date).AddMinutes($script:Interval)
    if ($script:Proc) { return }
    $script:ManualCheck = [bool]$Manual
    [void](Start-Checker @() 'check' $null ('Checking GitHub' + $Dots))
}

function Start-Install([string]$Name) {
    if ($script:Proc) { $script:QueuedInstall = $Name; return }
    $nice = Get-Nice $Name (Get-S $Name 'LatestTitle')
    Write-TrayLog "Installing $nice (you said yes)"
    [void](Start-Checker @('-InstallSource', $Name) 'install' $Name ("Installing {0}{1}" -f $nice, $Dots))
}

function Confirm-Install([string]$Name) {
    Set-TrayValue "Prompted_$Name" (Get-S $Name 'LatestTag')
    $script:Pending = @($script:Pending | Where-Object { $_ -ne $Name })
    Start-Install $Name
    if (-not ($script:Flyout -and $script:Flyout.IsVisible)) { Show-ProgressToast $Name }
}

function Get-AppInfo { return (Get-Prop2 $script:State '_app') }
function Get-Prop2($o, [string]$n) { if ($null -eq $o) { return $null }; $p = $o.PSObject.Properties[$n]; if ($p) { return $p.Value }; return $null }
function Test-AppUpdate { $a = Get-AppInfo; return [bool]($a -and $a.UpdateAvailable -eq $true -and $a.LatestVersion) }

function Start-AppUpdate {
    if ($script:Proc) { Show-Balloonless 'Busy right now, try again in a moment.'; return }
    $v = (Get-AppInfo).LatestVersion
    Set-TrayValue 'Prompted__app' $v
    $script:Pending = @($script:Pending | Where-Object { $_ -ne '_app' })
    Write-TrayLog "Updating Lichii Builds to $v (you said yes)"
    [void](Show-Toast @{ Kind = 'progress'; Source = '_app'; Kicker = 'UPDATING'; Title = "Updating Lichii Builds to $v"
                         Body = 'Takes a few seconds. Your settings stay as they are.'; Color = $Palette.Blue; AutoHide = 0 })
    [void](Start-Checker @('-UpdateApp') 'appupdate' '_app' ("Updating Lichii Builds" + $Dots))
}
function Show-Balloonless([string]$Text) {
    [void](Show-Toast @{ Kind = 'info'; Kicker = 'LICHII BUILDS'; Title = $Text; Color = $Palette.Gray; AutoHide = 5 })
}

function Show-AppUpdateToast {
    $a = Get-AppInfo
    Set-TrayValue 'Prompted__app' $a.LatestVersion
    $notes = (([string]$a.Notes) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' '
    if (-not $notes) { $notes = 'Fixes and improvements.' }
    [void](Show-Toast @{ Kind = 'update'; Source = '_app'; Kicker = 'APP UPDATE'; Title = "Lichii Builds $($a.LatestVersion) is out"
                         Body = $notes; Meta = "You have $AppVersion. One click, a few seconds, settings kept."
                         Primary = 'Update now'; OnPrimary = 'appupdate'; Secondary = 'Later'; OnSecondary = 'later'
                         Color = $Palette.Blue; AutoHide = 0 })
}

function Find-NewBuilds {
    if ((Test-AppUpdate) -and (Get-TrayValue 'Prompted__app') -ne (Get-AppInfo).LatestVersion -and $script:Pending -notcontains '_app') {
        $script:Pending = @('_app') + @($script:Pending)
    }
    foreach ($s in $script:Sources) {
        if ((Get-S $s.Name 'UpdateAvailable') -ne $true) { continue }
        $tag = Get-S $s.Name 'LatestTag'
        if (-not $tag) { continue }
        if ((Get-TrayValue "Prompted_$($s.Name)") -ne $tag -and $script:Pending -notcontains $s.Name) {
            $script:Pending = @($script:Pending) + $s.Name
        }
        if ((Get-TrayValue "Alerted_$($s.Name)") -ne $tag) {
            Set-TrayValue "Alerted_$($s.Name)" $tag
            Write-TrayLog ("New build: {0} ({1})" -f (Get-Nice $s.Name (Get-S $s.Name 'LatestTitle')), $tag)
        }
    }
}

function Get-Progress {
    if (-not (Test-Path -LiteralPath $ProgressPath)) { return $null }
    try { $p = [IO.File]::ReadAllText($ProgressPath) | ConvertFrom-Json } catch { return $null }
    $phase = [string]$p.Phase
    $done = [double]$p.Done; $total = [double]$p.Total
    $pct = 100; $text = ''; $label = $phase
    switch ($phase) {
        'Downloading' {
            $pct = 0
            if ($total -gt 0) { $pct = [math]::Min(100, [math]::Round(100.0 * $done / $total)) }
            $label = 'Downloading' + $Dots
            if ($total -gt 0) { $text = '{0:0.0} / {1:0.0} MB' -f ($done / 1MB), ($total / 1MB) }
        }
        'Verifying'  { $label = 'Checking the download' + $Dots }
        'Unpacking'  { $label = 'Unpacking' + $Dots }
        'Installing' { $label = 'Swapping in the new build' + $Dots }
    }
    return [pscustomobject]@{ Source = [string]$p.Source; Phase = $phase; Pct = [int]$pct; Label = $label; Text = $text }
}

function Complete-Child([string]$Kind, [string]$Name, [int]$Code) {
    Read-Config
    Read-State
    if ($Kind -eq 'check') {
        if ($Code -ne 0 -and $Code -ne 2) { Write-TrayLog "The checker stopped with code $Code (see the lines above)" }
        $script:LastCheck = Get-Date
        $script:ConfigProblem = ($Code -eq 2)
        $results = @($script:Sources | ForEach-Object { [string](Get-S $_.Name 'LastResult') })
        if ($results.Count -gt 0 -and @($results | Where-Object { $_ -like "couldn't reach*" }).Count -eq $results.Count) {
            $script:NextCheck = (Get-Date).AddMinutes(5)   # probably offline (e.g. right after boot): retry soon
        }
        Find-NewBuilds
        foreach ($src in $script:Sources) {   # a repo was renamed/moved on GitHub: say so once
            $mv = [string](Get-S $src.Name 'RepoMoved')
            if ($mv -and (Get-TrayValue "MoveSeen_$($src.Name)") -ne $mv) {
                Set-TrayValue "MoveSeen_$($src.Name)" $mv
                Write-TrayLog "Repo moved: $mv"
                Show-Toast @{ Kind = 'info'; Kicker = 'REPO MOVED'; Title = "$($src.Label) has a new home on GitHub"
                              Body = ($mv -replace ' -> ', ' is now ') + '.'; Meta = 'Updated automatically. Nothing to do.'
                              Color = $Palette.Blue; AutoHide = 30 }
            }
        }
        if ($script:ManualCheck -and -not ($script:Flyout -and $script:Flyout.IsVisible)) {
            if (@(Get-Updates).Count -eq 0 -and -not $script:ConfigProblem) {
                $have = ($script:Sources | ForEach-Object { Get-Nice $_.Name (Get-S $_.Name 'Title') }) -join $Dot
                Show-Toast @{ Kind = 'info'; Kicker = 'UP TO DATE'; Title = "You're on the latest builds"; Body = $have; Color = $Palette.Green; AutoHide = 6 }
            }
        }
        $script:ManualCheck = $false
    } elseif ($Kind -eq 'appupdate') {
        if ($Code -ne 0) {
            Show-Toast @{ Kind = 'error'; Source = '_app'; Kicker = 'UPDATE FAILED'; Title = "Lichii Builds didn't update"
                          Body = 'Nothing was changed. The log says why.'; Primary = 'Open log'; OnPrimary = 'openlog'; Secondary = 'Dismiss'; OnSecondary = 'dismiss'
                          Color = $Palette.Red; AutoHide = 25 }
        }   # on success the checker leaves restart.flag; the next tick restarts into the new version
    } else {
        $nice = Get-Nice $Name (Get-S $Name 'LatestTitle')
        if ($Code -eq 0) {
            Write-TrayLog "Installed $nice"
            $meta = 'Saves, mods and shader cache were not touched.'
            $body = 'The old build is in ARCHIVE.'
            if (-not (Get-S $Name 'ArchivedTo')) { $body = 'Fresh install.' }
            Show-Toast @{ Kind = 'done'; Source = $Name; Kicker = 'INSTALLED'; Title = "$nice is ready"; Body = $body; Meta = $meta
                          Primary = 'Open folder'; OnPrimary = 'openfolder'; Color = $Palette.Green; AutoHide = 12 }
        } elseif ($Code -eq 3) {
            Show-Toast @{ Kind = 'blocked'; Source = $Name; Kicker = 'CLOSE LICHII FIRST'; Title = 'Lichii is still running'
                          Body = "$nice can't go in while Lichii is running from that folder. Quit the game from the in-game options, close Lichii, then hit Retry."
                          Primary = 'Retry'; OnPrimary = 'retry'; Secondary = 'Cancel'; OnSecondary = 'dismiss'; Color = $Palette.Orange; AutoHide = 0 }
        } else {
            $why = [string](Get-S $Name 'LastResult')
            if (-not $why) { $why = "the checker stopped with code $Code" }
            Write-TrayLog "Install of $nice failed: $why"
            Show-Toast @{ Kind = 'error'; Source = $Name; Kicker = 'UPDATE FAILED'; Title = "$nice didn't install"; Body = $why
                          Meta = "Your current build wasn't changed."; Primary = 'Open log'; OnPrimary = 'openlog'; Secondary = 'Dismiss'; OnSecondary = 'dismiss'
                          Color = $Palette.Red; AutoHide = 25 }
        }
    }
    Update-Look
    Update-Flyout
}

# ================================================================ WPF helpers

function Read-Xaml([string]$File) {
    return [System.Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $UiDir $File)))
}
function New-UiWindow([string]$File) {
    $w = Read-Xaml $File
    $w.Resources.MergedDictionaries.Add((Read-Xaml 'Theme.xaml'))
    return $w
}
function New-Brush([string]$Hex) {
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze()
    return $b
}
function Get-WorkArea { return [System.Windows.SystemParameters]::WorkArea }

function Start-Anim($Target, $Prop, [double]$From, [double]$To, [int]$Ms) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = $From
    $a.To = $To
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($Ms))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $a.EasingFunction = $ease
    $a.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
    $Target.SetValue($Prop, $To)          # where it ends up once the animation is done
    $Target.BeginAnimation($Prop, $a)
}

function Open-Url([string]$Url) { if ($Url) { try { Start-Process $Url } catch {} } }
function Open-Log { try { Start-Process notepad.exe ('"{0}"' -f $LogPath) } catch {} }
function Get-BuildsRoot {
    if ($script:Sources.Count -gt 0 -and $script:Sources[0].Folder) { return (Split-Path -Parent $script:Sources[0].Folder) }
    return $ScriptDir
}
function Open-Folder([string]$Path) {
    if (-not $Path) { $Path = Get-BuildsRoot }
    if (-not (Test-Path -LiteralPath $Path)) { $Path = Split-Path -Parent $Path }
    try { Start-Process explorer.exe ('"{0}"' -f $Path) } catch {}
}

# ================================================================ status (shared by panel, icon, tooltip)

function Get-Summary {
    $ups = @(Get-Updates)
    $results = @($script:Sources | ForEach-Object { [string](Get-S $_.Name 'LastResult') })
    $failed = @($results | Where-Object { $_ -like 'install failed*' }).Count -gt 0
    $offline = ($results.Count -gt 0) -and (@($results | Where-Object { $_ -like "couldn't reach*" }).Count -eq $results.Count)
    if ($script:Busy -and $script:ProcKind -eq 'appupdate') { return @{ Text = 'Updating'; Fg = $Palette.Blue; Bg = $Palette.BlueBg; Icon = 'spin' } }
    if ($script:Busy -and $script:ProcKind -eq 'install') { return @{ Text = 'Installing'; Fg = $Palette.Blue; Bg = $Palette.BlueBg; Icon = 'spin' } }
    if ($script:Busy) { return @{ Text = 'Checking'; Fg = $Palette.Blue; Bg = $Palette.BlueBg; Icon = 'spin' } }
    if ($script:ConfigProblem) { return @{ Text = 'Problem'; Fg = $Palette.Red; Bg = $Palette.RedBg; Icon = 'bad' } }
    if ($ups.Count -eq 0 -and (Test-AppUpdate)) { return @{ Text = 'App update'; Fg = $Palette.Blue; Bg = $Palette.BlueBg; Icon = 'new' } }
    if ($ups.Count -eq 1) { return @{ Text = '1 update'; Fg = $Palette.Orange; Bg = $Palette.OrangeBg; Icon = 'new' } }
    if ($ups.Count -gt 1) { return @{ Text = "$($ups.Count) updates"; Fg = $Palette.Orange; Bg = $Palette.OrangeBg; Icon = 'new' } }
    if ($failed) { return @{ Text = 'Problem'; Fg = $Palette.Red; Bg = $Palette.RedBg; Icon = 'bad' } }
    if ($offline) { return @{ Text = 'Offline'; Fg = $Palette.Gray; Bg = $Palette.GrayBg; Icon = 'offline' } }
    if (-not $script:LastCheck) { return @{ Text = 'Starting'; Fg = $Palette.Gray; Bg = $Palette.GrayBg; Icon = 'ok' } }
    return @{ Text = 'Up to date'; Fg = $Palette.Green; Bg = $Palette.GreenBg; Icon = 'ok' }
}

function Get-SubLine {
    if ($script:Busy) {
        $p = $null
        if ($script:ProcKind -eq 'install') { $p = Get-Progress }
        if ($p -and $p.Phase -eq 'Downloading') { return ('{0}{1}{2}%' -f $script:BusyText, $Dot, $p.Pct) }
        return $script:BusyText
    }
    if (-not $script:LastCheck) { return 'First check in a moment' }
    return ('Checked {0}{1}next at {2}' -f $script:LastCheck.ToString('h:mm tt'), $Dot, $script:NextCheck.ToString('h:mm tt'))
}

function Update-Look {
    $sum = Get-Summary
    if (-not $script:Busy) {
        $script:Fast.Stop()
        $script:Tray.Icon = $Icons[$sum.Icon]
    }
    $tip = 'Lichii Builds: ' + $sum.Text.ToLower()
    $ups = @(Get-Updates)
    if (-not $script:Busy -and $ups.Count -gt 0) {
        $tip = 'Lichii Builds: new ' + (($ups | ForEach-Object { Get-Nice $_.Name (Get-S $_.Name 'LatestTitle') }) -join ', ')
    }
    if ($script:Busy) { $tip = 'Lichii Builds: ' + ($script:BusyText -replace [regex]::Escape($Dots), '...') }
    elseif ($script:LastCheck) { $tip += ' (checked ' + $script:LastCheck.ToString('h:mm tt') + ')' }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + '...' }
    $script:Tray.Text = $tip
}

# ================================================================ the panel (left-click)

function Get-CardTokens($Src) {
    $n = $Src.Name
    $tag = Get-S $n 'Tag'
    $title = Get-S $n 'Title'
    $lt = Get-S $n 'LatestTag'
    $ltitle = Get-S $n 'LatestTitle'
    $upd = ((Get-S $n 'UpdateAvailable') -eq $true) -and $lt
    $res = [string](Get-S $n 'LastResult')
    $installing = [bool]($script:Proc -and $script:ProcKind -eq 'install' -and $script:ProcName -eq $n)
    $size = Get-S $n 'LatestSizeMB'

    if ($installing)                     { $badge = 'Installing';    $bfg = $Palette.Blue;   $bbg = $Palette.BlueBg }
    elseif ($res -like 'install failed*') { $badge = 'Failed';       $bfg = $Palette.Red;    $bbg = $Palette.RedBg }
    elseif ($res -like 'waiting*')        { $badge = 'Waiting';      $bfg = $Palette.Orange; $bbg = $Palette.OrangeBg }
    elseif ($upd)                         { $badge = 'Update';       $bfg = $Palette.Orange; $bbg = $Palette.OrangeBg }
    elseif (-not $tag)                    { $badge = 'Not installed'; $bfg = $Palette.Gray;  $bbg = $Palette.GrayBg }
    elseif ($res -like "couldn't reach*") { $badge = 'Offline';      $bfg = $Palette.Gray;   $bbg = $Palette.GrayBg }
    else                                  { $badge = 'Latest';       $bfg = $Palette.Green;  $bbg = $Palette.GreenBg }

    $inst = Format-Version $title
    if (-not $inst) { $inst = 'Nothing yet' }
    $instSub = ''
    $at = Format-When (Get-S $n 'InstalledAt')
    if ($at) { $instSub = "Installed $at" }

    $latest = Format-Version $ltitle
    if (-not $latest) { $latest = 'Not checked yet' }
    $latestSub = ''
    $rel = Format-When (Get-S $n 'LatestPublishedAt')
    if ((Get-S $n 'LatestIsTest') -eq $true) {
        $latestSub = 'Test' + $Dot + [string](Get-S $n 'LatestBranch')
        if ($rel) { $latestSub += $Dot + $rel }
    } elseif ($rel) { $latestSub = "Released $rel" }

    $note = ''; $noteFg = $Palette.Gray; $noteBg = '#0FFFFFFF'; $glyph = [string][char]0xE946
    if ($res -like 'install failed*') {
        $note = 'Last install failed: ' + ($res -replace '^install failed:\s*', '') + " Your build wasn't changed."
        $noteFg = $Palette.Red; $noteBg = '#14FF99A4'; $glyph = [string][char]0xE7BA
    } elseif ($res -like '*running from the old folder*') {
        $note = 'Lichii is running from the old folder. Close it and this build moves to Other builds on the next check.'
        $noteFg = $Palette.Orange; $noteBg = '#14FFB454'
    } elseif ($res -like 'waiting*') {
        $note = 'Close Lichii to install this build.'
        $noteFg = $Palette.Orange; $noteBg = '#14FFB454'
    } elseif ($res -like "couldn't reach*") {
        $note = "Couldn't reach GitHub on the last check. It'll try again soon."
    }

    $dl = 'Download'
    if ((Get-S $n 'LatestIsTest') -eq $true) { $dl = 'Download test build' }
    if ($size) { $dl = $dl + $Dot + $size + ' MB' }

    $phase = 'Starting' + $Dots; $pct = ''; $pctVal = 0
    if ($installing) {
        $p = Get-Progress
        if ($p -and $p.Source -eq $n) {
            $phase = $p.Label; $pctVal = $p.Pct
            if ($p.Phase -eq 'Downloading') { $pct = '{0}%' -f $p.Pct; if ($p.Text) { $pct = $p.Text + $Dot + $pct } }
        }
    }

    $vis = 'Visible'; $col = 'Collapsed'
    return @{
        LABEL = $Src.Label; REPO = $Src.Repo
        BADGE = $badge; BADGEFG = $bfg; BADGEBG = $bbg
        INST = $inst; INSTSUB = $instSub
        LATEST = $latest; LATESTFG = $(if ($upd) { $Palette.Orange } else { $Palette.Text }); LATESTSUB = $latestSub
        NOTE = $note; NOTEFG = $noteFg; NOTEBG = $noteBg; NOTEGLYPH = $glyph; NOTEVIS = $(if ($note) { $vis } else { $col })
        ACTVIS = $(if ($upd -and -not $installing) { $vis } else { $col }); DLTEXT = $dl
        NOTESVIS = $(if (Get-S $n 'LatestUrl') { $vis } else { $col })
        PROGVIS = $(if ($installing) { $vis } else { $col }); PHASE = $phase; PCT = $pct; PCTVAL = [string]$pctVal
    }
}

function New-Card([hashtable]$Tokens) {
    $x = $script:CardXaml
    foreach ($k in $Tokens.Keys) { $x = $x.Replace("@@$k@@", [Security.SecurityElement]::Escape([string]$Tokens[$k])) }
    return [System.Windows.Markup.XamlReader]::Parse($x)
}

function New-Flyout {
    $w = New-UiWindow 'Flyout.xaml'
    $script:F = @{}
    foreach ($n in 'SubLine', 'Pill', 'PillDot', 'PillText', 'Cards', 'BtnCheck', 'CheckGlyph', 'BtnFolder', 'FolderLabel', 'BtnLog', 'BtnMore', 'BtnSettings', 'AppBanner', 'AppBannerTitle', 'AppBannerText', 'BtnAppUpdate') {
        $script:F[$n] = $w.FindName($n)
    }
    $script:F.BtnCheck.Add_Click({ try { Start-Check -Manual } catch { Write-TrayLog "Check: $($_.Exception.Message)" } })
    $script:F.BtnFolder.Add_Click({ Hide-Flyout; Open-Folder $null })
    $script:F.BtnLog.Add_Click({ Hide-Flyout; Open-Log })
    $script:F.BtnMore.Add_Click({ Hide-Flyout; Show-TrayMenu })
    $script:F.BtnSettings.Add_Click({ Open-Settings })
    $script:F.BtnAppUpdate.Add_Click({ Hide-Flyout; Start-AppUpdate })
    $w.Add_Deactivated({ Hide-Flyout })
    $w.Add_KeyDown({ param($s, $e) if ($e.Key -eq [System.Windows.Input.Key]::Escape) { Hide-Flyout } })
    try { [System.Windows.Forms.Integration.ElementHost]::EnableModelessKeyboardInterop($w) } catch {}
    $script:F.FolderLabel.Text = Split-Path -Leaf (Get-BuildsRoot)
    $script:Flyout = $w
}

function Set-Spin([bool]$On) {
    try {
        $rt = $script:F.CheckGlyph.RenderTransform
        if ($On -and -not $script:Spinning) {
            $a = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 360, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(900))))
            $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $rt.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $a)
            $script:Spinning = $true
        } elseif (-not $On -and $script:Spinning) {
            $rt.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
            $script:Spinning = $false
        }
    } catch {}
}

function Update-Flyout([switch]$Force) {
    if (-not $script:Flyout) { return }
    if (-not $Force -and -not $script:Flyout.IsVisible) { return }
    try {
        $F = $script:F
        $sum = Get-Summary
        $F.PillText.Text = $sum.Text
        $F.PillText.Foreground = New-Brush $sum.Fg
        $F.PillDot.Fill = New-Brush $sum.Fg
        $F.Pill.Background = New-Brush $sum.Bg
        $F.SubLine.Text = Get-SubLine
        if (Test-AppUpdate) {
            $a = Get-AppInfo
            $F.AppBanner.Visibility = 'Visible'
            $F.AppBannerTitle.Text = "Lichii Builds $($a.LatestVersion) is out"
            $F.AppBannerText.Text = "You have $AppVersion. One click, settings kept."
            $F.BtnAppUpdate.IsEnabled = -not $script:Proc
        } else { $F.AppBanner.Visibility = 'Collapsed' }
        $F.Cards.Children.Clear()
        $script:CardRefs = @{}
        foreach ($src in $script:Sources) {
            $card = New-Card (Get-CardTokens $src)
            $dl = $card.FindName('BtnDownload')
            if ($dl) {
                $dl.Tag = $src.Name
                $dl.IsEnabled = -not $script:Proc
                $dl.Add_Click({ param($s, $e) try { Confirm-Install ([string]$s.Tag) } catch { Write-TrayLog "Download: $($_.Exception.Message)" } })
            }
            $nb = $card.FindName('BtnNotes')
            if ($nb) { $nb.Tag = [string](Get-S $src.Name 'LatestUrl'); $nb.Add_Click({ param($s, $e) Open-Url ([string]$s.Tag) }) }
            $script:CardRefs[$src.Name] = @{ Bar = $card.FindName('Bar'); Phase = $card.FindName('Phase'); Pct = $card.FindName('Pct') }
            [void]$F.Cards.Children.Add($card)
        }
        $F.BtnCheck.IsEnabled = -not $script:Proc
        Set-Spin ([bool]$script:Busy)
        $script:FlyoutDirty = $false
    } catch { Write-TrayLog "Panel: $($_.Exception.Message)" }
}

function Show-Flyout {
    try {
        if ($script:Flyout -and $script:Flyout.IsVisible) { Hide-Flyout; return }
        if (((Get-Date) - $script:FlyoutHiddenAt).TotalMilliseconds -lt 350) { return }   # the click that just closed it
        if (-not $script:Flyout) { New-Flyout }
        if ($script:ToastSpec) { Hide-Toast }     # same corner: the panel shows the same info
        $w = $script:Flyout
        $wa = Get-WorkArea
        $w.Opacity = 0
        $w.Left = $wa.Right - $w.Width
        $w.Top = $wa.Bottom - 300
        $w.Show()
        Update-Flyout
        $w.UpdateLayout()
        $top = $wa.Bottom - $w.ActualHeight
        Start-Anim $w ([System.Windows.Window]::TopProperty) ($top + 18) $top 220
        Start-Anim $w ([System.Windows.UIElement]::OpacityProperty) 0 1 160
        [void]$w.Activate()
        if ($script:NativeOk) {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper $w).Handle
            [void][LichiiTray.Native]::SetForegroundWindow($h)
        }
    } catch {
        Write-TrayLog "Panel: $($_.Exception.Message)"
        Show-FallbackStatus
    }
}

function Hide-Flyout {
    try {
        if ($script:Flyout -and $script:Flyout.IsVisible) {
            $script:Flyout.Hide()
            $script:FlyoutHiddenAt = Get-Date
            Set-Spin $false
        }
    } catch {}
}

function Update-Progress {
    $p = Get-Progress
    if (-not $p) { return }
    if ($script:Flyout -and $script:Flyout.IsVisible) {
        try {
            $F = $script:F
            $F.SubLine.Text = Get-SubLine
            $r = $script:CardRefs[$p.Source]
            if ($r -and $r.Bar) {
                $r.Bar.Value = $p.Pct
                $r.Phase.Text = $p.Label
                $t = ''
                if ($p.Phase -eq 'Downloading') { $t = '{0}%' -f $p.Pct; if ($p.Text) { $t = $p.Text + $Dot + $t } }
                $r.Pct.Text = $t
            }
        } catch {}
    }
    if ($script:ToastSpec -and $script:ToastSpec.Kind -eq 'progress' -and $script:ToastWin.IsVisible) {
        try {
            $E = $script:ToastEl
            $E.Bar.Value = $p.Pct
            $E.PhaseText.Text = $p.Label
            $t = ''
            if ($p.Phase -eq 'Downloading') { $t = '{0}%' -f $p.Pct; if ($p.Text) { $t = $p.Text + $Dot + $t } }
            $E.PctText.Text = $t
        } catch {}
    }
    $tip = 'Lichii Builds: ' + ($script:BusyText -replace [regex]::Escape($Dots), '')
    if ($p.Phase -eq 'Downloading') { $tip += " $($p.Pct)%" }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + '...' }
    $script:Tray.Text = $tip
}

# ================================================================ the slide-in card (toast)

function New-Toast {
    $w = New-UiWindow 'Toast.xaml'
    $T = @{}
    foreach ($n in 'Strip', 'Kicker', 'TitleText', 'BodyText', 'MetaText', 'ProgressPanel', 'PhaseText', 'PctText', 'Bar', 'Buttons', 'Primary', 'Secondary', 'CloseBtn') {
        $T[$n] = $w.FindName($n)
    }
    $T.Primary.Add_Click({ Invoke-ToastAction 'primary' })
    $T.Secondary.Add_Click({ Invoke-ToastAction 'secondary' })
    $T.CloseBtn.Add_Click({ Invoke-ToastAction 'close' })
    $w.Add_MouseEnter({ $script:ToastHover = $true })
    $w.Add_MouseLeave({ $script:ToastHover = $false })
    $w.Add_SizeChanged({ try { if ($script:ToastWin.IsVisible -and $script:ToastSpec -and $script:ToastWin.Left -gt -5000) { $script:ToastWin.Top = (Get-WorkArea).Bottom - $script:ToastWin.ActualHeight } } catch {} })
    $script:ToastWin = $w
    $script:ToastEl = $T
}

function Set-ToastContent([hashtable]$Spec) {
        $E = $script:ToastEl
        $E.Strip.Background = New-Brush $Spec.Color
        $E.Kicker.Text = [string]$Spec.Kicker
        $E.Kicker.Foreground = New-Brush $Spec.Color
        $E.TitleText.Text = [string]$Spec.Title
        $E.BodyText.Text = [string]$Spec.Body
        $E.BodyText.Visibility = $(if ($Spec.Body) { 'Visible' } else { 'Collapsed' })
        $E.MetaText.Text = [string]$Spec.Meta
        $E.MetaText.Visibility = $(if ($Spec.Meta) { 'Visible' } else { 'Collapsed' })
        $E.ProgressPanel.Visibility = $(if ($Spec.Kind -eq 'progress') { 'Visible' } else { 'Collapsed' })
        if ($Spec.Kind -eq 'progress') { $E.Bar.Value = 0; $E.PhaseText.Text = 'Starting' + $Dots; $E.PctText.Text = '' }
        $E.Primary.Content = [string]$Spec.Primary
        $E.Primary.Visibility = $(if ($Spec.Primary) { 'Visible' } else { 'Collapsed' })
        $E.Secondary.Content = [string]$Spec.Secondary
        $E.Secondary.Visibility = $(if ($Spec.Secondary) { 'Visible' } else { 'Collapsed' })
        $E.Buttons.Visibility = $(if ($Spec.Primary -or $Spec.Secondary) { 'Visible' } else { 'Collapsed' })
}

function Show-Toast([hashtable]$Spec) {
    try {
        if (-not $script:ToastWin) { New-Toast }
        $w = $script:ToastWin
        $script:ToastGen++
        $script:ToastSpec = $Spec
        $wasVisible = $w.IsVisible
        $w.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        Set-ToastContent $Spec

        $script:ToastHideAt = [datetime]::MaxValue
        if ($Spec.AutoHide -gt 0) { $script:ToastHideAt = (Get-Date).AddSeconds([int]$Spec.AutoHide) }

        $wa = Get-WorkArea
        if (-not $wasVisible) {
            $w.Opacity = 0
            $w.Left = $wa.Right - $w.Width
            $w.Top = $wa.Bottom - 240
            $w.Show()
            $w.UpdateLayout()
            $top = $wa.Bottom - $w.ActualHeight
            Start-Anim $w ([System.Windows.Window]::TopProperty) ($top + 28) $top 280
            Start-Anim $w ([System.Windows.UIElement]::OpacityProperty) 0 1 200
        } else {
            $w.Opacity = 1
            $w.UpdateLayout()
            $w.Top = $wa.Bottom - $w.ActualHeight
        }
        return $true
    } catch {
        Write-TrayLog "Card: $($_.Exception.Message)"
        return $false
    }
}

function Hide-Toast {
    try {
        if (-not $script:ToastWin -or -not $script:ToastWin.IsVisible) { $script:ToastSpec = $null; return }
        $script:ToastSpec = $null
        $script:FadeGen = $script:ToastGen
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation(1, 0, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(180))))
        $a.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
        $a.Add_Completed({
            try {
                if ($script:ToastGen -eq $script:FadeGen -and -not $script:ToastSpec) { $script:ToastWin.Hide() }
                $script:ToastWin.Opacity = 1
            } catch {}
        })
        $script:ToastWin.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    } catch {}
}

function Invoke-ToastAction([string]$Which) {
    try {
        $spec = $script:ToastSpec
        if (-not $spec) { Hide-Toast; return }
        $action = 'dismiss'
        if ($Which -eq 'primary') { $action = $spec.OnPrimary }
        elseif ($Which -eq 'secondary') { $action = $spec.OnSecondary }
        switch ($action) {
            'install'    { Confirm-Install $spec.Source }
            'appupdate'  { Start-AppUpdate }
            'retry'      { Start-Install $spec.Source; Show-ProgressToast $spec.Source }
            'openfolder' { Hide-Toast; Open-Folder (Get-SourceFolder $spec.Source) }
            'openlog'    { Hide-Toast; Open-Log }
            'later'      {
                if ($spec.Source -eq '_app') { Write-TrayLog 'App update: later (still in the panel and the right-click menu)' }
                else { Write-TrayLog ('{0}: later (still in the panel and the right-click menu)' -f (Get-Nice $spec.Source (Get-S $spec.Source 'LatestTitle'))) }
                Hide-Toast
            }
            default      { Hide-Toast }
        }
    } catch { Write-TrayLog "Card button: $($_.Exception.Message)" }
}

function Get-SourceFolder([string]$Name) {
    foreach ($s in $script:Sources) { if ($s.Name -eq $Name) { return $s.Folder } }
    return $null
}

function Show-UpdateToast([string]$Name) {
    $tag = Get-S $Name 'LatestTag'
    Set-TrayValue "Prompted_$Name" $tag
    $nice = Get-Nice $Name (Get-S $Name 'LatestTitle')
    $cur = Get-Nice $Name (Get-S $Name 'Title')
    if (-not (Get-S $Name 'Title')) { $cur = 'nothing yet' }
    $meta = @()
    $size = Get-S $Name 'LatestSizeMB'
    if ($size) { $meta += "$size MB" }
    $when = Format-When (Get-S $Name 'LatestPublishedAt')
    if ($when) { $meta += "released $when" }
    $kicker = 'NEW BUILD'
    $body = "You're on $cur. Download and install it now?"
    if ((Get-S $Name 'LatestIsTest') -eq $true) {
        $kicker = 'NEW TEST BUILD'
        $body = "From the $(Get-S $Name 'LatestBranch') branch, not a release yet. You're on $cur. Download and install it now?"
    }
    $ok = Show-Toast @{
        Kind = 'update'; Source = $Name; Kicker = $kicker; Title = "$nice is out"
        Body = $body
        Meta = ($meta -join $Dot)
        Primary = 'Download & install'; OnPrimary = 'install'; Secondary = 'Later'; OnSecondary = 'later'
        Color = $Palette.Orange; AutoHide = 0
    }
    if (-not $ok) {   # UI failed to load: plain question instead, so updates still work
        $r = [System.Windows.Forms.MessageBox]::Show("$nice is out. You're on $cur.`n`nDownload and install it now?", 'Lichii Builds', 'YesNo', 'Information')
        if ($r -eq 'Yes') { Start-Install $Name }
    }
}

function Show-ProgressToast([string]$Name) {
    $nice = Get-Nice $Name (Get-S $Name 'LatestTitle')
    [void](Show-Toast @{
        Kind = 'progress'; Source = $Name; Kicker = 'INSTALLING'; Title = "Installing $nice"
        Body = 'Your current build moves to ARCHIVE when this is done.'
        Color = $Palette.Blue; AutoHide = 0
    })
}

function Show-FallbackStatus {
    $lines = @()
    foreach ($s in $script:Sources) {
        $lines += ('{0}: {1}   (GitHub: {2})' -f $s.Label, (Format-Version (Get-S $s.Name 'Title')), (Format-Version (Get-S $s.Name 'LatestTitle')))
    }
    [void][System.Windows.Forms.MessageBox]::Show(($lines -join "`n") + "`n`n" + (Get-SubLine), 'Lichii Builds')
}

# ================================================================ preview (preview.flag -> PNGs in .\preview)

function Save-VisualPng($Visual, [string]$Path) {
    $scale = 2.0
    $wpx = [int][math]::Ceiling($Visual.ActualWidth * $scale)
    $hpx = [int][math]::Ceiling($Visual.ActualHeight * $scale)
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($wpx, $hpx, (96 * $scale), (96 * $scale), [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($Visual)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Close() }
}

function Save-OffscreenWindow($W, [string]$Path) {
    $W.ShowActivated = $false
    $W.Left = -8000; $W.Top = -8000; $W.Opacity = 1
    $W.Show()
    $W.UpdateLayout()
    Save-VisualPng $W $Path
    $W.Hide()
}

function Save-UiPreview {
    $dir = Join-Path $ScriptDir 'preview'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    try {
        foreach ($k in 'ok', 'new', 'bad', 'offline') { $Icons[$k].ToBitmap().Save((Join-Path $dir "icon-$k.png"), [System.Drawing.Imaging.ImageFormat]::Png) }
        $Icons.spin[3].ToBitmap().Save((Join-Path $dir 'icon-busy.png'), [System.Drawing.Imaging.ImageFormat]::Png)

        if (-not $script:Flyout) { New-Flyout }
        $was = $script:Flyout.IsVisible
        if (-not $was) {
            Update-Flyout -Force
            Save-OffscreenWindow $script:Flyout (Join-Path $dir 'panel.png')
            $script:Flyout.ShowActivated = $true
            $script:FlyoutHiddenAt = [datetime]::MinValue
        }

        if (-not $script:ToastWin) { New-Toast }
        if (-not $script:ToastWin.IsVisible) {
            $n = $script:Sources[0].Name
            Set-ToastContent @{ Kind = 'update'; Source = $n; Kicker = 'NEW BUILD'; Title = 'Frizti v4 is out'
                                Body = "You're on Frizti v3. Download and install it now?"; Meta = ('79.8 MB' + $Dot + 'released Nov 7, 3:12 AM')
                                Primary = 'Download & install'; Secondary = 'Later'; Color = $Palette.Orange }
            Save-OffscreenWindow $script:ToastWin (Join-Path $dir 'card-new-build.png')
            Set-ToastContent @{ Kind = 'progress'; Source = $n; Kicker = 'INSTALLING'; Title = 'Installing Frizti v4'
                                Body = 'Your current build moves to ARCHIVE when this is done.'; Color = $Palette.Blue }
            $script:ToastEl.Bar.Value = 62; $script:ToastEl.PhaseText.Text = 'Downloading' + $Dots; $script:ToastEl.PctText.Text = '49.5 / 79.8 MB' + $Dot + '62%'
            Save-OffscreenWindow $script:ToastWin (Join-Path $dir 'card-installing.png')
            Set-ToastContent @{ Kind = 'done'; Source = $n; Kicker = 'INSTALLED'; Title = 'Frizti v4 is ready'; Body = 'The old build is in ARCHIVE.'
                                Meta = 'Saves, mods and shader cache were not touched.'; Primary = 'Open folder'; Color = $Palette.Green }
            Save-OffscreenWindow $script:ToastWin (Join-Path $dir 'card-done.png')
            $script:ToastWin.ShowActivated = $false
        }
        $sw = Initialize-SetupWindow
        $sw.Window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
        Save-OffscreenWindow $sw.Window (Join-Path $dir 'setup.png')
        $sw.Window.Close()
        Write-TrayLog "Saved UI preview images to $dir"
    } catch { Write-TrayLog "Preview: $($_.Exception.Message)" }
}

# ================================================================ right-click menu (dark)

function Add-MenuItem([string]$Text, [scriptblock]$OnClick, [string]$Tag = '', [bool]$Enabled = $true, [bool]$Bold = $false, [string]$Style = '') {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
    $it.Enabled = $Enabled
    $it.Tag = $Tag
    $it.Name = $Style
    $it.Padding = New-Object System.Windows.Forms.Padding(2, 4, 2, 4)
    if ($Bold) { $it.Font = New-Object System.Drawing.Font($script:Menu.Font, [System.Drawing.FontStyle]::Bold) }
    if ($OnClick) { $it.add_Click($OnClick) }
    [void]$script:Menu.Items.Add($it)
    return $it
}
function Add-MenuSeparator { [void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }

function Build-Menu {
    $script:Menu.Items.Clear()
    [void](Add-MenuItem 'Open Lichii Builds' { param($s, $e) Show-Flyout } '' $true $true)
    Add-MenuSeparator
    if (Test-AppUpdate) {
        [void](Add-MenuItem ('Update Lichii Builds to {0}' -f (Get-AppInfo).LatestVersion) { param($s, $e) Start-AppUpdate } '' (-not $script:Proc) $false 'accent')
    }
    foreach ($src in @(Get-Updates)) {
        [void](Add-MenuItem ('Download {0}' -f (Get-Nice $src.Name (Get-S $src.Name 'LatestTitle'))) { param($s, $e) Confirm-Install ([string]$s.Tag) } $src.Name (-not $script:Proc) $false 'accent')
    }
    [void](Add-MenuItem 'Check now' { param($s, $e) Start-Check -Manual } '' (-not $script:Proc))
    [void](Add-MenuItem ('Open {0} folder' -f (Split-Path -Leaf (Get-BuildsRoot))) { param($s, $e) Open-Folder $null })
    [void](Add-MenuItem 'Open log' { param($s, $e) Open-Log })
    [void](Add-MenuItem 'Settings...' { param($s, $e) Open-Settings })
    Add-MenuSeparator
    $sw = Add-MenuItem 'Start with Windows' {
        param($s, $e)
        try { Set-StartWithWindows (-not (Test-StartWithWindows)); Write-TrayLog ('Start with Windows: {0}' -f (Test-StartWithWindows)) }
        catch { Write-TrayLog "Start with Windows: $($_.Exception.Message)" }
    }
    $sw.Checked = Test-StartWithWindows
    [void](Add-MenuItem 'Exit' { param($s, $e) Exit-Tray })
    Add-MenuSeparator
    [void](Add-MenuItem ('Version {0}' -f $AppVersion) $null '' $false)
}

function Open-Settings {
    try {
        Hide-Flyout
        if ($script:SettingsOpen) { return }
        $script:SettingsOpen = $true
        $script:Timer.Stop()
        $saved = $false
        try { $saved = Show-SetupWindow } finally { $script:SettingsOpen = $false; $script:Timer.Start() }
        if ($saved) {
            Read-Config
            $script:NextCheck = (Get-Date).AddSeconds(2)
            Update-Look
        }
    } catch { Write-TrayLog "Settings: $($_.Exception.Message)" }
}

function Show-TrayMenu {
    try { Build-Menu; $script:Menu.Show([System.Windows.Forms.Cursor]::Position) } catch {}
}

function Exit-Tray {
    Write-TrayLog 'Tray app closed'
    try { $script:Timer.Stop(); $script:Fast.Stop() } catch {}
    try { if ($script:ToastWin) { $script:ToastWin.Close() } } catch {}
    try { if ($script:Flyout) { $script:Flyout.Close() } } catch {}
    try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch {}
    [System.Windows.Forms.Application]::Exit()
}

# Windows 11 hides new tray icons in the ^ overflow. Ask Explorer once to show this one.
function Show-IconOnTaskbar {
    if ((Get-TrayValue 'PromotedIcon') -eq $true) { $script:PromoteDone = $true; return }
    $base = 'HKCU:\Control Panel\NotifyIconSettings'
    if (-not (Test-Path -LiteralPath $base)) { $script:PromoteDone = $true; return }
    foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
        try {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop
            if ([string]$p.ExecutablePath -like '*powershell.exe' -and [string]$p.InitialTooltip -like 'Lichii*') {
                if ($p.IsPromoted -ne 1) { New-ItemProperty -LiteralPath $k.PSPath -Name 'IsPromoted' -Value 1 -PropertyType DWord -Force | Out-Null }
                Set-TrayValue 'PromotedIcon' $true
                $script:PromoteDone = $true
                Write-TrayLog 'Tray icon set to show on the taskbar'
                return
            }
        } catch {}
    }
}

# ================================================================ timers

function On-Fast {
    try {
        if (-not $script:Busy) { $script:Fast.Stop(); return }
        $script:SpinI = ($script:SpinI + 1) % 12
        $script:Tray.Icon = $Icons.spin[$script:SpinI]
        $script:FastN++
        if ($script:ProcKind -eq 'install' -and $script:FastN % 3 -eq 0) { Update-Progress }
    } catch {}
}

function On-Tick {
    try {
        $script:Ticks++
        if (Test-Path -LiteralPath $QuitFlag) {
            try { Remove-Item -LiteralPath $QuitFlag -Force } catch {}
            Exit-Tray; return
        }
        if (Test-Path -LiteralPath $RestartFlag) {
            try { Remove-Item -LiteralPath $RestartFlag -Force } catch {}
            Write-TrayLog 'Restarting to load the updated tray app'
            Start-TrayProcess ('-Background -AfterPid {0}' -f $PID)
            Exit-Tray; return
        }

        $pf = Join-Path $ScriptDir 'preview.flag'
        if (Test-Path -LiteralPath $pf) { try { Remove-Item -LiteralPath $pf -Force } catch {}; Save-UiPreview }

        if ($script:Proc) {
            if ($script:Proc.HasExited) {
                $code = $script:Proc.ExitCode
                $kind = $script:ProcKind
                $name = $script:ProcName
                $script:Proc.Dispose()
                $script:Proc = $null
                $script:Busy = $false
                Complete-Child $kind $name $code
            } elseif (((Get-Date) - $script:ProcStart).TotalMinutes -gt 30) {
                try { $script:Proc.Kill() } catch {}
                Write-TrayLog 'The checker took over 30 minutes, so it was stopped.'
            }
        } elseif ($script:QueuedInstall) {
            $n = $script:QueuedInstall
            $script:QueuedInstall = $null
            Start-Install $n
        } elseif ((Get-Date) -ge $script:NextCheck) {
            Start-Check
        } else {
            try {   # pick up a check run by hand
                if ((Test-Path -LiteralPath $StatePath) -and ((Get-Item -LiteralPath $StatePath).LastWriteTimeUtc -ne $script:StateStamp)) {
                    Read-State; Find-NewBuilds; Update-Look; Update-Flyout
                }
            } catch {}
        }

        # new-build card: one at a time, never over a fullscreen game, never over an active card
        $busyToast = $script:ToastSpec -and ($script:ToastSpec.Kind -in @('update', 'progress', 'blocked', 'error'))
        $panelUp = $script:Flyout -and $script:Flyout.IsVisible
        if (-not $script:Proc -and -not $busyToast -and -not $panelUp -and @($script:Pending).Count -gt 0 -and (Test-UserFree)) {
            $n = @($script:Pending)[0]
            $script:Pending = @($script:Pending | Select-Object -Skip 1)
            if ($n -eq '_app') { if (Test-AppUpdate) { Show-AppUpdateToast } }
            elseif ((Get-S $n 'UpdateAvailable') -eq $true) { Show-UpdateToast $n }
        }

        if ($script:ToastSpec -and -not $script:ToastHover -and (Get-Date) -ge $script:ToastHideAt) { Hide-Toast }
        if (-not $script:PromoteDone -and $script:Ticks -ge 5 -and $script:Ticks -le 240) { Show-IconOnTaskbar }
        if ($script:JustUpdatedFrom -and $script:Ticks -ge 2 -and -not $script:ToastSpec) {
            $from = $script:JustUpdatedFrom; $script:JustUpdatedFrom = $null
            $notes = (([string](Get-Prop2 (Get-AppInfo) 'Notes')) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' '
            Write-TrayLog "Now running Lichii Builds $AppVersion (was $from)"
            [void](Show-Toast @{ Kind = 'done'; Source = '_app'; Kicker = 'UPDATED'; Title = "Lichii Builds $AppVersion is ready"
                                 Body = $(if ($notes) { $notes } else { "Updated from $from." }); Meta = "Updated from $from. Your settings were kept."
                                 Color = $Palette.Green; AutoHide = 15 })
        }
        if ($script:Ticks % 15 -eq 0 -and -not $script:Busy) { Update-Flyout }
    } catch {
        Write-TrayLog "Tick error: $($_.Exception.Message)"
    }
}

# ================================================================ go

$script:TraySet        = Read-TraySettings
$script:Sources        = @()
$script:Interval       = 30
$script:State          = New-Object psobject
$script:StateStamp     = [datetime]::MinValue
$script:Proc           = $null
$script:ProcKind       = ''
$script:ProcName       = ''
$script:Busy           = $false
$script:BusyText       = ''
$script:Pending        = @()
$script:LastCheck      = $null
$script:ConfigProblem  = $false
$script:ManualCheck    = $false
$script:QueuedInstall  = $null
$script:PromoteDone    = $false
$script:Ticks          = 0
$script:FastN          = 0
$script:SpinI          = 0
$script:Flyout         = $null
$script:F              = @{}
$script:CardRefs       = @{}
$script:FlyoutHiddenAt = [datetime]::MinValue
$script:Spinning       = $false
$script:ToastWin       = $null
$script:ToastEl        = @{}
$script:ToastSpec      = $null
$script:ToastGen       = 0
$script:FadeGen        = -1
$script:ToastHover     = $false
$script:ToastHideAt    = [datetime]::MaxValue
$script:CardXaml       = ''
$script:SettingsOpen   = $false
$script:JustUpdatedFrom = $null

Read-Config
Read-State
Set-TrayValue 'UiVersion' $UiVersion
[void](Remove-OldHourlyTask)

# Load the UI files once up front, so a broken file shows up in the log right away.
try {
    $script:CardXaml = [IO.File]::ReadAllText((Join-Path $UiDir 'Card.xaml'))
    [void](New-UiWindow 'Toast.xaml')
    [void](New-UiWindow 'Flyout.xaml')
    if ($script:Sources.Count -gt 0) { [void](New-Card (Get-CardTokens $script:Sources[0])) }
} catch { Write-TrayLog "UI files didn't load: $($_.Exception.Message)" }

if ($Startup) { $script:NextCheck = (Get-Date).AddSeconds(45) } else { $script:NextCheck = (Get-Date).AddSeconds(3) }

$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:Menu.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$script:Menu.ShowImageMargin = $false
$script:Menu.ShowCheckMargin = $true
if ($script:DarkMenuOk) {
    $script:Menu.Renderer = New-Object LichiiTray.DarkRenderer
    $script:Menu.BackColor = [System.Drawing.Color]::FromArgb(43, 43, 43)
}
$script:Menu.add_Opening({ param($s, $e) try { Build-Menu } catch { Write-TrayLog "Menu: $($_.Exception.Message)" } })
$script:Menu.add_Opened({ param($s, $e) try { if ($script:NativeOk) { [LichiiTray.Native]::Win11Popup($script:Menu.Handle) } } catch {} })

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = $Icons.ok
$script:Tray.Text = 'Lichii Builds: starting'
$script:Tray.ContextMenuStrip = $script:Menu
$script:Tray.add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Flyout }
})
$script:Tray.Visible = $true

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 1000
$script:Timer.add_Tick({ On-Tick })
$script:Fast = New-Object System.Windows.Forms.Timer
$script:Fast.Interval = 110
$script:Fast.add_Tick({ On-Fast })
$script:Timer.Start()

$lastV = Get-TrayValue 'LastAppVersion'
if ($lastV -and $lastV -ne $AppVersion) { $script:JustUpdatedFrom = $lastV }
Set-TrayValue 'LastAppVersion' $AppVersion
Write-TrayLog ("Tray app started, new look (checks every {0} minutes, asks before downloading)" -f $script:Interval)
$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)

try { $TrayMutex.ReleaseMutex() } catch {}
try { $TrayMutex.Dispose() } catch {}
