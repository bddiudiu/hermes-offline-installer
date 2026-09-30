"""Bounded, observable release uploads. Credentials are read only by main().

Multipart parts are independently retried, then every remote byte is read back
and SHA-256 checked before publishing version/root update metadata.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import sys
import threading
import time
from urllib.parse import urlparse

PART_SIZE = 4 * 1024 * 1024
SOCKET_TIMEOUT = (15, 45)  # connect timeout and inactivity/read timeout, seconds
BUDGET_SECONDS = 18 * 60  # workflow has a separate hard 20-minute step timeout


class UploadError(RuntimeError):
    pass


class Budget:
    def __init__(self, seconds=BUDGET_SECONDS, clock=time.monotonic):
        self.clock = clock
        self.started = clock()
        self.seconds = seconds
        self.stage = "preflight"

    def check(self):
        if self.clock() - self.started >= self.seconds:
            raise UploadError("OSS upload exceeded its whole-step time budget")


def log(message):
    print(message, flush=True)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(PART_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def prepare_files(directory, prefix, path_prefix):
    if (not re.fullmatch(r"[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*", prefix)
            or not path_prefix.startswith(prefix + "/")
            or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}-[0-9]+", path_prefix[len(prefix) + 1:])):
        raise UploadError("Invalid version-scoped OSS destination")
    directory = Path(directory)
    files = sorted(p for p in directory.iterdir() if p.name != "latest.json")
    if not files or any(not p.is_file() or p.is_symlink() for p in files):
        raise UploadError("Upload directory contains missing, linked or unexpected entries")
    archives = [p for p in files if p.name.endswith((".zip", ".tar.gz"))]
    if not archives or set(files) != {p for archive in archives for p in (archive, Path(str(archive) + ".sha256"))}:
        raise UploadError("Every archive must have exactly one checksum sidecar")
    hashes = {}
    for archive in archives:
        expected = Path(str(archive) + ".sha256").read_text(encoding="utf-8").strip().split()
        if len(expected) != 2 or expected[1].lstrip("*") != archive.name or not re.fullmatch(r"[a-fA-F0-9]{64}", expected[0]):
            raise UploadError("Invalid archive checksum sidecar")
        actual = sha256(archive)
        if actual != expected[0].lower():
            raise UploadError("Local archive checksum mismatch")
        hashes[archive.name] = actual
    metadata = directory / "latest.json"
    if not metadata.is_file() or metadata.is_symlink():
        raise UploadError("Missing ordinary version metadata file")
    data = json.loads(metadata.read_text(encoding="utf-8"))
    edition = data.get("editions", {}).get("en", {})
    remote = urlparse(str(edition.get("base_url", "")))
    if (edition.get("version") != path_prefix[len(prefix) + 1:] or remote.scheme != "https"
            or remote.query or remote.fragment
            or not any(remote.path.endswith("/" + path_prefix + "/" + archive.name) for archive in archives)):
        raise UploadError("Metadata does not name the verified version-scoped archive")
    for path in [*files, metadata]:
        hashes.setdefault(path.name, sha256(path))
    return files, metadata, hashes


class Uploader:
    def __init__(self, bucket, part_info, *, budget=None, part_size=PART_SIZE, sleep=time.sleep):
        self.bucket = bucket
        self.part_info = part_info
        self.budget = budget or Budget()
        self.part_size = part_size
        self.sleep = sleep

    def call(self, label, action, *, attempts=3):
        for attempt in range(1, attempts + 1):
            self.budget.check()
            self.budget.stage = label
            log(f"OSS {label}: attempt {attempt}/{attempts}")
            try:
                result = action()
                status = getattr(result, "status", 200)
                if status < 200 or status >= 300:
                    error = UploadError("OSS operation returned an unsuccessful status")
                    error.status = status
                    raise error
                self.budget.check()
                return result
            except Exception as exc:
                self.budget.check()
                status = getattr(exc, "status", None)
                # No exception messages, HTTP bodies, signed URLs, request IDs or upload IDs.
                log(f"OSS {label}: failed ({type(exc).__name__}, status={status if isinstance(status, int) else 'unavailable'})")
                if attempt == attempts or (isinstance(status, int) and 400 <= status < 500 and status not in (408, 429)):
                    raise UploadError(f"OSS {label} failed after bounded retries") from None
                self.sleep(2 ** attempt)

    def progress(self, filename, completed, total):
        last = [0.0]
        def callback(consumed, size):
            self.budget.check()
            now = self.budget.clock()
            if now - last[0] >= 5 or consumed == size:
                log(f"OSS upload {filename}: {min(total, completed + consumed)}/{total} bytes")
                last[0] = now
        return callback

    def upload(self, path, key, expected):
        path = Path(path)
        size = path.stat().st_size
        if sha256(path) != expected:
            raise UploadError("Local release file changed after preflight")
        headers = {"x-oss-meta-sha256": expected}
        if path.name == "latest.json":
            headers["Content-Type"] = "application/json"
        if size <= self.part_size:
            contents = path.read_bytes()
            self.call("put " + path.name, lambda: self.bucket.put_object(
                key, contents, headers=headers, progress_callback=self.progress(path.name, 0, size)))
        else:
            # Never replay an ambiguous multipart initialization. No update pointer is
            # written until completion AND complete remote SHA-256 verification.
            result = self.call("begin multipart " + path.name,
                               lambda: self.bucket.init_multipart_upload(key, headers=headers), attempts=1)
            upload_id = result.upload_id
            completed = False
            try:
                parts = []
                with path.open("rb") as stream:
                    offset = 0
                    number = 1
                    while chunk := stream.read(self.part_size):
                        result = self.call(f"part {number} {path.name}", lambda: self.bucket.upload_part(
                            key, upload_id, number, chunk,
                            progress_callback=self.progress(path.name, offset, size)))
                        parts.append(self.part_info(number, result.etag, size=len(chunk), part_crc=getattr(result, "crc", None)))
                        offset += len(chunk)
                        number += 1
                self.call("complete multipart " + path.name,
                          lambda: self.bucket.complete_multipart_upload(key, upload_id, parts))
                completed = True
            finally:
                if not completed:
                    try:
                        self.call("abort incomplete " + path.name,
                                  lambda: self.bucket.abort_multipart_upload(key, upload_id), attempts=1)
                    except Exception:
                        log("OSS incomplete multipart cleanup could not be confirmed; update metadata remains unchanged")
        self.verify(key, path.name, size, expected)

    def verify(self, key, filename, size, expected):
        head = self.call("head " + filename, lambda: self.bucket.head_object(key))
        if int(head.content_length) != size or not head.etag:
            raise UploadError("Remote object size/identity check failed")
        digest = hashlib.sha256()
        for offset in range(0, size, self.part_size):
            length = min(self.part_size, size - offset)
            def read_part():
                result = self.bucket.get_object(key, byte_range=(offset, offset + length - 1),
                                                headers={"If-Match": '"' + head.etag.strip('"') + '"'})
                try:
                    if getattr(result, "status", 0) not in (200, 206):
                        raise UploadError("Remote range read failed")
                    data = result.read(length + 1)
                    if len(data) != length:
                        raise UploadError("Remote range length mismatch")
                    return data
                finally:
                    result.close()
            data = self.call(f"verify {offset + length}/{size} {filename}", read_part)
            digest.update(data)
        if digest.hexdigest() != expected:
            raise UploadError("Remote SHA-256 verification failed; metadata not promoted")
        log(f"OSS verified {filename}: {size} bytes, SHA-256 matched")


def publish_directory(bucket, part_info, directory, prefix, path_prefix, *, promote=False, budget=None, part_size=PART_SIZE, sleep=time.sleep):
    files, metadata, hashes = prepare_files(directory, prefix, path_prefix)
    uploader = Uploader(bucket, part_info, budget=budget, part_size=part_size, sleep=sleep)
    for path in files:
        uploader.upload(path, path_prefix + "/" + path.name, hashes[path.name])
    # Publication barrier: all archives/sidecars above are remotely verified first.
    uploader.upload(metadata, path_prefix + "/latest.json", hashes[metadata.name])
    if promote:
        uploader.upload(metadata, prefix + "/latest.json", hashes[metadata.name])
    else:
        log("Root latest.json preserved")
    log("OSS version upload and full checksum verification complete")


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, default=Path("upload"))
    parser.add_argument("--path-prefix", required=True)
    args = parser.parse_args(argv)
    stop = threading.Event()
    timer = None
    try:
        required = ("ALIYUN_OSS_BUCKET", "ALIYUN_OSS_ENDPOINT", "ALIYUN_OSS_ACCESS_KEY_ID", "ALIYUN_OSS_ACCESS_KEY_SECRET")
        if any(not os.environ.get(name) for name in required):
            raise UploadError("Missing OSS credential/configuration variables")
        endpoint = os.environ["ALIYUN_OSS_ENDPOINT"].strip()
        if "://" not in endpoint:
            endpoint = "https://" + endpoint
        if urlparse(endpoint).scheme != "https":
            raise UploadError("OSS endpoint must use HTTPS")
        import oss2
        from oss2.models import PartInfo
        logging.getLogger("oss2").setLevel(logging.CRITICAL)
        bucket = oss2.Bucket(oss2.Auth(os.environ["ALIYUN_OSS_ACCESS_KEY_ID"], os.environ["ALIYUN_OSS_ACCESS_KEY_SECRET"]),
                             endpoint, os.environ["ALIYUN_OSS_BUCKET"], connect_timeout=SOCKET_TIMEOUT, enable_crc=True)
        budget = Budget()
        def expire():
            log("OSS hard time budget exceeded; stopping without publishing further metadata")
            os._exit(124)
        timer = threading.Timer(BUDGET_SECONDS, expire)
        timer.daemon = True
        timer.start()
        def heartbeat():
            while not stop.wait(20):
                log(f"OSS active: {budget.stage}; elapsed={int(budget.clock() - budget.started)}s")
        threading.Thread(target=heartbeat, daemon=True).start()
        publish_directory(bucket, PartInfo, args.directory, os.environ.get("ALIYUN_OSS_PREFIX", "hermes").strip("/"),
                          args.path_prefix, promote=os.environ.get("UPDATE_ROOT_LATEST") == "true", budget=budget)
        return 0
    except UploadError as exc:
        log("OSS publish failed: " + str(exc))
        return 1
    except Exception as exc:
        log("OSS publish failed: " + type(exc).__name__)
        return 1
    finally:
        stop.set()
        if timer:
            timer.cancel()


if __name__ == "__main__":
    raise SystemExit(main())
