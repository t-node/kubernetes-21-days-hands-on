"""A minimal admission webhook server -- stdlib only, no dependencies.

Two endpoints:

  POST /mutate    if a pod declares no runAsNonRoot, inject
                  securityContext: {runAsNonRoot: true, runAsUser: 1234}
  POST /validate  reject a pod that asks for runAsNonRoot: true AND
                  runAsUser: 0, because those two cannot both be honoured

Both speak AdmissionReview v1. The rules mirror the CKA course lab; the point is
the protocol, not the policy.
"""

import base64
import json
import ssl
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

DEFAULT_UID = 1234
CERT = "/tls/tls.crt"
KEY = "/tls/tls.key"
PORT = 8443


def log(*a):
    print(*a, flush=True)          # unbuffered, so `kubectl logs -f` is live


def review(uid, allowed, message=None, patch=None):
    """Build the AdmissionReview the API server expects back."""
    response = {"uid": uid, "allowed": allowed}
    if message:
        # this string is what the user sees on their terminal
        response["status"] = {"code": 403, "message": message}
    if patch:
        response["patchType"] = "JSONPatch"
        response["patch"] = base64.b64encode(json.dumps(patch).encode()).decode()
    return {
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": response,
    }


def mutate(pod):
    spec = pod.get("spec", {})
    sc = spec.get("securityContext")
    patch = []

    if sc is None:
        patch.append({
            "op": "add",
            "path": "/spec/securityContext",
            "value": {"runAsNonRoot": True, "runAsUser": DEFAULT_UID},
        })
    else:
        if "runAsNonRoot" not in sc:
            patch.append({"op": "add", "path": "/spec/securityContext/runAsNonRoot", "value": True})
        # do not force a UID onto a pod that deliberately opted out
        if "runAsUser" not in sc and sc.get("runAsNonRoot") is not False:
            patch.append({"op": "add", "path": "/spec/securityContext/runAsUser", "value": DEFAULT_UID})

    return patch


def validate(pod):
    sc = pod.get("spec", {}).get("securityContext") or {}
    if sc.get("runAsNonRoot") is True and sc.get("runAsUser") == 0:
        return False, ("securityContext conflict: runAsNonRoot is true but "
                       "runAsUser is 0 (root). Set runAsNonRoot to false, or "
                       "pick a non-zero UID.")
    return True, None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass                       # silence the default per-request access log

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/healthz"):
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send({"error": "bad json"}, 400)
            return

        req = body.get("request", {})
        uid = req.get("uid", "")
        obj = req.get("object", {}) or {}
        name = obj.get("metadata", {}).get("name") or obj.get("metadata", {}).get("generateName", "?")
        user = req.get("userInfo", {}).get("username", "?")

        if self.path.startswith("/mutate"):
            patch = mutate(obj)
            log("MUTATE   pod=%s user=%s ops=%d" % (name, user, len(patch)))
            self._send(review(uid, True, patch=patch))
        elif self.path.startswith("/validate"):
            allowed, msg = validate(obj)
            log("VALIDATE pod=%s user=%s allowed=%s %s" % (name, user, allowed, msg or ""))
            self._send(review(uid, allowed, message=msg))
        else:
            self._send(review(uid, True))


def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    httpd = HTTPServer(("0.0.0.0", PORT), Handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    log("admission webhook listening on :%d (TLS)" % PORT)
    httpd.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
