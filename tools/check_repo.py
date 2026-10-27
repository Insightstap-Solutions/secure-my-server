#!/usr/bin/env python3
"""Repository checks that `claude plugin validate` does not do.

- SKILL.md / agent frontmatter: name format and length, description length.
- Every `${CLAUDE_PLUGIN_ROOT}/...` and `${CLAUDE_SKILL_DIR}/...` path named in
  Markdown exists in the repository.
- plugin.json version matches the newest CHANGELOG entry.
- Privacy: no public IPv4 addresses outside documentation ranges, and no email
  addresses other than the allowed ones. This repository is public.

Run: python3 tools/check_repo.py   (exit 1 on any problem)
"""
from __future__ import annotations

import ipaddress
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
RESERVED = ("claude", "anthropic")
PATH_RE = re.compile(r"\$\{(CLAUDE_PLUGIN_ROOT|CLAUDE_SKILL_DIR)\}/([A-Za-z0-9_./-]+)")
IPV4_RE = re.compile(r"(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(?![\w.])")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
ALLOWED_EMAILS = {"noreply@anthropic.com"}
# RFC 5737 documentation ranges plus addresses that appear in configs on purpose.
DOC_NETS = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
SKIP_DIRS = {".git", "node_modules", "tests/fixtures"}
TEXT_SUFFIXES = {".md", ".sh", ".py", ".json", ".yml", ".yaml", ".ini", ".conf", ".inc", ".rules", ".snippet", ".bats", ""}

problems: list[str] = []


def frontmatter(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        problems.append(f"{path}: no frontmatter")
        return {}
    end = text.find("\n---", 4)
    fields: dict[str, str] = {}
    for line in text[4:end].splitlines():
        m = re.match(r"^([A-Za-z_-]+):\s*(.*)$", line)
        if m:
            fields[m.group(1)] = m.group(2).strip().strip('"')
    return fields


def check_named(path: Path, kind: str) -> None:
    fm = frontmatter(path)
    name, desc = fm.get("name", ""), fm.get("description", "")
    if not NAME_RE.match(name) or len(name) > 64:
        problems.append(f"{path}: {kind} name {name!r} must be lowercase words joined by hyphens, max 64 chars")
    if any(name.startswith(r) for r in RESERVED):
        problems.append(f"{path}: {kind} name {name!r} uses a reserved word")
    if not desc:
        problems.append(f"{path}: {kind} has no description")
    elif len(desc) > 1024:
        problems.append(f"{path}: {kind} description is {len(desc)} chars (max 1024)")


def walk_text_files():
    for p in ROOT.rglob("*"):
        rel = p.relative_to(ROOT).as_posix()
        if not p.is_file() or any(rel == d or rel.startswith(d + "/") for d in SKIP_DIRS):
            continue
        if p.name == "LEARN-CLAUDE-SKILLS.md" or p.suffix not in TEXT_SUFFIXES:
            continue
        yield p, rel


def main() -> int:
    for skill in sorted((ROOT / "skills").glob("*/SKILL.md")):
        check_named(skill, "skill")
        if skill.parent.name != frontmatter(skill).get("name"):
            problems.append(f"{skill}: folder name and skill name differ")
    for agent in sorted((ROOT / "agents").glob("*.md")):
        check_named(agent, "agent")

    for p, rel in walk_text_files():
        text = p.read_text(encoding="utf-8", errors="replace")
        if p.suffix == ".md":
            skill_dir = None
            parts = rel.split("/")
            if parts[0] == "skills" and len(parts) > 2:
                skill_dir = ROOT / "skills" / parts[1]
            for var, sub in PATH_RE.findall(text):
                sub = sub.rstrip(".")
                base = ROOT if var == "CLAUDE_PLUGIN_ROOT" else skill_dir
                if base is None:
                    continue
                target = base / sub
                if "<" in sub or "*" in sub:
                    continue
                if not target.exists():
                    problems.append(f"{rel}: names ${{{var}}}/{sub}, which does not exist")
        for ip in IPV4_RE.findall(text):
            try:
                addr = ipaddress.ip_address(ip)
            except ValueError:
                continue
            if addr.is_global and not any(addr in n for n in DOC_NETS):
                problems.append(f"{rel}: public IPv4 address {ip} (use 203.0.113.x for examples)")
        for email in EMAIL_RE.findall(text):
            if email not in ALLOWED_EMAILS and not email.endswith((".invalid", "example.com", "example.org")):
                problems.append(f"{rel}: email address {email}")

    version = json.loads((ROOT / ".claude-plugin/plugin.json").read_text())["version"]
    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    m = re.search(r"^## \[?(\d+\.\d+\.\d+)", changelog, re.M)
    if not m or m.group(1) != version:
        problems.append(f"CHANGELOG.md newest entry ({m.group(1) if m else 'none'}) != plugin.json version {version}")

    for line in problems:
        print(f"FAIL  {line}")
    print(f"{'OK' if not problems else 'FAILED'}: {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
