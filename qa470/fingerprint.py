import hashlib
import importlib.util
import os
import platform
import sys
import tempfile
from pathlib import Path

from localmodels import stack_binding

script = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("pr470", script)
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
with tempfile.TemporaryDirectory(dir=os.environ["LOCALAPPDATA"]) as scratch:
    profile = Path(scratch)
    exe = Path(sys.executable)
    print("Bundled interpreter:", platform.machine(), sys.version.split()[0], flush=True)
    for name in ("settings.json", "models.json"):
        (profile / name).write_bytes(b"{}\r\n")
    try:
        stack_binding._profile_fingerprint(exe, profile)
    except ValueError as error:
        if "ownership inspection is unavailable" not in str(error):
            raise
        print("Original dev45 reproduced:", error)
    else:
        raise RuntimeError("Original dev45 unexpectedly accepted the profile")
    for has_auth in (False, True):
        if has_auth:
            (profile / "auth.json").write_bytes(b'{"sample":true}')
        digest = hashlib.sha256(exe.read_bytes())
        for name in ("settings.json", "models.json", "auth.json"):
            if (profile / name).exists():
                digest.update(name.encode())
                digest.update((profile / name).read_bytes())
        observed = adapter.profile_fingerprint(exe, profile)
        if observed != digest.hexdigest():
            raise RuntimeError("Unexpected fingerprint")
        print("PR fingerprint matched; optional auth present:", has_auth)
    target = profile / "settings.json"
    with open(target, "rb", opener=adapter.open_profile_fd) as original:
        owner = adapter.file_owner_sid(original.fileno())
        replacement = profile / "next.json"
        replacement.write_bytes(b'{"updated":true}')
        os.replace(replacement, target)
        if not owner or original.read() != b"{}\r\n" or target.read_bytes() != b'{"updated":true}':
            raise RuntimeError("Replacement changed the opened object")
        print("Replacement preserved the inspected file handle")
