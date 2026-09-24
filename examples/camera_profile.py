"""Read the verified hardware profile shared by the installer and examples."""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from tools.camera_profile import profile  # noqa: E402


def load(name):
    data = profile(name)
    capture = data["capture"]
    indices, links = capture["camera_indices"], capture["links"]
    if (len(indices) != 2 or len(set(indices)) != 2 or
            set(links) != {"a", "b"} or len(links) != 2 or
            any(not isinstance(i, int) or i < 0 for i in indices)):
        raise ValueError("Invalid dual-camera capture mapping")
    return data
