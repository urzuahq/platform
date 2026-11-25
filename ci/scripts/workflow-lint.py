#!/usr/bin/env python3
"""Check a repository's GitHub workflow files against the org CI standard (RFC-1).

usage: python3 -I workflow-lint.py [--ci-workflow PATH] [--default-branch NAME]
                                   [--workflows-dir DIR] [FILE ...]

The ci workflow gets the R1 and R2 rules; every workflow file gets the R4 and
R5 rules. FILE arguments replace the glob of DIR/*.yml and DIR/*.yaml, and the
ci workflow is always checked. Every finding is printed, as a GitHub annotation
and as a plain line.

exit: 0 clean; 1 findings; 2 bad invocation, unreadable file or invalid YAML.
"""
import argparse
import glob
import re
import sys

import yaml

PR_TYPES = {"opened", "synchronize", "reopened", "labeled", "unlabeled"}
FILTER_KEYS = ("branches", "branches-ignore", "paths", "paths-ignore")
SAFE_REFS = {
    "github.repository", "github.sha", "github.run_id", "github.workspace",
    "runner.temp", "runner.os", "runner.arch",
}
CONCURRENCY_GROUP = "ci-${{ github.workflow }}-${{ github.ref }}"
CONCURRENCY_CANCEL = (
    "${{ github.event_name == 'pull_request' && github.event.action == 'synchronize' }}"
)
EXPR = re.compile(r"\$\{\{(.*?)\}\}", re.S)
SHA_PIN = re.compile(r"^[^@\s]+@[0-9a-f]{40}$")
DIGEST_PIN = re.compile(r"^docker://\S+@sha256:[0-9a-f]{64}$")


def norm(text):
    return EXPR.sub(lambda m: "${{ " + " ".join(m.group(1).split()) + " }}", text.strip())


def line_of(node):
    return node.start_mark.line + 1


def scalar(node):
    return node.value if isinstance(node, yaml.ScalarNode) else None


def get(node, key):
    """The (key node, value node) for key in a mapping node, or (None, None)."""
    if isinstance(node, yaml.MappingNode):
        for k, v in node.value:
            if scalar(k) == key:
                return k, v
    return None, None


def items(node):
    if isinstance(node, yaml.MappingNode):
        return [(scalar(k), k, v) for k, v in node.value]
    return []


def str_list(node):
    if isinstance(node, yaml.SequenceNode):
        vals = [scalar(n) for n in node.value]
        return None if None in vals else vals
    return None


