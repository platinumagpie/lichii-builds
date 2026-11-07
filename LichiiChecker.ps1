<#
    Lichii Build Checker
    --------------------
    Checks GitHub for new Lichii builds (pre-releases included, since every
    Lichii build is posted as a pre-release) and records what's new in
    state.json. A build is only downloaded when AutoInstall is on for that
    repo, or when you ask for it (-InstallSource, which the tray app uses).
    Installing puts each repo's build in its OWN folder, carries your user
    data over and moves the old build into ARCHIVE, so a "main" build can
    never replace the Frizti build.

    The tray app (LichiiTray.ps1) runs this every 30 minutes and asks you
    before downloading anything.

    Usage:
      LichiiChecker.ps1                        check once
      LichiiChecker.ps1 -InstallSource frizti  download + install the newest build for that repo now
      LichiiChecker.ps1 -Status                show what's installed and what's on GitHub
      LichiiChecker.ps1 -Uninstall             remove the old hourly scheduled task, if it's there

    Exit codes: 0 ok, 2 config problem, 3 install blocked (Lichii is running
    from that folder), 4 install failed.

    Settings live in config.json next to this script.
#>
[CmdletBinding()]
param(
    [string]$InstallSource,
    [switch]$UpdateApp,
    [switch]$NoNotify,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$Quiet,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # the progress bar makes downloads ~10x slower in Windows PowerShell
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$OnWindows = ($env:OS -eq 'Windows_NT')
$ScriptDir = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'config.json' }
$StatePath = Join-Path $ScriptDir 'state.json'
$LogPath   = Join-Path $ScriptDir 'log.txt'
$TaskName  = 'Lichii Build Checker'
$UserAgent = 'LichiiBuildChecker'
$DefaultExeNames = @('lichii.exe', 'eglantine.exe')
$VersionPath = Join-Path $ScriptDir 'VERSION'
$AppVersion = '0.0.0'
try { if (Test-Path -LiteralPath $VersionPath) { $AppVersion = (Get-Content -LiteralPath $VersionPath -Raw).Trim() } } catch {}
# App files that an app update replaces (everything else, like config.json and state.json, is yours and stays)
$AppKeep = @('config.json', 'state.json', 'tray.json', 'log.txt', 'progress.json', 'preview', 'old versions', 'restart.flag', 'quit.flag', 'preview.flag')
$DefaultCarryOver = @('user', 'portable.txt')

# ---------------------------------------------------------------- helpers

function Write-Log([string]$Message, [string]$Source = '') {
    $tag = ''
    if ($Source) { $tag = "[$Source] " }
    $line = '{0} {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $tag, $Message
    if (-not $Quiet) { Write-Host $line }
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch {}
}

function Limit-Log {
    try {
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 512KB)) {
            $keep = Get-Content -LiteralPath $LogPath -Tail 2000
            Set-Content -LiteralPath $LogPath -Value $keep -Encoding UTF8
        }
    } catch {}
}

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Resolve-PathSetting([string]$Value) {
    if (-not $Value) { return $null }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $v = $Value.Replace('%DESKTOP%', $desktop)
    $v = [Environment]::ExpandEnvironmentVariables($v)
    if (-not [IO.Path]::IsPathRooted($v)) { $v = Join-Path $ScriptDir $v }
    $full = [IO.Path]::GetFullPath($v)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
    return $full
}

