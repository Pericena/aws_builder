from __future__ import annotations

import importlib.util
import json
import tempfile
import threading
import unittest
from http import HTTPStatus
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from unittest.mock import patch

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "report-web.py"
SPEC = importlib.util.spec_from_file_location("audit_report_web", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
report_web = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(report_web)


class AuditReportWebTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.report_root = Path(self.temp_dir.name) / "reports"
        self.report_root.mkdir()
        self.report_root.chmod(0o700)
        self.report_patch = patch.object(report_web, "REPORT_ROOT", self.report_root)
        self.report_patch.start()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), report_web.AuditReportHandler)
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(timeout=2)
        self.report_patch.stop()
        self.temp_dir.cleanup()

    def _write_report(self, name: str, payload: dict[str, object]) -> Path:
        run_dir = self.report_root / name
        run_dir.mkdir()
        report_path = run_dir / "report.json"
        report_path.write_text(json.dumps(payload), encoding="utf-8")
        return report_path

    @staticmethod
    def _valid_report(run_id: str = "test-run") -> dict[str, object]:
        return {
            "tool": "AWS Cloud Security Lab Internal Auditor",
            "read_only": True,
            "run_id": run_id,
            "summary": {"checks_total": 1, "findings_total": 0, "errors_total": 0},
            "checks": [{"status": "PASS"}],
            "inventory": {},
        }

    def test_web_page_has_security_headers_and_serves_dashboard(self) -> None:
        with urlopen(self.base_url + "/", timeout=2) as response:
            body = response.read().decode("utf-8")
            self.assertEqual(response.status, HTTPStatus.OK)
            self.assertIn("Auditoría de seguridad", body)
            self.assertEqual(response.headers["Cache-Control"], "no-store, max-age=0")
            self.assertEqual(response.headers["X-Content-Type-Options"], "nosniff")
            self.assertIn("frame-ancestors 'none'", response.headers["Content-Security-Policy"])

    def test_application_server_binds_only_to_loopback(self) -> None:
        server = report_web.create_server(0)
        try:
            self.assertEqual(server.server_address[0], "127.0.0.1")
        finally:
            server.server_close()

    def test_latest_report_endpoint_returns_valid_report_without_caching(self) -> None:
        payload = self._valid_report("run-latest")
        self._write_report("run-latest", payload)
        with urlopen(self.base_url + "/api/latest", timeout=2) as response:
            result = json.loads(response.read())
            self.assertEqual(response.status, HTTPStatus.OK)
            self.assertEqual(result["run_id"], "run-latest")
            self.assertEqual(result["report_file"], "run-latest/report.json")
            self.assertEqual(response.headers["Cache-Control"], "no-store, max-age=0")

    def test_invalid_newest_report_falls_back_to_last_valid_report(self) -> None:
        valid_path = self._write_report("run-valid", self._valid_report("run-valid"))
        invalid_path = self._write_report("run-invalid", {"not": "an audit report"})
        valid_path.touch()
        invalid_path.touch()
        with urlopen(self.base_url + "/api/latest", timeout=2) as response:
            result = json.loads(response.read())
        self.assertEqual(result["run_id"], "run-valid")

    def test_missing_report_returns_not_found(self) -> None:
        with self.assertRaises(HTTPError) as error:
            urlopen(self.base_url + "/api/latest", timeout=2)
        self.assertEqual(error.exception.code, HTTPStatus.NOT_FOUND)
        self.assertEqual(json.loads(error.exception.read())["error"], "No valid audit report found")

    def test_unknown_path_and_post_are_rejected(self) -> None:
        with self.assertRaises(HTTPError) as error:
            urlopen(self.base_url + "/../.env", timeout=2)
        self.assertEqual(error.exception.code, HTTPStatus.NOT_FOUND)
        request = Request(self.base_url + "/api/latest", data=b"{}", method="POST")
        with self.assertRaises(HTTPError) as error:
            urlopen(request, timeout=2)
        self.assertEqual(error.exception.code, HTTPStatus.METHOD_NOT_ALLOWED)

    def test_page_renders_report_strings_as_text(self) -> None:
        html_path = report_web.WEB_ROOT / "index.html"
        source = html_path.read_text(encoding="utf-8")
        self.assertIn("textContent", source)
        self.assertNotIn("innerHTML", source)

    def test_report_limit_skips_oversized_files(self) -> None:
        report_path = self._write_report("run-large", self._valid_report("run-large"))
        report_path.write_bytes(b" " * (report_web.MAX_REPORT_BYTES + 1))
        self.assertIsNone(report_web.AuditReportHandler._latest_valid_report())


if __name__ == "__main__":
    unittest.main()