class Linter:
    def __init__(self, path, lines, root):
        self.path, self.lines, self.root = path, lines, root
        self.findings = []

    def add(self, line, rule, msg):
        self.findings.append((self.path, line, rule, msg))

    def events(self):
        """The `on:` triggers as {name: value node or None}, and the node to cite."""
        k, v = get(self.root, "on")
        if k is None:
            return {}, self.root
        if isinstance(v, yaml.ScalarNode):
            return {v.value: None}, k
        if isinstance(v, yaml.SequenceNode):
            return {scalar(n): None for n in v.value}, k
        return {name: val for name, _, val in items(v)}, k

    def lint_ci(self, default_branch):
        events, on_key = self.events()
        at = line_of(on_key) if on_key is not self.root else 1

        pr = events.get("pull_request")
        _, types = get(pr, "types")
        got = str_list(types)
        if "pull_request" not in events or got is None or set(got) != PR_TYPES:
            self.add(line_of(types) if types is not None else at, "R2.pull-request-types",
                     "on.pull_request.types must be exactly " + ", ".join(sorted(PR_TYPES)))

        if "merge_group" not in events:
            self.add(at, "R2.merge-group", "merge_group must be a trigger")

        push = events.get("push")
        _, branches = get(push, "branches")
        if str_list(branches) != [default_branch]:
            self.add(line_of(branches) if branches is not None else at, "R2.push-branches",
                     f"on.push.branches must be exactly [{default_branch}]")

        if "workflow_dispatch" in events:
            self.add(at, "R2.no-dispatch", "workflow_dispatch must not be a trigger")

        for name, banned in (("pull_request", FILTER_KEYS), ("merge_group", FILTER_KEYS),
                             ("push", ("paths", "paths-ignore"))):
            for key in banned:
                k, _ = get(events.get(name), key)
                if k is not None:
                    self.add(line_of(k), "R2.no-filter", f"{name} must not filter on {key}")

        self.lint_concurrency()
        self.lint_gate()

    def lint_concurrency(self):
        k, conc = get(self.root, "concurrency")
        if k is None:
            self.add(1, "R2.concurrency", "workflow-level concurrency is required")
            return
        _, group = get(conc, "group")
        _, cancel = get(conc, "cancel-in-progress")
        if scalar(group) is None or norm(scalar(group)) != CONCURRENCY_GROUP:
            self.add(line_of(group or k), "R2.concurrency",
                     f"concurrency.group must be {CONCURRENCY_GROUP}")
        if scalar(cancel) is None or norm(scalar(cancel)) != CONCURRENCY_CANCEL:
            self.add(line_of(cancel or k), "R2.concurrency",
                     f"concurrency.cancel-in-progress must be {CONCURRENCY_CANCEL}")

    def lint_gate(self):
        jk, jobs = get(self.root, "jobs")
        ids = [name for name, _, _ in items(jobs)]
        _, gate = get(jobs, "ci")
        if gate is None:
            self.add(line_of(jk) if jk is not None else 1, "R1.gate-job",
                     "a job with id ci must exist")
            return
        k, cond = get(gate, "if")
        if scalar(cond) is None or norm(scalar(cond)) not in ("always()", "${{ always() }}"):
            self.add(line_of(cond or k or gate), "R1.gate-job", "the ci job must have if: always()")
        k, needs = get(gate, "needs")
        listed = [scalar(needs)] if isinstance(needs, yaml.ScalarNode) else str_list(needs) or []
        missing = [i for i in ids if i != "ci" and i not in listed]
        if missing:
            self.add(line_of(needs or gate), "R1.gate-job",
                     "the ci job must need every other job; missing " + ", ".join(missing))

    def lint_all(self):
        k, perms = get(self.root, "permissions")
        if k is None:
            self.add(1, "R4.permissions", "top-level permissions is required")
        elif not self.read_only(perms):
            self.add(line_of(perms), "R4.permissions", "top-level permissions must not grant write")

        _, jobs = get(self.root, "jobs")
        for job_id, _, job in items(jobs):
            self.lint_job(job_id, job)

    @staticmethod
    def read_only(perms):
        if isinstance(perms, yaml.ScalarNode):
            return perms.value == "read-all"
        if isinstance(perms, yaml.MappingNode):
            return all(scalar(v) in ("read", "none") for _, _, v in items(perms))
        return False

    def lint_job(self, job_id, job):
        _, uses = get(job, "uses")
        _, steps = get(job, "steps")
        if uses is not None:
            self.check_pin(uses)
        elif steps is not None and get(job, "timeout-minutes")[0] is None:
            self.add(line_of(job), "R4.timeout", f"job {job_id} needs timeout-minutes")

        sk, secrets = get(job, "secrets")
        if scalar(secrets) == "inherit":
            self.add(line_of(secrets), "R4.secrets-inherit",
                     f"job {job_id} must pass secrets by name, not inherit")

        _, jperms = get(job, "permissions")
        pushes = scalar(jperms) == "write-all" or any(
            n == "contents" and scalar(v) == "write" for n, _, v in items(jperms))
        for step in steps.value if isinstance(steps, yaml.SequenceNode) else []:
            _, suses = get(step, "uses")
            if suses is not None:
                self.check_pin(suses)
                if re.match(r"actions/checkout(@|$)", suses.value or ""):
                    self.check_checkout(step, suses, pushes)
            _, run = get(step, "run")
            if isinstance(run, yaml.ScalarNode):
                self.check_run(run)

    def check_checkout(self, step, uses, pushes):
        _, with_ = get(step, "with")
        _, persist = get(with_, "persist-credentials")
        if pushes or get(with_, "token")[0] is not None:
            return
        if scalar(persist) != "false":
            self.add(line_of(uses), "R4.persist-credentials",
                     "actions/checkout must set persist-credentials: false")

    def check_run(self, run):
        base = run.start_mark.line + (1 if run.style in ("|", ">") else 0)
        for m in EXPR.finditer(run.value):
            expr = re.sub(r"'(?:[^']|'')*'", "", m.group(1))
            refs = [r for r in re.findall(r"[A-Za-z_][\w-]*(?:\.[\w*-]+)*(?!\w|\.|\()", expr)
                    if r not in ("true", "false", "null")]
            if all(r in SAFE_REFS for r in refs):
                continue
            line = base + run.value.count("\n", 0, m.start()) + 1
            self.add(line, "R4.expression-in-run",
                     f"pass {norm(m.group(0))} through env:, not inline in run")

    def check_pin(self, node):
        ref = node.value or ""
        if ref.startswith("./"):
            return
        if ref.startswith("docker://"):
            if not DIGEST_PIN.match(ref):
                self.add(line_of(node), "R5.pin", f"{ref} needs an @sha256: digest")
            return
        if not SHA_PIN.match(ref):
            self.add(line_of(node), "R5.pin", f"{ref} must be pinned to a 40-hex commit SHA")
            return
        line = self.lines[node.start_mark.line] if node.start_mark.line < len(self.lines) else ""
        rest = line[node.end_mark.column:] if node.end_mark.line == node.start_mark.line else ""
        if not re.match(r"['\"]?\s+#\s*\S", rest):
            self.add(line_of(node), "R5.pin", f"{ref} needs a trailing # <version> comment")


