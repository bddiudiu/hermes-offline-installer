#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import urllib.request
from urllib.error import URLError


DEFAULT_REPO = "NousResearch/hermes-agent"


def latest_release_tag(repo: str) -> str:
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "hermes-offline-installer/1.0",
    }
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=15.0) as response:
            payload = json.load(response)
    except URLError:
        payload = json.loads(
            subprocess.check_output(
                [
                    "curl",
                    "--fail",
                    "--silent",
                    "--show-error",
                    "-H",
                    f"Accept: {headers['Accept']}",
                    "-H",
                    f"User-Agent: {headers['User-Agent']}",
                    url,
                ],
                text=True,
            )
        )
    tag = str(payload.get("tag_name", "")).strip()
    if not tag:
        raise SystemExit(f"Latest release for {repo} does not include tag_name")
    return tag


def build_source(repo: str, tag: str) -> str:
    return f"hermes-agent @ git+https://github.com/{repo}.git@{tag}"


def main() -> None:
    parser = argparse.ArgumentParser(description="Resolve Hermes Agent source from an explicit or latest upstream tag.")
    parser.add_argument("--repo", default=DEFAULT_REPO, help="GitHub repo in owner/name form.")
    parser.add_argument("--tag", default="", help="Optional upstream tag override, e.g. v2026.7.1.")
    args = parser.parse_args()

    tag = args.tag.strip() or latest_release_tag(args.repo)
    print(f"HERMES_SOURCE={build_source(args.repo, tag)}")
    print(f"HERMES_UPSTREAM_TAG={tag}")


if __name__ == "__main__":
    main()
