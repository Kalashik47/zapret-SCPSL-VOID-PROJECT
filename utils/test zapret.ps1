$hasErrors = $false

$rootDir = Split-Path $PSScriptRoot
$listsDir = Join-Path $rootDir "lists"
$utilsDir = Join-Path $rootDir "utils"
$resultsDir = Join-Path $utilsDir "test results"
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }

# Define functions early
function Get-IpsetStatus {
    $listFile = Join-Path $listsDir "ipset-all.txt"
    if (-not (Test-Path $listFile)) { return "none" }
    $lineCount = (Get-Content $listFile | Measure-Object -Line).Lines
    if ($lineCount -eq 0) { return "any" }
    $hasDummy = Get-Content $listFile | Select-String -Pattern "203\.0\.113\.113/32" -Quiet
    if ($hasDummy) { return "none" } else { return "loaded" }
}

function Set-IpsetMode {
    param([string]$mode)
    $listFile = Join-Path $listsDir "ipset-all.txt"
    $backupFile = Join-Path $listsDir "ipset-all.test-backup.txt"
    if ($mode -eq "any") {
        # Always backup current file (even if none)
        if (Test-Path $listFile) {
            Copy-Item $listFile $backupFile -Force
        } else {
            # If none, create empty backup
            "" | Out-File $backupFile -Encoding UTF8
        }
        # Make file empty
        "" | Out-File $listFile -Encoding UTF8
    } elseif ($mode -eq "restore") {
        if (Test-Path $backupFile) {
            Move-Item $backupFile $listFile -Force
        }
    }
}

trap {
    Write-Host "[ERROR] Script interrupted. Restoring ipset..." -ForegroundColor Red
    if ($originalIpsetStatus -and $originalIpsetStatus -ne "any") {
        Set-IpsetMode -mode "restore"
    }
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
    break
}

function New-OrderedDict { New-Object System.Collections.Specialized.OrderedDictionary }
function Add-OrSet {
    param($dict, $key, $val)
    if ($dict.Contains($key)) { $dict[$key] = $val } else { $dict.Add($key, $val) }
}

# Convert raw target value to structured target (supports PING:ip for ping-only targets)
function Convert-Target {
    param(
        [string]$Name,
        [string]$Value
    )

    if ($Value -like "PING:*") {
        $ping = $Value -replace '^PING:\s*', ''
        $url = $null
        $pingTarget = $ping
    } else {
        $url = $Value
        $pingTarget = $url -replace "^https?://", "" -replace "/.*$", ""
    }

    return (New-Object PSObject -Property @{
        Name       = $Name
        Url        = $url
        PingTarget = $pingTarget
    })
}

# DPI checker defaults (override via MONITOR_* env vars like in monitor.ps1)
$dpiTimeoutSeconds = 5
$dpiRangeBytes = 65536
$dpiMaxParallel = 8
$dpiCustomHost = $env:MONITOR_HOST
if ($env:MONITOR_TIMEOUT) { [int]$dpiTimeoutSeconds = $env:MONITOR_TIMEOUT }
if ($env:MONITOR_RANGE) { [int]$dpiRangeBytes = $env:MONITOR_RANGE }
if ($env:MONITOR_MAX_PARALLEL) { [int]$dpiMaxParallel = $env:MONITOR_MAX_PARALLEL }

