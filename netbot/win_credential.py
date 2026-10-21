"""Read the router password from Windows Credential Manager (stdlib ctypes, Windows only).

install.ps1 stores it as a generic credential whose target name is the keychain_service from config.toml
(netbot-linksys) and whose user name is the router user. The password is returned to the caller in memory
only: never logged, never written to disk.
"""
import ctypes
from ctypes import wintypes

CRED_TYPE_GENERIC = 1


class _CREDENTIAL(ctypes.Structure):
    _fields_ = [("Flags", wintypes.DWORD), ("Type", wintypes.DWORD), ("TargetName", wintypes.LPWSTR),
                ("Comment", wintypes.LPWSTR), ("LastWritten", wintypes.FILETIME), ("CredentialBlobSize", wintypes.DWORD),
                ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)), ("Persist", wintypes.DWORD),
                ("AttributeCount", wintypes.DWORD), ("Attributes", ctypes.c_void_p), ("TargetAlias", wintypes.LPWSTR),
                ("UserName", wintypes.LPWSTR)]


def read_password(target, user):
    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    advapi.CredReadW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(ctypes.POINTER(_CREDENTIAL))]
    advapi.CredReadW.restype = wintypes.BOOL
    advapi.CredFree.argtypes = [ctypes.c_void_p]
    pcred = ctypes.POINTER(_CREDENTIAL)()
    if not advapi.CredReadW(target, CRED_TYPE_GENERIC, 0, ctypes.byref(pcred)):
        raise RuntimeError(f"Credential Manager item '{target}' not found or access denied")
    try:
        c = pcred.contents
        if c.UserName and user and c.UserName != user:
            raise RuntimeError(f"Credential Manager item '{target}' is for another user name")
        return ctypes.string_at(c.CredentialBlob, c.CredentialBlobSize).decode("utf-16-le")   # CredWriteW stores UTF-16
    finally:
        advapi.CredFree(pcred)
