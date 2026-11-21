# Compares a password with a PostgreSQL SCRAM-SHA-256 verifier, or makes a new verifier.
# Used by roles/database_server so the password itself never reaches PostgreSQL: the server
# only ever receives the verifier (the same value it would store), so the password can't end
# up in the server log or in pg_stat_activity.
#
# stdin, two lines: the password, then the current verifier (pg_authid.rolpassword; may be empty).
# stdout: "unchanged" if the password matches the current verifier, otherwise a new verifier
# with a random salt, in the form PostgreSQL stores:
#   SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>
import base64
import hashlib
import hmac
import os
import sys

ITERATIONS = 4096  # PostgreSQL's default (scram_iterations)


def verifier(password, salt, iterations):
    salted = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    client_key = hmac.new(salted, b"Client Key", "sha256").digest()
    server_key = hmac.new(salted, b"Server Key", "sha256").digest()
    stored_key = hashlib.sha256(client_key).digest()

    def b64(data):
        return base64.b64encode(data).decode("ascii")

    return "SCRAM-SHA-256$%d:%s$%s:%s" % (iterations, b64(salt), b64(stored_key), b64(server_key))


password = sys.stdin.readline().rstrip("\n")
current = sys.stdin.readline().strip()

try:
    method, params, _keys = current.split("$")
    iterations, salt = params.split(":")
    if method == "SCRAM-SHA-256" and verifier(password, base64.b64decode(salt), int(iterations)) == current:
        print("unchanged")
        sys.exit(0)
except ValueError:
    pass  # no password yet, or an old md5 hash: make a new verifier

print(verifier(password, os.urandom(16), ITERATIONS))
