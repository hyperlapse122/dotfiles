from contextlib import closing
import ctypes
import sys

from keyring.backend import KeyringBackend
from keyring.errors import KeyringError, PasswordDeleteError


SERVICES = {"gh:github.com", "gh:gist.github.com"}


class Keyring(KeyringBackend):
    priority = 1

    def _operate(self, operation, service, username, password=None):
        if service not in SERVICES or not isinstance(username, str):
            raise KeyringError("Unsupported GitHub credential identity")
        try:
            if sys.platform == "win32":
                return self._windows(operation, service, username, password)
            if sys.platform == "linux":
                return self._linux(operation, service, username, password)
            if sys.platform == "darwin":
                from keyring.backends.macOS import Keyring as MacKeyring
                native = MacKeyring()
                if operation == "get":
                    return native.get_password(service, username)
                if operation == "set":
                    return native.set_password(service, username, password)
                return native.delete_password(service, username)
            raise KeyringError("No supported native credential store on this OS")
        except Exception:
            # Backend exceptions may include credentials or service replies.
            raise KeyringError("Native GitHub credential store operation failed") from None

    def get_password(self, service, username):
        return self._operate("get", service, username)

    def set_password(self, service, username, password):
        if not isinstance(password, str) or not password:
            raise KeyringError("A nonempty GitHub token is required")
        self._operate("set", service, username, password)

    def delete_password(self, service, username):
        self._operate("delete", service, username)

    @staticmethod
    def _windows(operation, service, username, password):
        from ctypes import wintypes

        class Credential(ctypes.Structure):
            _fields_ = [
                ("Flags", wintypes.DWORD),
                ("Type", wintypes.DWORD),
                ("TargetName", wintypes.LPWSTR),
                ("Comment", wintypes.LPWSTR),
                ("LastWritten", wintypes.FILETIME),
                ("CredentialBlobSize", wintypes.DWORD),
                ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
                ("Persist", wintypes.DWORD),
                ("AttributeCount", wintypes.DWORD),
                ("Attributes", ctypes.c_void_p),
                ("TargetAlias", wintypes.LPWSTR),
                ("UserName", wintypes.LPWSTR),
            ]

        api = ctypes.WinDLL("Advapi32.dll", use_last_error=True)
        api.CredReadW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                  ctypes.POINTER(ctypes.POINTER(Credential))]
        api.CredReadW.restype = wintypes.BOOL
        api.CredWriteW.argtypes = [ctypes.POINTER(Credential), wintypes.DWORD]
        api.CredWriteW.restype = wintypes.BOOL
        api.CredDeleteW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD]
        api.CredDeleteW.restype = wintypes.BOOL
        api.CredFree.argtypes = [ctypes.c_void_p]
        api.CredFree.restype = None
        target = service + ":" + username
        if operation == "get":
            credential = ctypes.POINTER(Credential)()
            if not api.CredReadW(target, 1, 0, ctypes.byref(credential)):
                if ctypes.get_last_error() == 1168:
                    return None
                raise KeyringError("Windows credential read failed")
            try:
                value = credential.contents
                return ctypes.string_at(value.CredentialBlob, value.CredentialBlobSize).decode("utf-8")
            finally:
                api.CredFree(credential)
        if operation == "delete":
            if not api.CredDeleteW(target, 1, 0):
                raise PasswordDeleteError("Windows credential deletion failed")
            return None
        encoded = password.encode("utf-8")
        blob = (ctypes.c_ubyte * len(encoded)).from_buffer_copy(encoded)
        credential = Credential(
            Type=1, TargetName=target, CredentialBlobSize=len(encoded),
            CredentialBlob=blob, Persist=2, UserName=username,
        )
        if not api.CredWriteW(ctypes.byref(credential), 0):
            raise KeyringError("Windows credential write failed")
        return None

    @staticmethod
    def _linux(operation, service, username, password):
        import secretstorage

        with closing(secretstorage.dbus_init()) as connection:
            login = "/org/freedesktop/secrets/collection/login"
            selected = next((collection for collection in secretstorage.get_all_collections(connection)
                             if collection.collection_path == login), None)
            if selected is None:
                # Unlike get_default_collection(), constructing the alias never
                # creates a collection or changes the user's keyring policy.
                selected = secretstorage.Collection(connection)
            if selected.is_locked():
                selected.unlock()
                selected.ensure_not_locked()
            attributes = {"service": service, "username": username}
            if operation == "set":
                selected.create_item("GitHub CLI credential", attributes, password.encode("utf-8"),
                                     replace=True, content_type="text/plain; charset=utf8")
                return None
            for item in selected.search_items(attributes):
                if item.is_locked():
                    item.unlock()
                    item.ensure_not_locked()
                if operation == "get":
                    return item.get_secret().decode("utf-8")
                item.delete()
                return None
            if operation == "delete":
                raise PasswordDeleteError("Native credential does not exist")
            return None
