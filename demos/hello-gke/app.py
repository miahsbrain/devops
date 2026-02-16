from fastapi import FastAPI
import hashlib
import os

app = FastAPI()

# Read the secret from the mounted file
SECRET_PATH = "/secrets/DB_PASSWORD"

@app.get("/")
def read_root():
    try:
        with open(SECRET_PATH, "r") as f:
            secret = f.read().strip()
    except FileNotFoundError:
        secret = "missing"

    secret_hash = hashlib.sha256(secret.encode()).hexdigest()
    
    return {
        "service": "hello-gke",
        "secret_present": secret != "missing",
        "secret_sha256": secret_hash
    }

