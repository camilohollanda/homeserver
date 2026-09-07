#!/usr/bin/env python3
"""Provision Plane's external dependencies; never print credential values.

Needs an Infisical identity with write access and SSH to the two VMs.
Use --user for the existing Infisical CLI login; otherwise uses
INFISICAL_CLIENT_ID/INFISICAL_CLIENT_SECRET from the environment.
Signing keys and passwords are created once in Infisical /Plane/ prod.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import boto3
from botocore.config import Config

BASE = "https://infisical.internal.prakash.com.br"
PROJECT = "73e3fb3c-f972-4014-b70f-c519d5415684"
PG_HOST = "deployer@192.168.20.23"
GARAGE_HOST = "deployer@192.168.20.22"
ORIGIN = "https://plane.internal.prakash.com.br"


def remote(host, script):
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
         "sudo", "-n", "bash", "-s"],
        input="set -euo pipefail\n" + script, text=True, capture_output=True,
        timeout=180,
    )
    if result.returncode:
        # stderr may contain SQL/credentials; don't copy it into logs.
        raise RuntimeError(f"Dependency operation on {host} failed (exit {result.returncode}).")
    return result.stdout


class Infisical:
    def __init__(self, user=False):
        self.token = None
        if user:
            result = subprocess.run(
                ['infisical', 'user', 'get', 'token', '--plain', '--silent',
                 '--domain', BASE + '/api'], capture_output=True, text=True, timeout=30,
            )
            if result.returncode:
                raise RuntimeError('No valid Infisical CLI user session. Run infisical login first.')
            self.token = result.stdout.strip()
            return
        result = self.request("POST", "/api/v1/auth/universal-auth/login", {
            "clientId": os.environ["INFISICAL_CLIENT_ID"],
            "clientSecret": os.environ["INFISICAL_CLIENT_SECRET"],
        })
        self.token = result["accessToken"]

    def request(self, method, path, data=None):
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        request = urllib.request.Request(
            BASE + path, method=method, headers=headers,
            data=None if data is None else json.dumps(data).encode(),
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    def prepare(self):
        query = urllib.parse.urlencode({"workspaceId": PROJECT, "environment": "prod", "path": "/"})
        folders = self.request("GET", "/api/v1/folders?" + query)["folders"]
        if not any(folder["name"] == "Plane" for folder in folders):
            self.request("POST", "/api/v1/folders", {
                "workspaceId": PROJECT, "environment": "prod", "name": "Plane", "path": "/",
            })
        query = urllib.parse.urlencode({
            "workspaceId": PROJECT, "environment": "prod", "secretPath": "/Plane/",
        })
        self.secrets = {secret["secretKey"]: secret["secretValue"] for secret in
                        self.request("GET", "/api/v3/secrets/raw?" + query)["secrets"]}

    def ensure(self, name, value):
        if name not in self.secrets:
            self.request("POST", "/api/v3/secrets/raw/" + name, {
                "workspaceId": PROJECT, "environment": "prod", "secretPath": "/Plane/",
                "type": "shared", "secretValue": value,
            })
            self.secrets[name] = value
        return self.secrets[name]


def random_secret():
    value = subprocess.check_output(["openssl", "rand", "-base64", "32"], text=True)
    return value.strip().translate(str.maketrans("", "", "=+/"))[:32]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--user', action='store_true', help='Use the authenticated Infisical CLI user')
    args = parser.parse_args()
    infisical = Infisical(user=args.user)
    infisical.prepare()
    password = infisical.ensure("POSTGRES_PASSWORD", random_secret())
    # Only generated alphanumeric passwords are accepted in SQL below.
    if not re.fullmatch(r"[A-Za-z0-9]{32}", password):
        raise RuntimeError("Existing POSTGRES_PASSWORD must be 32 alphanumeric characters.")
    for name in ["SECRET_KEY", "LIVE_SERVER_SECRET_KEY", "RABBITMQ_PASSWORD"]:
        infisical.ensure(name, random_secret())
    if not re.fullmatch(r"[A-Za-z0-9]{32}", infisical.secrets['RABBITMQ_PASSWORD']):
        raise RuntimeError("RABBITMQ_PASSWORD must be URL-safe, 32 alphanumeric characters.")

    url = f"postgresql://plane:{password}@pg18.internal.prakash.com.br:5432/plane?sslmode=require"
    if "DATABASE_URL" in infisical.secrets and infisical.secrets["DATABASE_URL"] != url:
        raise RuntimeError("Existing DATABASE_URL differs from provisioned database; review before proceeding.")
    # Credentials travel in SSH stdin, never in command-line arguments.
    remote(PG_HOST, r"""sudo -u postgres psql -X -v ON_ERROR_STOP=1 <<'SQL'