function Get-DpiSuite {
    # Suite sourced from https://github.com/hyperion-cs/dpi-checkers (Apache-2.0 license)
    # Original copyright retained from dpi-checkers repository
    $url = "https://hyperion-cs.github.io/dpi-checkers/ru/tcp-16-20/suite.v2.json"

    try {
        (Invoke-RestMethod -Uri $url -TimeoutSec $dpiTimeoutSeconds) |
            Select-Object `
                @{n='Id';       e={$_.id}},
                @{n='Provider'; e={$_.provider}},
                @{n='Country';  e={$_.country}},
                @{n='Host';     e={$_.host}}
    }
    catch {
        Write-Host "[WARN] Fetch dpi suite failed." -ForegroundColor Yellow
        @()
    }
}

function Build-DpiTargets {
    param(
        [string]$CustomHost
    )

    $suite = Get-DpiSuite
    $targets = @()

    if ($CustomHost) {
        $targets += @{ Id = "CUSTOM"; Provider = "Custom"; Country = "💡"; Host = $CustomHost }
    } else {
        foreach ($entry in $suite) {
            $targets += @{ Id = $entry.Id; Country = $entry.Country; Provider = $entry.Provider; Host = $entry.Host }
        }
    }

    return $targets
}

function Invoke-DpiSuite {
    param(
        [array]$Targets,
        [int]$TimeoutSeconds,
        [int]$RangeBytes,
        [int]$MaxParallel
    )

    $tests = @(
        @{ Label = "HTTP";   Args = @("--http1.1") },
        @{ Label = "TLS1.2"; Args = @("--tlsv1.2", "--tls-max", "1.2") },
        @{ Label = "TLS1.3"; Args = @("--tlsv1.3", "--tls-max", "1.3") }
    )

    $rangeSpec = "0-$($RangeBytes - 1)"
    $warnDetected = $false

    Write-Host "[INFO] Targets: $($Targets.Count) (custom URL overrides suite). Range: $rangeSpec bytes; Timeout: $($TimeoutSeconds)s" -ForegroundColor Cyan
    Write-Host "[INFO] Starting DPI TCP 16-20 checks (parallel: $MaxParallel)..." -ForegroundColor DarkGray

    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxParallel)
    $runspacePool.Open()

    $payload = New-Object byte[] $RangeBytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($payload)

    $payloadFile = New-TemporaryFile
    [IO.File]::WriteAllBytes($payloadFile, $payload)

    $scriptBlock = {
        param($payloadFile, $target, $tests, $rangeSpec, $TimeoutSeconds)

        $warned = $false
        $lines = @()

        foreach ($test in $tests) {
            $curlArgs = @(
                "--range", $rangeSpec,
                "-m", $TimeoutSeconds,
                "-w", "%{http_code} %{size_upload} %{size_download} %{time_total}",
                "-o", "NUL",
                "-X", "POST",
                "--data-binary", "@$payloadFile",
                "-s"
            ) + $test.Args + @("https://$($target.Host)")

            $output = $payload | curl.exe @curlArgs 2>&1
            $exit = $LASTEXITCODE
            $text = ($output | Out-String).Trim()

            $code = "NA"
            $upBytes = 0
            $downBytes = 0
            $time = -1

            if ($text -match '^(?<code>\d{3})\s+(?<up>\d+)\s+(?<down>\d+)\s+(?<time>[\d\.]+)$') {
                $code = $matches['code']
                $upBytes = [int64]$matches['up']
                $downBytes = [int64]$matches['down']
                $time = [double]$matches['time']
            } elseif (($exit -eq 35) -or ($text -match "not supported|does not support|protocol\s+'.+'\s+not\s+supported|protocol\s+.+\s+not\s+supported|unsupported protocol|TLS.not supported|Unrecognized option|Unknown option|unsupported option|unsupported feature|schannel|SSL")) {
                $code = "UNSUP"
            } elseif ($text) {
                $code = "ERR"
            }

            $upKB = [math]::Round($upBytes / 1024, 1)
            $downKB = [math]::Round($downBytes / 1024, 1)
            $status = "OK"
            $color = "Green"

            if ($code -eq "UNSUP") {
                $status = "UNSUPPORTED"
                $color = "Yellow"
            } elseif ($exit -ne 0 -or $code -eq "ERR" -or $code -eq "NA") {
                $status = "FAIL"
                $color = "Red"
            }

            if (($upBytes -gt 0) -and ($downBytes -eq 0) -and ($time -ge $TimeoutSeconds) -and ($exit -ne 0)) {
                $status = "LIKELY_BLOCKED"
                $color = "Yellow"
                $warned = $true
            }

            $lines += [PSCustomObject]@{
                TestLabel = $test.Label
                Code      = $code
                UpBytes   = $upBytes
                UpKB      = $upKB
                DownBytes = $downBytes
                DownKB    = $downKB
                Time      = $time
                Status    = $status
                Color     = $color
                Warned    = $warned
            }
        }

        return [PSCustomObject]@{
            TargetId = $target.Id
            Provider = $target.Provider
            Country   = $target.Country
            Lines    = $lines
            Warned   = $warned
        }
    }

    $runspaces = @()
    foreach ($target in $Targets) {
        $powershell = [powershell]::Create().AddScript($scriptBlock)
        [void]$powershell.AddArgument($payloadFile)
        [void]$powershell.AddArgument($target)
        [void]$powershell.AddArgument($tests)
        [void]$powershell.AddArgument($rangeSpec)
        [void]$powershell.AddArgument($TimeoutSeconds)
        $powershell.RunspacePool = $runspacePool

        $runspaces += [PSCustomObject]@{
            Powershell = $powershell
            Handle     = $powershell.BeginInvoke()
            TargetId   = $target.Id
        }
    }

    $results = @()
    foreach ($rs in $runspaces) {
        # Wait for the runspace to complete with a small grace period beyond curl's timeout
        try {
            # Each target runs three curl variants sequentially inside its runspace.
            $waitMs = (([int]$TimeoutSeconds * 3) + 5) * 1000
            $handle = $rs.Handle
            if ($handle -and $handle.AsyncWaitHandle) {
                $completed = $handle.AsyncWaitHandle.WaitOne($waitMs)
                if (-not $completed) {
                    Write-Host "[WARN] Runspace for [$($rs.TargetId)] timed out after $waitMs ms; stopping runspace..." -ForegroundColor Yellow
                    try { $rs.Powershell.Stop() } catch {}
                }
            }
        } catch {
            # ignore wait errors and attempt to EndInvoke
        }

        try {
            $res = $rs.Powershell.EndInvoke($rs.Handle)
            $results += $res

            Write-Host "`n=== [$($res.Country)][$($res.Provider)] $($res.TargetId) ===" -ForegroundColor DarkCyan
            foreach ($line in $res.Lines) {
                $msg = "[{0}] code={1} buf_up={2} bytes ({3} KB) buf_down={4} bytes ({5} KB) time={6}s status={7}" -f $line.TestLabel, $line.Code, $line.UpBytes, $line.UpKB, $line.DownBytes, $line.DownKB, $line.Time, $line.Status
                Write-Host $msg -ForegroundColor $line.Color
                if ($line.Status -eq "LIKELY_BLOCKED") {
                    Write-Host "  Pattern matches 16-20KB freeze; censor likely cutting this strategy." -ForegroundColor Yellow
                }
            }

            if ($res.Warned) {
                $warnDetected = $true
            } else {
                Write-Host "  No 16-20KB freeze pattern for this target." -ForegroundColor Green
            }
        } catch {
            Write-Host "[WARN] EndInvoke failed for a runspace; treating as failure." -ForegroundColor Yellow
            $failedLine = [PSCustomObject]@{
                TestLabel  = 'RUNSPACE'
                Code       = 'ERR'
                SizeBytes  = 0
                SizeKB     = 0
                Status     = 'FAIL'
                Color      = 'Red'
                Warned     = $false
            }
            $results += [PSCustomObject]@{ TargetId = 'UNKNOWN'; Provider = 'UNKNOWN'; Lines = @($failedLine); Warned = $false }
        }
        $rs.Powershell.Dispose()
    }
    $runspacePool.Close()
    $runspacePool.Dispose()

    if ($warnDetected) {
        Write-Host ""
        Write-Host "[WARNING] Detected possible DPI TCP 16-20 blocking on one or more targets. Consider changing strategy/SNI/IP." -ForegroundColor Red
    } else {
        Write-Host ""
        Write-Host "[OK] No 16-20KB freeze pattern detected across targets." -ForegroundColor Green
    }

    return $results
}

function Test-ZapretServiceConflict {
    return [bool](Get-Service -Name "zapret" -ErrorAction SilentlyContinue)
}

# Check Admin
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] Run as Administrator to execute tests" -ForegroundColor Red
    $hasErrors = $true
} else {
    Write-Host "[OK] Administrator rights detected" -ForegroundColor Green
}

# Check curl
if (-not (Get-Command "curl.exe" -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] curl.exe not found" -ForegroundColor Red
    Write-Host "Install curl or add it to PATH" -ForegroundColor Yellow
    $hasErrors = $true
} else {
    Write-Host "[OK] curl.exe found" -ForegroundColor Green
}

# Check for leftover ipset flag from previous interrupted run
$ipsetFlagFile = Join-Path $rootDir "ipset_switched.flag"
if (Test-Path $ipsetFlagFile) {
    Write-Host "[INFO] Detected leftover ipset switch flag. Restoring ipset..." -ForegroundColor Yellow
    Set-IpsetMode -mode "restore"
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
}

# Get original ipset status early
$originalIpsetStatus = Get-IpsetStatus

