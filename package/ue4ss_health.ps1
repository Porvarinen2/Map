<#
  UE4SS health check, shared by CHECK.ps1 and DIAGNOSE.ps1.

  The mod cannot run if UE4SS never reaches the point where it starts Lua
  mods. This works out whether it loaded at all this session, and recognises
  the failure modes that stop it: a missing proxy DLL, a log from an older
  run, and the AOB pattern-scan loop that never finishes.

  Dot-source it and call Get-UE4SSHealth <Win64 path>.
#>

function Get-UE4SSHealth {
  param([string]$Win64)

  $h = [ordered]@{
    win64 = $Win64
    proxyDlls = @()
    ue4ssDll = $null
    settings = $null
    modsDirs = @()
    loaderDate = $null
    logPath = $null
    logTime = $null
    logLastEntry = $null
    logClockOffsetMinutes = $null
    scanAge = $null
    scanIsFresh = $false
    loaderInProcess = $null
    processModules = $null
    gameExeDate = $null
    logAgeMinutes = $null
    serverStart = $null
    logIsFromThisRun = $false
    version = $null
    modsDirectoryInLog = $null
    scanAttempts = 0
    scanFailure = $null
    fatalError = $null
    scanThreads = $null
    scanSeconds = $null
    scanFixApplied = $false
    startedLuaMods = @()
    verdict = "UNKNOWN"
    action = @()
  }

  if (-not (Test-Path $Win64)) {
    $h.verdict = "NO_WIN64"
    $h.action += "Win64 folder not found: $Win64"
    return $h
  }

  # UE4SS loads through a proxy DLL next to the executable.
  foreach ($n in @("dwmapi.dll", "xinput1_3.dll", "d3d11.dll", "dinput8.dll", "version.dll")) {
    $p = Join-Path $Win64 $n
    if (Test-Path $p) {
      $h.proxyDlls += ("{0} ({1:N0} B, {2})" -f $n, (Get-Item $p).Length,
                       (Get-Item $p).LastWriteTime.ToString("yyyy-MM-dd"))
    }
  }
  foreach ($n in @(@("ue4ss", "UE4SS.dll"), @("UE4SS.dll"))) {
    $p = $Win64; foreach ($seg in $n) { $p = Join-Path $p $seg }
    if (Test-Path $p) {
      $h.ue4ssDll = $p
      $h.loaderDate = (Get-Item $p).LastWriteTime.ToString("yyyy-MM-dd")
      break
    }
  }
  foreach ($n in @(@("ue4ss", "UE4SS-settings.ini"), @("UE4SS-settings.ini"))) {
    $p = $Win64; foreach ($seg in $n) { $p = Join-Path $p $seg }
    if (Test-Path $p) { $h.settings = $p; break }
  }
  if ($h.settings) {
    # The scanner's own settings decide how the pattern search behaves, so
    # they belong in the verdict rather than in a separate investigation.
    foreach ($l in (Get-Content $h.settings -ErrorAction SilentlyContinue)) {
      if ($l -match '^\s*SigScannerNumThreads\s*=\s*(\d+)') { $h.scanThreads = [int]$Matches[1] }
      if ($l -match '^\s*SecondsToScanBeforeGivingUp\s*=\s*(\d+)') { $h.scanSeconds = [int]$Matches[1] }
    }
    $h.scanFixApplied = Test-Path ($h.settings + ".tesles-backup")
  }
  foreach ($n in @(@("ue4ss", "Mods"), @("Mods"))) {
    $p = $Win64; foreach ($seg in $n) { $p = Join-Path $p $seg }
    if (Test-Path $p) {
      $mt = Join-Path $p "mods.txt"
      $h.modsDirs += [pscustomobject]@{
        path = $p
        hasModsTxt = (Test-Path $mt)
        modsTxtTime = $(if (Test-Path $mt) { (Get-Item $mt).LastWriteTime } else { $null })
        folders = (Get-ChildItem $p -Directory -ErrorAction SilentlyContinue).Count
      }
    }
  }

  # Pick the newest log, not the first one found: a stale log in the old
  # location is exactly what makes this hard to read.
  $logs = @()
  foreach ($n in @(@("ue4ss", "UE4SS.log"), @("UE4SS.log"), @("Mods", "UE4SS.log"))) {
    $p = $Win64; foreach ($seg in $n) { $p = Join-Path $p $seg }
    if (Test-Path $p) { $logs += (Get-Item $p) }
  }
  if ($logs.Count -gt 0) {
    $newest = $logs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $h.logPath = $newest.FullName
    $h.logTime = $newest.LastWriteTime
    $h.logAgeMinutes = [math]::Round(((Get-Date) - $newest.LastWriteTime).TotalMinutes, 1)
    $h.allLogs = $logs | ForEach-Object { "{0}  ({1})" -f $_.FullName, $_.LastWriteTime }
  }

  $exe = Join-Path $Win64 "SCUMServer.exe"
  if (Test-Path $exe) { $h.gameExeDate = (Get-Item $exe).LastWriteTime }

  $proc = Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue
  if ($proc) {
    try { $h.serverStart = $proc.StartTime } catch {}
    # The decisive question when there is no log: did the running server
    # actually load UE4SS's proxy DLL? Everything else is inference.
    try {
      $mods = @($proc.Modules | ForEach-Object { $_.ModuleName })
      $h.processModules = $mods.Count
      $h.loadedProxies = @($mods | Where-Object {
        $_ -match '^(UE4SS|dwmapi|xinput1_3|d3d11|dinput8|version)\.dll$'
      })
      # An empty list is Windows refusing to enumerate (another user, a
      # protected process, a bitness mismatch), not proof that the server
      # loaded nothing. Only a populated list can show the proxy is absent.
      if ($mods.Count -ge 8) {
        $h.loaderInProcess = ($h.loadedProxies.Count -gt 0)
      }
    } catch {
      $h.processModules = -1
    }
  }

  if ($h.logPath) {
    # Read the tail only: these logs reach hundreds of thousands of lines
    # once the scan loop starts.
    $tail = Get-Content $h.logPath -Tail 400 -ErrorAction SilentlyContinue
    $head = Get-Content $h.logPath -TotalCount 60 -ErrorAction SilentlyContinue
    $all = @($head) + @($tail)

    foreach ($l in $head) {
      if ($l -match "UE4SS - (v[\d\.]+[^\s]*)") { $h.version = $Matches[1] }
      if ($l -match "mods directory:\s*(.+)$") { $h.modsDirectoryInLog = $Matches[1].Trim() }
    }
    $scan = $all | Select-String -Pattern "PS Scan attempt (\d+)" -AllMatches
    if ($scan) {
      $nums = $scan.Matches | ForEach-Object { [int]$_.Groups[1].Value }
      $h.scanAttempts = ($nums | Measure-Object -Maximum).Maximum
    }
    $fail = $all | Select-String -Pattern "Failed to find ([^:]+):(.*)$" | Select-Object -Last 1
    if ($fail) { $h.scanFailure = $fail.Line.Trim() }
    # UE4SS does not merely stall on a failed scan: it gives up after
    # SecondsToScanBeforeGivingUp and aborts. That line is the real verdict.
    $fatal = $all | Select-String -Pattern "Fatal Error:(.*)$" | Select-Object -Last 1
    if ($fatal) { $h.fatalError = $fatal.Line.Trim() }
    $started = $all | Select-String -Pattern "Starting Lua mod '([^']+)'"
    if ($started) {
      $h.startedLuaMods = $started.Matches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    }
    # Windows updates LastWriteTime lazily while a file is held open, so the
    # timestamps inside the log are the reliable signal, not the file's own.
    $stamps = $all | Select-String -Pattern '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]' |
              ForEach-Object { $_.Matches[0].Groups[1].Value }
    if ($stamps) {
      $last = $stamps | Select-Object -Last 1
      try { $h.logLastEntry = [datetime]::ParseExact($last, "yyyy-MM-dd HH:mm:ss", $null) } catch {}
    }
    # UE4SS writes its timestamps in UTC on this setup while the file's own
    # timestamp is local, so the two can differ by whole hours. The later of
    # the two is the honest "when did something last happen" - the file
    # timestamp catches the offset, the content catches a log held open whose
    # timestamp Windows has not flushed.
    if ($h.logLastEntry -and $h.logTime) {
      $offset = [math]::Round(($h.logTime - $h.logLastEntry).TotalMinutes)
      if ([math]::Abs($offset) -ge 55) { $h.logClockOffsetMinutes = $offset }
    }
    $effective = $h.logTime
    if ($h.logLastEntry -and (-not $effective -or $h.logLastEntry -gt $effective)) {
      $effective = $h.logLastEntry
    }
    if ($effective) {
      $limit = $(if ($h.scanSeconds) { $h.scanSeconds } else { 30 }) + 90
      # UE4SS may log in UTC while the clock here is local, so a whole number
      # of hours of offset is ignored when judging freshness.
      $age = [math]::Abs(((Get-Date) - $effective).TotalSeconds)
      $age = $age % 3600
      if ($age -gt 1800) { $age = 3600 - $age }
      $h.scanAge = [int]$age
      $h.scanIsFresh = ($age -le $limit) -and
                       ([math]::Abs(((Get-Date) - $effective).TotalDays) -lt 1)
    }
    if ($h.serverStart -and $effective) {
      # UE4SS logs in UTC on some setups and local time on others, so compare
      # generously: anything within a few hours either way counts as this run,
      # and a log from a clearly earlier session does not.
      $delta = ($effective - $h.serverStart).TotalMinutes
      $h.logIsFromThisRun = ($delta -ge -3) -or
                            ([math]::Abs($delta % 60) -lt 3 -and [math]::Abs($delta) -lt 900)
    }
  }

  # --- verdict ---
  if (-not $h.logPath) {
    $h.verdict = "NO_LOG"
    $h.action += "UE4SS has not written a log at all."
    if ($h.proxyDlls.Count -eq 0) {
      $h.action += "There is no UE4SS proxy DLL (dwmapi.dll or xinput1_3.dll) in the Win64 folder."
      $h.action += "Install UE4SS on the server again."
    } else {
      $h.action += "The proxy DLL is in place but does not start. Check your antivirus."
    }
  }
  elseif ($h.serverStart -and -not $h.logIsFromThisRun) {
    $h.verdict = "STALE_LOG"
    $h.action += ("The last UE4SS.log entry is {0}, but the server started {1}." -f
                  ($(if ($h.logLastEntry) { $h.logLastEntry } else { $h.logTime })), $h.serverStart)
    $h.action += "So UE4SS wrote nothing during this run."
    if ($h.loaderInProcess -eq $true) {
      $h.action += ""
      $h.action += "BUT: the proxy DLL IS loaded in the server process"
      $h.action += ("  ({0})" -f ($h.loadedProxies -join ", "))
      $h.action += "so UE4SS loaded and crashed before opening its log."
      $h.action += "The likeliest cause is UE4SS-settings.ini."
      if ($h.scanFixApplied) {
        $h.action += "The scan fix is on - undo it first:"
        $h.action += "  tools\FIX_UE4SS_SCAN.bat -Revert"
        $h.action += "Start the server and run tools\CHECK.bat again."
      }
    } elseif ($h.loaderInProcess -eq $false) {
      $h.action += ""
      $h.action += "The server process has NOT loaded the UE4SS proxy DLL."
      $h.action += ("  loaded modules: {0}" -f $h.processModules)
      $h.action += "The cause is the injection, not UE4SS's settings:"
      $h.action += "  - is dwmapi.dll still in the Win64 folder (antivirus?)"
      $h.action += "  - is the server started from this same Win64 folder"
      if ($h.gameExeDate) {
        $h.action += ("  - SCUMServer.exe was updated {0}" -f $h.gameExeDate.ToString("yyyy-MM-dd"))
      }
    } else {
      $h.action += "The process modules could not be read (permissions)."
      $h.action += "Run tools\CHECK.bat as administrator to see whether the proxy DLL loaded."
      $h.action += "Check that the proxy DLL is in place and the server starts"
      $h.action += "from the same Win64 folder."
    }
    if ($h.scanFixApplied -and $h.loaderInProcess -ne $false) {
      $h.action += ""
      $h.action += "If nothing else explains this, undo the scan fix:"
      $h.action += "  tools\FIX_UE4SS_SCAN.bat -Revert"
    }
  }
  elseif ($h.startedLuaMods -contains "TeslesNPCOverhaul") {
    $h.verdict = "MOD_STARTED"
    $h.action += "UE4SS started the mod. The problem is inside the mod - see boot.log."
  }
  elseif ($h.scanAttempts -ge 5 -and -not $h.fatalError -and $h.scanIsFresh) {
    # The scan has not resolved yet. With a single thread and a raised
    # deadline that legitimately takes minutes, so it is not a failure.
    $h.verdict = "SCANNING"
    $h.action += ("UE4SS is scanning ({0} attempts, no result yet)." -f
                  $h.scanAttempts)
    $h.action += ("Wait {0} s and run tools\CHECK.bat again." -f
                  $(if ($h.scanSeconds) { $h.scanSeconds } else { 60 }))
    $h.action += "This is not an error yet."
  }
  elseif ($h.fatalError -and $h.fatalError -match "scan") {
    $h.verdict = "SCAN_ABORTED"
    $h.action += "UE4SS STOPPED starting on its own error:"
    $h.action += ("  {0}" -f $h.fatalError)
    if ($h.scanFailure) { $h.action += ("  {0}" -f $h.scanFailure) }
    $h.action += ("It made {0} scan attempts before timing out." -f $h.scanAttempts)
    $h.action += "So UE4SS loaded no Lua mod at all - neither this one nor others."
    $h.action += "This is about compatibility between UE4SS and the game build,"
    $h.action += "not about this mod's code."
    $h.action += ""
    $h.action += "Fix, in this order:"
    $h.action += "  1. INSTALL.bat  - installs the newer UE4SS shipped with this"
    $h.action += "     package. Do this first if you have not."
    $h.action += "  2. tools\FIX_UE4SS_SCAN.bat -Auto"
    if ($h.scanFailure -and $h.scanFailure -match "FText") {
      $h.action += "     UE4SS failed on the FText pattern. -Auto finds it"
      $h.action += "     in SCUMServer.exe itself and writes it for UE4SS."
    } else {
      $h.action += "     Finds the missing byte pattern in SCUMServer.exe itself."
    }
    $h.action += "     It writes the pattern only if it is unambiguous."
    $h.action += "     To undo: tools\FIX_UE4SS_SCAN.bat -Revert"
    if ($h.scanFixApplied) {
      $h.action += "  3. The thread fix was tried and did not help. Undo it,"
      $h.action += "     so the start is not slowed for nothing:"
      $h.action += "     tools\FIX_UE4SS_SCAN.bat -Revert"
    }
    if ($h.version) { $h.action += ("Installed now: {0}" -f $h.version) }
    if ($h.loaderDate) { $h.action += ("Loader date: {0}" -f $h.loaderDate) }
  }
  elseif ($h.scanAttempts -ge 5) {
    $h.verdict = "SCAN_LOOP"
    $h.action += ("UE4SS got stuck in the AOB scan: {0} attempts." -f $h.scanAttempts)
    if ($h.scanFailure) { $h.action += $h.scanFailure }
    $h.action += "It cannot run any Lua mod before the scan succeeds."
    $h.action += "This is not this mod's fault: it blocks every other Lua mod too."
    $h.action += "Fix: tools\UPDATE_UE4SS.bat"
    if ($h.version) { $h.action += ("Installed version: {0}" -f $h.version) }
  }
  elseif ($h.startedLuaMods.Count -gt 0) {
    $h.verdict = "MOD_NOT_IN_LIST"
    $h.action += ("UE4SS started these Lua mods: {0}" -f ($h.startedLuaMods -join ", "))
    $h.action += "TeslesNPCOverhaul is not on the list - check mods.txt and the folder name."
  }
  else {
    $h.verdict = "NO_MODS_STARTED"
    $h.action += "UE4SS loaded but started no Lua mod."
    $h.action += "Read the whole UE4SS.log: the cause is there, before the first mod."
  }

  return $h
}

