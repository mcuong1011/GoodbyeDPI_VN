@ECHO OFF
start "" "%~dp0goodbyedpi_tray.exe" -3 --dns-addr 8.8.8.8 --dns-port 53 --dnsv6-addr 2001:4860:4860::8888 --dnsv6-port 53
