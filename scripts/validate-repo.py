#!/usr/bin/env python3
"""Repo-wide consistency checks.

    python scripts/validate-repo.py

Three checks:
  1. every .yaml/.yml parses, and every document has a `kind`
  2. every relative markdown link resolves to a file that exists
  3. every .sh file passes a shell syntax check (needs bash or sh on PATH)

Deliberate exclusions are listed in SKIP_DIRS / NOT_MANIFESTS below, each with
the reason. Anything excluded silently would defeat the point of the checks.
"""
import os
import re
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required:  pip install pyyaml")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Directories that are not ours to validate.
SKIP_DIRS = (
    ".git",
    "app/devboard",      # somebody else's repository, fetched by app/get-devboard.sh
    ".transcript",       # the indexed course transcript, gitignored
)

# YAML files that are deliberately NOT Kubernetes manifests.
NOT_MANIFESTS = (
    "/patches/",                      # strategic-merge patches have no kind, by design
    "cka/28-helm/solution/mychart/templates/",   # Helm templates: Go templating, not YAML
    "cka/28-helm/solution/mychart/Chart.yaml",   # chart metadata
    "cka/28-helm/solution/mychart/values.yaml",  # chart values
    "cka/28-helm/solution/values-",              # per-environment values files
)


def norm(p):
    return p.replace("\\", "/")


def skipped(path):
    p = norm(path)
    return any(s in p for s in SKIP_DIRS)


def is_manifest(path):
    p = norm(path)
    return not any(s in p for s in NOT_MANIFESTS)


def walk(exts):
    for dirpath, dirnames, filenames in os.walk(ROOT):
        if skipped(dirpath):
            dirnames[:] = []
            continue
        for name in filenames:
            if name.endswith(exts):
                full = os.path.join(dirpath, name)
                if not skipped(full):
                    yield full


def rel(path):
    return norm(os.path.relpath(path, ROOT))


def check_yaml():
    checked = skipped_count = 0
    problems = []
    for path in walk((".yaml", ".yml")):
        if not is_manifest(path):
            skipped_count += 1
            continue
        checked += 1
        try:
            with open(path, encoding="utf-8") as fh:
                for doc in yaml.safe_load_all(fh):
                    if isinstance(doc, dict) and "kind" not in doc:
                        problems.append((rel(path), "document has no `kind`"))
                        break
        except Exception as exc:  # noqa: BLE001 - we want the message, whatever it is
            problems.append((rel(path), str(exc).splitlines()[0][:100]))
    print(f"YAML   {checked} manifests checked, {skipped_count} non-manifests skipped, "
          f"{len(problems)} problems")
    return problems


def check_links():
    checked = 0
    problems = []
    pattern = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
    for path in walk((".md",)):
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        for match in pattern.finditer(text):
            target = match.group(1).split("#")[0].strip()
            if not target or target.startswith(("http://", "https://", "mailto:")):
                continue
            checked += 1
            resolved = os.path.normpath(os.path.join(os.path.dirname(path), target))
            if not os.path.exists(resolved):
                problems.append((rel(path), target))
    print(f"LINKS  {checked} relative links checked, {len(problems)} broken")
    return problems


def check_shell():
    checked = 0
    problems = []
    shell = "bash" if _has("bash") else ("sh" if _has("sh") else None)
    if shell is None:
        print("SHELL  skipped -- no bash or sh on PATH")
        return problems
    for path in walk((".sh",)):
        checked += 1
        # Pass a repo-relative POSIX path and run from ROOT: on Windows, Git Bash
        # mangles backslashes in an absolute path into an unusable string.
        result = subprocess.run([shell, "-n", rel(path)], cwd=ROOT,
                                capture_output=True, text=True)
        if result.returncode != 0:
            problems.append((rel(path), result.stderr.strip().splitlines()[-1][:100]))
    print(f"SHELL  {checked} scripts checked with `{shell} -n`, {len(problems)} problems")
    return problems


def _has(cmd):
    from shutil import which
    return which(cmd) is not None


def main():
    print(f"validating {ROOT}\n")
    problems = check_yaml() + check_links() + check_shell()
    if problems:
        print("\nproblems:")
        for where, what in problems:
            print(f"  {where}: {what}")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
