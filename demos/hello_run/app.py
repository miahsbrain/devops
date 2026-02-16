import hashlib
import os

from fastapi import FastAPI

app = FastAPI()


@app.get("/")
def read_root():
    secret = os.getenv("DB_PASSWORD", "missing")
    secret_hash = hashlib.sha256(secret.encode()).hexdigest()

    return {
        "service": "hello-run",
        "secret_present": secret != "missing",
        "secret_sha256": secret_hash,
    }
