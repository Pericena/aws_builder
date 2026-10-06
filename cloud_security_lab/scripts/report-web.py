#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

PROJECT_DIR = Path(__file__).resolve().parent.parent
REPORT_ROOT = PROJECT_DIR / "reports"
WEB_ROOT = PROJECT_DIR / "web"

MAX_REPORT_BYTES = 10 * 1024 * 1024
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 5000


class AuditReportHandler(BaseHTTPRequestHandler):
    server_version = "AWSAuditReport/1.0"
    sys_version = ""

    def do_GET(self) -> None:
        path = urlsplit(self.path).path

        if path in ("/", "/index.html"):
            self._send_file(
                WEB_ROOT / "index.html",
                "text/html; charset=utf-8",
            )

        elif path == "/api/latest":
            self._send_latest_report()

        elif path == "/health":
            self._send_json(
                HTTPStatus.OK,
                {"status": "ok"},
            )

        else:
            self._send_json(
                HTTPStatus.NOT_FOUND,
                {"error": "Not found"},
            )

    def do_HEAD(self) -> None:
        path = urlsplit(self.path).path

        if path in ("/", "/index.html"):
            self._send_headers(
                HTTPStatus.OK,
                "text/html; charset=utf-8",
                0,
            )

        elif path == "/health":
            self._send_headers(
                HTTPStatus.OK,
                "application/json; charset=utf-8",
                0,
            )

        else:
            self._send_headers(
                HTTPStatus.NOT_FOUND,
                "application/json; charset=utf-8",
                0,
            )

    def do_POST(self) -> None:
        self._send_json(
            HTTPStatus.METHOD_NOT_ALLOWED,
            {"error": "Only GET and HEAD are supported"},
        )

    def _send_latest_report(self) -> None:
        try:
            report = self._latest_valid_report()

        except OSError:
            self._send_json(
                HTTPStatus.SERVICE_UNAVAILABLE,
                {"error": "Report directory is unavailable"},
            )
            return

        if report is None:
            self._send_json(
                HTTPStatus.NOT_FOUND,
                {"error": "No valid audit report found"},
            )
            return

        self._send_json(
            HTTPStatus.OK,
            report,
        )

    @staticmethod
    def _latest_valid_report() -> dict[str, object] | None:
        if REPORT_ROOT.is_symlink() or not REPORT_ROOT.is_dir():
            return None

        report_paths: list[Path] = []

        for run_dir in REPORT_ROOT.iterdir():
            if run_dir.is_symlink() or not run_dir.is_dir():
                continue

            report_path = run_dir / "report.json"

            if report_path.is_symlink() or not report_path.is_file():
                continue

            report_paths.append(report_path)

        for report_path in sorted(
            report_paths,
            key=lambda item: item.stat().st_mtime_ns,
            reverse=True,
        ):
            try:
                if report_path.stat().st_size > MAX_REPORT_BYTES:
                    continue

                with report_path.open(
                    "r",
                    encoding="utf-8",
                ) as report_file:
                    report = json.load(report_file)

            except (
                OSError,
                UnicodeError,
                json.JSONDecodeError,
            ):
                continue

            if (
                isinstance(report, dict)
                and report.get("tool")
                == "AWS Cloud Security Lab Internal Auditor"
                and report.get("read_only") is True
                and isinstance(report.get("summary"), dict)
                and isinstance(report.get("checks"), list)
            ):
                report["report_file"] = (
                    report_path.parent.name + "/report.json"
                )

                return report

        return None

    def _send_file(
        self,
        path: Path,
        content_type: str,
    ) -> None:
        try:
            content = path.read_bytes()

        except OSError:
            self._send_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"error": "Web interface is unavailable"},
            )
            return

        self._send_response(
            HTTPStatus.OK,
            content_type,
            content,
        )

    def _send_json(
        self,
        status: HTTPStatus,
        payload: dict[str, object],
    ) -> None:
        content = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")

        self._send_response(
            status,
            "application/json; charset=utf-8",
            content,
        )

    def _send_response(
        self,
        status: HTTPStatus,
        content_type: str,
        body: bytes,
    ) -> None:
        self._send_headers(
            status,
            content_type,
            len(body),
        )

        self.wfile.write(body)

    def _send_headers(
        self,
        status: HTTPStatus,
        content_type: str,
        content_length: int,
    ) -> None:
        self.send_response(status)

        self.send_header(
            "Content-Type",
            content_type,
        )

        self.send_header(
            "Content-Length",
            str(content_length),
        )

        self.send_header(
            "Cache-Control",
            "no-store, max-age=0",
        )

        self.send_header(
            "X-Content-Type-Options",
            "nosniff",
        )

        self.send_header(
            "X-Frame-Options",
            "DENY",
        )

        self.send_header(
            "Referrer-Policy",
            "no-referrer",
        )

        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; "
            "style-src 'unsafe-inline'; "
            "script-src 'unsafe-inline'; "
            "connect-src 'self'; "
            "img-src 'self' data:; "
            "base-uri 'none'; "
            "form-action 'none'; "
            "frame-ancestors 'none'",
        )

        self.end_headers()

    def log_message(
        self,
        format_string: str,
        *args: object,
    ) -> None:
        message = format_string % args

        print(
            f"[web] {self.client_address[0]} {message}",
            flush=True,
        )


class PublicHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def create_server(
    host: str,
    port: int,
) -> PublicHTTPServer:
    return PublicHTTPServer(
        (host, port),
        AuditReportHandler,
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Muestra el reporte de auditoría más reciente "
            "mediante un servidor web."
        )
    )

    parser.add_argument(
        "--host",
        default=DEFAULT_HOST,
        help=(
            "Dirección de escucha "
            "(predeterminada: 0.0.0.0)"
        ),
    )

    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=(
            "Puerto de escucha "
            "(predeterminado: 5000)"
        ),
    )

    args = parser.parse_args()

    if not 1 <= args.port <= 65535:
        parser.error(
            "--port debe estar entre 1 y 65535"
        )

    if os.name != "posix":
        parser.error(
            "El visor está diseñado para ejecutarse "
            "en Linux/Ubuntu de la EC2."
        )

    try:
        server = create_server(
            args.host,
            args.port,
        )

    except OSError as error:
        parser.exit(
            1,
            (
                f"ERROR: no se pudo abrir "
                f"{args.host}:{args.port}: {error}\n"
            ),
        )

    print(
        f"Visor de auditoría activo en "
        f"http://{args.host}:{args.port}/",
        flush=True,
    )

    print(
        f"Escuchando en {args.host}:{args.port}",
        flush=True,
    )

    print(
        f"Health check: "
        f"http://{args.host}:{args.port}/health",
        flush=True,
    )

    print(
        "Ctrl+C para detener.",
        flush=True,
    )

    try:
        server.serve_forever()

    except KeyboardInterrupt:
        print(
            "\nVisor detenido.",
            flush=True,
        )

    finally:
        server.server_close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

