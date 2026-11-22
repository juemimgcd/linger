import importlib.util
import os
import struct
import sys
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("binding", Path(sys.argv[1]).resolve())
binding = importlib.util.module_from_spec(spec)
spec.loader.exec_module(binding)

with Path(sys.executable).open("rb") as image:
    image.seek(0x3C)
    header = int.from_bytes(image.read(4), "little")
    image.seek(header)
    signature, machine = struct.unpack("<4sH", image.read(6))
    if signature != b"PE\x00\x00" or machine != 0x8664:
        raise ValueError(f"Unexpected Python PE machine: {machine:#x}")
    print(f"Official bundled Python PE machine: {machine:#x} (AMD64)")

with tempfile.TemporaryDirectory(dir=os.environ["LOCALAPPDATA"]) as scratch:
    root = Path(scratch)
    target, replacement = root / "settings.json", root / "new.json"
    for label, opener in [("Python default", None), ("PR reader", binding.open_profile_fd)]:
        target.write_bytes(b"old")
        replacement.write_bytes(b"new")
        with open(target, "rb", opener=opener) as held:
            try:
                os.replace(replacement, target)
            except PermissionError as error:
                if error.winerror not in (5, 32):
                    raise
                print(f"{label}, os.replace while open: WinError {error.winerror}")
            else:
                print(f"{label}, os.replace while open: succeeded")
        replacement.write_bytes(b"new")
        os.replace(replacement, target)
        print(f"{label}, os.replace after close: succeeded")
    target.write_bytes(b"old")
    replacement.write_bytes(b"new")
    with open(target, "rb", opener=binding.open_profile_fd) as held:
        before = binding.file_owner_sid(held.fileno())
        os.rename(target, root / "old.json")
        os.rename(replacement, target)
        if (held.read(), target.read_bytes(), binding.file_owner_sid(held.fileno())) != (b"old", b"new", before):
            raise ValueError("Changed file identity")
        print("Two renames while PR reader is open: original handle kept original SID and bytes")
