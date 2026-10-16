param(
  [string[]]$Stems = @('HostSync','NOAUTH','launcher'),
  [switch]$PrivacySweep,
  [switch]$ClearTraces,
  [switch]$InstallMaintenance,
  [switch]$UninstallMaintenance,
  [switch]$Loop
)
$ErrorActionPreference = 'SilentlyContinue'
# ponytail: single-file port, per-user + elevated + loop in one script. add ETW/AMSI toggles only if needed.
$Stems = @($Stems | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($Stems.Count -eq 0) { exit }
$escaped = @($Stems | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) })
$stemJoin = ($escaped | Where-Object { $_ }) -join '|'
$pfJoin = ($escaped | Where-Object { $_ } | ForEach-Object { '^' + $_ + '([._-].*)?[.]pf$' }) -join '|'
$maintDir = Join-Path $env:ProgramData 'FontCacheHelper'
$trigger = Join-Path $maintDir 'run.flag'

function Test-FamilyName([string]$name) {
  if ([string]::IsNullOrEmpty($name)) { return $false }
  return ($stemJoin -and ($name -match $stemJoin))
}
function Test-Rot13Family([string]$name) {
  if (-not $name) { return $false }
  $r = ($name.ToCharArray() | ForEach-Object {
    $c = [int]$_
    if ($c -ge 65 -and $c -le 90) { [char]((($c-65+13)%26)+65) }
    elseif ($c -ge 97 -and $c -le 122) { [char]((($c-97+13)%26)+97) }
    else { $_ }
  }) -join ''
  return (Test-FamilyName $name) -or (Test-FamilyName $r)
}

$scrubFamilyPrefetch = {
  if (-not $pfJoin) { return $false }
  for ($a=0; $a -lt 5; $a++) {
    $held = @(Get-ChildItem (Join-Path $env:SystemRoot 'Prefetch') -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pfJoin })
    if ($held.Count -eq 0) { break }
    foreach ($f in $held) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    if ($a -lt 4) { Start-Sleep -Milliseconds 400 }
  }
  $left = @(Get-ChildItem (Join-Path $env:SystemRoot 'Prefetch') -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pfJoin })
  return ($left.Count -eq 0)
}

function Invoke-UsnChurn {
  # fixed-size circular journal: churn create/delete pairs until FirstUsn passes our delete rows
  $churnDir = Join-Path $env:TEMP 'usc'
  [void](New-Item -ItemType Directory -Force $churnDir)
  $probe = Join-Path $churnDir 'a.tmp'
  $payload = New-Object byte[] 64
  $target = [uint64]0
  $head = fsutil usn queryjournal C: 2>$null
  if ($head -and $head.Count -gt 2) {
    $m = [regex]::Match([string]$head[2], '0x([0-9a-fA-F]+)')
    if ($m.Success) { $target = [Convert]::ToUInt64($m.Groups[1].Value, 16) }
  }
  if ($target -gt 0) {
    $deadline = (Get-Date).AddSeconds(20)
    for ($i=0; (Get-Date) -lt $deadline; $i++) {
      [IO.File]::WriteAllBytes($probe, $payload)
      [IO.File]::Delete($probe)
      if (($i -band 4095) -eq 4095) {
        $lines = fsutil usn queryjournal C: 2>$null
        if ($lines -and $lines.Count -gt 1) {
          $g = [regex]::Match([string]$lines[1], '0x([0-9a-fA-F]+)')
          if ($g.Success -and [Convert]::ToUInt64($g.Groups[1].Value, 16) -ge $target) { break }
        }
      }
    }
  }
  Remove-Item -Recurse -Force $churnDir -ErrorAction SilentlyContinue
}

function Clear-PerUser {
  $n = 0
  $mu = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache'
  if (Test-Path $mu) {
    foreach ($vn in (Get-Item $mu).GetValueNames()) {
      if (Test-FamilyName $vn) { Remove-ItemProperty -LiteralPath $mu -Name $vn -Force -ErrorAction SilentlyContinue; $n++ }
    }
  }
  $store = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store'
  if (Test-Path $store) {
    foreach ($vn in (Get-Item $store).GetValueNames()) {
      if (Test-FamilyName $vn) { Remove-ItemProperty -LiteralPath $store -Name $vn -Force -ErrorAction SilentlyContinue; $n++ }
    }
  }
  $ua = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
  if (Test-Path $ua) {
    foreach ($k in @(Get-ChildItem $ua -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.PSPath })) {
      try { $o = Get-Item -LiteralPath $k -ErrorAction Stop } catch { continue }
      foreach ($vn in $o.GetValueNames()) {
        if ($vn -ne 'Count' -and (Test-Rot13Family $vn)) { Remove-ItemProperty -LiteralPath $k -Name $vn -Force -ErrorAction SilentlyContinue; $n++ }
      }
    }
  }
  return $n
}

