"""Serves the Sileo repo and receives tweak logs during development.

python -I tools/dev_server.py <bind ip> <port> <repo folder> <log folder>
"""
import functools
import http.server
import os
import pathlib
import sys

MAX_LOG_BYTES = 4 * 1024 * 1024


class Handler(http.server.SimpleHTTPRequestHandler):
    log_folder: pathlib.Path

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if self.path != "/log" or not 0 < length <= MAX_LOG_BYTES:
            self.send_error(400)
            return
        body = self.rfile.read(length)
        latest = self.log_folder / "latest.log"
        # The log restarts with each app launch, so keep the previous run when it shrinks.
        if latest.exists() and len(body) < latest.stat().st_size:
            os.replace(latest, self.log_folder / "previous.log")
        temporary = self.log_folder / "latest.tmp"
        temporary.write_bytes(body)
        os.replace(temporary, latest)
        self.send_response(204)
        self.end_headers()


def main(ip: str, port: int, repo: str, log_folder: str) -> None:
    folder = pathlib.Path(log_folder)
    folder.mkdir(parents=True, exist_ok=True)
    Handler.log_folder = folder
    handler = functools.partial(Handler, directory=repo)
    http.server.ThreadingHTTPServer((ip, port), handler).serve_forever()


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4])
