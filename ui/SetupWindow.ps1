# Setup / Settings window for Lichii Builds. Dot-sourced by LichiiTray.ps1.
# Uses from the caller: $UiDir, $ConfigPath, $ScriptDir, Set-StartWithWindows, Test-StartWithWindows, Write-TrayLog

$SwKnown = @(
    @{ Name = 'frizti'; Label = 'Frizti'; Repo = 'Frizti/Fritchii' },
    @{ Name = 'main';   Label = 'Main';   Repo = 'zortos293/Lichii' }
)
$SwPlaceholder = 'owner/repo'
$SwDefaultAppRepo = 'platinumagpie/lichii-builds'   # where this app's own updates come from
$SwTokenUrl = 'https://github.com/settings/tokens/new?description=Lichii%20Builds%20test%20builds'

function Sw-Desktop {
    $d = [Environment]::GetFolderPath('Desktop')
    if (-not $d) { $d = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Desktop' }
    return $d
}

function Sw-Resolve([string]$Value) {
    if (-not $Value) { return $null }
    $v = $Value.Replace('%DESKTOP%', (Sw-Desktop))
    $v = [Environment]::ExpandEnvironmentVariables($v)
    if (-not [IO.Path]::IsPathRooted($v)) { $v = Join-Path $ScriptDir $v }
    return [IO.Path]::GetFullPath($v).TrimEnd('\', '/')
}

# C:\Users\x\Desktop\Foo -> %DESKTOP%\Foo, so the config still works if the Desktop moves (OneDrive etc.)
function Sw-ToSetting([string]$Full) {
    if (-not $Full) { return $Full }
    $d = (Sw-Desktop).TrimEnd('\', '/')
    if ($d -and $Full.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)) { return '%DESKTOP%' + $Full.Substring($d.Length) }
    return $Full
}

function Sw-Inside([string]$Child, [string]$Parent) {
    if (-not $Child -or -not $Parent) { return $false }
    $c = $Child.TrimEnd('\', '/'); $p = $Parent.TrimEnd('\', '/')
    if ([string]::Equals($c, $p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return ($c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase) -or $c.StartsWith($p + '/', [StringComparison]::OrdinalIgnoreCase))
}

function Sw-HasLichii([string]$Folder) {
    foreach ($n in 'lichii.exe', 'eglantine.exe') { if (Test-Path -LiteralPath (Join-Path $Folder $n) -PathType Leaf) { return $true } }
    return $false
}

# A picked folder becomes the build folder if it's empty or already holds Lichii;
# otherwise a "Lichii <label>" folder inside it is used.
function Sw-BuildFolderFor([string]$Picked, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Picked)) { return $Picked }
    if (Sw-HasLichii $Picked) { return $Picked }
    if (@(Get-ChildItem -LiteralPath $Picked -Force -ErrorAction SilentlyContinue).Count -eq 0) { return $Picked }
    return (Join-Path $Picked ('Lichii ' + $Label))
}

function Sw-IsTooBroad([string]$Folder) {
    $f = $Folder.TrimEnd('\', '/')
    foreach ($bad in @((Sw-Desktop), [Environment]::GetFolderPath('UserProfile'), [IO.Path]::GetPathRoot($Folder), [Environment]::GetFolderPath('MyDocuments'))) {
        if ($bad -and [string]::Equals($f, $bad.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# What the window shows, from config.json (or defaults on first run).
function Get-SetupModel {
    $base = Join-Path (Sw-Desktop) 'Lichii Builds'
    $m = @{
        Interval = 30
        Archive = (Join-Path $base 'Old builds')
        StartWithWindows = $true
        Token = ''
        Rows = @{
            frizti = @{ Name = 'frizti'; Label = 'Frizti'; Repo = 'Frizti/Fritchii';    Enabled = $true;  Folder = (Join-Path $base 'Lichii Frizti'); Test = 'off' }
            main   = @{ Name = 'main';   Label = 'Main';   Repo = 'zortos293/Lichii'; Enabled = $true;  Folder = (Join-Path $base 'Lichii Main'); Test = 'off' }
            custom = @{ Name = 'custom'; Label = 'Other';  Repo = '';                 Enabled = $false; Folder = (Join-Path $base 'Lichii Other'); Test = 'off' }
        }
        Existing = $null
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $c = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            $m.Existing = $c
            if ($c.CheckEveryMinutes) { $m.Interval = [int]$c.CheckEveryMinutes }
            if ($c.ArchiveFolder) { $m.Archive = Sw-Resolve $c.ArchiveFolder }
            if ($c.GitHubToken) { $m.Token = [string]$c.GitHubToken }
            $m.StartWithWindows = Test-StartWithWindows
            $m.Rows.frizti.Enabled = $false
            $m.Rows.main.Enabled = $false
            foreach ($s in @($c.Sources)) {
                if ($null -eq $s) { continue }
                $key = 'custom'
                if ($s.Name -eq 'frizti' -or $s.Name -eq 'main') { $key = [string]$s.Name }
                elseif ($m.Rows.custom.Repo) { continue }   # the window shows one extra repo; others are kept untouched
                $r = $m.Rows[$key]
                $r.Name = [string]$s.Name
                if ($s.Label) { $r.Label = [string]$s.Label }
                if ($s.Repo) { $r.Repo = [string]$s.Repo }
                $r.Enabled = ($s.Enabled -ne $false)
                if ($s.InstallFolder) { $r.Folder = Sw-Resolve $s.InstallFolder }
                if ($s.TestBuilds -eq 'main' -or $s.TestBuilds -eq 'all') { $r.Test = [string]$s.TestBuilds } else { $r.Test = 'off' }
            }
        } catch { Write-TrayLog "Settings: couldn't read config.json ($($_.Exception.Message)); showing defaults" }
    }
    return $m
}

# Returns an error message, or $null if the choices are fine.
function Test-SetupModel([hashtable]$M) {
    $on = @($M.Rows.Values | Where-Object { $_.Enabled })
    if ($on.Count -eq 0) { return 'Turn on at least one build to watch.' }
    $c = $M.Rows.custom
    if ($c.Enabled -and ($c.Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')) { return 'Type the other repo as owner/name, like zortos293/Lichii.' }
    foreach ($r in $on) {
        if (-not $r.Folder) { return "Pick a folder for $($r.Label)." }
        if (Sw-IsTooBroad $r.Folder) { return "$($r.Label) needs a folder of its own, not the whole $(Split-Path -Leaf $r.Folder)." }
        if ((Test-Path -LiteralPath $r.Folder) -and -not (Sw-HasLichii $r.Folder) -and @(Get-ChildItem -LiteralPath $r.Folder -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            return "$($r.Folder) has other files in it. Pick an empty folder or one that already has Lichii in it."
        }
        if ((Sw-Inside $M.Archive $r.Folder) -or (Sw-Inside $r.Folder $M.Archive)) { return "Old builds can't go inside the $($r.Label) folder (or the other way around)." }
    }
    for ($i = 0; $i -lt $on.Count; $i++) {
        for ($j = $i + 1; $j -lt $on.Count; $j++) {
            if ((Sw-Inside $on[$i].Folder $on[$j].Folder) -or (Sw-Inside $on[$j].Folder $on[$i].Folder)) {
                return "$($on[$i].Label) and $($on[$j].Label) need separate folders, so one can never replace the other."
            }
        }
    }
    if (-not $M.Archive) { return 'Pick a folder for old builds.' }
    if (@($on | Where-Object { $_.Test -ne 'off' }).Count -gt 0 -and -not ([string]$M.Token).Trim()) {
        return "Test builds need a GitHub token. Hit 'Get a free token', make one, and paste it in."
    }
    return $null
}

# Merge the window's choices into the existing config, keeping everything else as it was.
function New-ConfigFromModel([hashtable]$M) {
    $old = $M.Existing
    $cfg = [ordered]@{}
    if ($old) { foreach ($p in $old.PSObject.Properties) { if ($p.Name -ne 'Sources') { $cfg[$p.Name] = $p.Value } } }
    $cfg['CheckEveryMinutes'] = [int]$M.Interval
    $cfg['ArchiveFolder'] = Sw-ToSetting $M.Archive
    $cfg['GitHubToken'] = ([string]$M.Token).Trim()
    if (-not $cfg.Contains('AppRepo')) { $cfg['AppRepo'] = $SwDefaultAppRepo }

    $sources = @()
    $handled = @()
    foreach ($key in 'frizti', 'main', 'custom') {
        $r = $M.Rows[$key]
        if ($key -eq 'custom' -and -not $r.Repo) { continue }
        $prev = $null
        if ($old) { $prev = @($old.Sources) | Where-Object { $_ -and $_.Name -eq $r.Name } | Select-Object -First 1 }
        $s = [ordered]@{}
        if ($prev) { foreach ($p in $prev.PSObject.Properties) { $s[$p.Name] = $p.Value } }
        $s['Name'] = $r.Name
        if (-not $s.Contains('Label') -or $key -ne 'custom') { $s['Label'] = $r.Label }
        $s['Repo'] = $r.Repo
        $s['Enabled'] = [bool]$r.Enabled
        $s['TestBuilds'] = [string]$r.Test
        if (-not $s.Contains('AutoInstall')) { $s['AutoInstall'] = $false }
        if (-not $s.Contains('IncludePrereleases')) { $s['IncludePrereleases'] = $true }
        $newSetting = Sw-ToSetting $r.Folder
        if ($prev -and $prev.InstallFolder) {
            $oldFull = Sw-Resolve $prev.InstallFolder
            if (-not [string]::Equals($oldFull, $r.Folder, [StringComparison]::OrdinalIgnoreCase)) {
                $s['MoveFrom'] = @([string]$prev.InstallFolder)   # bring the existing build along on the next check
            }
        }
        $s['InstallFolder'] = $newSetting
        if (-not $s.Contains('AssetPattern')) { $s['AssetPattern'] = '(windows|win64|win-x64).*\.zip$' }
        if (-not $s.Contains('ExcludePattern')) { $s['ExcludePattern'] = 'symbols|debug|pdb|-ci-|pgo|source' }
        if (-not $s.Contains('ExeNames')) { $s['ExeNames'] = @('lichii.exe', 'eglantine.exe') }
        if (-not $s.Contains('CarryOver')) { $s['CarryOver'] = @('user', 'portable.txt') }
        $sources += [pscustomobject]$s
        $handled += $r.Name
    }
    if ($old) {   # repos the window doesn't show stay exactly as they were
        foreach ($p in @($old.Sources)) { if ($p -and $handled -notcontains $p.Name) { $sources += $p } }
    }
    $cfg['Sources'] = $sources
    return $cfg
}

function Save-SetupModel([hashtable]$M) {
    $cfg = New-ConfigFromModel $M
    $json = [pscustomobject]$cfg | ConvertTo-Json -Depth 6
    $tmp = "$ConfigPath.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
    try { Set-StartWithWindows ([bool]$M.StartWithWindows) } catch { Write-TrayLog "Start with Windows: $($_.Exception.Message)" }
    Write-TrayLog ('Settings saved: ' + (($M.Rows.Values | Where-Object { $_.Enabled } | ForEach-Object { '{0} -> {1}' -f $_.Repo, $_.Folder }) -join '; ') + "; old builds -> $($M.Archive); every $($M.Interval) min")
}

function Sw-PickFolder($Window, [string]$Title, [string]$Start) {
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
        return [LichiiTray.Native]::PickFolder($h, $Title, $Start)
    } catch {
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = $Title
        if ($Start -and (Test-Path -LiteralPath $Start)) { $d.SelectedPath = $Start }
        if ($d.ShowDialog() -eq 'OK') { return $d.SelectedPath }
        return $null
    }
}

# Builds the window and wires it up. Returns @{ Window; El; Model }.
function Initialize-SetupWindow([switch]$FirstRun) {
    $w = [System.Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $UiDir 'Setup.xaml')))
    $w.Resources.MergedDictionaries.Add([System.Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $UiDir 'Theme.xaml'))))
    $E = @{}
    foreach ($n in 'TitleBar', 'HeaderText', 'CloseBtn', 'UseFrizti', 'FriztiRow', 'FriztiPath', 'FriztiChange', 'UseMain', 'MainRow', 'MainPath', 'MainChange',
                   'UseCustom', 'CustomRow', 'CustomRepo', 'CustomPath', 'CustomChange', 'ArchivePath', 'ArchiveChange',
                   'Every15', 'Every30', 'Every60', 'StartWithWindows', 'ErrorBox', 'ErrorText', 'CancelBtn', 'SaveBtn', 'SaveLabel',
                   'Token', 'TokenLink', 'FriztiTests', 'MainTests', 'CustomTests', 'FriztiTRel', 'FriztiTMain', 'FriztiTAll',
                   'MainTRel', 'MainTMain', 'MainTAll', 'CustomTRel', 'CustomTMain', 'CustomTAll') {
        $E[$n] = $w.FindName($n)
    }
    $M = Get-SetupModel
    $script:Sw = @{ Window = $w; El = $E; Model = $M; Saved = $false }

    if (-not $FirstRun) { $E.HeaderText.Text = 'Lichii Builds settings'; $E.SaveLabel.Text = 'Save' }

    # fill in
    $E.UseFrizti.IsChecked = [bool]$M.Rows.frizti.Enabled
    $E.UseMain.IsChecked = [bool]$M.Rows.main.Enabled
    $E.UseCustom.IsChecked = [bool]$M.Rows.custom.Enabled
    $E.FriztiPath.Text = $M.Rows.frizti.Folder
    $E.MainPath.Text = $M.Rows.main.Folder
    $E.CustomPath.Text = $M.Rows.custom.Folder
    if ($M.Rows.custom.Repo) { $E.CustomRepo.Text = $M.Rows.custom.Repo } else { $E.CustomRepo.Text = $SwPlaceholder }
    $E.ArchivePath.Text = $M.Archive
    $E.Every15.IsChecked = ($M.Interval -le 15)
    $E.Every60.IsChecked = ($M.Interval -ge 60)
    $E.Every30.IsChecked = ($M.Interval -gt 15 -and $M.Interval -lt 60)
    $E.StartWithWindows.IsChecked = [bool]$M.StartWithWindows
    $E.Token.Text = [string]$M.Token
    foreach ($pair in @(@('frizti', 'Frizti'), @('main', 'Main'), @('custom', 'Custom'))) {
        $t = $M.Rows[$pair[0]].Test
        $E[($pair[1] + 'TRel')].IsChecked = ($t -ne 'main' -and $t -ne 'all')
        $E[($pair[1] + 'TMain')].IsChecked = ($t -eq 'main')
        $E[($pair[1] + 'TAll')].IsChecked = ($t -eq 'all')
    }
    $E.TokenLink.Add_Click({ try { Start-Process $SwTokenUrl } catch {} })

    # rows fade out when their switch is off
    $sync = {
        $E2 = $script:Sw.El
        $E2.FriztiRow.IsEnabled = [bool]$E2.UseFrizti.IsChecked; $E2.FriztiRow.Opacity = $(if ($E2.UseFrizti.IsChecked) { 1 } else { 0.4 })
        $E2.MainRow.IsEnabled = [bool]$E2.UseMain.IsChecked;     $E2.MainRow.Opacity = $(if ($E2.UseMain.IsChecked) { 1 } else { 0.4 })
        $E2.CustomRow.IsEnabled = [bool]$E2.UseCustom.IsChecked; $E2.CustomRow.Opacity = $(if ($E2.UseCustom.IsChecked) { 1 } else { 0.4 })
        $E2.FriztiTests.IsEnabled = [bool]$E2.UseFrizti.IsChecked; $E2.FriztiTests.Opacity = $(if ($E2.UseFrizti.IsChecked) { 1 } else { 0.4 })
        $E2.MainTests.IsEnabled = [bool]$E2.UseMain.IsChecked;     $E2.MainTests.Opacity = $(if ($E2.UseMain.IsChecked) { 1 } else { 0.4 })
    }
    foreach ($t in @($E.UseFrizti, $E.UseMain, $E.UseCustom)) { $t.Add_Checked($sync); $t.Add_Unchecked($sync) }
    & $sync

    $E.CustomRepo.Add_GotFocus({ if ($script:Sw.El.CustomRepo.Text -eq $SwPlaceholder) { $script:Sw.El.CustomRepo.Text = '' } })
    $E.CustomRepo.Add_LostFocus({ if (-not $script:Sw.El.CustomRepo.Text.Trim()) { $script:Sw.El.CustomRepo.Text = $SwPlaceholder } })

    $E.FriztiChange.Tag = 'frizti'; $E.MainChange.Tag = 'main'; $E.CustomChange.Tag = 'custom'
    $pickBuild = {
        param($s, $e)
        $key = [string]$s.Tag
        $r = $script:Sw.Model.Rows[$key]
        $p = Sw-PickFolder $script:Sw.Window ("Where should {0} builds go?" -f $r.Label) $r.Folder
        if ($p) {
            $label = $r.Label
            if ($key -eq 'custom') { $label = 'Other' }
            $f = Sw-BuildFolderFor $p $label
            $r.Folder = $f
            $script:Sw.El[('{0}Path' -f (Get-Culture).TextInfo.ToTitleCase($key))].Text = $f
        }
    }
    $E.FriztiChange.Add_Click($pickBuild); $E.MainChange.Add_Click($pickBuild); $E.CustomChange.Add_Click($pickBuild)
    $E.ArchiveChange.Add_Click({
        $p = Sw-PickFolder $script:Sw.Window 'Where should old builds go?' $script:Sw.Model.Archive
        if ($p) {
            if (Sw-IsTooBroad $p) { $p = Join-Path $p 'Old Lichii builds' }
            $script:Sw.Model.Archive = $p
            $script:Sw.El.ArchivePath.Text = $p
        }
    })

    $E.TitleBar.Add_MouseLeftButtonDown({ try { $script:Sw.Window.DragMove() } catch {} })
    $E.CloseBtn.Add_Click({ $script:Sw.Window.Close() })
    $E.CancelBtn.Add_Click({ $script:Sw.Window.Close() })
    $w.Add_KeyDown({ param($s, $e) if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $script:Sw.Window.Close() } })
    $E.SaveBtn.Add_Click({
        try {
            $M2 = $script:Sw.Model; $E2 = $script:Sw.El
            $M2.Rows.frizti.Enabled = [bool]$E2.UseFrizti.IsChecked
            $M2.Rows.main.Enabled = [bool]$E2.UseMain.IsChecked
            $M2.Rows.custom.Enabled = [bool]$E2.UseCustom.IsChecked
            $repo = $E2.CustomRepo.Text.Trim() -replace '^(https?://)?(www\.)?github\.com/', '' -replace '/+$', '' -replace '/releases.*$', ''
            if ($repo -eq $SwPlaceholder) { $repo = '' }
            $M2.Rows.custom.Repo = $repo
            if ($repo) { $M2.Rows.custom.Label = ($repo -split '/')[0] }
            $M2.Interval = $(if ($E2.Every15.IsChecked) { 15 } elseif ($E2.Every60.IsChecked) { 60 } else { 30 })
            $M2.StartWithWindows = [bool]$E2.StartWithWindows.IsChecked
            $M2.Token = $E2.Token.Text.Trim()
            foreach ($pair in @(@('frizti', 'Frizti'), @('main', 'Main'), @('custom', 'Custom'))) {
                $t = 'off'
                if ($E2[($pair[1] + 'TMain')].IsChecked) { $t = 'main' }
                if ($E2[($pair[1] + 'TAll')].IsChecked) { $t = 'all' }
                $M2.Rows[$pair[0]].Test = $t
            }
            $err = Test-SetupModel $M2
            if ($err) {
                $E2.ErrorText.Text = $err
                $E2.ErrorBox.Visibility = 'Visible'
                return
            }
            Save-SetupModel $M2
            $script:Sw.Saved = $true
            $script:Sw.Window.Close()
        } catch {
            $script:Sw.El.ErrorText.Text = "Couldn't save: $($_.Exception.Message)"
            $script:Sw.El.ErrorBox.Visibility = 'Visible'
        }
    })
    try { [System.Windows.Forms.Integration.ElementHost]::EnableModelessKeyboardInterop($w) } catch {}
    return $script:Sw
}

# Shows the window and waits. Returns $true if settings were saved.
function Show-SetupWindow([switch]$FirstRun) {
    $sw = Initialize-SetupWindow -FirstRun:$FirstRun
    [void]$sw.Window.ShowDialog()
    return [bool]$sw.Saved
}