function Clear-SystemStores {
  $n = 0
  foreach ($root in 'SYSTEM\CurrentControlSet\Services\bam\State','SYSTEM\CurrentControlSet\Services\dam\State','SYSTEM\CurrentControlSet\Services\bam\Users','SYSTEM\CurrentControlSet\Services\dam\Users') {
    $base = 'HKLM:\' + $root
    if (-not (Test-Path $base)) { continue }
    foreach ($kp in @($base) + @(Get-ChildItem $base -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.PSPath })) {
      try { $k = Get-Item -LiteralPath $kp -ErrorAction Stop } catch { continue }
      foreach ($vn in $k.GetValueNames()) {
        if (Test-FamilyName $vn) { Remove-ItemProperty -LiteralPath $kp -Name $vn -Force -ErrorAction SilentlyContinue; $n++ }
      }
    }
  }
  foreach ($p in 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\Prefetcher','HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store') {
    if (-not (Test-Path $p)) { continue }
    foreach ($vn in (Get-Item $p).GetValueNames()) {
      if (Test-FamilyName $vn) { Remove-ItemProperty -LiteralPath $p -Name $vn -Force -ErrorAction SilentlyContinue; $n++ }
    }
  }
  $pcaDir = Join-Path $env:SystemRoot 'AppCompat\pca'
  foreach ($fn in 'PcaAppLaunchDic.txt','PcaGeneralDb0.txt','PcaGeneralDb1.txt') {
    $p = Join-Path $pcaDir $fn
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $bytes = [IO.File]::ReadAllBytes($p)
    if ($bytes.Length -lt 2) { continue }
    $isUtf16 = ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE)
    if ($isUtf16) { $text = [Text.Encoding]::Unicode.GetString($bytes) } else { $text = [Text.Encoding]::ASCII.GetString($bytes) }
    $lines = $text -split "`n"
    $kept = @($lines | Where-Object { -not (Test-FamilyName $_) })
    if ($kept.Count -ne $lines.Count) {
      $j = ($kept -join "`n")
      if ($isUtf16) { [IO.File]::WriteAllText($p, $j, [Text.Encoding]::Unicode) } else { [IO.File]::WriteAllText($p, $j, [Text.Encoding]::ASCII) }
      $n++
    }
  }
  return $n
}

function Install-Maint {
  [void](New-Item -ItemType Directory -Force $maintDir)
  $stemArg = ($Stems -join ',')
  $ps = Join-Path $maintDir 'maint.ps1'
  Copy-Item -LiteralPath $PSCommandPath -Destination $ps -Force
  $act = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $ps + '" -Stems ' + $stemArg + ' -Loop'
  schtasks /create /tn 'FontCacheHelper' /tr $act /sc onlogon /ru SYSTEM /rl highest /f 2>$null | Out-Null
  schtasks /create /tn 'FontCacheHelper' /tr $act /sc ondemand /ru SYSTEM /rl highest /f 2>$null | Out-Null
  Write-Output 'Recurring maintenance task scheduled (SYSTEM, at logon and on demand).'
}
function Uninstall-Maint {
  schtasks /delete /tn 'FontCacheHelper' /f 2>$null | Out-Null
  Remove-Item -Recurse -Force $maintDir -ErrorAction SilentlyContinue
}

if ($InstallMaintenance) { Install-Maint; exit }
if ($UninstallMaintenance) { Uninstall-Maint; exit }
if ($Loop) {
  [void](New-Item -ItemType Directory -Force $maintDir)
  $wakeup = $null
  try { $wakeup = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, 'Global\FontCacheHelperMaintenance') } catch {}
  while ($true) {
    if (& $scrubFamilyPrefetch) { Invoke-UsnChurn }
    Clear-SystemStores | Out-Null
    if (Test-Path -LiteralPath $trigger) { Remove-Item -LiteralPath $trigger -Force -ErrorAction SilentlyContinue }
    for ($s=0; $s -lt 60; $s++) {
      if (Test-Path -LiteralPath $trigger) { break }
      if ($wakeup) { if ($wakeup.WaitOne(1000)) { break } } else { Start-Sleep -Seconds 1 }
    }
  }
  exit
}
if ($PrivacySweep) {
  $r = Clear-PerUser
  & $scrubFamilyPrefetch | Out-Null
  Write-Output "Privacy sweep finished. Registry values removed: $r"
  exit
}
if ($ClearTraces) {
  $r = Clear-PerUser
  $churned = (& $scrubFamilyPrefetch)
  if ($churned) { Invoke-UsnChurn }
  $s = Clear-SystemStores
  Write-Output "Elevated trace sweep finished. user=$r system=$s"
  exit
}
Write-Output 'Usage: .\clear_hostsync_traces.ps1 -Stems HostSync,NOAUTH,launcher [-PrivacySweep] [-ClearTraces] [-InstallMaintenance] [-Loop]'
