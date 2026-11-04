"""Read public release metadata without losing asset digests or requiring login."""

import json
from urllib.request import Request, urlopen


if __name__ == "__main__":
    request = Request(
        "https://api.github.com/repos/pingdotgg/t3code/releases/latest",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "dotfiles-t3-code"},
    )
    with urlopen(request, timeout=30) as response:
        print(json.dumps(json.load(response)))
