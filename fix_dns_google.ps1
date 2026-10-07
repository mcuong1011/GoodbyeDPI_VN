# Sets IPv4 + IPv6 DNS to Google on Ethernet and Wi-Fi, so the router's
# IPv6 DNS (fe80::1, which returns 127.0.0.1 for Steam) is no longer used.
# Run as administrator. To undo: Set-DnsClientServerAddress -InterfaceAlias Ethernet -ResetServerAddresses

$adapters = 'Ethernet', 'Wi-Fi'
foreach ($a in $adapters) {
  if (-not (Get-NetAdapter -Name $a -ErrorAction SilentlyContinue)) { continue }
  Set-DnsClientServerAddress -InterfaceAlias $a -ServerAddresses @(
    '8.8.8.8', '8.8.4.4',
    '2001:4860:4860::8888', '2001:4860:4860::8844'
  )
  Write-Host "Set DNS on $a"
}
Clear-DnsClientCache

Write-Host "`nCurrent DNS servers:"
Get-DnsClientServerAddress -InterfaceAlias $adapters -ErrorAction SilentlyContinue |
  Where-Object ServerAddresses | Format-Table InterfaceAlias, AddressFamily, ServerAddresses -AutoSize

Write-Host "Steam lookups (should NOT be 127.0.0.1):"
foreach ($h in 'store.steampowered.com', 'checkout.steampowered.com', 'cache1-sgp1.steamcontent.com') {
  $ips = (Resolve-DnsName $h -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -in 'A', 'AAAA' } | ForEach-Object IPAddress) -join ', '
  Write-Host "  $h => $ips"
}
Read-Host "`nPress Enter to close"