# Warn about ipset switching and X button behavior
if ($originalIpsetStatus -ne "any") {
    Write-Host "[INFO] Current ipset status: $originalIpsetStatus" -ForegroundColor Cyan
    Write-Host "[WARNING] Ipset will be switched to 'any' for accurate DPI tests." -ForegroundColor Yellow
    Write-Host "[WARNING] If you close the window with the X button, ipset will NOT restore immediately." -ForegroundColor Yellow
    Write-Host "[WARNING] It will be restored automatically on the next script run." -ForegroundColor Yellow
}

# Check if zapret service installed
if (Test-ZapretServiceConflict) {
    Write-Host "[ERROR] Windows service 'zapret' is installed" -ForegroundColor Red
    Write-Host "         Remove the service before running tests" -ForegroundColor Yellow
    Write-Host "         Open service.bat and choose 'Remove Services'" -ForegroundColor Yellow
    $hasErrors = $true
}

if ($hasErrors) {
    Write-Host ""
    Write-Host "Fix the errors above and rerun." -ForegroundColor Yellow
    Write-Host "Press any key to exit..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
    exit 1
}

$dpiTargets = Build-DpiTargets -CustomHost $dpiCustomHost

# Config
$targetDir = $rootDir
if (-not $targetDir) { $targetDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$batFiles = Get-ChildItem -Path $targetDir -Filter "general*.bat" |
    Where-Object { $_.Name -like 'general (SCPSL HARD *).bat' } |
    Sort-Object { [Regex]::Replace($_.Name, "(\d+)", { $args[0].Value.PadLeft(8, "0") }) }

$globalResults = @()

# Select top-level test type (standard vs DPI checkers)
function Read-TestType {
    while ($true) {
        Write-Host ""
        Write-Host "Select test type:" -ForegroundColor Cyan
        Write-Host "  [1] Standard tests (HTTP/ping)" -ForegroundColor Gray
        Write-Host "  [2] DPI checkers (TCP 16-20 freeze)" -ForegroundColor Gray
        $choice = Read-Host "Enter 1 or 2"
        switch ($choice) {
            '1' { return 'standard' }
            '2' { return 'dpi' }
            default { Write-Host "Incorrect input. Please try again." -ForegroundColor Yellow }
        }
    }
}

# Select test mode: all configs or custom subset
function Read-ModeSelection {
    while ($true) {
        Write-Host ""
        Write-Host "Select test run mode:" -ForegroundColor Cyan
        Write-Host "  [1] All SCP:SL HARD profiles 1-24" -ForegroundColor Gray
        Write-Host "  [2] Selected SCP:SL HARD profiles" -ForegroundColor Gray
        Write-Host "  [3] Confirmed md5sig variants 16-24" -ForegroundColor Gray
        $choice = Read-Host "Enter 1, 2 or 3"
        switch ($choice) {
            '1' { return 'scpsl-hard' }
            '2' { return 'select' }
            '3' { return 'scpsl-new' }
            default { Write-Host "Incorrect input. Please try again." -ForegroundColor Yellow }
        }
    }
}

function Read-ConfigSelection {
    param([array]$allFiles)

    while ($true) {
        Write-Host "" 
        Write-Host "Available configs:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $allFiles.Count; $i++) {
            $idx = $i + 1
            Write-Host "  [$idx] $($allFiles[$i].Name)" -ForegroundColor Gray
        }

        $selectionInput = Read-Host "Enter numbers (e.g. 1,3,5) , ranges (e.g. 2-7), or mixed (e.g. 1,5-10,12). '0' for all"
        $trimmed = $selectionInput.Trim()
        
        if ($trimmed -eq '0') {
            return $allFiles
        }

        $parts = $selectionInput -split '[,\s]+' | Where-Object { $_ -match '^\d+(-\d+)?$' }
        if ($parts.Count -eq 0) {
            Write-Host ""
            Write-Host "Invalid input format. Use numbers, ranges (1-5), or combinations (1,3-7,10). Try again." -ForegroundColor Yellow
            continue
        }
        $selectedIndices = @()
        $hasErrors = $false
        
        foreach ($part in $parts) {
            if ($part -match '^(\d+)-(\d+)$') {
                $start = [int]$matches[1]
                $end = [int]$matches[2]
                
                if ($start -gt $end) {
                    Write-Host "  [WARN] Invalid range '$part' (start > end). Skipping." -ForegroundColor Yellow
                    $hasErrors = $true
                    continue
                }
                
                if ($start -lt 1 -or $end -gt $allFiles.Count) {
                    Write-Host "  [WARN] Range '$part' out of bounds (valid: 1-$($allFiles.Count)). Skipping invalid parts." -ForegroundColor Yellow
                    $hasErrors = $true
                    $start = [Math]::Max($start, 1)
                    $end = [Math]::Min($end, $allFiles.Count)
                }
                
                for ($i = $start; $i -le $end; $i++) {
                    $selectedIndices += $i
                }
            } else {
                $num = [int]$part
                if ($num -ge 1 -and $num -le $allFiles.Count) {
                    $selectedIndices += $num
                } else {
                    Write-Host "  [WARN] Number '$num' out of bounds (valid: 1-$($allFiles.Count)). Skipping." -ForegroundColor Yellow
                    $hasErrors = $true
                }
            }
        }
        $valid = $selectedIndices | Sort-Object -Unique | Where-Object { $_ -ge 1 -and $_ -le $allFiles.Count }
        if ($valid.Count -eq 0) {
            Write-Host ""
            Write-Host "No valid configs selected. Try again." -ForegroundColor Yellow
            continue
        }

        # Checker
         Write-Host "Selected configs: $($valid -join ', ')" -ForegroundColor Green
        if ($hasErrors) {
            Write-Host "Some entries were skipped due to errors (see warnings above)." -ForegroundColor Yellow
        }
        
        return $valid | ForEach-Object { $allFiles[$_ - 1] }
    }
}

