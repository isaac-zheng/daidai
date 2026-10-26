"""Check image login, frontend assets, non-root execution, and volume survival without a model key."""

import http.client
import json
import re
import subprocess
import sys
import time
import urllib.parse
import uuid


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True, stderr=subprocess.STDOUT, timeout=90).strip()


def request(port, path, cookie=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        headers = {} if cookie is None else {"Cookie": cookie}
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        connection.close()


def ready(container):
    details = json.loads(docker("inspect", container))[0]
    port = int(details["NetworkSettings"]["Ports"]["3080/tcp"][0]["HostPort"])
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        state = json.loads(docker("inspect", container))[0]["State"]
        if not state["Running"]:
            raise RuntimeError(f"Container exited with code {state['ExitCode']}")
        logs = docker("logs", container)
        if re.search(r"did not activate|failed to import|ERR_MODULE_NOT_FOUND", logs):
            raise RuntimeError("Application plugin activation failed")
        urls = re.findall(r"http://127\.0\.0\.1:3080/\?token=([A-Za-z0-9_-]+)", logs)
        if urls:
            try:
                status, headers, _ = request(port, "/?token=" + urls[-1])
                if status == 303:
                    return headers["set-cookie"].split(";", 1)[0], port
            except (OSError, http.client.HTTPException):
                pass  # The bounded readiness loop retries transport startup only.
        time.sleep(1)
    raise TimeoutError("No successful launch-token exchange within 180 seconds")


def main():
    image = sys.argv[1]
    name = "daidai-smoke-" + uuid.uuid4().hex
    volume = docker("volume", "create", name)
    container = None

    def start():
        identifier = docker(
            "run", "--detach", "--platform", "linux/amd64", "--name", name, "--init", "--cap-drop=ALL",
            "--security-opt=no-new-privileges:true", "--publish", "127.0.0.1::3080",
            "--mount", f"type=volume,source={volume},target=/home/agent/.dsh", image,
        )
        return identifier

    try:
        container = start()
        cookie, port = ready(container)
        assert request(port, "/")[0] == 401, "Anonymous index must require authentication"
        assert request(port, "/?token=invalid")[0] == 401, "Invalid token must be rejected"
        status, _, body = request(port, "/", cookie)
        assert status == 200 and b"<html" in body, "Authenticated frontend must render"
        assets = re.findall(rb'(?:src|href)="([^" ]+\.(?:js|css))"', body)
        assert assets, "Frontend must reference built assets"
        for asset in assets:
            path = urllib.parse.urljoin("/", asset.decode())
            assert request(port, path, cookie)[0] == 200, f"Missing asset {path}"
        assert docker("exec", container, "id", "-u") == "1001", "Agent must run without root"
        docker("exec", container, "sh", "-c", "printf persistent > /home/agent/.dsh/smoke-marker")
        docker("restart", "--time", "30", container)
        ready(container)
        docker("rm", "--force", container)
        container = start()
        ready(container)
        assert docker("exec", container, "cat", "/home/agent/.dsh/smoke-marker") == "persistent"
        print("PASS: login, invalid-token rejection, frontend assets, UID 1001, restart and recreation persistence")
    except Exception:
        if container:
            logs = docker("logs", container)
            print(re.sub(r"token=[^\s]+", "token=[REDACTED]", logs)[-12000:], file=sys.stderr)
        raise
    finally:
        # The chosen name also covers a run that created the container but timed out before returning its ID.
        cleanup = subprocess.run(["docker", "rm", "--force", name], capture_output=True, text=True, timeout=90)
        if cleanup.returncode and "No such container" not in cleanup.stderr:
            raise RuntimeError(cleanup.stderr)
        subprocess.run(["docker", "volume", "rm", volume], check=True, capture_output=True, timeout=90)


if __name__ == "__main__":
    main()