SELECT 'CREATE ROLE plane LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'plane')\gexec
ALTER ROLE plane PASSWORD '%s' CONNECTION LIMIT 20;
SELECT 'CREATE DATABASE plane OWNER plane'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'plane')\gexec
REVOKE CONNECT ON DATABASE plane FROM PUBLIC;
GRANT CONNECT ON DATABASE plane TO plane;
\connect plane
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO plane;
SQL
""" % password)
    infisical.ensure("DATABASE_URL", url)
    print("PostgreSQL plane ready; role limited to 20 connections; DATABASE_URL stored.")

    key_info = remote(GARAGE_HOST, """
docker exec garage /garage bucket info plane >/dev/null 2>&1 || docker exec garage /garage bucket create plane >/dev/null
if docker exec garage /garage key info plane-key >/dev/null 2>&1; then
  docker exec garage /garage key info --show-secret plane-key
else
  docker exec garage /garage key create plane-key
fi
""")
    key_id = re.search(r"(?im)^Key ID:\s*(\S+)", key_info)
    key_secret = re.search(r"(?im)^Secret key:\s*(\S+)", key_info)
    if not key_id or not key_secret:
        raise RuntimeError("Could not parse Garage key; credential output suppressed.")
    for name, value in [("AWS_ACCESS_KEY_ID", key_id[1]), ("AWS_SECRET_ACCESS_KEY", key_secret[1])]:
        if name in infisical.secrets and infisical.secrets[name] != value:
            raise RuntimeError(f"Existing {name} differs from Garage plane-key; review before proceeding.")
        infisical.ensure(name, value)
    cors = {"CORSRules": [{
        "AllowedOrigins": [ORIGIN], "AllowedMethods": ["GET", "PUT", "POST", "HEAD", "DELETE"],
        "AllowedHeaders": ["*"], "ExposeHeaders": ["ETag"], "MaxAgeSeconds": 3000,
    }]}
    s3 = boto3.client('s3', endpoint_url='https://garage.internal.prakash.com.br',
                      region_name='garage', aws_access_key_id=key_id[1],
                      aws_secret_access_key=key_secret[1],
                      config=Config(signature_version='s3v4', s3={'addressing_style': 'path'}))
    # CORS needs owner permission; runtime only retains read/write. Revoke owner
    # even if CORS configuration fails.
    remote(GARAGE_HOST, "docker exec garage /garage bucket allow --read --write --owner plane --key plane-key >/dev/null\n")
    try:
        s3.put_bucket_cors(Bucket='plane', CORSConfiguration=cors)
    finally:
        remote(GARAGE_HOST, "docker exec garage /garage bucket deny --owner plane --key plane-key >/dev/null\n")
    # The existing replication job enumerates only buckets readable by this key.
    remote(GARAGE_HOST, "docker exec garage /garage bucket allow --read plane --key replica-ro >/dev/null\n")
    print("Garage plane bucket, CORS and read/write key ready; replica-ro granted read access.")
    print("Infisical /Plane/ prod contains signing keys and dependency credentials; values suppressed.")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        sys.exit(f"Infisical API returned HTTP {error.code}; response body suppressed.")
    except (RuntimeError, KeyError, subprocess.TimeoutExpired) as error:
        sys.exit(str(error))
