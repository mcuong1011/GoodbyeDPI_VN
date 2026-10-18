# Steam Unblock Setup Guide (GoodbyeDPI standalone, Vietnam ISP)

A step-by-step guide to getting Steam working again on a network where the ISP blocks it: store browsing, checkout, and game downloads, all without DNSveil.

The settings below were chosen by testing 15+ GoodbyeDPI configurations on this network (October 2026). See [Why these settings](#why-these-settings) at the end.

---

## What is in this folder

| File | What it does |
|---|---|
| `fix_dns_google.ps1` | **Step 1.** Points Windows DNS (IPv4 and IPv6) at Google DNS. Run once; the change is permanent. |
| `3_steam_vn_dnsfix.cmd` | **Step 4.** Starts GoodbyeDPI in the system tray with the tested settings (`-3` plus DNS redirect). |
| `goodbyedpi_tray.exe` | The tray app that `3_steam_vn_dnsfix.cmd` starts. Runs GoodbyeDPI with no console window. Source and `build.cmd` are in `tray\`. |
| `service_install_steam.cmd` | *Optional, Step 6.* Installs GoodbyeDPI as a Windows service so it starts automatically at boot. |
| `service_remove.cmd` | Removes the GoodbyeDPI service and the WinDivert driver. |
| `x86_64\`, `x86\` | The GoodbyeDPI 0.2.2 program and WinDivert driver (64-bit and 32-bit). The `.cmd` files pick the right one automatically. |
| `licenses\` | GoodbyeDPI / WinDivert licenses. |

> Keep this folder in a permanent location (for example `C:\Tools\goodbyedpi\`) **before** Step 6. The service remembers the folder path it was installed from.

---

## The problem in one paragraph

The ISP blocks Steam in two ways:

1. **DNS block.** The router's DNS (including its IPv6 DNS `fe80::1`) answers `127.0.0.1` for every Steam domain. That makes Steam "not exist". Setting only IPv4 DNS to 8.8.8.8 is **not enough**, because Windows keeps asking the router over IPv6.
2. **Connection (SNI/DPI) block.** Some Steam servers have their secure connection cut mid-handshake: `checkout.steampowered.com`, `help.steampowered.com`, `cdn.fastly.steamstatic.com` and the game download servers `*.steamcontent.com`. Only GoodbyeDPI mode `-3` got through all of these.

Steps 1–2 fix the DNS block. Steps 3–5 fix the connection block.

---

## Step 1: Set Google DNS for IPv4 and IPv6

This replaces the router's DNS (which lies about Steam) with Google DNS on the **Ethernet** and **Wi-Fi** adapters.

1. Press **Start** and type `PowerShell`.
2. Right-click **Windows PowerShell** and choose **Run as administrator**. Click **Yes** on the UAC prompt.
3. Paste this and press Enter (change the path if you moved the folder):

   ```
   powershell -ExecutionPolicy Bypass -File "C:\Users\Mcuongyeue\Desktop\goodbyedpi-0.2.2\handoff\fix_dns_google.ps1"
   ```

4. The script prints the DNS servers and then three Steam lookups. **Check the lookups:**

   - ✅ Good: real addresses, e.g. `store.steampowered.com => 118.68.82.144`
   - ❌ Bad: `127.0.0.1`. The DNS is still poisoned; see [Troubleshooting](#troubleshooting).

5. Press Enter to close the window.

**You only need to do this once.** The setting survives reboots. Re-run it only if you reinstall Windows, add a new network adapter, or someone resets the network settings.

What it sets:

| Adapter | IPv4 DNS | IPv6 DNS |
|---|---|---|
| Ethernet, Wi-Fi | `8.8.8.8`, `8.8.4.4` | `2001:4860:4860::8888`, `2001:4860:4860::8844` |

---

## Step 2 (optional, recommended): Encrypt DNS with DNS over HTTPS

Today the ISP does not tamper with traffic to Google DNS, but plain DNS can be intercepted at any time. Encrypting it removes that risk.

1. Open **Settings → Network & internet → Ethernet**.
   (For Wi-Fi: **Settings → Network & internet → Wi-Fi → *your network* → Hardware properties**.)
2. Next to **DNS server assignment**, click **Edit**. It should already say **Manual** because of Step 1.
3. Turn **IPv4** on and fill in:
   - Preferred DNS: `8.8.8.8`, DNS over HTTPS: **On (automatic template)**
   - Alternate DNS: `8.8.4.4`, DNS over HTTPS: **On (automatic template)**
   - Leave **Fallback to plaintext** off.
4. Turn **IPv6** on and fill in:
   - Preferred DNS: `2001:4860:4860::8888`, DNS over HTTPS: **On (automatic template)**
   - Alternate DNS: `2001:4860:4860::8844`, DNS over HTTPS: **On (automatic template)**
5. Click **Save**.
6. Back on the adapter page, the DNS servers should now show **(Encrypted)** after each address.

Repeat for Wi-Fi if you use it.

---

## Step 3: Start GoodbyeDPI with the Steam settings

1. Double-click **`3_steam_vn_dnsfix.cmd`**. Click **Yes** on the UAC prompt.
2. No window stays open. GoodbyeDPI runs in the background with an icon in the system tray (bottom-right, next to the clock; it may be under the **^** overflow arrow). A notification says it's running.
   - **Right-click the icon** to **Stop** / **Start** GoodbyeDPI, open **Show log**, or **Exit**. Exit stops GoodbyeDPI.
   - The icon turns grey when GoodbyeDPI is stopped. If it stops on its own, a notification appears; click it to see the log.
   - Tip: drag the icon out of the overflow onto the taskbar to keep it visible.

The command it runs (the arguments live in `3_steam_vn_dnsfix.cmd`; running `goodbyedpi_tray.exe` directly uses the same ones):

```
goodbyedpi.exe -3 --dns-addr 8.8.8.8 --dns-port 53 --dnsv6-addr 2001:4860:4860::8888 --dnsv6-port 53
```

| Part | Meaning |
|---|---|
| `-3` | Legacy modeset = `-p -r -s -e 40`: blocks the ISP's injected resets, tweaks HTTP headers, and splits HTTPS handshakes into 40-byte pieces using TCP window sizing. This was the only mode that opened checkout, help, Fastly and the download servers. |
| `--dns-addr` / `--dnsv6-addr` | Safety net: forces any leftover plain DNS (IPv4 and IPv6) to Google, in case Windows or an app still asks the router. Harmless if Step 1/2 already handle DNS. |

You need GoodbyeDPI running whenever you use Steam. If you don't want to start it by hand each time, use Step 6.

---

## Step 4: Check that Steam works

**Quick check in a browser:** open these. All should load:

- https://store.steampowered.com/
- https://checkout.steampowered.com/ (blocked without `-3`)
- https://help.steampowered.com/ (blocked without `-3`)

**Optional command-line check:** in PowerShell (no admin needed):

```
foreach ($u in 'https://store.steampowered.com/','https://checkout.steampowered.com/','https://help.steampowered.com/','https://cache1-sgp1.steamcontent.com/') { $c = curl.exe -s -o NUL --ssl-revoke-best-effort -m 10 -w '%{http_code}' $u; "$u -> $c" }
```

Any number other than `000` means the connection worked (`200`, `302`, `403`, `404` are all fine). `000` means it is still blocked.

**In the Steam client:** restart Steam fully (right-click the tray icon → Exit, then reopen), browse the Store tab, and start a small download to confirm the download servers work.

---

## Step 5 (optional): Start GoodbyeDPI automatically at boot

Instead of running the `.cmd` every time, install it as a Windows service.

1. Move this folder to its permanent location first (the service stores the path).
2. Exit the GoodbyeDPI tray icon from Step 3 (right-click → **Exit**). The tray app and the service can't run at the same time; the tray app refuses to start while the service is running.
3. Right-click **`service_install_steam.cmd`** → **Run as administrator** → press any key when asked.
4. You should see `[SC] CreateService SUCCESS` and the service start.

From now on GoodbyeDPI runs in the background at every boot, with no window.

- **Check it:** press Win+R, type `services.msc`, and find **GoodbyeDPI**. It should be *Running*, startup type *Automatic*.
- **Remove it:** right-click **`service_remove.cmd`** → **Run as administrator**.
- **Change settings later:** run `service_install_steam.cmd` again. It deletes and recreates the service.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Step 1 lookups still show `127.0.0.1` | Run `ipconfig /flushdns` as admin and check again. Make sure you're on the adapter the script set (it only touches `Ethernet` and `Wi-Fi`; if your adapter has another name, e.g. `Ethernet 2`, edit `$adapters` in the script). |
| Store loads but checkout / downloads fail | GoodbyeDPI isn't running, or DNSveil's copy is running alongside it. Re-check Steps 3–4. |
| `-3` stops working one day (ISP changed something) | Edit `3_steam_vn_dnsfix.cmd` and replace `-3` with `-1`, then `-2`. Those use the same window-size method. Newer modes `-5`, `-6` and `-9` did **not** get through on this network. |
| No internet at all after Step 2 | DNS over HTTPS can't reach Google. In the DNS edit dialog, set **Fallback to plaintext** on, or set DNS over HTTPS to **Off**. |
| Tray icon goes grey right after starting ("GoodbyeDPI stopped") | Right-click the icon → **Show log** for the error. Usually antivirus quarantined `WinDivert64.sys`; add an exclusion for this folder. |
| "The GoodbyeDPI service is already running" | The Step 5 service is installed. Use one or the other: keep the service, or run `service_remove.cmd` as admin and use the tray. |
| Some sites act strange while GoodbyeDPI runs | Right-click the tray icon → **Stop** (or stop the service) to check. It only touches web traffic (ports 80/443). |
| Steam is slow to download | The fastest path is your ISP's local cache (~25–33 MB/s in testing), which you get when DNS is Google. Make sure Step 1 is in place. |

### Undo everything

1. Stop GoodbyeDPI: right-click its tray icon → **Exit**, or run `service_remove.cmd` as admin if you installed the service.
2. Reset DNS to automatic (PowerShell as admin):

   ```
   Set-DnsClientServerAddress -InterfaceAlias Ethernet -ResetServerAddresses
   Set-DnsClientServerAddress -InterfaceAlias Wi-Fi -ResetServerAddresses
   ```

3. In Settings → Network & internet → *adapter* → DNS server assignment, set it back to **Automatic (DHCP)**.

---