function Write-UE4SSHealth {
  param($h)
  function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

  $col = switch ($h.verdict) {
    "MOD_STARTED" { "Green" }
    "SCANNING" { "Cyan" }
    "SCAN_ABORTED" { "Red" }
    "SCAN_LOOP" { "Red" }
    "STALE_LOG" { "Red" }
    "NO_LOG" { "Red" }
    default { "Yellow" }
  }
  Write-Host ""
  Say "UE4SS: $($h.verdict)" $col
  if ($h.version) { Say "  version       : $($h.version)" }
  if ($h.ue4ssDll) {
    Say "  UE4SS.dll     : $($h.ue4ssDll)"
    Say "  loader built  : $($h.loaderDate)"
  }
  if ($h.proxyDlls.Count -gt 0) {
    Say "  proxy-DLL     : $($h.proxyDlls -join ', ')"
  } else {
    Say "  proxy-DLL     : NOT FOUND" "Red"
  }
  if ($h.logPath) {
    Say "  log           : $($h.logPath)"
    if ($h.logLastEntry) {
      Say "  last entry    : $($h.logLastEntry)"
    }
    Say "  file modified : $($h.logTime)"
  }
  if ($null -ne $h.loaderInProcess) {
    if ($h.loaderInProcess) {
      Say "  in process    : $($h.loadedProxies -join ', ')" "Green"
    } else {
      Say "  in process    : UE4SS NOT loaded ($($h.processModules) modules)" "Red"
    }
  } elseif ($h.serverStart) {
    Say "  in process    : module list could not be read" "DarkGray"
  }
  if ($h.logClockOffsetMinutes) {
    Say "  log uses UTC ($($h.logClockOffsetMinutes) min from local time)" "DarkGray"
  }
  if ($h.gameExeDate) { Say "  SCUMServer.exe: $($h.gameExeDate.ToString('yyyy-MM-dd'))" }
  if ($h.serverStart) { Say "  server started: $($h.serverStart)" }
  if ($h.modsDirectoryInLog) { Say "  mods (in log) : $($h.modsDirectoryInLog)" }
  foreach ($m in $h.modsDirs) {
    Say "  mods folder   : $($m.path)  ($($m.folders) mods)"
  }
  if ($h.scanAttempts -gt 0) { Say "  AOB scan      : $($h.scanAttempts) attempts" "Yellow" }
  if ($h.scanThreads) {
    $note = if ($h.scanFixApplied) { " (scan fix on)" } else { "" }
    Say "  scan threads  : $($h.scanThreads), time limit $($h.scanSeconds) s$note"
  }
  if ($h.fatalError) { Say "  UE4SS error   : $($h.fatalError)" "Red" }
  if ($h.startedLuaMods.Count -gt 0) {
    Say "  started       : $($h.startedLuaMods -join ', ')"
  }
  Write-Host ""
  foreach ($a in $h.action) { Say $a $col }
  Write-Host ""
}
