#!/usr/bin/env python3
"""通过 GitHub REST API 推送本地提交（绕开 git/HTTPS 传输层）。

背景：某些网络环境下 `git push` 到 github.com:443 会持续失败
（GnuTLS -110 / 连接超时），但 `api.github.com` 稳定可用。
这个脚本用 Git Data API 把「本地 HEAD 的树」和「远端分支的树」做差异对比，
只上传变化的 blob，然后提交并更新 ref。

设计要点（无状态，可反复运行）：
- 不依赖本地与远端 commit 对象同源：GitHub API 创建的 commit sha 与本地不同，
  所以每次都用 `git ls-tree -r HEAD` 与远端 recursive tree 对比内容（blob sha + mode）。
- 只删除「远端有、本地 HEAD 没有」的 blob（本分支只由本流程写入，安全）。
- 保留文件模式（100644/100755）。
- token 从 ~/.git-credentials 读取；不打印 token。

用法：
    python3 tool/push_via_api.py [--branch windows/full-desktop] [--message "..."] [--dry-run]

注意：API 推送后本地分支与远端分支的 commit sha 会不一致（内容相同）。等网络恢复后
用 `git push --force origin <branch>` 可以让远端历史回到本地提交（内容不变）。
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
        request = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "User-Agent": "flit-windows-port",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:500]
            raise SystemExit(f"GitHub API {method} {path} 失败: {error.code} {detail}")


def git(*args: str, cwd: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True
    )
    if check and result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} 失败: {result.stderr.strip()}")
    return result.stdout


def local_entries(root: str) -> dict[str, tuple[str, str]]:
    """path -> (mode, blob sha)，来自本地 HEAD 的树。"""
    out = git("ls-tree", "-r", "-z", "HEAD", cwd=root)
    entries: dict[str, tuple[str, str]] = {}
    for record in out.split("\x00"):
        if not record:
            continue
        meta, path = record.split("\t", 1)
        mode, kind, sha = meta.split(" ")
        if kind == "blob":
            entries[path] = (mode, sha)
    return entries


def remote_entries(api: Api, branch: str) -> tuple[str, str, dict[str, tuple[str, str]]]:
    """返回 (remote head sha, remote tree sha, path -> (mode, blob sha))。"""
    ref = api.call("GET", f"/git/ref/heads/{branch}")
    head = ref["object"]["sha"]
    commit = api.call("GET", f"/git/commits/{head}")
    tree_sha = commit["tree"]["sha"]
    tree = api.call("GET", f"/git/trees/{tree_sha}?recursive=1")
    if tree.get("truncated"):
        raise SystemExit("远端树太大被截断，无法做精确对比")
    entries = {}
    for entry in tree.get("tree", []):
        if entry.get("type") == "blob":
            entries[entry["path"]] = (entry["mode"] if "mode" in entry else "100644", entry["sha"])
    return head, tree_sha, entries


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=REPO_DEFAULT)
    parser.add_argument("--branch", default="windows/full-desktop")
    parser.add_argument(
        "--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )
    parser.add_argument("--message", default=None)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    api = Api(read_token(), args.repo)
    root = args.root

    local_head = git("rev-parse", "HEAD", cwd=root).strip()
    local = local_entries(root)
    remote_head, base_tree, remote = remote_entries(api, args.branch)
    print(f"local  HEAD: {local_head[:12]}  files={len(local)}")
    print(f"remote HEAD: {remote_head[:12]}  files={len(remote)}  ({args.branch})")

    changed = [p for p, value in local.items() if remote.get(p) != value]
    deleted = [p for p in remote if p not in local]
    if not changed and not deleted:
        print("内容一致，无需推送")
        return 0
    print(f"changed={len(changed)} deleted={len(deleted)}")

    tree_entries = []
    for path in changed:
        mode, blob_sha = local[path]
        # 必须用提交里记录的 blob，而不是工作区文件：
        # .gitattributes 的 EOL 归一化会让磁盘内容（CRLF）与提交内容（LF）不同。
        data = subprocess.run(
            ["git", "cat-file", "blob", blob_sha],
            cwd=root,
            check=True,
            capture_output=True,
        ).stdout
        blob = api.call(
            "POST",
            "/git/blobs",
            {
                "content": base64.b64encode(data).decode("ascii"),
                "encoding": "base64",
            },
        )
        tree_entries.append(
            {"path": path, "mode": mode, "type": "blob", "sha": blob["sha"]}
        )
        print(f"  blob {blob['sha'][:10]} {path}")
    for path in deleted:
        tree_entries.append(
            {"path": path, "mode": "100644", "type": "blob", "sha": None}
        )
        print(f"  delete {path}")

    if args.dry_run:
        print("dry-run：不写远端")
        return 0

    tree = api.call(
        "POST",
        "/git/trees",
        {"base_tree": base_tree, "tree": tree_entries},
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
    print(
        f"pushed commit {commit['sha'][:12]} -> {args.branch} "
        f"(ref now {updated['object']['sha'][:12]})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())