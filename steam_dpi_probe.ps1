# Steam DPI probe: tries GoodbyeDPI 0.2.2 configs and reports which ones get
# through the ISP's SNI block for Steam. Self-elevates (GoodbyeDPI needs admin).
# It stops the running GoodbyeDPI tray app during the test, then restarts the
# tray app with the best config it found (or the original -3 if none worked).

$ErrorActionPreference = 'Continue'
$gdpiDir = 'C:\Users\Mcuongyeue\Desktop\VN_GoodbyeDPI'
$exe     = Join-Path $gdpiDir 'x86_64\goodbyedpi.exe'
$tray    = Join-Path $gdpiDir 'goodbyedpi_tray.exe'
$dns     = '--dns-addr 8.8.8.8 --dns-port 53 --dnsv6-addr 2001:4860:4860::8888 --dnsv6-port 53'
$out     = Join-Path $PSScriptRoot 'steam_dpi_results.txt'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  exit
}

$configs = @(
  '-3',
  '-1',
  '-5',
  '-6',
  '-p -r -s -e 1 --native-frag',
  '-p -r -s -e 2 --native-frag --reverse-frag',
  '-p -r -s -f 2 -e 2 --native-frag --reverse-frag --wrong-chksum',
  '-p -r -s -f 2 -e 2 --native-frag --reverse-frag --wrong-seq',
  '-p -r -s -f 2 -e 2 --native-frag --reverse-frag --wrong-chksum --wrong-seq',
  '-p -r -s -f 2 -e 2 --native-frag --reverse-frag --auto-ttl',
  '-p -r -s -f 2 -e 2 --native-frag --reverse-frag --set-ttl 2',
  '-p -r -s -f 2 -e 2 --native-frag --reverse-frag --set-ttl 3',
  '-p -r -s -f 2 -e 2 --native-frag --reverse-frag --set-ttl 4'
)
$urls = [ordered]@{
  community = 'https://steamcommunity.com/'
  store     = 'https://store.steampowered.com/'
  checkout  = 'https://checkout.steampowered.com/'
  help      = 'https://help.steampowered.com/'
  google    = 'https://www.google.com/'   # control: must stay working
}

function Stop-Gdpi { Get-Process goodbyedpi_tray, goodbyedpi -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2 }
function Test-Urls($cfg) {
  $r = [ordered]@{ Config = $cfg }
  foreach ($k in $urls.Keys) {
    $code = curl.exe -4 -s -o NUL --ssl-revoke-best-effort -m 6 -w '%{http_code}' $urls[$k]
    $r[$k] = if ($code -and $code -ne '000') { 'OK' } else { '--' }
  }
  [pscustomobject]$r
}

Write-Host "Stopping current GoodbyeDPI..." ; Stop-Gdpi
$results = @()
Write-Host "Baseline (no GoodbyeDPI)..."
$results += Test-Urls '(none)'

$i = 0
foreach ($c in $configs) {
  $i++; Write-Host "[$i/$($configs.Count)] $c"
  $p = Start-Process $exe -ArgumentList "$c $dns" -WindowStyle Hidden -PassThru
  Start-Sleep 3
  if ($p.HasExited) { $row = [ordered]@{ Config = $c }; foreach ($k in $urls.Keys) { $row[$k] = 'ERR' }; $results += [pscustomobject]$row; continue }
  $results += Test-Urls $c
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Start-Sleep 2
}

$cols = @('Config') + @($urls.Keys)
$table = $results | Select-Object $cols | Format-Table -AutoSize | Out-String -Width 250
$best = $results | Where-Object { $_.Config -ne '(none)' -and $_.google -eq 'OK' } |
  Sort-Object { ($_.PSObject.Properties | Where-Object Value -eq 'OK').Count } -Descending | Select-Object -First 1
$summary = "Best: $($best.Config)"
"$(Get-Date)`r`n$table`r`n$summary" | Set-Content -Path $out -Encoding utf8
Write-Host $table; Write-Host $summary -ForegroundColor Green

$restart = if ($best -and $best.community -eq 'OK') { $best.Config } else { '-3' }
Write-Host "Restarting GoodbyeDPI tray with: $restart $dns"
Start-Process $tray -ArgumentList "$restart $dns"
Write-Host "Results saved to $out"
Read-Host "Press Enter to close"
