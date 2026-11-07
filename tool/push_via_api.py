#!/usr/bin/env python3
"""通过 GitHub REST API 推送本地提交（绕开 git/HTTPS 传输层）。

背景：某些网络环境下 `git push` 到 github.com:443 会持续失败
（GnuTLS -110 / 连接超时），但 `api.github.com` 稳定可用。
这个脚本用 Git Data API 把本地 HEAD 与远端分支之间的差异写上去：

    blobs → tree(base_tree) → commit(parents=[remote_head]) → PATCH ref

用法：
    python3 tool/push_via_api.py [--branch windows/full-desktop] [--remote-sha SHA]
                                 [--dry-run] [--message "..."]

要点：
- 只支持 fast-forward（父提交必须是远端 head）；冲突会拒绝并提示先 rebase。
- 保留文件模式（100644/100755）与删除（sha: null）。
- token 从 ~/.git-credentials 读取（格式 https://user:TOKEN@github.com）。
- 不打印 token。
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request


REPO_DEFAULT = "seek888/flit"


def read_token() -> str:
    path = os.path.expanduser("~/.git-credentials")
    text = open(path, encoding="utf-8").read().strip()
    match = re.match(r"https://([^:]+):([^@]+)@", text)
    if not match:
        raise SystemExit("无法从 ~/.git-credentials 解析 token")
    return match.group(2)


class Api:
    def __init__(self, token: str, repo: str):
        self.token = token
        self.repo = repo

    def call(self, method: str, path: str, body=None):
        url = f"https://api.github.com/repos/{self.repo}{path}"
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "flit-windows-port",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:500]
            raise SystemExit(f"GitHub API {method} {path} 失败: {error.code} {detail}")


def git(*args: str, cwd: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout


def changed_entries(root: str, base: str, head: str):
    """返回 [(status, old_path, new_path)]；status 取 A/M/D/R。"""
    out = git("diff", "--name-status", "-z", base, head, cwd=root)
    parts = [p for p in out.split("\x00") if p]
    entries = []
    i = 0
    while i < len(parts):
        status = parts[i]
        if status.startswith("R") or status.startswith("C"):
            entries.append((status[0], parts[i + 1], parts[i + 2]))
            i += 3
        else:
            entries.append((status[0], parts[i + 1], parts[i + 1]))
            i += 2
    return entries


def file_mode(root: str, path: str) -> str:
    out = git("ls-tree", "HEAD", "--", path, cwd=root).strip()
    if not out:
        return "100644"
    return "100755" if out.split()[0] == "100755" else "100644"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=REPO_DEFAULT)
    parser.add_argument("--branch", default="windows/full-desktop")
    parser.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    parser.add_argument("--message", default=None)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    token = read_token()
    api = Api(token, args.repo)
    root = args.root

    local_head = git("rev-parse", "HEAD", cwd=root).strip()
    ref = api.call("GET", f"/git/ref/heads/{args.branch}")
    remote_head = ref["object"]["sha"]
    print(f"local  HEAD: {local_head[:12]}")
    print(f"remote HEAD: {remote_head[:12]}  ({args.branch})")
    if local_head == remote_head:
        print("远端已是最新，无需推送")
        return 0

    # 父提交必须是远端 head（fast-forward）
    try:
        git("merge-base", "--is-ancestor", remote_head, local_head, cwd=root)
        is_ff = True
    except subprocess.CalledProcessError:
        is_ff = False
    if not is_ff:
        raise SystemExit("远端 head 不是本地 HEAD 的祖先，拒绝覆盖；请先 rebase")

    entries = changed_entries(root, remote_head, local_head)
    print(f"changes: {len(entries)}")

    tree_entries = []
    for status, old_path, new_path in entries:
        if status == "D":
            tree_entries.append(
                {"path": old_path, "mode": "100644", "type": "blob", "sha": None}
            )
            continue
        if status == "R":
            tree_entries.append(
                {"path": old_path, "mode": "100755", "type": "blob", "sha": None}
            )
        full = os.path.join(root, new_path)
        data = open(full, "rb").read()
        blob = api.call("POST", "/git/blobs", {"content": base64.b64encode(data).decode("ascii"), "encoding": "base64"})
        tree_entries.append(
            {"path": new_path, "mode": file_mode(root, new_path), "type": "blob", "sha": blob["sha"]}
        )
        print(f"  blob {blob['sha'][:10]} {new_path}")

    if args.dry_run:
        print("dry-run：不写远端")
        return 0

    remote_commit = api.call("GET", f"/git/commits/{remote_head}")
    tree = api.call(
        "POST",
        "/git/trees",
        {"base_tree": remote_commit["tree"]["sha"], "tree": tree_entries},
    )
    message = args.message or git("log", "-1", "--format=%B", cwd=root).strip()
    commit = api.call(
        "POST",
        "/git/commits",
        {
            "message": message,
            "tree": tree["sha"],
            "parents": [remote_head],
            "author": {"name": "DSH", "email": "dsh@local"},
        },
    )
    updated = api.call(
        "PATCH",
        f"/git/refs/heads/{args.branch}",
        {"sha": commit["sha"], "force": False},
    )
    print(f"pushed commit {commit['sha'][:12]} -> {args.branch} (ref now {updated['object']['sha'][:12]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())