import importlib.machinery
import importlib.util
import multiprocessing
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import tempfile
import os
import socket
import struct
import threading
import time
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


SCRIPT = Path(os.environ.get("DESKTOP_SSH_SCRIPT",
                            str(Path(__file__).resolve().parents[1] / "scripts/desktop-ssh")))
loader = importlib.machinery.SourceFileLoader("desktop_ssh", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
desktop_ssh = importlib.util.module_from_spec(spec)
loader.exec_module(desktop_ssh)


class MemoryWallet:
    def __init__(self):
        self.entries = {}
        self.fail_write = False
        self.fail_readback = False

    def read(self, name):
        if self.fail_readback and name in self.entries:
            return "incorrect-readback"
        return self.entries.get(name)

    def write(self, name, value):
        if self.fail_write:
            raise desktop_ssh.DesktopSSHError("wallet write failed")
        self.entries[name] = value


class ServingTests(unittest.TestCase):
    def start_server(self, fail_first_start=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = str(Path(temporary.name) / "agent.sock")
        ready, child_ready = socket.socketpair()

        def child():
            ready.close()
            desktop_ssh.MAX_CONNECTIONS = 2
            if fail_first_start:
                original = threading.Thread.start
                attempts = 0

                def start(thread):
                    nonlocal attempts
                    attempts += 1
                    if attempts == 1:
                        raise RuntimeError("injected thread creation failure")
                    return original(thread)
                threading.Thread.start = start

            class Handler:
                def handle(self, payload):
                    return b"\x0c" + struct.pack(">I", 0)

            desktop_ssh.serve(path, Handler, child_ready)

        process = multiprocessing.get_context("fork").Process(target=child)
        process.start()
        child_ready.close()

        def stop():
            process.terminate()
            process.join(5)
        self.addCleanup(stop)
        ready.settimeout(5)
        try:
            self.assertEqual(ready.recv(1), b"1")
        finally:
            ready.close()
        return path

    def connect(self, path):
        client = socket.socket(socket.AF_UNIX)
        self.addCleanup(client.close)
        client.settimeout(1)
        client.connect(path)
        return client

    def request(self, client):
        desktop_ssh.send(client, b"\x0b")
        self.assertEqual(desktop_ssh.receive(client), b"\x0c\0\0\0\0")

    def test_connection_overload_is_rejected_and_capacity_recovers(self):
        path = self.start_server()
        first, second = self.connect(path), self.connect(path)
        self.request(first)
        self.request(second)
        overflow = self.connect(path)
        with self.assertRaises((EOFError, OSError)):
            self.request(overflow)
        first.close()
        deadline = time.monotonic() + 5
        while True:
            recovered = self.connect(path)
            try:
                self.request(recovered)
                break
            except (EOFError, OSError):
                recovered.close()
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.01)
        self.request(second)

    def test_thread_start_failure_does_not_stop_accepting_clients(self):
        path = self.start_server(fail_first_start=True)
        first = self.connect(path)
        with self.assertRaises((EOFError, OSError)):
            self.request(first)
        self.request(self.connect(path))


class CredentialACLTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "credential"
        self.path.write_bytes(b"fake-credential-source")
        self.path.chmod(0o400)
        self.info = list(self.path.stat())
        self.info[0] = (self.info[0] & ~0o777) | 0o440
        self.info[4] = 0
        self.entries = [(1, 4, 0xffffffff), (2, 4, os.getuid()),
                        (4, 0, 0xffffffff), (16, 4, 0xffffffff), (32, 0, 0xffffffff)]

    def acl(self, entries=None, version=2):
        return struct.pack("<I", version) + b"".join(
            struct.pack("<HHI", *entry) for entry in (entries if entries is not None else self.entries))

    def read(self, acl, source=True, info=None):
        def read_acl(fd, name):
            self.assertIsInstance(fd, int)
            self.assertEqual(name, "system.posix_acl_access")
            if acl is None:
                raise OSError("no ACL")
            return acl
        with patch.object(desktop_ssh.os, "fstat", return_value=os.stat_result(info or self.info)), \
                patch.object(desktop_ssh.os, "getxattr", side_effect=read_acl):
            return desktop_ssh.read_private_file(self.path, source=source)

    def test_systemd_root_credential_acl_accepts_only_service_user_read(self):
        self.assertEqual(self.read(self.acl()), b"fake-credential-source")

    def test_credential_acl_rejects_every_extra_reader_or_writer(self):
        altered = [None, b"", self.acl(version=1), self.acl() + b"trailing",
                   self.acl(self.entries + [(2, 4, os.getuid() + 1)]),
                   self.acl(self.entries + [(8, 4, 42)]),
                   self.acl(self.entries + [self.entries[1]])]
        for index in range(len(self.entries)):
            changed = list(self.entries)
            tag, perm, ident = changed[index]
            changed[index] = (tag, 6 if perm else 4, ident)
            altered.append(self.acl(changed))
        changed = list(self.entries)
        changed[1] = (2, 4, os.getuid() + 1)
        altered.append(self.acl(changed))
        for acl in altered:
            with self.subTest(acl=acl), self.assertRaises(desktop_ssh.DesktopSSHError):
                self.read(acl)

    def test_acl_exception_never_applies_to_working_or_user_owned_files(self):
        with self.assertRaises(desktop_ssh.DesktopSSHError):
            self.read(self.acl(), source=False)
        user_owned = list(self.info)
        user_owned[4] = os.getuid()
        with self.assertRaises(desktop_ssh.DesktopSSHError):
            self.read(self.acl(), info=user_owned)
        linked = list(self.info)
        linked[3] = 2
        with self.assertRaises(desktop_ssh.DesktopSSHError):
            self.read(self.acl(), info=linked)


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=Path.cwd())
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.key_file = self.root / ".ssh/id_ed25519_nix_config"
        self.source = self.root / "source"
        self.public = self.root / "source.pub"
        self.wallet = MemoryWallet()
        self.source_key = self.new_source()

    def new_source(self):
        key = Ed25519PrivateKey.generate()
        self.source.unlink(missing_ok=True)
        self.source.write_bytes(key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH,
            serialization.NoEncryption()))
        self.source.chmod(0o400)
        self.public.write_bytes(key.public_key().public_bytes(
            serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH))
        return key

    def provision(self):
        return desktop_ssh.provision(self.source, self.public, self.key_file, self.wallet)

    def assert_encrypted_identity(self, key):
        data = self.key_file.read_bytes()
        with self.assertRaises((ValueError, TypeError)):
            serialization.load_ssh_private_key(data, password=None)
        password = self.wallet.entries[desktop_ssh.fingerprint(key.public_key())]
        loaded = serialization.load_ssh_private_key(data, password=password.encode())
        self.assertEqual(desktop_ssh.public_bytes(loaded.public_key()),
                         desktop_ssh.public_bytes(key.public_key()))
        self.assertEqual(self.key_file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.key_file.parent.stat().st_mode & 0o777, 0o700)

    def test_protected_key_and_unchanged_pair(self):
        self.assertTrue(self.provision())
        self.assert_encrypted_identity(self.source_key)
        before = self.key_file.read_bytes()
        inode = self.key_file.stat().st_ino
        entries = dict(self.wallet.entries)
        self.assertFalse(self.provision())
        self.assertEqual(self.key_file.read_bytes(), before)
        self.assertEqual(self.key_file.stat().st_ino, inode)
        self.assertEqual(self.wallet.entries, entries)

    def test_rotation_and_recovery_keep_source_identity(self):
        self.provision()
        old_entries = dict(self.wallet.entries)
        key = self.new_source()
        self.provision()
        self.assert_encrypted_identity(key)
        self.assertTrue(old_entries.items() <= self.wallet.entries.items())
        self.key_file.unlink()
        self.provision()
        self.assert_encrypted_identity(key)
        self.wallet.entries.clear()
        self.provision()
        self.assert_encrypted_identity(key)

    def test_concurrent_provisioning_retains_one_pair(self):
        with ThreadPoolExecutor(max_workers=2) as workers:
            results = list(workers.map(lambda _: self.provision(), range(2)))
        self.assertEqual(sorted(results), [False, True])
        self.assertEqual(len(self.wallet.entries), 1)
        self.assert_encrypted_identity(self.source_key)

    def test_loading_requires_matching_wallet_and_metadata(self):
        self.provision()
        declared = desktop_ssh.read_public_key(self.public)
        loaded = desktop_ssh.load_working_key(self.key_file, declared, self.wallet)
        self.assertEqual(desktop_ssh.public_bytes(loaded.public_key()),
                         desktop_ssh.public_bytes(self.source_key.public_key()))
        password = self.wallet.entries[desktop_ssh.fingerprint(declared)]
        mismatched = Ed25519PrivateKey.generate().public_key()
        self.wallet.entries[desktop_ssh.fingerprint(mismatched)] = password
        with self.assertRaisesRegex(desktop_ssh.WorkingKeyUnavailable, "do not match"):
            desktop_ssh.load_working_key(self.key_file, mismatched, self.wallet)
        self.wallet.entries[desktop_ssh.fingerprint(declared)] = "wrong-password"
        with self.assertRaisesRegex(desktop_ssh.WorkingKeyUnavailable, "do not match"):
            desktop_ssh.load_working_key(self.key_file, declared, self.wallet)
        self.wallet.entries.clear()
        with self.assertRaisesRegex(desktop_ssh.DesktopSSHError, "missing from KWallet"):
            desktop_ssh.load_working_key(self.key_file, declared, self.wallet)

    def test_failures_preserve_usable_pair(self):
        self.provision()
        old_key = self.key_file.read_bytes()
        old_entries = dict(self.wallet.entries)
        self.new_source()
        self.wallet.fail_write = True
        with self.assertRaises(desktop_ssh.DesktopSSHError):
            self.provision()
        self.assertEqual(self.key_file.read_bytes(), old_key)
        self.assertEqual(self.wallet.entries, old_entries)
        self.wallet.fail_write = False
        self.wallet.fail_readback = True
        with self.assertRaises(desktop_ssh.DesktopSSHError):
            self.provision()
        self.assertEqual(self.key_file.read_bytes(), old_key)
        self.wallet.fail_readback = False
        with patch.object(desktop_ssh.os, "replace", side_effect=OSError("fake failure")):
            with self.assertRaises(OSError):
                self.provision()
        self.assertEqual(self.key_file.read_bytes(), old_key)
        self.assertTrue(old_entries.items() <= self.wallet.entries.items())
        self.assertEqual(sorted(p.name for p in self.key_file.parent.iterdir()),
                         [".desktop-ssh.lock", "id_ed25519_nix_config"])

    def test_mismatched_metadata_and_unsafe_files_rejected(self):
        self.provision()
        before = self.key_file.read_bytes()
        self.public.write_bytes(Ed25519PrivateKey.generate().public_key().public_bytes(
            serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH))
        with self.assertRaises(desktop_ssh.DesktopSSHError):
            self.provision()
        self.assertEqual(self.key_file.read_bytes(), before)
        self.public.write_bytes(desktop_ssh.public_bytes(self.source_key.public_key()))
        self.key_file.chmod(0o644)
        with self.assertRaises(desktop_ssh.DesktopSSHError):
            self.provision()
        self.key_file.chmod(0o600)
        self.key_file.unlink()
        outside = self.root / "outside"
        outside.write_text("do not replace")
        self.key_file.symlink_to(outside)
        with self.assertRaises(desktop_ssh.DesktopSSHError):
            self.provision()
        self.assertEqual(outside.read_text(), "do not replace")

    def test_symlink_parent_and_lock_rejected(self):
        outside = self.root / "outside"
        outside.mkdir(mode=0o700)
        self.key_file.parent.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(desktop_ssh.DesktopSSHError):
            self.provision()
        self.assertEqual(list(outside.iterdir()), [])
        self.key_file.parent.unlink()
        self.key_file.parent.mkdir(mode=0o700)
        (self.key_file.parent / ".desktop-ssh.lock").symlink_to(self.source)
        with self.assertRaises(desktop_ssh.DesktopSSHError):
            self.provision()

    def test_wallet_backend_error_does_not_expose_credentials(self):
        import dbus

        leaked_value = "FAKE-sensitive-backend-detail"
        with patch.object(dbus.bus, "BusConnection", side_effect=dbus.DBusException(leaked_value)):
            with self.assertRaises(desktop_ssh.DesktopSSHError) as error:
                desktop_ssh.KWallet()
        self.assertNotIn(leaked_value, str(error.exception))

    def test_wallet_calls_select_the_overload_kwalletd_declares_last(self):
        import dbus
        import dbus.lowlevel
        import dbus.proxies
        from dbus._expat_introspect_parser import process_introspection_data

        # Mirrors kwalletd6's introspection order for its overloaded methods.
        introspection = """<node><interface name="org.kde.KWallet">
          <method name="close"><arg direction="out" type="i"/>
            <arg direction="in" type="s"/><arg direction="in" type="b"/></method>
          <method name="close"><arg direction="out" type="i"/>
            <arg direction="in" type="i"/><arg direction="in" type="b"/>
            <arg direction="in" type="s"/></method>
          <method name="isOpen"><arg direction="out" type="b"/>
            <arg direction="in" type="s"/></method>
          <method name="isOpen"><arg direction="out" type="b"/>
            <arg direction="in" type="i"/></method>
          <method name="open"><arg direction="out" type="i"/>
            <arg direction="in" type="s"/><arg direction="in" type="x"/>
            <arg direction="in" type="s"/></method>
          <method name="hasFolder"><arg direction="out" type="b"/>
            <arg direction="in" type="i"/><arg direction="in" type="s"/>
            <arg direction="in" type="s"/></method>
        </interface></node>"""
        replies = {"isOpen": True, "open": 7, "hasFolder": True, "close": 0}
        calls = []

        class Bus:
            def activate_name_owner(self, name):
                return name

            def get_object(self, name, path):
                proxy = dbus.proxies.ProxyObject(self, name, path, introspect=False)
                proxy._introspect_method_map = process_introspection_data(introspection)
                return proxy

            def call_blocking(self, name, path, interface, method, signature, args, **keywords):
                # The real marshaller rejects arguments the signature cannot carry.
                dbus.lowlevel.MethodCallMessage(name, path, interface, method).append(
                    *args, signature=signature)
                calls.append((method, signature))
                return replies[method]

        with patch.object(dbus.bus, "BusConnection", return_value=Bus()):
            wallet = desktop_ssh.KWallet()
            wallet.close()
        self.assertEqual(calls, [("isOpen", "s"), ("open", "sxs"), ("hasFolder", "iss"),
                                 ("close", "ibs")])


