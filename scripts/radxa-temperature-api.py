#!/usr/bin/env python3

import glob
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def read_thermal(sensor_type):
    for zone in glob.glob("/sys/class/thermal/thermal_zone*"):
        try:
            with open(f"{zone}/type", "r") as f:
                zone_type = f.read().strip()

            if zone_type == sensor_type:
                with open(f"{zone}/temp", "r") as f:
                    return round(int(f.read().strip()) / 1000.0, 1)
        except (OSError, ValueError):
            continue

    return None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/", "/cpu-temp"):
            self.send_error(404)
            return

        cluster0 = read_thermal("cluster0-thermal")
        cluster1 = read_thermal("cluster1-thermal")

        values = [v for v in (cluster0, cluster1) if v is not None]
        cpu = max(values) if values else None

        data = {
            "cpu": cpu,
            "cluster0": cluster0,
            "cluster1": cluster1,
        }

        body = json.dumps(data).encode()

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


server = ThreadingHTTPServer(("192.168.46.165", 9101), Handler)
server.serve_forever()
