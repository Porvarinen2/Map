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
    logPath = $null
    logTime = $null
    logAgeMinutes = $null
    serverStart = $null
    logIsFromThisRun = $false
    version = $null
    modsDirectoryInLog = $null
    scanAttempts = 0
    scanFailure = $null
    startedLuaMods = @()
    verdict = "UNKNOWN"
    action = @()
  }

  if (-not (Test-Path $Win64)) {
    $h.verdict = "NO_WIN64"
    $h.action += "Win64-kansiota ei loydy: $Win64"
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
  foreach ($n in @("UE4SS.dll", "ue4ss\UE4SS.dll")) {
    $p = Join-Path $Win64 $n
    if (Test-Path $p) { $h.ue4ssDll = $p; break }
  }
  foreach ($n in @("UE4SS-settings.ini", "ue4ss\UE4SS-settings.ini")) {
    $p = Join-Path $Win64 $n
    if (Test-Path $p) { $h.settings = $p; break }
  }
  foreach ($n in @("Mods", "ue4ss\Mods")) {
    $p = Join-Path $Win64 $n
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
  foreach ($n in @("UE4SS.log", "ue4ss\UE4SS.log", "Mods\UE4SS.log")) {
    $p = Join-Path $Win64 $n
    if (Test-Path $p) { $logs += (Get-Item $p) }
  }
  if ($logs.Count -gt 0) {
    $newest = $logs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $h.logPath = $newest.FullName
    $h.logTime = $newest.LastWriteTime
    $h.logAgeMinutes = [math]::Round(((Get-Date) - $newest.LastWriteTime).TotalMinutes, 1)
    $h.allLogs = $logs | ForEach-Object { "{0}  ({1})" -f $_.FullName, $_.LastWriteTime }
  }

  $proc = Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue
  if ($proc) {
    try { $h.serverStart = $proc.StartTime } catch {}
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
    $started = $all | Select-String -Pattern "Starting Lua mod '([^']+)'"
    if ($started) {
      $h.startedLuaMods = $started.Matches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    }
    if ($h.serverStart -and $h.logTime) {
      $h.logIsFromThisRun = ($h.logTime -ge $h.serverStart.AddMinutes(-2))
    }
  }

  # --- verdict ---
  if (-not $h.logPath) {
    $h.verdict = "NO_LOG"
    $h.action += "UE4SS ei ole kirjoittanut lokia lainkaan."
    if ($h.proxyDlls.Count -eq 0) {
      $h.action += "Win64-kansiossa ei ole UE4SS:n proxy-DLL:aa (dwmapi.dll tai xinput1_3.dll)."
      $h.action += "Asenna UE4SS uudelleen palvelimelle."
    } else {
      $h.action += "Proxy-DLL on paikallaan, mutta se ei kaynnisty. Tarkista virustorjunta."
    }
  }
  elseif ($h.serverStart -and -not $h.logIsFromThisRun) {
    $h.verdict = "STALE_LOG"
    $h.action += ("UE4SS.log on ajalta {0}, mutta palvelin kaynnistyi {1}." -f
                  $h.logTime, $h.serverStart)
    $h.action += "UE4SS ei siis lataudu tassa ajossa - mikaan Lua-modi ei kayty."
    $h.action += "Tarkista etta palvelin kaynnistetaan samasta Win64-kansiosta"
    $h.action += "ja etta proxy-DLL on yha paikallaan (SCUM-paivitys voi poistaa sen)."
  }
  elseif ($h.startedLuaMods -contains "TeslesNPCOverhaul") {
    $h.verdict = "MOD_STARTED"
    $h.action += "UE4SS kaynnisti modin. Ongelma on modin sisalla - katso boot.log."
  }
  elseif ($h.scanAttempts -ge 5) {
    $h.verdict = "SCAN_LOOP"
    $h.action += ("UE4SS juuttui AOB-skannaukseen: {0} yritysta." -f $h.scanAttempts)
    if ($h.scanFailure) { $h.action += $h.scanFailure }
    $h.action += "Se ei paase kayttamaan yhtaan Lua-modia ennen kuin skannaus onnistuu."
    $h.action += "Tama ei ole taman modin vika: sama estaa kaikki muutkin Lua-modit."
    $h.action += "Korjaus: paivita UE4SS uudempaan versioon joka tukee SCUMin nykyista buildia."
    if ($h.version) { $h.action += ("Asennettu versio: {0}" -f $h.version) }
  }
  elseif ($h.startedLuaMods.Count -gt 0) {
    $h.verdict = "MOD_NOT_IN_LIST"
    $h.action += ("UE4SS kaynnisti nama Lua-modit: {0}" -f ($h.startedLuaMods -join ", "))
    $h.action += "TeslesNPCOverhaul ei ole listalla - tarkista mods.txt ja kansion nimi."
  }
  else {
    $h.verdict = "NO_MODS_STARTED"
    $h.action += "UE4SS latautui mutta ei kaynnistanyt yhtaan Lua-modia."
    $h.action += "Katso UE4SS.log kokonaan: syy on siella ennen ensimmaista modia."
  }

  return $h
}

function Write-UE4SSHealth {
  param($h)
  function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

  $col = switch ($h.verdict) {
    "MOD_STARTED" { "Green" }
    "SCAN_LOOP" { "Red" }
    "STALE_LOG" { "Red" }
    "NO_LOG" { "Red" }
    default { "Yellow" }
  }
  Write-Host ""
  Say "UE4SS: $($h.verdict)" $col
  if ($h.version) { Say "  versio        : $($h.version)" }
  if ($h.ue4ssDll) { Say "  UE4SS.dll     : $($h.ue4ssDll)" }
  if ($h.proxyDlls.Count -gt 0) {
    Say "  proxy-DLL     : $($h.proxyDlls -join ', ')"
  } else {
    Say "  proxy-DLL     : EI LOYDY" "Red"
  }
  if ($h.logPath) {
    Say "  loki          : $($h.logPath)"
    Say "  loki kirjattu : $($h.logTime)  ($($h.logAgeMinutes) min sitten)"
  }
  if ($h.serverStart) { Say "  palvelin alkoi: $($h.serverStart)" }
  if ($h.modsDirectoryInLog) { Say "  mods (lokista): $($h.modsDirectoryInLog)" }
  foreach ($m in $h.modsDirs) {
    Say "  mods-kansio   : $($m.path)  ($($m.folders) modia)"
  }
  if ($h.scanAttempts -gt 0) { Say "  AOB-skannaus  : $($h.scanAttempts) yritysta" "Yellow" }
  if ($h.startedLuaMods.Count -gt 0) {
    Say "  kaynnistetyt  : $($h.startedLuaMods -join ', ')"
  }
  Write-Host ""
  foreach ($a in $h.action) { Say $a $col }
  Write-Host ""
}