while ($true) {
    $globalResults = @()
$testType = Read-TestType
$mode = Read-ModeSelection
if ($mode -eq 'select') {
    $selected = Read-ConfigSelection -allFiles $batFiles
    $batFiles = @($selected)
} elseif ($mode -eq 'scpsl-hard') {
    $batFiles = @($batFiles | Where-Object { $_.Name -like 'general (SCPSL HARD *).bat' })
    Write-Host "[INFO] Selected $($batFiles.Count) aggressive SCP:SL profiles." -ForegroundColor Cyan
} elseif ($mode -eq 'scpsl-new') {
    $batFiles = @($batFiles | Where-Object { $_.Name -match '^general \(SCPSL HARD (1[6-9]|2[0-4])\)\.bat$' })
    Write-Host "[INFO] Selected $($batFiles.Count) variants of the confirmed md5sig profile." -ForegroundColor Cyan
}

# Load targets once for standard mode
$targetList = @()
$maxNameLen = 10
if ($testType -eq 'standard') {
    $targetsFile = Join-Path $utilsDir "targets.txt"
    $rawTargets = New-OrderedDict
    if (Test-Path $targetsFile) {
        Get-Content $targetsFile | ForEach-Object {
            if ($_ -match '^\s*(\w+)\s*=\s*"(.+)"\s*$') {
                Add-OrSet -dict $rawTargets -key $matches[1] -val $matches[2]
            }
        }
    }

    if ($rawTargets.Count -eq 0) {
        Write-Host "[INFO] targets.txt missing or empty. Using defaults." -ForegroundColor Gray
        Add-OrSet $rawTargets "Discord Main"           "https://discord.com"
        Add-OrSet $rawTargets "Discord Gateway"        "https://gateway.discord.gg"
        Add-OrSet $rawTargets "Discord CDN"            "https://cdn.discordapp.com"
        Add-OrSet $rawTargets "Discord Updates"        "https://updates.discord.com"
        Add-OrSet $rawTargets "YouTube Web"            "https://www.youtube.com"
        Add-OrSet $rawTargets "YouTube Short"          "https://youtu.be"
        Add-OrSet $rawTargets "YouTube Image"          "https://i.ytimg.com"
        Add-OrSet $rawTargets "YouTube Video Redirect" "https://redirector.googlevideo.com"
        Add-OrSet $rawTargets "Google Main"            "https://www.google.com"
        Add-OrSet $rawTargets "Google Gstatic"         "https://www.gstatic.com"
        Add-OrSet $rawTargets "Cloudflare Web"         "https://www.cloudflare.com"
        Add-OrSet $rawTargets "Cloudflare CDN"         "https://cdnjs.cloudflare.com"
        Add-OrSet $rawTargets "SCPSL Main"             "https://scpslgame.com"
        Add-OrSet $rawTargets "SCPSL Api"              "https://api.scpslgame.com"
        Add-OrSet $rawTargets "SCPSL Api Servers"      "https://api.scpslgame.com/servers.php"
        Add-OrSet $rawTargets "SCPSL Sbg1"             "https://sbg1.scpslgame.com"
        Add-OrSet $rawTargets "SCPSL Slac"             "https://slac.scpslgame.com"
        Add-OrSet $rawTargets "Cloudflare DNS 1.1.1.1" "PING:1.1.1.1"
        Add-OrSet $rawTargets "Cloudflare DNS 1.0.0.1" "PING:1.0.0.1"
        Add-OrSet $rawTargets "Google DNS 8.8.8.8"     "PING:8.8.8.8"
        Add-OrSet $rawTargets "Google DNS 8.8.4.4"     "PING:8.8.4.4"
        Add-OrSet $rawTargets "Quad9 DNS 9.9.9.9"      "PING:9.9.9.9"
    } else {
        Write-Host ""
        Write-Host "[INFO] Loaded targets from targets.txt" -ForegroundColor Gray
        Write-Host "[INFO] Targets loaded: $($rawTargets.Count)" -ForegroundColor Gray
    }

    foreach ($key in $rawTargets.Keys) {
        $targetList += Convert-Target -Name $key -Value $rawTargets[$key]
    }

    if ($mode -eq 'scpsl-hard' -or $mode -eq 'scpsl-new') {
        $targetList = @($targetList | Where-Object { $_.Name -like 'SCPSL*' -or $_.Name -like 'Cloudflare*' })
        Write-Host "[INFO] SCP:SL mode: unrelated Discord/YouTube/Google targets were skipped." -ForegroundColor DarkGray
    }

    $maxNameLen = ($targetList | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    if (-not $maxNameLen -or $maxNameLen -lt 10) { $maxNameLen = 10 }
}

# Ensure we have configs to run
if (-not $batFiles -or $batFiles.Count -eq 0) {
    Write-Host "[ERROR] No general*.bat files found" -ForegroundColor Red
    Write-Host "Press any key to exit..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
    exit 1
}

# Stop winws
function Stop-Zapret {
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force
}

# Capture/restore running winws instances to return user ipset/config
function Get-WinwsSnapshot {
    try {
        return Get-CimInstance Win32_Process -Filter "Name='winws.exe'" |
            Select-Object ProcessId, CommandLine, ExecutablePath
    } catch {
        return @()
    }
}

function Restore-WinwsSnapshot {
    param($snapshot)

    if (-not $snapshot -or $snapshot.Count -eq 0) { return }

    $current = @()
    try { $current = (Get-WinwsSnapshot).CommandLine } catch { $current = @() }

    Write-Host "[INFO] Restoring previously running winws instances..." -ForegroundColor DarkGray
    foreach ($p in $snapshot) {
        if (-not $p.ExecutablePath) { continue }

        # Skip if an identical command line is already active
        if ($current -and $current -contains $p.CommandLine) { continue }

        $exe = $p.ExecutablePath
        $processArgs = ""
        if ($p.CommandLine) {
            $quotedExe = '"' + $exe + '"'
            if ($p.CommandLine.StartsWith($quotedExe)) {
                $processArgs = $p.CommandLine.Substring($quotedExe.Length).Trim()
            } elseif ($p.CommandLine.StartsWith($exe)) {
                $processArgs = $p.CommandLine.Substring($exe.Length).Trim()
            }
        }

        Start-Process -FilePath $exe -ArgumentList $processArgs -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Minimized | Out-Null
    }
}

$env:NO_UPDATE_CHECK = "1"
$originalWinws = Get-WinwsSnapshot

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                 ZAPRET CONFIG TESTS" -ForegroundColor Cyan
Write-Host "                 Mode: $($testType.ToUpper())" -ForegroundColor Cyan
Write-Host "                 Total configs: $($batFiles.Count.ToString().PadLeft(2))" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

try {
    # Save original ipset status and switch to 'any' for accurate DPI tests
    if (($originalIpsetStatus -ne "any") -and ($testType -eq 'dpi')) {
        Write-Host "[WARNING] Ipset is in '$originalIpsetStatus' mode. Switching to 'any' for accurate DPI tests..." -ForegroundColor Yellow
        Set-IpsetMode -mode "any"
        # Create flag file to indicate ipset was switched
        "" | Out-File -FilePath $ipsetFlagFile -Encoding UTF8
    }
    Write-Host "[WARNING] Tests may take several minutes to complete. Please wait..." -ForegroundColor Yellow

    $configNum = 0
    foreach ($file in $batFiles) {
    $configNum++
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "  [$configNum/$($batFiles.Count)] $($file.Name)" -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
    
    # Cleanup
    Stop-Zapret
    
    # Start config
    Write-Host "  > Starting config..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$($file.FullName)`"" -WorkingDirectory $targetDir -PassThru -WindowStyle Minimized
    
    # Wait init
    Start-Sleep -Seconds 5

    # A batch file can exit successfully even when winws rejected an argument.
    # Never treat direct, unfiltered curl results as a tested strategy.
    $activeWinws = @(Get-WinwsSnapshot)
    if ($activeWinws.Count -eq 0) {
        $fallbackWinws = @(Get-Process -Name "winws" -ErrorAction SilentlyContinue)
        foreach ($fallbackProcess in $fallbackWinws) {
            $activeWinws += [PSCustomObject]@{
                ProcessId = $fallbackProcess.Id
                CommandLine = '[command line unavailable through CIM]'
                ExecutablePath = $null
            }
        }
    }
    if ($activeWinws.Count -eq 0) {
        Write-Host "  [STARTUP ERROR] winws.exe is not running. This config was NOT tested." -ForegroundColor Red
        $globalResults += @{
            Config = $file.Name
            Type = 'startup_error'
            Error = 'winws.exe exited or failed to start before network checks'
        }
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        continue
    }

    $activePid = ($activeWinws | Select-Object -First 1).ProcessId
    $activeCommandLine = ($activeWinws | Select-Object -First 1).CommandLine
    Write-Host "  [OK] winws.exe is active (PID $activePid)." -ForegroundColor Green
    
    if ($testType -eq 'standard') {
        $curlTimeoutSeconds = 7

        # Parallel target checks via runspace pool (faster than jobs)
        $maxParallel = 8
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxParallel)
        $runspacePool.Open()

        $skipTls13 = ($mode -eq 'scpsl-hard' -or $mode -eq 'scpsl-new')
        # SCP:SL targets get one additional Unity-like request.
        $curlTestCount = 4

        $scriptBlock = {
            param($t, $curlTimeoutSeconds, $skipTls13)

            $httpPieces = @()
            $remoteIps = @()
            $resolvedIps = @()

            if ($t.PingTarget) {
                try {
                    $resolvedIps = @([System.Net.Dns]::GetHostAddresses($t.PingTarget) |
                        ForEach-Object { $_.IPAddressToString } |
                        Sort-Object -Unique)
                } catch {
                    $resolvedIps = @()
                }
            }

            if ($t.Url) {
                $tests = @(
                    @{ Label = "HTTP";   Args = @("--http1.1") },
                    @{ Label = "TLS1.2"; Args = @("--tlsv1.2", "--tls-max", "1.2") }
                )
                if (-not $skipTls13) {
                    $tests += @{ Label = "TLS1.3"; Args = @("--tlsv1.3", "--tls-max", "1.3") }
                }
                if ($t.Name -like "SCPSL*") {
                    $tests += @{
                        Label = "GAMEUA"
                        Args = @("--http1.1", "-A", "UnityPlayer/2022.3 (UnityWebRequest/1.0, libcurl)", "-H", "Accept: application/json")
                    }
                }

                # GET with a small range is closer to the game than HEAD. Curl timings
                # separate a TCP timeout from a TLS timeout or a silent HTTP endpoint.
                $metricFormat = "%{http_code}|%{remote_ip}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}"
                $baseArgs = @("-sS", "-m", $curlTimeoutSeconds, "--connect-timeout", $curlTimeoutSeconds, "--range", "0-1023", "-o", "NUL", "-w", $metricFormat)

                foreach ($test in $tests) {
                    try {
                        $curlArgs = $baseArgs + $test.Args
                        $stderr = $null
                        $output = & curl.exe @curlArgs $t.Url 2>&1 | ForEach-Object {
                            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                                $stderr += $_.Exception.Message + " "
                            } else {
                                $_
                            }
                        }
                        $curlExitCode = $LASTEXITCODE
                        $metricText = (($output | Select-Object -Last 1) | Out-String).Trim()
                        $httpCode = "000"
                        $remoteIp = ""
                        $connectTime = 0.0
                        $appConnectTime = 0.0

                        if ($metricText -match '^(?<code>\d{3})\|(?<ip>[^|]*)\|(?<connect>[\d\.]+)\|(?<app>[\d\.]+)\|(?<start>[\d\.]+)$') {
                            $httpCode = $matches['code']
                            $remoteIp = $matches['ip']
                            $connectTime = [double]::Parse($matches['connect'], [Globalization.CultureInfo]::InvariantCulture)
                            $appConnectTime = [double]::Parse($matches['app'], [Globalization.CultureInfo]::InvariantCulture)
                            if ($remoteIp) { $remoteIps += $remoteIp }
                        }

                        $dnsFailure = (($curlExitCode -eq 6) -or ($stderr -match "Could not resolve host|Name or service not known|No such host is known"))
                        if ($dnsFailure) {
                            $httpPieces += "$($test.Label):DNS"
                            continue
                        }

                        $certificateFailure = ($stderr -match "certificate|SSL certificate problem|self[- ]?signed|certificate verify failed|unable to get local issuer certificate")
                        if ($certificateFailure) {
                            $httpPieces += "$($test.Label):CERT"
                            continue
                        }

                        $unsupported = ($stderr -match "does not support|not supported|protocol\s+'?.+'?\s+not\s+supported|unsupported protocol|TLS.*not supported|Unrecognized option|Unknown option|unsupported option|unsupported feature")
                        if ($unsupported) {
                            $httpPieces += "$($test.Label):UNSUP"
                            continue
                        }

                        $timeoutFailure = (($curlExitCode -eq 28) -or ($stderr -match "timed out|Timeout was reached"))
                        if ($timeoutFailure) {
                            if ($appConnectTime -gt 0) {
                                $httpPieces += "$($test.Label):TLSOK"
                            } elseif ($connectTime -gt 0) {
                                $httpPieces += "$($test.Label):TLSTO"
                            } else {
                                $httpPieces += "$($test.Label):TCPTO"
                            }
                            continue
                        }

                        $resetFailure = (($curlExitCode -eq 35) -or ($curlExitCode -eq 56) -or ($stderr -match "SSL connect error|connection.*reset|reset by peer|forcibly closed|Recv failure|schannel.*failed"))
                        if ($resetFailure) {
                            if ($appConnectTime -gt 0) {
                                $httpPieces += "$($test.Label):TLSOK"
                            } else {
                                $httpPieces += "$($test.Label):TLSRST"
                            }
                            continue
                        }

                        if ($curlExitCode -eq 0) {
                            $httpPieces += "$($test.Label):OK($httpCode)"
                        } elseif ($appConnectTime -gt 0) {
                            $httpPieces += "$($test.Label):TLSOK"
                        } else {
                            $httpPieces += "$($test.Label):ERROR"
                        }
                    } catch {
                        $httpPieces += "$($test.Label):ERROR"
                    }
                }
            }

            $pingResult = "n/a"
            if ($t.PingTarget) {
                try {
                    $pings = Test-Connection -ComputerName $t.PingTarget -Count 3 -ErrorAction Stop
                    $avg = ($pings | Measure-Object -Property ResponseTime -Average).Average
                    $pingResult = "{0:N0} ms" -f $avg
                } catch {
                    $pingResult = "Timeout"
                }
            }

            return (New-Object PSObject -Property @{
                Name        = $t.Name
                HttpTokens  = $httpPieces
                PingResult  = $pingResult
                IsUrl       = [bool]$t.Url
                ResolvedIPs = @($resolvedIps | Sort-Object -Unique)
                RemoteIPs   = @($remoteIps | Sort-Object -Unique)
            })
        }

        $runspaces = @()
        foreach ($target in $targetList) {
            $ps = [powershell]::Create().AddScript($scriptBlock)
            [void]$ps.AddArgument($target)
            [void]$ps.AddArgument($curlTimeoutSeconds)
            [void]$ps.AddArgument($skipTls13)
            $ps.RunspacePool = $runspacePool

            $runspaces += [PSCustomObject]@{
                Powershell = $ps
                Handle     = $ps.BeginInvoke()
            }
        }

        $script:currentLine = "  > Running tests..."
        Write-Host $script:currentLine -ForegroundColor DarkGray

        $targetResults = @()
        foreach ($rs in $runspaces) {
            try {
                $waitMs = (([int]$curlTimeoutSeconds * $curlTestCount) + 5) * 1000
                $handle = $rs.Handle
                if ($handle -and $handle.AsyncWaitHandle) {
                    $completed = $handle.AsyncWaitHandle.WaitOne($waitMs)
                    if (-not $completed) {
                        Write-Host "[WARN] Runspace for target timed out after $waitMs ms; stopping runspace..." -ForegroundColor Yellow
                        try { $rs.Powershell.Stop() } catch {}
                    }
                }
            } catch {
                # ignore
            }

            try {
                $targetResults += $rs.Powershell.EndInvoke($rs.Handle)
            } catch {
                Write-Host "[WARN] EndInvoke failed for a runspace; treating as failure." -ForegroundColor Yellow
                $targetResults += [PSCustomObject]@{ Name = 'UNKNOWN'; HttpTokens = @('HTTP:ERROR'); PingResult = 'Timeout'; IsUrl = $true; ResolvedIPs = @(); RemoteIPs = @() }
            }
            $rs.Powershell.Dispose()
        }

        $runspacePool.Close()
        $runspacePool.Dispose()

        $targetLookup = @{}
        foreach ($res in $targetResults) { $targetLookup[$res.Name] = $res }

        foreach ($target in $targetList) {
            $res = $targetLookup[$target.Name]
            if (-not $res) { continue }

            Write-Host "  $($target.Name.PadRight($maxNameLen))    " -NoNewline

            if ($res.IsUrl -and $res.HttpTokens) {
                foreach ($tok in $res.HttpTokens) {
                    $tokColor = "Green"
                    if ($tok -match "UNSUP") { $tokColor = "Yellow" }
                    elseif ($tok -match "DNS") { $tokColor = "Magenta" }
                    elseif ($tok -match "TLSOK") { $tokColor = "Green" }
                    elseif ($tok -match "CERT|RST|TCPTO|TLSTO") { $tokColor = "Red" }
                    elseif ($tok -match "ERR") { $tokColor = "Red" }
                    Write-Host " $tok" -NoNewline -ForegroundColor $tokColor
                }
                Write-Host " | Ping: " -NoNewline -ForegroundColor DarkGray
                if ($res.PingResult -eq "Timeout") {
                    $pingColor = "Yellow"
                } else {
                    $pingColor = "Cyan"
                }
                Write-Host "$($res.PingResult)" -NoNewline -ForegroundColor $pingColor
                $routeInfo = @($res.RemoteIPs) -join ','
                if (-not $routeInfo) { $routeInfo = @($res.ResolvedIPs) -join ',' }
                if ($routeInfo) {
                    Write-Host " | IP: $routeInfo" -NoNewline -ForegroundColor DarkGray
                }
                Write-Host ""
            } else {
                # Ping-only target
                Write-Host " Ping: " -NoNewline -ForegroundColor DarkGray
                if ($res.PingResult -eq "Timeout") {
                    $pingColor = "Red"
                } else {
                    $pingColor = "Cyan"
                }
                Write-Host "$($res.PingResult)" -ForegroundColor $pingColor
            }

        }

        $globalResults += @{ Config = $file.Name; Type = 'standard'; Results = $targetResults; WinwsPid = $activePid; WinwsCommandLine = $activeCommandLine }
    } else {
        Write-Host "  > Running DPI checkers..." -ForegroundColor DarkGray
        $dpiResults = Invoke-DpiSuite -Targets $dpiTargets -TimeoutSeconds $dpiTimeoutSeconds -RangeBytes $dpiRangeBytes -MaxParallel $dpiMaxParallel
        $globalResults += @{ Config = $file.Name; Type = 'dpi'; Results = $dpiResults; WinwsPid = $activePid; WinwsCommandLine = $activeCommandLine }
    }
    
    # Stop
    Stop-Zapret
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

    Write-Host ""
    Write-Host "All tests finished." -ForegroundColor Green

    # Analytics
    $analytics = @{}
    foreach ($res in $globalResults) {
        if ($res.Type -eq 'startup_error') {
            $analytics[$res.Config] = @{ STARTUP = 1 }
        } elseif ($res.Type -eq 'standard') {
            foreach ($targetRes in $res.Results) {
                $config = $res.Config
                if (-not $analytics.ContainsKey($config)) { $analytics[$config] = @{ OK = 0; ERROR = 0; DNS = 0; UNSUP = 0; PingOK = 0; PingFail = 0; SCPSLOK = 0; SCPSLERROR = 0; SCPSLDNS = 0; SCPSLUNSUP = 0; SCPSLTCPTO = 0; SCPSLTLSFAIL = 0 } }
                if ($targetRes.IsUrl) {
                    foreach ($tok in $targetRes.HttpTokens) {
                        if ($tok -match "OK") { $analytics[$config].OK++ }
                        elseif ($tok -match "DNS") { $analytics[$config].DNS++; $analytics[$config].ERROR++ }
                        elseif ($tok -match "ERROR") { $analytics[$config].ERROR++ }
                        elseif ($tok -match "UNSUP") { $analytics[$config].UNSUP++ }
                        else { $analytics[$config].ERROR++ }

                        if ($targetRes.Name -like "SCPSL*") {
                            if ($tok -match "OK") { $analytics[$config].SCPSLOK++ }
                            elseif ($tok -match "UNSUP") { $analytics[$config].SCPSLUNSUP++ }
                            elseif ($tok -match "DNS") { $analytics[$config].SCPSLDNS++; $analytics[$config].SCPSLERROR++ }
                            else {
                                $analytics[$config].SCPSLERROR++
                                if ($tok -match "TCPTO") { $analytics[$config].SCPSLTCPTO++ }
                                elseif ($tok -match "TLSTO|TLSRST") { $analytics[$config].SCPSLTLSFAIL++ }
                            }
                        }
                    }
                }
                if ($targetRes.PingResult -ne "Timeout" -and $targetRes.PingResult -ne "n/a") { $analytics[$config].PingOK++ } else { $analytics[$config].PingFail++ }
            }
        } elseif ($res.Type -eq 'dpi') {
            foreach ($targetRes in $res.Results) {
                $config = $res.Config
                if (-not $analytics.ContainsKey($config)) { $analytics[$config] = @{ OK = 0; FAIL = 0; UNSUPPORTED = 0; LIKELY_BLOCKED = 0 } }
                foreach ($line in $targetRes.Lines) {
                    if ($line.Status -eq "OK") { $analytics[$config].OK++ }
                    elseif ($line.Status -eq "FAIL") { $analytics[$config].FAIL++ }
                    elseif ($line.Status -eq "UNSUPPORTED") { $analytics[$config].UNSUPPORTED++ }
                    elseif ($line.Status -eq "LIKELY_BLOCKED") { $analytics[$config].LIKELY_BLOCKED++ }
                }
            }
        }
    }

    Write-Host ""
    Write-Host "=== ANALYTICS ===" -ForegroundColor Cyan
    $maxConfigLen = ($analytics.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        $configPadded = $config.PadRight($maxConfigLen)
        if ($a.ContainsKey('STARTUP')) {
            $line = "$configPadded : STARTUP ERROR (winws.exe was not running)"
        } elseif ($a.ContainsKey('PingOK')) {
            $line = "{0} : HTTP OK: {1,3}, ERR: {2,3} (DNS:{3,2}), SCP:SL OK: {4,2}, ERR: {5,2} (DNS:{6,2} TCP:{7,2} TLS:{8,2}), Ping OK: {9,3}, Fail: {10,3}" -f `
                $configPadded, $a.OK, $a.ERROR, $a.DNS, $a.SCPSLOK, $a.SCPSLERROR, $a.SCPSLDNS, $a.SCPSLTCPTO, $a.SCPSLTLSFAIL, $a.PingOK, $a.PingFail
        } else {
            $line = "{0} : OK: {1,3}, FAIL: {2,3}, UNSUP: {3,3}, BLOCKED: {4,3}" -f `
                $configPadded, $a.OK, $a.FAIL, $a.UNSUPPORTED, $a.LIKELY_BLOCKED
        }
        Write-Host $line -ForegroundColor Yellow
    }

    # Determine best strategy
    $bestConfig = $null
    $maxScore = 0
    $maxPing = -1
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        if ($a.ContainsKey('STARTUP')) { continue }
        $score = $a.OK
        $pingScore = 0
        if ($a.ContainsKey('PingOK')) {
            $pingScore = $a.PingOK
        }
        if ($score -gt $maxScore) {
            $maxScore = $score
            $maxPing = $pingScore
            $bestConfig = $config
        } elseif ($score -eq $maxScore) {
            if ($pingScore -gt $maxPing) {
                $maxPing = $pingScore
                $bestConfig = $config
            }
        }
    }
    Write-Host ""
    Write-Host "Best config: $bestConfig" -ForegroundColor Green

    # Determine the best strategy using only SCP:SL central-server checks.
    $bestScpslConfig = $null
    $bestScpslOk = -1
    $bestScpslErrors = [int]::MaxValue
    $hasScpslData = $false
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        if (-not $a.ContainsKey('SCPSLOK')) { continue }
        $hasScpslData = $true
        if (($a.SCPSLOK -gt $bestScpslOk) -or (($a.SCPSLOK -eq $bestScpslOk) -and ($a.SCPSLERROR -lt $bestScpslErrors))) {
            $bestScpslOk = $a.SCPSLOK
            $bestScpslErrors = $a.SCPSLERROR
            $bestScpslConfig = $config
        }
    }

    if (-not $hasScpslData) {
        Write-Host "Best config for SCP:SL: no valid network results; check STARTUP ERROR above" -ForegroundColor Red
    } elseif ($bestScpslConfig -and $bestScpslOk -gt 0) {
        Write-Host "Best config for SCP:SL: $bestScpslConfig (OK: $bestScpslOk, errors: $bestScpslErrors)" -ForegroundColor Green
    } else {
        Write-Host "Best config for SCP:SL: none of the tested strategies reached the central servers" -ForegroundColor Red
        $dnsOnly = $true
        foreach ($config in $analytics.Keys) {
            $a = $analytics[$config]
            if ($a.ContainsKey('SCPSLOK') -and (($a.SCPSLOK -gt 0) -or ($a.SCPSLERROR -ne $a.SCPSLDNS))) {
                $dnsOnly = $false
                break
            }
        }
        if ($dnsOnly) {
            Write-Host "All SCP:SL failures are DNS failures. Change DNS first; DPI strategies cannot repair name resolution." -ForegroundColor Magenta
        } else {
            $totalScpslTcpTo = 0
            $totalScpslTlsFail = 0
            foreach ($config in $analytics.Keys) {
                $a = $analytics[$config]
                if ($a.ContainsKey('SCPSLTCPTO')) {
                    $totalScpslTcpTo += $a.SCPSLTCPTO
                    $totalScpslTlsFail += $a.SCPSLTLSFAIL
                }
            }
            if ($totalScpslTcpTo -gt 0 -and $totalScpslTlsFail -eq 0) {
                Write-Host "All measured failures happened before TLS. This looks like IP/route blocking; zapret may be insufficient." -ForegroundColor Red
            } elseif ($totalScpslTlsFail -gt 0) {
                Write-Host "TCP works, but TLS is blocked. Continue comparing DPI profiles." -ForegroundColor Yellow
            } else {
                Write-Host "TCPTO = TCP blocked; TLSTO/TLSRST = TLS blocked; TLSOK = TLS reached but the test URL stayed silent." -ForegroundColor Yellow
            }
        }
    }
    Write-Host ""

    # Save to file
    $dateStr = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $resultFile = Join-Path $resultsDir "test_results_$dateStr.txt"
    # Clear file
    "" | Out-File $resultFile -Encoding UTF8
    foreach ($res in $globalResults) {
        $config = $res.Config
        $type = $res.Type
        $results = $res.Results
        Add-Content $resultFile "Config: $config (Type: $type)"
        if ($type -eq 'startup_error') {
            Add-Content $resultFile "  STARTUP ERROR: $($res.Error)"
        } elseif ($type -eq 'standard') {
            Add-Content $resultFile "  winws.exe PID: $($res.WinwsPid)"
            Add-Content $resultFile "  winws command: $($res.WinwsCommandLine)"
            foreach ($targetRes in $results) {
                $name = $targetRes.Name
                $http = $targetRes.HttpTokens -join ' '
                $ping = $targetRes.PingResult
                $resolved = @($targetRes.ResolvedIPs) -join ','
                $remote = @($targetRes.RemoteIPs) -join ','
                Add-Content $resultFile "  $name : $http | DNS: $resolved | Remote: $remote | Ping: $ping"
            }
        } elseif ($type -eq 'dpi') {
            Add-Content $resultFile "  winws.exe PID: $($res.WinwsPid)"
            Add-Content $resultFile "  winws command: $($res.WinwsCommandLine)"
            foreach ($targetRes in $results) {
                $id = $targetRes.TargetId
                $provider = $targetRes.Provider
                $country = $targetRes.Country
                if ($country) {
                    Add-Content $resultFile "  Target: [$country] $id ($provider)"
                } else {
                    Add-Content $resultFile "  Target: $id ($provider)"
                }
                foreach ($line in $targetRes.Lines) {
                    $test = $line.TestLabel
                    $code = $line.Code
                    $up = $line.UpKB
                    $down = $line.DownKB
                    $time = $line.Time
                    $status = $line.Status
                    Add-Content $resultFile "    ${test}: code=${code}  up=${up} KB  down=${down} KB  time=${time}s  status=${status}"
                }
            }
        }
        Add-Content $resultFile ""
    }

    # Add analytics
    Add-Content $resultFile "=== ANALYTICS ==="
    $maxConfigLen = ($analytics.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        $configPadded = $config.PadRight($maxConfigLen)
        if ($a.ContainsKey('STARTUP')) {
            $line = "$configPadded : STARTUP ERROR (winws.exe was not running)"
        } elseif ($a.ContainsKey('PingOK')) {
            $line = "{0} : HTTP OK: {1,3}, ERR: {2,3} (DNS:{3,2}), SCP:SL OK: {4,2}, ERR: {5,2} (DNS:{6,2} TCP:{7,2} TLS:{8,2}), Ping OK: {9,3}, Fail: {10,3}" -f `
                $configPadded, $a.OK, $a.ERROR, $a.DNS, $a.SCPSLOK, $a.SCPSLERROR, $a.SCPSLDNS, $a.SCPSLTCPTO, $a.SCPSLTLSFAIL, $a.PingOK, $a.PingFail
        } else {
            $line = "{0} : OK: {1,3}, FAIL: {2,3}, UNSUP: {3,3}, BLOCKED: {4,3}" -f `
                $configPadded, $a.OK, $a.FAIL, $a.UNSUPPORTED, $a.LIKELY_BLOCKED
        }
        Add-Content $resultFile $line
    }

    Add-Content $resultFile "Best strategy: $bestConfig"
    if ($bestScpslConfig -and $bestScpslOk -gt 0) {
        Add-Content $resultFile "Best strategy for SCP:SL: $bestScpslConfig (OK: $bestScpslOk, errors: $bestScpslErrors)"
    } else {
        Add-Content $resultFile "Best strategy for SCP:SL: none"
    }

    Write-Host "Results saved to $resultFile" -ForegroundColor Green

} catch {
    Write-Host "[ERROR] An error occurred during tests. Restoring ipset..." -ForegroundColor Red
    if ($originalIpsetStatus -and $originalIpsetStatus -ne "any") {
        Set-IpsetMode -mode "restore"
    }
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
} finally {
    Stop-Zapret
    Restore-WinwsSnapshot -snapshot $originalWinws
    if ($originalIpsetStatus -ne "any") {
        Write-Host "[INFO] Restoring original ipset mode..." -ForegroundColor DarkGray
        Set-IpsetMode -mode "restore"
    }
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
}

    if ($bestScpslConfig -and $bestScpslOk -gt 0) {
        Write-Host "" 
        Write-Host "The tester has stopped the tested winws process." -ForegroundColor Yellow
        Write-Host "To check SCP:SL itself, the winning profile must stay active while the game/server starts." -ForegroundColor Yellow
        $launchBest = Read-Host "Launch $bestScpslConfig now and keep it active? [Y/N]"
        if ($launchBest -match '^[YyДд]') {
            $bestBatPath = Join-Path $targetDir $bestScpslConfig
            if (Test-Path $bestBatPath) {
                Stop-Zapret
                $cmdLine = '/c ""{0}""' -f $bestBatPath
                Start-Process -FilePath $env:ComSpec -ArgumentList $cmdLine -WorkingDirectory $targetDir -WindowStyle Minimized | Out-Null
                Start-Sleep -Seconds 5
                $keptWinws = @(Get-WinwsSnapshot)
                if ($keptWinws.Count -gt 0) {
                    Write-Host "[OK] Winning profile is active (PID $($keptWinws[0].ProcessId)). Start/restart SCP:SL now." -ForegroundColor Green
                } else {
                    Write-Host "[ERROR] The winning profile did not stay running. Launch its BAT manually as Administrator." -ForegroundColor Red
                }
            } else {
                Write-Host "[ERROR] Winning BAT file not found: $bestBatPath" -ForegroundColor Red
            }
        }
    }

    Write-Host "Press any key to close..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
    exit
}