def esc(text, prop=False):
    text = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return text.replace(":", "%3A").replace(",", "%2C") if prop else text


def load(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    root = yaml.compose(text, Loader=yaml.SafeLoader)
    if not isinstance(root, yaml.MappingNode):
        raise ValueError("top level is not a mapping")
    return text.split("\n"), root


def main():
    ap = argparse.ArgumentParser(prog="workflow-lint", allow_abbrev=False)
    ap.add_argument("--ci-workflow", default=".github/workflows/ci.yml")
    ap.add_argument("--default-branch", default="main")
    ap.add_argument("--workflows-dir", default=".github/workflows")
    ap.add_argument("files", nargs="*")
    try:
        args = ap.parse_args()
    except SystemExit as e:
        return 2 if e.code else 0

    files = args.files or sorted(
        glob.glob(args.workflows_dir + "/*.yml") + glob.glob(args.workflows_dir + "/*.yaml"))
    if args.ci_workflow not in files:
        files.append(args.ci_workflow)

    findings, broken = [], False
    for path in files:
        try:
            lines, root = load(path)
        except (OSError, UnicodeDecodeError, yaml.YAMLError, ValueError) as e:
            print(f"workflow-lint: {path}: {' '.join(str(e).split())}", file=sys.stderr)
            broken = True
            continue
        linter = Linter(path, lines, root)
        if path == args.ci_workflow:
            linter.lint_ci(args.default_branch)
        linter.lint_all()
        findings += sorted(linter.findings, key=lambda f: f[1])

    for path, line, rule, msg in findings:
        print(f"::error file={esc(path, True)},line={line}::{esc(rule)}: {esc(msg)}")
        print(f"{path}:{line}: {rule}: {msg}")
    if broken:
        return 2
    if findings:
        print(f"workflow-lint: {len(findings)} finding(s)", file=sys.stderr)
        return 1
    print(f"workflow-lint: {len(files)} workflow file(s) clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
