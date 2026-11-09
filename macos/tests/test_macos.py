"""Core tests and real HTTP/TLS via a local proxy; requires example.com access."""
import contextlib
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
MACOS = ROOT / "macos"
BUILD = MACOS / "build"
RESOURCES = ROOT / "GoodbyeDPI macOS.app/Contents/Resources"


class NativeCoreTests(unittest.TestCase):
    def test_production_core(self):
        subprocess.run([
            "/usr/bin/xcrun", "swiftc", "-module-cache-path", str(BUILD / "module-cache"),
            str(MACOS / "Core.swift"), str(MACOS / "System.swift"), str(MACOS / "tests/CoreTests.swift"),
            "-o", str(BUILD / "core-tests"),
        ], check=True, capture_output=True, text=True)
        result = subprocess.run([str(BUILD / "core-tests"), str(BUILD / "test-state")],
                                check=True, capture_output=True, text=True)
        self.assertIn("core tests passed", result.stdout)
        print(result.stdout, end="")

    def test_pf_rule_syntax(self):
        # Export the actual production constant, then ask Apple's parser to
        # validate it with -n (no changes and no admin privilege required).
        directory = Path(tempfile.mkdtemp(prefix="pf-test-", dir=BUILD))
        main = directory / "main.swift"
        main.write_text("import Foundation\nprint(Engine.rules)\n")
        binary = directory / "rules"
        subprocess.run(["/usr/bin/xcrun", "swiftc", "-module-cache-path", str(BUILD / "module-cache"),
                        str(MACOS / "Core.swift"), str(main), "-o", str(binary)], check=True, capture_output=True)
        rules = subprocess.check_output([str(binary)])
        anchor = directory / "pf.anchor"
        anchor.write_bytes(rules)
        subprocess.run(["/sbin/pfctl", "-n", "-a", "com.apple/goodbyedpi-vn", "-f", str(anchor)],
                       check=True, capture_output=True)

    def test_packaged_helper_and_architectures(self):
        for binary in [RESOURCES / "tpws", RESOURCES / "helper", RESOURCES.parent / "MacOS/GoodbyeDPI"]:
            output = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True)
            self.assertIn("arm64", output)
            self.assertIn("x86_64", output)
        output = subprocess.check_output([str(RESOURCES / "helper"), "status"], text=True)
        self.assertTrue(output.strip())
        result = subprocess.run([str(RESOURCES / "helper"), "not-a-command"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown command", result.stderr)


class ForwardingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = Path(tempfile.mkdtemp(prefix="forwarding-", dir=BUILD))

    @contextlib.contextmanager
    def proxy(self, extra=()):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        with (self.directory / f"tpws-{port}.log").open("wb") as log:
            proc = subprocess.Popen([str(RESOURCES / "tpws"), "--debug=1", "--socks", "--bind-addr=127.0.0.1",
                                     f"--port={port}", "--split-pos=2", "--hostcase", "--hostnospace", *extra],
                                    stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if proc.poll() is not None:
                        self.fail("tpws failed to start; inspect retained test log")
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=.1):
                            break
                    except OSError:
                        time.sleep(.02)
                else:
                    self.fail("tpws did not listen")
                yield port
            finally:
                if proc.poll() is None:
                    proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=3)

    def request(self, proxy, tls=False):
        scheme = "https" if tls else "http"
        return subprocess.check_output([
            "/usr/bin/curl", "--fail", "--silent", "--show-error", "--max-time", "20", "--http1.1",
            "--noproxy", "", "--socks5-hostname", f"127.0.0.1:{proxy}",
            f"{scheme}://example.com/",
        ], text=True)

    def test_http_forwarding_and_host_manipulation(self):
        with self.proxy() as proxy:
            self.assertIn("Example Domain", self.request(proxy))
        log = (self.directory / f"tpws-{proxy}.log").read_text()
        self.assertIn("Changing 'Host:' => 'host:'", log)
        self.assertIn("Removing space before host name", log)

    def test_verified_tls_forwarding_with_split_enabled(self):
        with self.proxy() as proxy:
            self.assertIn("Example Domain", self.request(proxy, tls=True))
        log = (self.directory / f"tpws-{proxy}.log").read_text()
        self.assertIn("Data block contains TLS ClientHello", log)
        self.assertIn("multisplit pos: 2", log)

    def test_non_steam_hosts_are_forwarded_without_manipulation(self):
        with self.proxy(["--hostlist=" + str(MACOS / "steam-hosts.txt")]) as proxy:
            self.assertIn("Example Domain", self.request(proxy))
        log = (self.directory / f"tpws-{proxy}.log").read_text()
        self.assertNotIn("Changing 'Host:'", log)

    def test_upstream_rejects_local_destination(self):
        # This upstream safety guard is why forwarding tests use example.com.
        with self.proxy() as proxy, socket.create_connection(("127.0.0.1", proxy), timeout=3) as client:
            client.sendall(b"\x05\x01\x00")
            self.assertEqual(client.recv(2), b"\x05\x00")
            client.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01\x00\x50")
            reply = client.recv(10)
            self.assertEqual(reply[:2], b"\x05\x02")


if __name__ == "__main__":
    unittest.main()