class FakeAgent:
    """A real Unix protocol endpoint, with distinct identities and recorded requests."""
    def __init__(self, path, keys, stall=False, deny=False, delay=0):
        self.keys = keys
        self.path = str(path)
        self.stall = stall
        self.deny = deny
        self.delay = delay
        self.reject_binding = False
        self.requests = []
        self.connections = []
        self.peer_pids = []
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(self.path)
        self.listener.listen()
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        try:
            while True:
                client, _ = self.listener.accept()
                self.connections.append(client)
                self.peer_pids.append(struct.unpack("3i", client.getsockopt(
                    socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[0])
                threading.Thread(target=self.client, args=(client,), daemon=True).start()
        except OSError:
            pass

    def client(self, client):
        try:
            while True:
                payload = desktop_ssh.receive(client)
                self.requests.append(payload)
                time.sleep(self.delay)
                if self.stall:
                    time.sleep(1)
                    continue
                if payload == b"\x0b":
                    reply = desktop_ssh.identity_response([
                        (desktop_ssh.identity_blob(key.public_key()), b"fake")
                        for key in self.keys])
                elif payload[:1] == b"\x0d" and not self.deny:
                    packet = desktop_ssh.Packet(payload[1:])
                    blob, data, flags = packet.string(), packet.string(), packet.uint()
                    packet.end()
                    selected = next((key for key in self.keys if
                                     desktop_ssh.identity_blob(key.public_key()) == blob), None)
                    reply = b"\x0e" + desktop_ssh.ssh_string(
                        desktop_ssh.ssh_string(b"ssh-ed25519") +
                        desktop_ssh.ssh_string(selected.sign(data))) if selected else b"\x05"
                elif payload[:1] == b"\x1b":
                    reply = b"\x1c" if self.reject_binding else b"\x06"
                else:
                    reply = b"\x05"
                desktop_ssh.send(client, reply)
        except (OSError, EOFError, ValueError):
            pass

    def close(self):
        try:
            self.listener.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.listener.close()
        for client in self.connections:
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            client.close()
        Path(self.path).unlink(missing_ok=True)


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.primary_key = Ed25519PrivateKey.generate()
        self.fallback_key = Ed25519PrivateKey.generate()
        self.public = self.root / "primary.pub"
        self.public.write_bytes(desktop_ssh.public_bytes(self.primary_key.public_key()))
        self.config = {"public_key": str(self.public), "key_file": str(self.root / "protected"),
                       "primary_socket": str(self.root / "primary.sock"),
                       "fallback_socket": str(self.root / "fallback.sock")}
        self.proxy = desktop_ssh.Composite(self.config)
        self.addCleanup(self.proxy.close)

    def backend(self, name, keys, **kwargs):
        backend = FakeAgent(self.config[name + "_socket"], keys, **kwargs)
        self.addCleanup(backend.close)
        return backend

    def sign(self, blob, data=b"proof", flags=0):
        return b"\x0d" + desktop_ssh.ssh_string(blob) + desktop_ssh.ssh_string(data) + struct.pack(">I", flags)

    def verify_signature(self, key, response):
        self.assertEqual(response[:1], b"\x0e")
        outer = desktop_ssh.Packet(response[1:])
        inner = desktop_ssh.Packet(outer.string())
        outer.end()
        self.assertEqual(inner.string(), b"ssh-ed25519")
        key.public_key().verify(inner.string(), b"proof")
        inner.end()

    def test_primary_first_deduplicated_and_flags_preserved(self):
        primary = self.backend("primary", [self.primary_key])
        fallback = self.backend("fallback", [self.primary_key, self.fallback_key, self.fallback_key])
        items = desktop_ssh.identities(self.proxy.handle(b"\x0b"))
        self.assertEqual([blob for blob, _ in items], [desktop_ssh.identity_blob(key.public_key())
                         for key in (self.primary_key, self.fallback_key)])
        self.verify_signature(self.primary_key, self.proxy.handle(self.sign(items[0][0])))
        payload = self.sign(items[1][0], flags=4)
        self.verify_signature(self.fallback_key, self.proxy.handle(payload))
        self.assertEqual(fallback.requests[-1], payload)
        self.assertEqual(primary.requests[-1], self.sign(items[0][0]))

    def test_unavailable_or_stalled_fallback_does_not_block_primary(self):
        self.backend("primary", [self.primary_key])
        items = desktop_ssh.identities(self.proxy.handle(b"\x0b"))
        self.verify_signature(self.primary_key, self.proxy.handle(self.sign(items[0][0])))
        self.proxy.close()
        self.proxy = desktop_ssh.Composite(self.config)
        self.addCleanup(self.proxy.close)
        self.backend("fallback", [self.fallback_key], stall=True)
        start = time.monotonic()
        items = desktop_ssh.identities(self.proxy.handle(b"\x0b"))
        self.assertLess(time.monotonic() - start, 0.8)
        self.verify_signature(self.primary_key, self.proxy.handle(self.sign(items[0][0])))

    def test_primary_failure_allows_same_connection_fallback(self):
        self.backend("primary", [self.primary_key], deny=True)
        self.backend("fallback", [self.fallback_key])
        items = desktop_ssh.identities(self.proxy.handle(b"\x0b"))
        self.assertEqual(self.proxy.handle(self.sign(items[0][0])), b"\x05")
        self.verify_signature(self.fallback_key, self.proxy.handle(self.sign(items[1][0])))

    def test_missing_primary_metadata_still_allows_fallback(self):
        self.backend("fallback", [self.fallback_key])
        self.public.unlink()
        items = desktop_ssh.identities(self.proxy.handle(b"\x0b"))
        self.assertEqual(len(items), 1)
        self.verify_signature(self.fallback_key, self.proxy.handle(self.sign(items[0][0])))

    def test_primary_unlock_uses_an_inherited_pipe_not_stdout(self):
        self.config["config_path"] = "/fake/config.json"
        agent = desktop_ssh.Primary(self.config)
        def unlock(arguments, **kwargs):
            self.assertEqual(kwargs["stdout"], desktop_ssh.subprocess.DEVNULL)
            self.assertIn("--key-fd", arguments)
            fd = int(arguments[-1])
            self.assertEqual(kwargs["pass_fds"], (fd,))
            os.write(fd, self.primary_key.private_bytes(
                serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                serialization.NoEncryption()))
            return desktop_ssh.subprocess.CompletedProcess(arguments, 0)
        with patch.object(desktop_ssh.subprocess, "run", side_effect=unlock):
            key = agent.load()
        self.assertEqual(desktop_ssh.public_bytes(key.public_key()),
                         desktop_ssh.public_bytes(self.primary_key.public_key()))

    def test_responsive_delayed_fallback_remains_available(self):
        self.backend("fallback", [self.fallback_key], delay=.1)
        items = desktop_ssh.identities(self.proxy.handle(b"\x0b"))
        self.assertEqual(len(items), 2)
        self.verify_signature(self.fallback_key, self.proxy.handle(self.sign(items[1][0])))

    def test_locked_native_wallet_does_not_open_or_read_failure_reprovision(self):
        import dbus
        from unittest.mock import Mock
        interface = Mock()
        interface.isOpen.return_value = False
        with patch.object(dbus.bus, "BusConnection"), patch.object(dbus, "Interface", return_value=interface):
            with self.assertRaises(desktop_ssh.DesktopSSHError):
                desktop_ssh.KWallet()
        interface.open.assert_not_called()
        wallet = Mock()
        wallet.read.side_effect = desktop_ssh.DesktopSSHError("native read failed")
        with self.assertRaises(desktop_ssh.DesktopSSHError) as error:
            desktop_ssh.load_working_key("/missing", self.primary_key.public_key(), wallet)
        self.assertNotIsInstance(error.exception, desktop_ssh.WorkingKeyUnavailable)

    def test_failed_unlock_is_shared_by_waiters_but_fresh_request_retries(self):
        self.config["key_file"] = str(self.root / "missing")
        agent = desktop_ssh.Primary(self.config)
        payload = self.sign(desktop_ssh.identity_blob(self.primary_key.public_key()))
        entered, release = threading.Event(), threading.Event()
        attempts = []
        def fail():
            attempts.append(1)
            entered.set()
            release.wait(5)
            raise desktop_ssh.DesktopSSHError("fake failure")
        def request():
            with self.assertRaises(desktop_ssh.DesktopSSHError):
                agent.handle(payload)
        with patch.object(agent, "load", side_effect=fail):
            with ThreadPoolExecutor(max_workers=4) as pool:
                first = pool.submit(request)
                self.assertTrue(entered.wait(2))
                waiting = [pool.submit(request) for _ in range(3)]
                time.sleep(.1)
                release.set()
                for future in [first] + waiting:
                    future.result(3)
            self.assertEqual(len(attempts), 1)
            request()
            self.assertEqual(len(attempts), 2)

    def test_disconnected_queued_signer_never_unlocks(self):
        self.config["key_file"] = str(self.root / "missing")
        agent = desktop_ssh.Primary(self.config)
        client, server = socket.socketpair()
        self.addCleanup(client.close)
        self.addCleanup(server.close)
        agent.lock.acquire()
        worker = threading.Thread(target=desktop_ssh.serve_connection,
                                  args=(server, agent))
        with patch.object(agent, "load", side_effect=desktop_ssh.DesktopSSHError("fake")) as load:
            worker.start()
            desktop_ssh.send(client, self.sign(desktop_ssh.identity_blob(self.primary_key.public_key())))
            time.sleep(.1)
            client.close()
            agent.lock.release()
            worker.join(2)
            self.assertFalse(worker.is_alive())
            load.assert_not_called()

    def test_binding_and_sign_share_backend_connection(self):
        fallback = self.backend("fallback", [self.fallback_key])
        binding = b"\x1b" + desktop_ssh.ssh_string(b"session-bind@openssh.com") + b"".join(
            desktop_ssh.ssh_string(item) for item in (b"host", b"session", b"signature")) + b"\x00"
        self.assertEqual(self.proxy.handle(binding), b"\x06")
        items = desktop_ssh.identities(self.proxy.handle(b"\x0b"))
        self.proxy.handle(self.sign(items[1][0]))
        self.assertEqual(len(fallback.connections), 1)
        self.assertEqual(fallback.requests[0], binding)
        other = desktop_ssh.Composite(self.config)
        self.addCleanup(other.close)
        other.handle(b"\x0b")
        self.assertEqual(len(fallback.connections), 2)

    def test_unsupported_binding_is_honest_without_hiding_unconstrained_keys(self):
        fallback = self.backend("fallback", [self.fallback_key])
        fallback.reject_binding = True
        binding = b"\x1b" + desktop_ssh.ssh_string(b"session-bind@openssh.com") + b"".join(
            desktop_ssh.ssh_string(item) for item in (b"host", b"session", b"signature")) + b"\x00"
        self.assertEqual(self.proxy.handle(binding), b"\x1c")
        items = desktop_ssh.identities(self.proxy.handle(b"\x0b"))
        self.verify_signature(self.fallback_key, self.proxy.handle(self.sign(items[1][0])))

    def test_dead_backend_is_not_reconnected_without_its_session_binding(self):
        self.backend("fallback", [self.fallback_key])
        items = desktop_ssh.identities(self.proxy.handle(b"\x0b"))
        self.proxy.fallback.close()
        with patch.object(desktop_ssh.socket, "socket") as reconnect:
            self.assertEqual(self.proxy.handle(self.sign(items[1][0])), b"\x05")
            reconnect.assert_not_called()

    def test_oversized_fallback_selection_is_not_silently_truncated(self):
        self.backend("fallback", [self.fallback_key] * (desktop_ssh.MAX_IDENTITIES + 1))
        items = desktop_ssh.identities(self.proxy.handle(b"\x0b"))
        self.assertEqual(items[0][0], desktop_ssh.identity_blob(self.primary_key.public_key()))
        self.assertEqual(len(items), 1)
        self.assertEqual(self.proxy.handle(self.sign(desktop_ssh.identity_blob(
            self.fallback_key.public_key()))), b"\x05")

    def test_unknown_mutation_extensions_and_malformed_packets(self):
        self.backend("fallback", [self.fallback_key])
        self.proxy.handle(b"\x0b")
        self.assertEqual(self.proxy.handle(self.sign(b"unknown")), b"\x05")
        for command in (17, 18, 19, 22, 23, 25):
            self.assertEqual(self.proxy.handle(bytes([command])), b"\x05")
        self.assertEqual(self.proxy.handle(b"\x1b" + desktop_ssh.ssh_string(b"unknown")), b"\x1c")
        with self.assertRaises(ValueError):
            self.proxy.handle(b"\x0d" + struct.pack(">I", 100) + b"short")
        with self.assertRaises(ValueError):
            self.proxy.handle(self.sign(b"unknown") + b"trailing")
        one, two = socket.socketpair()
        self.addCleanup(one.close)
        self.addCleanup(two.close)
        one.sendall(struct.pack(">I", desktop_ssh.MAX_FRAME + 1))
        with self.assertRaises(ValueError):
            desktop_ssh.receive(two)

    def test_primary_caches_key_but_invalidates_rotated_metadata(self):
        self.config["key_file"] = str(self.root / "missing")
        agent = desktop_ssh.Primary(self.config)
        blob = desktop_ssh.identity_blob(self.primary_key.public_key())
        with patch.object(agent, "load", return_value=self.primary_key) as load:
            self.verify_signature(self.primary_key, agent.handle(self.sign(blob)))
            self.verify_signature(self.primary_key, agent.handle(self.sign(blob)))
            self.assertEqual(load.call_count, 1)
            Path(self.config["key_file"]).write_bytes(b"replacement-protected-key")
            Path(self.config["key_file"]).chmod(0o600)
            self.verify_signature(self.primary_key, agent.handle(self.sign(blob)))
            self.assertEqual(load.call_count, 2)
            self.assertEqual(agent.handle(self.sign(blob, flags=2)), b"\x05")
            self.public.write_bytes(desktop_ssh.public_bytes(self.fallback_key.public_key()))
            self.assertEqual(agent.handle(self.sign(blob)), b"\x05")
            self.assertIsNone(agent.key)

    def test_transport_options_stop_at_remote_operands(self):
        self.assertEqual(list(desktop_ssh.command_options(
            ["-vv", "-lroot", "-o", "IdentityAgent=none", "host", "-oIdentityAgent=evil"],
            "lo")), [("v", ""), ("v", ""), ("l", "root"), ("o", "IdentityAgent=none")])
        self.assertEqual(list(desktop_ssh.command_options(["source", "-Sother"], "S")), [])


if __name__ == "__main__":
    unittest.main()