function Test-PathInside([string]$Child, [string]$Parent) {
    # True when Child is Parent itself or anywhere underneath it.
    if (-not $Child -or -not $Parent) { return $false }
    $c = $Child.TrimEnd('\', '/')
    $p = $Parent.TrimEnd('\', '/')
    if ([string]::Equals($c, $p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    foreach ($sep in @('\', '/')) {
        if ($c.StartsWith($p + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-SafeName([string]$Name) {
    $bad = [IO.Path]::GetInvalidFileNameChars() + [char[]]'\/:*?"<>|'
    $out = $Name
    foreach ($ch in $bad) { $out = $out.Replace([string]$ch, '_') }
    return $out
}

function ConvertTo-UtcDate($Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return [datetime]::MinValue }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}

function Get-ExeNames($Src) {
    $n = @(Get-Prop $Src 'ExeNames')
    if ($n.Count -eq 0 -or -not $n[0]) { return $DefaultExeNames }
    return $n
}

function Get-CarryOver($Src) {
    $n = Get-Prop $Src 'CarryOver'
    if ($null -eq $n) { return $DefaultCarryOver }
    return @($n)
}

function Find-Exe([string]$Folder, $ExeNames) {
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder -PathType Container)) { return $null }
    foreach ($n in $ExeNames) {
        $p = Join-Path $Folder $n
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

# ---------------------------------------------------------------- config / state

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "config.json not found at $ConfigPath" }
    return (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json)
}

function Get-State {
    if (Test-Path -LiteralPath $StatePath) {
        try { return (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json) }
        catch { Write-Log "state.json was unreadable, starting fresh ($($_.Exception.Message))" }
    }
    return New-Object psobject
}

function Save-State($State) {
    $tmp = "$StatePath.tmp"
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}

function Set-SourceState($State, [string]$Name, $Value) {
    if ($State.PSObject.Properties[$Name]) { $State.$Name = $Value }
    else { $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Set-SourceField($State, [string]$Name, [string]$Field, $Value) {
    $s = Get-Prop $State $Name
    if ($null -eq $s) { $s = New-Object psobject; Set-SourceState $State $Name $s }
    if ($s.PSObject.Properties[$Field]) { $s.$Field = $Value }
    else { $s | Add-Member -NotePropertyName $Field -NotePropertyValue $Value }
}

# ---------------------------------------------------------------- notifications

# Built from a string at runtime so that a PowerShell without WinRT (pwsh 7, Linux) gets a
# catchable error instead of a compile error that would end the whole run.
$ToastCode = @'
param($XmlText)
$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml($XmlText)
$toast = New-Object Windows.UI.Notifications.ToastNotification $xml
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
'@

# Fallback: old-style tray balloon, if toasts aren't available.
$BalloonCode = @'
param($Title, $Body)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.SystemIcons]::Information
$icon.Visible = $true
$icon.ShowBalloonTip(10000, $Title, $Body, [System.Windows.Forms.ToolTipIcon]::Info)
Start-Sleep -Seconds 8
$icon.Dispose()
'@

function Show-Notification([string]$Title, [string]$Body, [string]$OpenPath) {
    Write-Log "Notify: $Title - $Body"
    if (-not $OnWindows -or $NoNotify) { return }
    $t = [Security.SecurityElement]::Escape($Title)
    $b = [Security.SecurityElement]::Escape($Body)
    $launch = ''
    try {
        if ($OpenPath -and (Test-Path -LiteralPath $OpenPath)) {
            $uri = [Security.SecurityElement]::Escape(([Uri]$OpenPath).AbsoluteUri)
            $launch = " activationType=`"protocol`" launch=`"$uri`""
        }
    } catch {}
    try {
        $xmlText = "<toast$launch><visual><binding template=`"ToastGeneric`"><text>$t</text><text>$b</text></binding></visual></toast>"
        & ([scriptblock]::Create($ToastCode)) $xmlText
    } catch {
        try { & ([scriptblock]::Create($BalloonCode)) $Title $Body }
        catch { Write-Log "Couldn't show a notification: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------- GitHub

function Get-Text([string]$Url, [hashtable]$Headers) {
    if (-not $Headers) { $Headers = @{} }
    $resp = Invoke-WebRequest -Uri $Url -Headers $Headers -UserAgent $UserAgent -UseBasicParsing -TimeoutSec 60
    $c = $resp.Content
    if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
    return [string]$c
}

function Get-Api([string]$Path) {
    $base = 'https://api.github.com'
    $apiBase = Get-Prop $Config 'ApiBase'
    if ($apiBase) { $base = $apiBase.TrimEnd('/') }
    $headers = @{}
    $token = Get-Prop $Config 'GitHubToken'
    if ($token) { $headers['Authorization'] = "Bearer $token" }
    return ((Get-Text "$base$Path" $headers) | ConvertFrom-Json)
}

function Get-Releases([string]$Repo) {
    $parsed = Get-Api "/repos/$Repo/releases?per_page=10"
    return @($parsed | ForEach-Object { $_ })
}

# Test builds: Windows builds the repo's "release-binaries" workflow made but that aren't releases.
# TestBuilds = "main" (repo's main branch only) or "all" (every branch, including experiments).
# Listing them needs no login; downloading them needs a GitHub token (GitHubToken in config.json).
function Get-NewestTestBuild($Src) {
    $mode = [string](Get-Prop $Src 'TestBuilds')
    if ($mode -ne 'main' -and $mode -ne 'all') { return $null }
    $wf = Get-Prop $Src 'TestWorkflow'
    if (-not $wf) { $wf = 'release-binaries.yml' }
    $pattern = Get-Prop $Src 'TestArtifactPattern'
    if (-not $pattern) { $pattern = '^(lichii|eglantine)-windows-x86_64-[0-9a-f]{7,}$' }
    $q = "/repos/$($Src.Repo)/actions/workflows/$wf/runs?status=success&per_page=10"
    if ($mode -eq 'main') {
        $info = Get-Api "/repos/$($Src.Repo)"
        $q += '&branch=' + [Uri]::EscapeDataString([string]$info.default_branch)
    }
    $checked = 0
    foreach ($run in @((Get-Api $q).workflow_runs)) {
        if ($null -eq $run) { continue }
        if ($checked -ge 3) { break }
        $checked++
        foreach ($a in @((Get-Api "/repos/$($Src.Repo)/actions/runs/$($run.id)/artifacts").artifacts)) {
            if ($null -eq $a -or $a.expired -or ([string]$a.name -notmatch $pattern)) { continue }
            $sha = ([string]$run.head_sha).Substring(0, 7)
            $asset = [pscustomobject]@{ name = ([string]$a.name + '.zip'); size = $a.size_in_bytes; digest = (Get-Prop $a 'digest'); browser_download_url = [string]$a.archive_download_url }
            $rel = [pscustomobject]@{ html_url = [string]$run.html_url; assets = @(); id = $a.id }
            return [pscustomobject]@{ Release = $rel; Asset = $asset; Date = (ConvertTo-UtcDate $a.created_at); Tag = "test-$sha"
                                      Title = "Test build $sha"; IsTest = $true; Branch = [string]$run.head_branch }
        }
    }
    return $null
}

# GitHub keeps old repo addresses working after a rename, and release links show the new name.
# When they differ, follow the move: update config.json and say so.
function Update-RepoIfMoved($Src, $Build, $State) {
    $u = [string]$Build.Release.html_url
    if ($u -notmatch 'github\.com/([^/]+/[^/]+)/releases') { return }
    $actual = $Matches[1]
    $old = [string]$Src.Repo
    if ([string]::Equals($actual, $old, [StringComparison]::OrdinalIgnoreCase)) { return }
    Write-Log "$old has moved to $actual on GitHub; following it (config.json updated)" $Src.Name
    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        foreach ($s in @($raw.Sources)) { if ($s -and $s.Name -eq $Src.Name) { $s.Repo = $actual } }
        $tmp = "$ConfigPath.tmp"
        $raw | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
        $Src.Repo = $actual
    } catch { Write-Log "Couldn't update config.json with the new repo name: $($_.Exception.Message)" $Src.Name }
    Set-SourceField $State $Src.Name 'RepoMoved' ('{0} -> {1}' -f $old, $actual)
    Set-SourceField $State $Src.Name 'Repo' $actual
    Show-Notification "Lichii $($Src.Name): repo moved" "$old is now $actual on GitHub. Updated automatically." $null
}

function Select-Asset($Release, $Src) {
    # Loose on purpose: Frizti v1 was "lichii-frizti-v1-windows-x86_64.zip", v2+ are
    # "Lichii-Frizti-v3-Windows-x64.zip". Matching is case-insensitive.
    $pattern = Get-Prop $Src 'AssetPattern'
    if (-not $pattern) { $pattern = '(windows|win64|win-x64).*\.zip$' }
    $exclude = Get-Prop $Src 'ExcludePattern'
    if ($null -eq $exclude) { $exclude = 'symbols|debug|pdb|-ci-|pgo|source' }
    foreach ($a in @($Release.assets)) {
        if ($null -eq $a) { continue }
        if ($a.name -notmatch $pattern) { continue }
        if ($exclude -and ($a.name -match $exclude)) { continue }
        return $a
    }
    return $null
}

function Get-NewestBuild($Src) {
    $includePre = (Get-Prop $Src 'IncludePrereleases') -ne $false
    $best = $null
    $script:LastRelease = $null
    foreach ($r in (Get-Releases $Src.Repo)) {
        if ($r.draft) { continue }
        if ($r.prerelease -and -not $includePre) { continue }
        $asset = Select-Asset $r $Src
        if (-not $asset) { continue }
        $date = ConvertTo-UtcDate $r.published_at
        if (-not $best -or $date -gt $best.Date) {
            $title = $r.name
            if (-not $title) { $title = $r.tag_name }
            $best = [pscustomobject]@{ Release = $r; Asset = $asset; Date = $date; Tag = [string]$r.tag_name; Title = [string]$title; IsTest = $false; Branch = '' }
        }
    }
    $script:LastRelease = $best
    $test = $null
    try { $test = Get-NewestTestBuild $Src } catch { Write-Log "Couldn't look up test builds: $($_.Exception.Message)" $Src.Name }
    if ($test -and (-not $best -or $test.Date -gt $best.Date)) { return $test }
    return $best
}

function Test-Download([string]$Zip, $Build) {
    $asset = $Build.Asset
    $len = (Get-Item -LiteralPath $Zip).Length
    if ($asset.size -and ($len -ne [int64]$asset.size)) {
        throw "download is $len bytes but GitHub says it should be $($asset.size)"
    }
    $expected = $null
    $digest = Get-Prop $asset 'digest'
    if ($digest -and ($digest -match '^sha256:([0-9a-fA-F]{64})$')) { $expected = $Matches[1] }
    if (-not $expected) {
        foreach ($s in @($Build.Release.assets | Where-Object { $_.name -match '^(CI-)?SHA256SUMS(\.txt)?$' })) {
            try { $txt = Get-Text $s.browser_download_url } catch { continue }
            foreach ($line in ($txt -split "`r?`n")) {
                if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
                    $h = $Matches[1]
                    $fname = $Matches[2] -replace '^.*[\\/]', ''
                    if ($fname -eq $asset.name) { $expected = $h; break }
                }
            }
            if ($expected) { break }
        }
    }
    if ($expected) {
        $actual = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash
        if ($actual -ne $expected) { throw "checksum mismatch (expected $expected, got $actual)" }
        return 'sha256 verified'
    }
    return 'size checked, no checksum published'
}

# ---------------------------------------------------------------- install

function Get-RunningFrom([string]$Folder, $ExeNames) {
    $names = @($ExeNames | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }) + @('eden-cli')
    $hits = @()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($names -notcontains $p.ProcessName) { continue }
        $path = $null
        try { $path = $p.Path } catch {}
        # If Windows won't tell us where it runs from, assume it's this one (safe side).
        if (-not $path -or (Test-PathInside $path $Folder)) { $hits += $p }
    }
    return $hits
}

function Move-Folder([string]$From, [string]$To) {
    try {
        Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop
    } catch {
        if ([IO.Path]::GetPathRoot($From) -ne [IO.Path]::GetPathRoot($To)) {
            Copy-Item -LiteralPath $From -Destination $To -Recurse -Force -ErrorAction Stop
            Remove-Item -LiteralPath $From -Recurse -Force -ErrorAction Stop
        } else { throw }
    }
}

# progress.json: what the tray app shows while installing ({Source, Phase, Done, Total})
$ProgressPath = Join-Path $ScriptDir 'progress.json'
function Set-Progress([string]$Source, [string]$Phase, [int64]$Done = 0, [int64]$Total = 0) {
    $json = '{{"Source":"{0}","Phase":"{1}","Done":{2},"Total":{3},"At":"{4}"}}' -f $Source, $Phase, $Done, $Total, (Get-Date).ToString('s')
    try { [IO.File]::WriteAllText($ProgressPath, $json) } catch {}
}
function Clear-Progress { try { if (Test-Path -LiteralPath $ProgressPath) { Remove-Item -LiteralPath $ProgressPath -Force } } catch {} }

function Resolve-AuthRedirect([string]$Url) {
    $token = Get-Prop $Config 'GitHubToken'
    if (-not $token) { throw 'test builds need a GitHub token: add one in Settings' }
    $r0 = [System.Net.HttpWebRequest]::Create($Url)
    $r0.UserAgent = $UserAgent
    $r0.AllowAutoRedirect = $false
    $r0.Timeout = 60000
    $r0.Headers['Authorization'] = "Bearer $token"
    $resp = $null
    try { $resp = $r0.GetResponse() }
    catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
        if ($ex -and $ex.Response) { $resp = $ex.Response } else { throw }
    }
    try {
        $code = [int]$resp.StatusCode
        if ($code -ge 300 -and $code -lt 400 -and $resp.Headers['Location']) { return [string]$resp.Headers['Location'] }
        if ($code -eq 401 -or $code -eq 403) { throw "GitHub refused the download ($code); check the GitHub token in Settings" }
        if ($code -eq 410) { throw 'that test build has expired on GitHub' }
        throw "GitHub answered $code instead of a download link"
    } finally { $resp.Close() }
}

function Save-Download([string]$Url, [string]$OutFile, [string]$Source, [int64]$Expected, [switch]$Auth) {
    if ($Auth) { $Url = Resolve-AuthRedirect $Url }
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = $UserAgent
    $req.AllowAutoRedirect = $true
    $req.Timeout = 60000
    $req.ReadWriteTimeout = 120000
    $resp = $req.GetResponse()
    try {
        $total = $resp.ContentLength
        if ($total -le 0) { $total = $Expected }
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($OutFile)
        try {
            $buf = New-Object byte[] 262144
            $done = [int64]0
            $last = [datetime]::MinValue
            Set-Progress $Source 'Downloading' 0 $total
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n)
                $done += $n
                if (((Get-Date) - $last).TotalMilliseconds -ge 250) { Set-Progress $Source 'Downloading' $done $total; $last = Get-Date }
            }
            Set-Progress $Source 'Downloading' $done $total
        } finally { $out.Dispose(); $in.Dispose() }
    } finally { $resp.Close() }
}

function Install-Build($Src, $Build, [string]$InstallDir, [string]$ArchiveDir, $State) {
    $exeNames = Get-ExeNames $Src
    $parent = Split-Path -Parent $InstallDir
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $staging = "$InstallDir.__new"
    $zip = Join-Path ([IO.Path]::GetTempPath()) ('lichii-{0}-{1}.zip' -f $Src.Name, [guid]::NewGuid().ToString('N'))
    $archived = $null
    try {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }

        $mb = [math]::Round(([double]$Build.Asset.size) / 1MB, 1)
        Write-Log "Downloading $($Build.Asset.name) ($mb MB) from $($Build.Tag)" $Src.Name
        Save-Download $Build.Asset.browser_download_url $zip $Src.Name ([int64]$Build.Asset.size) -Auth:([bool]$Build.IsTest)
        Set-Progress $Src.Name 'Verifying'
        $check = Test-Download $zip $Build
        Write-Log "Download OK ($check)" $Src.Name

        Set-Progress $Src.Name 'Unpacking'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $staging)
        $root = $staging
        $kids = @(Get-ChildItem -LiteralPath $staging -Force)
        if ($kids.Count -eq 1 -and $kids[0].PSIsContainer) { $root = $kids[0].FullName }
        $innerZips = @(Get-ChildItem -LiteralPath $root -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if (-not (Find-Exe $root $exeNames) -and $innerZips.Count -eq 1) {
            $staging2 = "$InstallDir.__new2"
            if (Test-Path -LiteralPath $staging2) { Remove-Item -LiteralPath $staging2 -Recurse -Force }
            [IO.Compression.ZipFile]::ExtractToDirectory($innerZips[0].FullName, $staging2)
            $root = $staging2
            $kids = @(Get-ChildItem -LiteralPath $staging2 -Force)
            if ($kids.Count -eq 1 -and $kids[0].PSIsContainer) { $root = $kids[0].FullName }
        }
        if (-not (Find-Exe $root $exeNames)) { throw "the new zip has no $($exeNames -join ' / ') in it, so it wasn't installed" }

        # Old build -> ARCHIVE (one rename; fails cleanly if anything in it is still open)
        Set-Progress $Src.Name 'Installing'
        if (Test-Path -LiteralPath $InstallDir) {
            $oldTag = Get-Prop (Get-Prop $State $Src.Name) 'Tag'
            if (-not $oldTag) { $oldTag = 'previous' }
            if (-not (Test-Path -LiteralPath $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null }
            $archived = Join-Path $ArchiveDir (Get-SafeName ('{0}-{1}' -f $Src.Name, $oldTag))
            if (Test-Path -LiteralPath $archived) { $archived = '{0}-{1}' -f $archived, (Get-Date -Format 'yyyyMMdd-HHmmss') }
            Move-Folder $InstallDir $archived
        }

        # New build -> install folder (put the old one back if this fails)
        try { Move-Folder $root $InstallDir }
        catch {
            if ($archived) { Move-Folder $archived $InstallDir; $archived = $null }
            throw
        }

        # Carry user data (saves, keys, mods, settings) from the old build into the new one
        if ($archived) {
            foreach ($item in (Get-CarryOver $Src)) {
                if (-not $item) { continue }
                $from = Join-Path $archived $item
                if (-not (Test-Path -LiteralPath $from)) { continue }
                $to = Join-Path $InstallDir $item
                try {
                    if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Recurse -Force }
                    Move-Item -LiteralPath $from -Destination $to -ErrorAction Stop
                    Write-Log "Carried '$item' over from the old build" $Src.Name
                } catch {
                    Write-Log "Couldn't carry '$item' over: $($_.Exception.Message). It's still in $archived" $Src.Name
                    Show-Notification "Lichii $($Src.Name): check your user data" "Couldn't move '$item' into the new build. It's safe in $archived" $archived
                }
            }
        }
    } finally {
        Clear-Progress
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath "$InstallDir.__new2") { Remove-Item -LiteralPath "$InstallDir.__new2" -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
    }
    return $archived
}

# ---------------------------------------------------------------- updating this app itself

function ConvertTo-AppVersion([string]$Tag) {
    $t = ([string]$Tag) -replace '^[vV]', ''
    $v = $null
    if ([version]::TryParse($t, [ref]$v)) { return $v }
    return $null
}

# Looks at the app's own GitHub repo (AppRepo in config.json) and records what's there in state.json (_app).
function Update-AppInfo($State) {
    $repo = [string](Get-Prop $Config 'AppRepo')
    if (-not $repo) { return }
    try {
        $best = $null
        foreach ($r in @((Get-Api "/repos/$repo/releases?per_page=5") | ForEach-Object { $_ })) {
            if ($null -eq $r -or $r.draft) { continue }
            $v = ConvertTo-AppVersion $r.tag_name
            if (-not $v) { continue }
            $a = @($r.assets) | Where-Object { $_ -and $_.name -match '^Lichii[- ]Builds.*\.zip$' } | Select-Object -First 1
            if (-not $a) { continue }
            if (-not $best -or $v -gt $best.V) { $best = [pscustomobject]@{ V = $v; R = $r; A = $a } }
        }
        $cur = ConvertTo-AppVersion $AppVersion
        if (-not $cur) { $cur = [version]'0.0.0' }
        $info = [pscustomobject]@{
            Version = $AppVersion; Repo = $repo; LastChecked = (Get-Date).ToString('s'); UpdateAvailable = $false
            LatestVersion = $AppVersion; LatestUrl = ''; Notes = ''; AssetUrl = ''; AssetName = ''; AssetSize = 0; AssetDigest = ''
        }
        if ($best) {
            $info.LatestVersion = $best.V.ToString()
            $info.LatestUrl = [string]$best.R.html_url
            $notes = [string]$best.R.body
            if ($notes.Length -gt 600) { $notes = $notes.Substring(0, 600) + '...' }
            $info.Notes = $notes
            $info.AssetUrl = [string]$best.A.browser_download_url
            $info.AssetName = [string]$best.A.name
            $info.AssetSize = $best.A.size
            $info.AssetDigest = [string](Get-Prop $best.A 'digest')
            $info.UpdateAvailable = ($best.V -gt $cur)
            if ($info.UpdateAvailable -and (Get-Prop (Get-Prop $State '_app') 'LatestVersion') -ne $info.LatestVersion) {
                Write-Log "Lichii Builds $($info.LatestVersion) is out (you have $AppVersion)"
            }
        }
        Set-SourceState $State '_app' $info
    } catch { Write-Log "Couldn't check for Lichii Builds updates: $($_.Exception.Message)" }
}

# Downloads the newest app version and swaps its files in. config.json, state.json and the log
# are never touched; the current version is copied to "old versions" first.
function Invoke-AppUpdate($State) {
    Update-AppInfo $State
    Save-State $State
    $app = Get-Prop $State '_app'
    if (-not $app -or -not $app.UpdateAvailable) { Write-Log 'Lichii Builds is already up to date.'; return 0 }
    $zip = Join-Path ([IO.Path]::GetTempPath()) ('lichii-builds-{0}.zip' -f [guid]::NewGuid().ToString('N'))
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('lichii-builds-{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        Write-Log "Updating Lichii Builds $AppVersion -> $($app.LatestVersion)"
        Save-Download $app.AssetUrl $zip 'app' ([int64]$app.AssetSize)
        $fake = [pscustomobject]@{ Asset = [pscustomobject]@{ name = $app.AssetName; size = $app.AssetSize; digest = $app.AssetDigest }; Release = [pscustomobject]@{ assets = @() } }
        [void](Test-Download $zip $fake)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
        $tray = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'LichiiTray.ps1' -File | Select-Object -First 1
        if (-not $tray) { throw "the update zip doesn't contain the app" }
        $newRoot = $tray.DirectoryName

        $bk = Join-Path (Join-Path $ScriptDir 'old versions') (Get-SafeName $AppVersion)
        if (Test-Path -LiteralPath $bk) { $bk = '{0}-{1}' -f $bk, (Get-Date -Format 'yyyyMMdd-HHmmss') }
        New-Item -ItemType Directory -Path $bk -Force | Out-Null
        foreach ($item in @(Get-ChildItem -LiteralPath $ScriptDir -Force)) {
            if ($AppKeep -contains $item.Name) { continue }
            Copy-Item -LiteralPath $item.FullName -Destination $bk -Recurse -Force
        }
        foreach ($f in @(Get-ChildItem -LiteralPath $newRoot -Recurse -File)) {
            $rel = $f.FullName.Substring($newRoot.Length).TrimStart('\', '/')
            if ($AppKeep -contains (($rel -split '[\\/]')[0])) { continue }
            $dest = Join-Path $ScriptDir $rel
            $dd = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        }
        Set-Content -LiteralPath (Join-Path $ScriptDir 'restart.flag') -Value 'update' -Encoding ASCII
        Write-Log "Updated Lichii Builds to $($app.LatestVersion). The previous version is in $bk"
        return 0
    } catch {
        Write-Log "Lichii Builds update failed: $($_.Exception.Message). If the app acts up, copy the files back from the 'old versions' folder."
        return 4
    } finally {
        Clear-Progress
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------- old hourly task (replaced by the tray app)

function Unregister-CheckerTask {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log "Scheduled task '$TaskName' removed."
    } else {
        Write-Log "Scheduled task '$TaskName' wasn't installed."
    }
}

# ---------------------------------------------------------------- main

Limit-Log
$Config = Get-Config

if ($Uninstall) { Unregister-CheckerTask; exit 0 }

$ArchiveDir = Resolve-PathSetting (Get-Prop $Config 'ArchiveFolder')
if (-not $ArchiveDir) { $ArchiveDir = Resolve-PathSetting '%DESKTOP%\ARCHIVE\Lichii' }

$Sources = @()
foreach ($s in @($Config.Sources)) {
    if ($null -eq $s -or (Get-Prop $s 'Enabled') -eq $false) { continue }
    $Sources += [pscustomobject]@{ Src = $s; Dir = (Resolve-PathSetting $s.InstallFolder) }
}

# Safety checks: refuse to run with a config that could let one build overwrite another.
$problems = @()
for ($i = 0; $i -lt $Sources.Count; $i++) {
    $a = $Sources[$i]
    if (-not $a.Src.Name -or -not $a.Src.Repo -or -not $a.Dir) { $problems += "a source is missing Name, Repo or InstallFolder" }
    if ((Test-PathInside $ArchiveDir $a.Dir) -or (Test-PathInside $a.Dir $ArchiveDir)) { $problems += "'$($a.Src.Name)' InstallFolder overlaps the ARCHIVE folder" }
    if (Test-PathInside $ScriptDir $a.Dir) { $problems += "'$($a.Src.Name)' InstallFolder contains the checker itself" }
    $userHome = [Environment]::GetFolderPath('UserProfile')
    $desk = [Environment]::GetFolderPath('Desktop')
    foreach ($bad in @($userHome, $desk, [IO.Path]::GetPathRoot($a.Dir))) {
        if ($bad -and [string]::Equals($a.Dir, $bad.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
            $problems += "'$($a.Src.Name)' InstallFolder is $bad - it must be a folder just for that build"
        }
    }
    foreach ($mf in @(Get-Prop $a.Src 'MoveFrom')) {
        $m = Resolve-PathSetting $mf
        if (-not $m) { continue }
        if ((Test-PathInside $m $a.Dir) -or (Test-PathInside $a.Dir $m)) { $problems += "'$($a.Src.Name)' MoveFrom overlaps its own InstallFolder" }
        if ((Test-PathInside $m $ArchiveDir) -or (Test-PathInside $ArchiveDir $m)) { $problems += "'$($a.Src.Name)' MoveFrom overlaps the ARCHIVE folder" }
        foreach ($o in $Sources) {
            if ($o -eq $a) { continue }
            if ((Test-PathInside $m $o.Dir) -or (Test-PathInside $o.Dir $m)) {
                $problems += "'$($a.Src.Name)' MoveFrom points at '$($o.Src.Name)' InstallFolder, so it could take that build"
            }
        }
    }
    for ($j = $i + 1; $j -lt $Sources.Count; $j++) {
        $b = $Sources[$j]
        if ($a.Src.Name -eq $b.Src.Name) { $problems += "two sources are both named '$($a.Src.Name)'" }
        if ((Test-PathInside $a.Dir $b.Dir) -or (Test-PathInside $b.Dir $a.Dir)) {
            $problems += "'$($a.Src.Name)' and '$($b.Src.Name)' use the same (or nested) InstallFolder, so one could overwrite the other"
        }
    }
}
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Log "CONFIG PROBLEM: $p" }
    Write-Log 'Not checking anything until config.json is fixed.'
    Show-Notification 'Lichii checker: config problem' (($problems | Select-Object -First 1) + ' - nothing was changed.') $ScriptDir
    exit 2
}

$TrayMutexName = 'Local\LichiiCheckerTray'
function Test-TrayRunning {
    try { $m = [System.Threading.Mutex]::OpenExisting($TrayMutexName); $m.Dispose(); return $true } catch { return $false }
}

if ($Status) {
    $state = Get-State
    foreach ($e in $Sources) {
        $st = Get-Prop $state $e.Src.Name
        $exe = Find-Exe $e.Dir (Get-ExeNames $e.Src)
        $latest = Get-Prop $st 'LatestTag'
        $flag = ''
        if ((Get-Prop $st 'UpdateAvailable') -eq $true) { $flag = '   <-- NEW, not installed' }
        Write-Host ''
        Write-Host ("[{0}]  {1}" -f $e.Src.Name, $e.Src.Repo)
        Write-Host ("  folder:      {0}{1}" -f $e.Dir, $(if ($exe) { '' } else { '  (no build there yet)' }))
        Write-Host ("  installed:   {0}  {1}" -f (Get-Prop $st 'Tag'), (Get-Prop $st 'Title'))
        Write-Host ("  on GitHub:   {0}  {1}{2}" -f $latest, (Get-Prop $st 'LatestTitle'), $flag)
        Write-Host ("  last check:  {0}   ({1})" -f (Get-Prop $st 'LastChecked'), (Get-Prop $st 'LastResult'))
    }
    Write-Host ''
    $app = Get-Prop $state '_app'
    $appLine = "Lichii Builds $AppVersion"
    if ($app -and $app.UpdateAvailable) { $appLine += "   (version $($app.LatestVersion) is out: right-click the tray icon to update)" }
    Write-Host $appLine
    if (Test-TrayRunning) { Write-Host 'Tray app: running' } else { Write-Host 'Tray app: NOT running (run "Start Lichii Builds.bat")' }
    exit 0
}

if ($InstallSource -and -not ($Sources | Where-Object { $_.Src.Name -eq $InstallSource })) {
    Write-Log "Unknown source '$InstallSource' (config.json has: $(($Sources | ForEach-Object { $_.Src.Name }) -join ', '))"
    exit 2
}

# A plain run (e.g. the old hourly task) while the tray app isn't running: start the tray app
# instead, and let it do the checking from now on.
if ($OnWindows -and -not $NoNotify -and -not $InstallSource -and -not $UpdateApp -and -not (Test-TrayRunning)) {
    $trayScript = Join-Path $ScriptDir 'LichiiTray.ps1'
    if (Test-Path -LiteralPath $trayScript) {
        $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
        $trayArgs = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Startup' -f $trayScript
        try {
            if (Test-Path -LiteralPath $conhost) { Start-Process -FilePath $conhost -ArgumentList ('--headless "{0}" {1}' -f $ps, $trayArgs) -WindowStyle Hidden }
            else { Start-Process -FilePath $ps -ArgumentList $trayArgs -WindowStyle Hidden }
            Write-Log 'The tray app was not running, so it was started; it does the checking from now on.'
            exit 0
        } catch { Write-Log "Couldn't start the tray app: $($_.Exception.Message). Checking without it." }
    }
}

# Run by an older tray app (before the new look): replace it with the current one.
$TrayUiVersion = 2
if ($OnWindows -and $NoNotify -and -not $InstallSource -and -not $UpdateApp -and (Test-TrayRunning)) {
    $tv = 0
    try { $tj = Get-Content -LiteralPath (Join-Path $ScriptDir 'tray.json') -Raw | ConvertFrom-Json; if ($tj.UiVersion) { $tv = [int]$tj.UiVersion } } catch {}
    $trayScript = Join-Path $ScriptDir 'LichiiTray.ps1'
    if ($tv -lt $TrayUiVersion -and (Test-Path -LiteralPath $trayScript) -and (Test-Path -LiteralPath (Join-Path $ScriptDir 'ui\Flyout.xaml'))) {
        Write-Log 'An older tray app is running; swapping in the new one.'
        try {
            foreach ($proc in @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop)) {
                $cl = [string]$proc.CommandLine
                if ($proc.ProcessId -ne $PID -and $cl -like '*LichiiTray.ps1*' -and $cl -notlike '*-Setup*') { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue }
            }
            for ($i = 0; $i -lt 20 -and (Test-TrayRunning); $i++) { Start-Sleep -Milliseconds 250 }
            $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
            $trayArgs = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Background' -f $trayScript
            if (Test-Path -LiteralPath $conhost) { Start-Process -FilePath $conhost -ArgumentList ('--headless "{0}" {1}' -f $ps, $trayArgs) -WindowStyle Hidden }
            else { Start-Process -FilePath $ps -ArgumentList $trayArgs -WindowStyle Hidden }
            Write-Log 'Started the new tray app.'
        } catch { Write-Log "Couldn't swap the tray app: $($_.Exception.Message)" }
        exit 0
    }
}

# Only one checker run at a time (tray check + manual run can't collide)
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\LichiiBuildChecker')
    $got = $false
    try { $got = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) {
        Write-Log 'Another check is already running; skipping this one.'
        if ($InstallSource) { exit 4 }
        exit 0
    }
} catch { $mutex = $null }

if ($UpdateApp) {
    $code = 4
    try { $st0 = Get-State; $code = Invoke-AppUpdate $st0 }
    finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose() } }
    exit $code
}

$ExitCode = 0
try {
    $state = Get-State
    foreach ($e in $Sources) {
        $src = $e.Src
        $dir = $e.Dir
        $name = [string]$src.Name
        if ($InstallSource -and $name -ne $InstallSource) { continue }
        $forced = [bool]$InstallSource
        $label = Get-Prop $src 'Label'
        if (-not $label) { $label = $name }
        $exeNames = Get-ExeNames $src

        # Relocate a build from an old folder (MoveFrom) into InstallFolder, once nothing runs from it.
        $wait = $false
        if (-not (Find-Exe $dir $exeNames)) {
            foreach ($mf in @(Get-Prop $src 'MoveFrom')) {
                $old = Resolve-PathSetting $mf
                if (-not $old -or -not (Find-Exe $old $exeNames)) { continue }
                if (@(Get-RunningFrom $old $exeNames).Count -gt 0) {
                    Write-Log "Lichii is running from $old; it'll move to $dir after you close it" $name
                    Set-SourceField $state $name 'LastResult' 'waiting: Lichii is running from the old folder'
                    $wait = $true; break
                }
                try {
                    $p = Split-Path -Parent $dir
                    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
                    Move-Folder $old $dir
                    Write-Log "Moved the build from $old to $dir" $name
                } catch {
                    Write-Log "Couldn't move $old to $($dir): $($_.Exception.Message). Will try again next check." $name
                    Set-SourceField $state $name 'LastResult' "waiting: couldn't move $old"
                    $wait = $true
                }
                break
            }
        }
        if ($wait) {
            # Don't install anything while the old copy is in use, but still say what's on GitHub.
            try {
                $nb = Get-NewestBuild $src
                if ($nb) {
                    if ($script:LastRelease) { Update-RepoIfMoved $src $script:LastRelease $state }
                    Set-SourceField $state $name 'LastChecked' (Get-Date).ToString('s')
                    Set-SourceField $state $name 'LatestTag' $nb.Tag
                    Set-SourceField $state $name 'LatestTitle' $nb.Title
                    Set-SourceField $state $name 'LatestUrl' ([string]$nb.Release.html_url)
                    Set-SourceField $state $name 'LatestPublishedAt' $nb.Date.ToString('o')
                    Set-SourceField $state $name 'LatestAsset' ([string]$nb.Asset.name)
                    Set-SourceField $state $name 'LatestSizeMB' ([math]::Round(([double]$nb.Asset.size) / 1MB, 1))
                    Set-SourceField $state $name 'LatestIsTest' ([bool]$nb.IsTest)
                    Set-SourceField $state $name 'LatestBranch' ([string]$nb.Branch)
                    Set-SourceField $state $name 'UpdateAvailable' ((Get-Prop (Get-Prop $state $name) 'Tag') -ne $nb.Tag)
                }
            } catch { Write-Log "Couldn't reach GitHub for $($src.Repo): $($_.Exception.Message)" $name }
            Save-State $state
            if ($forced) { $ExitCode = 3 }
            continue
        }

        try { $newest = Get-NewestBuild $src }
        catch {
            $msg = $_.Exception.Message
            Write-Log "Couldn't reach GitHub for $($src.Repo): $msg" $name
            Set-SourceField $state $name 'LastResult' "couldn't reach GitHub: $msg"
            Save-State $state
            if ($forced) { $ExitCode = 4 }
            continue
        }
        Set-SourceField $state $name 'LastChecked' (Get-Date).ToString('s')

        if (-not $newest) {
            Write-Log "No Windows build found in $($src.Repo) releases" $name
            Set-SourceField $state $name 'LastResult' 'no Windows build on GitHub'
            Save-State $state
            if ($forced) { $ExitCode = 4 }
            continue
        }

        if ($script:LastRelease) { Update-RepoIfMoved $src $script:LastRelease $state }
        Set-SourceField $state $name 'LatestTag' $newest.Tag
        Set-SourceField $state $name 'LatestTitle' $newest.Title
        Set-SourceField $state $name 'LatestUrl' ([string]$newest.Release.html_url)
        Set-SourceField $state $name 'LatestPublishedAt' $newest.Date.ToString('o')
        Set-SourceField $state $name 'LatestAsset' ([string]$newest.Asset.name)
        Set-SourceField $state $name 'LatestSizeMB' ([math]::Round(([double]$newest.Asset.size) / 1MB, 1))
        Set-SourceField $state $name 'LatestIsTest' ([bool]$newest.IsTest)
        Set-SourceField $state $name 'LatestBranch' ([string]$newest.Branch)

        $st = Get-Prop $state $name
        $curTag = Get-Prop $st 'Tag'
        $haveExe = Find-Exe $dir $exeNames

        if ($haveExe -and $curTag -eq $newest.Tag) {
            Write-Log "Up to date ($($newest.Tag))" $name
            Set-SourceField $state $name 'UpdateAvailable' $false
            Set-SourceField $state $name 'LastResult' 'up to date'
            Save-State $state
            continue
        }

        if ($haveExe -and $curTag -and ((ConvertTo-UtcDate (Get-Prop $st 'PublishedAt')) -gt $newest.Date)) {
            Write-Log "Installed $curTag is newer than anything listed on GitHub; leaving it alone" $name
            Set-SourceField $state $name 'UpdateAvailable' $false
            Set-SourceField $state $name 'LastResult' 'up to date (installed build is newer than GitHub)'
            Save-State $state
            continue
        }

        if ((Test-Path -LiteralPath $dir) -and -not $haveExe) {
            Write-Log "Install folder exists but has no $($exeNames -join ' / ') in it, so it isn't touched: $dir" $name
            Set-SourceField $state $name 'UpdateAvailable' $false
            Set-SourceField $state $name 'LastResult' "skipped: $dir isn't a Lichii build folder"
            if ((Get-Prop $st 'WarnedFolder') -ne $dir) {
                Show-Notification "Lichii $($label): folder skipped" "$dir doesn't look like a Lichii build, so the checker won't touch it. Fix InstallFolder in config.json." $dir
                Set-SourceField $state $name 'WarnedFolder' $dir
            }
            Save-State $state
            if ($forced) { $ExitCode = 4 }
            continue
        }

        Set-SourceField $state $name 'UpdateAvailable' $true
        if ((Get-Prop $src 'AutoInstall') -eq $false -and -not $forced) {
            Write-Log "New build available: $($newest.Tag) ($($newest.Title)). Not downloading until you say so." $name
            Set-SourceField $state $name 'LastResult' 'new build available'
            if ((Get-Prop $st 'NotifiedTag') -ne $newest.Tag) {
                Show-Notification "New Lichii build ($label)" "$($newest.Title) is out." $null
                if (-not $NoNotify) { Set-SourceField $state $name 'NotifiedTag' $newest.Tag }
            }
            Save-State $state
            continue
        }

        $running = @(Get-RunningFrom $dir $exeNames)
        if ($running.Count -gt 0) {
            Write-Log "Can't install $($newest.Tag) yet: Lichii is running from this folder." $name
            Set-SourceField $state $name 'LastResult' 'waiting: Lichii is running from this folder'
            if (-not $forced -and (Get-Prop $st 'NotifiedTag') -ne $newest.Tag) {
                Show-Notification "New Lichii build ready ($label)" "$($newest.Title) is out. Close Lichii and it installs on the next check." $null
                if (-not $NoNotify) { Set-SourceField $state $name 'NotifiedTag' $newest.Tag }
            }
            Save-State $state
            if ($forced) { $ExitCode = 3 }
            continue
        }

        Set-SourceField $state $name 'LastResult' "installing $($newest.Tag)"
        Save-State $state
        try {
            $archived = Install-Build $src $newest $dir $ArchiveDir $state
        } catch {
            $msg = $_.Exception.Message
            Write-Log "Install of $($newest.Tag) failed: $msg (old build left as it was)" $name
            Set-SourceField $state $name 'LastResult' "install failed: $msg"
            if ((Get-Prop $st 'FailedTag') -ne $newest.Tag) {
                Show-Notification "Lichii $($label) update failed" "$($newest.Tag): $msg. Your current build wasn't changed." $LogPath
                Set-SourceField $state $name 'FailedTag' $newest.Tag
            }
            Save-State $state
            if ($forced) { $ExitCode = 4 }
            continue
        }

        $record = [pscustomobject]@{
            Repo              = $src.Repo
            Tag               = $newest.Tag
            Title             = $newest.Title
            Asset             = $newest.Asset.name
            ReleaseId         = $newest.Release.id
            PublishedAt       = $newest.Date.ToString('o')
            InstalledAt       = (Get-Date).ToString('s')
            LastChecked       = (Get-Date).ToString('s')
            Folder            = $dir
            NotifiedTag       = $newest.Tag
            LatestTag         = $newest.Tag
            LatestTitle       = $newest.Title
            LatestUrl         = [string]$newest.Release.html_url
            LatestPublishedAt = $newest.Date.ToString('o')
            LatestAsset       = [string]$newest.Asset.name
            LatestSizeMB      = [math]::Round(([double]$newest.Asset.size) / 1MB, 1)
            LatestIsTest      = [bool]$newest.IsTest
            LatestBranch      = [string]$newest.Branch
            IsTest            = [bool]$newest.IsTest
            UpdateAvailable   = $false
            LastResult        = 'installed'
            ArchivedTo        = [string]$archived
        }
        Set-SourceState $state $name $record
        Save-State $state

        $where = 'Fresh install.'
        if ($archived) { $where = "Old build moved to $archived" }
        Write-Log "Installed $($newest.Tag) into $dir. $where" $name
        $toastBody = "$($newest.Title) is installed."
        if ($archived) { $toastBody += ' Old build moved to ARCHIVE.' }
        Show-Notification "Lichii $label updated" $toastBody $dir
    }
    if (-not $InstallSource) { Update-AppInfo $state; Save-State $state }
} finally {
    if ($mutex) { try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose() }
}
exit $ExitCode
