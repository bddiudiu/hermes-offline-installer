"""Hermes installer compatibility hooks for running pip on Windows.

This file is copied to a temporary directory as ``sitecustomize.py`` while the
Windows installer invokes pip. It keeps pip from failing on Windows profiles
where pip's vendored platformdirs falls back to incomplete Shell Folders
registry values.
"""

from __future__ import annotations

import functools
import os
import sys


def _folder_from_env(csidl_name: str) -> str:
    user_profile = os.environ.get("USERPROFILE") or os.path.expanduser("~")
    common_data = (
        os.environ.get("ProgramData")
        or os.environ.get("ALLUSERSPROFILE")
        or r"C:\ProgramData"
    )
    mapping = {
        "CSIDL_APPDATA": os.environ.get("APPDATA")
        or os.path.join(user_profile, "AppData", "Roaming"),
        "CSIDL_COMMON_APPDATA": common_data,
        "CSIDL_LOCAL_APPDATA": os.environ.get("LOCALAPPDATA")
        or os.path.join(user_profile, "AppData", "Local"),
        "CSIDL_PERSONAL": os.path.join(user_profile, "Documents"),
        "CSIDL_DOWNLOADS": os.path.join(user_profile, "Downloads"),
        "CSIDL_MYPICTURES": os.path.join(user_profile, "Pictures"),
        "CSIDL_MYVIDEO": os.path.join(user_profile, "Videos"),
        "CSIDL_MYMUSIC": os.path.join(user_profile, "Music"),
        "CSIDL_DESKTOPDIRECTORY": os.path.join(user_profile, "Desktop"),
    }
    value = mapping.get(csidl_name)
    if not value:
        raise ValueError(f"Unknown CSIDL name: {csidl_name}")
    return value


def _patch_pip_platformdirs() -> None:
    if sys.platform != "win32":
        return

    try:
        import pip._vendor.platformdirs.windows as windows
    except Exception:
        return

    patched = functools.lru_cache(maxsize=None)(_folder_from_env)
    patched._hermes_env_patch = True  # type: ignore[attr-defined]
    windows.get_win_folder = patched


_patch_pip_platformdirs()
