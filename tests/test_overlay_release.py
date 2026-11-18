from contextlib import redirect_stderr
import copy
from email.message import Message
import hashlib
import importlib.machinery
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.request

release = importlib.machinery.SourceFileLoader("overlay_release", str(Path(__file__).resolve().parents[1] / "scripts/overlay-release")).load_module()


class OverlayReleaseTests(unittest.TestCase):
    def setUp(self):
        self.api_url = "https://api.github.com/repos/owner/repo/releases/latest"
        self.url = "https://github.com/owner/repo/releases/download/v1.0/font-1.0.zip"
        self.new_url = self.url.replace("1.0", "2.0")
        self.pin = {"font": {"tag": "v1.0", "url": self.url, "sha256": "old"}}
        self.data = {"tag_name": "v2.0", "assets": [{"name": "font-2.0.zip", "browser_download_url": self.new_url}]}

    def fetch(self, url):
        return json.dumps(self.data).encode() if url.endswith("/latest") else b"archive"

    def test_font_update(self):
        result = release.refresh(self.pin, self.fetch)
        self.assertEqual(result["font"]["url"], self.new_url)
        self.assertEqual(result["font"]["sha256"], hashlib.sha256(b"archive").hexdigest())

    def test_bun_preserves_target_metadata(self):
        pin = {"tag": "v1.0", "targets": {"linux": dict(self.pin["font"], path="bun", format="zip")}}
        del pin["targets"]["linux"]["tag"]
        self.assertEqual(release.refresh(pin, self.fetch)["targets"]["linux"]["path"], "bun")

    def test_incomplete_or_untrusted_release_leaves_input_unchanged(self):
        for mutate in [
            lambda d: d.update(assets=[]),
            lambda d: d.update(prerelease=True),
            lambda d: d.update(tag_name="nightly"),
            lambda d: d["assets"][0].update(browser_download_url="https://other.invalid/file"),
            lambda d: d["assets"][0].update(digest="sha256:wrong"),
        ]:
            original = copy.deepcopy(self.pin)
            data = copy.deepcopy(self.data)
            mutate(self.data)
            with self.assertRaises(ValueError):
                release.refresh(self.pin, self.fetch)
            self.assertEqual(self.pin, original)
            self.data = data

    def test_no_downgrade(self):
        self.data["tag_name"] = "v0.9"
        self.assertEqual(release.refresh(self.pin, self.fetch), self.pin)

    @staticmethod
    def response(request, status, body=b"", **headers):
        message = Message()
        for name, value in headers.items():
            message[name] = value
        response = urllib.response.addinfourl(io.BytesIO(body), message, request.full_url, status)
        response.msg = {200: "OK", 302: "Found", 403: "Forbidden", 429: "Too Many Requests"}[status]
        return response

    def test_workflow_token_only_reaches_initial_metadata_request(self):
        for redirect in (
            "https://api.github.com/repositories/1/releases/latest",
            "https://other.invalid/releases/latest",
        ):
            with self.subTest(redirect=redirect):
                requests = []

                def https_open(handler, request):
                    url = request.full_url
                    token = request.get_header("Authorization")
                    requests.append((url, token))
                    if url == self.api_url:
                        if token is None:
                            return self.response(request, 403, b'{"message":"API rate limit exceeded"}')
                        return self.response(request, 302, Location=redirect)
                    if url == redirect:
                        return self.response(request, 200, json.dumps(self.data).encode())
                    return self.response(request, 200, b"archive")

                with patch.dict("os.environ", {"GH_TOKEN": "fake-token"}, clear=True), \
                        patch.object(urllib.request.HTTPSHandler, "https_open", https_open):
                    result = release.refresh(self.pin)

                self.assertEqual(result["font"]["sha256"], hashlib.sha256(b"archive").hexdigest())
                self.assertEqual(requests, [
                    (self.api_url, "Bearer fake-token"),
                    (redirect, None),
                    (self.new_url, None),
                ])

    def test_rate_limit_retry_honors_server_wait(self):
        for status, headers, wait in (
            (403, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "110"}, 10),
            (429, {"Retry-After": "15"}, 15),
            (403, {}, 60),
        ):
            with self.subTest(status=status, headers=headers):
                def https_open(handler, request):
                    if not sleep.called:
                        return self.response(request, status, b'{"message":"API rate limit exceeded"}', **headers)
                    return self.response(request, 200, json.dumps(self.data).encode())

                self.data["tag_name"] = "v1.0"
                with patch.dict("os.environ", {}, clear=True), \
                        patch.object(urllib.request.HTTPSHandler, "https_open", https_open), \
                        patch("time.time", return_value=100), patch("time.sleep") as sleep:
                    self.assertEqual(release.refresh(self.pin), self.pin)
                sleep.assert_called_once_with(wait)

    def test_rate_limit_failure_leaves_pin_unwritten(self):
        for delay, attempts in (("5", 2), ("300", 1)):
            with self.subTest(delay=delay), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "pin.json"
                original = json.dumps(self.pin)
                path.write_text(original)
                errors = io.StringIO()

                def https_open(handler, request):
                    return self.response(request, 429, **{"Retry-After": delay})

                with patch.dict("os.environ", {"GH_TOKEN": "fake-token"}, clear=True), \
                        patch.object(urllib.request.HTTPSHandler, "https_open", autospec=True,
                                     side_effect=https_open) as request, \
                        patch("time.sleep") as sleep, patch("sys.argv", ["overlay-release", "--output", str(path)]), \
                        redirect_stderr(errors), self.assertRaises(SystemExit) as failure:
                    release.main()

                self.assertEqual(failure.exception.code, 1)
                self.assertIn("GitHub API rate limit", errors.getvalue())
                self.assertIn(self.api_url, errors.getvalue())
                self.assertNotIn("fake-token", errors.getvalue())
                self.assertEqual(path.read_text(), original)
                self.assertEqual(request.call_count, attempts)
                self.assertEqual(sleep.call_count, attempts - 1)

    def test_permission_error_is_not_retried(self):
        def https_open(handler, request):
            return self.response(request, 403, b'{"message":"Resource not accessible by integration"}')

        with patch.dict("os.environ", {"GH_TOKEN": "fake-token"}, clear=True), \
                patch.object(urllib.request.HTTPSHandler, "https_open", https_open), \
                patch("time.sleep") as sleep:
            with self.assertRaisesRegex(urllib.error.HTTPError, "HTTP Error 403"):
                release.refresh(self.pin)
        sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
