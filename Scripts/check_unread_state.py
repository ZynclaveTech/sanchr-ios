#!/usr/bin/env python3
"""Finds state that is written and never read, and product methods whose only
callers are tests. See check-unread-state.sh for why."""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PRODUCT_DIRS = ["App", "Core", "Features", "Platform", "Shared", "SanchrShared"]
TEST_DIRS = ["Tests"]

# Framework and protocol entry points: called by UIKit, SwiftUI, Combine or a
# delegate rather than by name, so an absent caller proves nothing.
CALLED_BY_FRAMEWORK = re.compile(
    r"^(body|make\w*|update\w*|dismantle\w*|view\w*|scene\w*|application|"
    r"encode|decode|hash|init|deinit|callAsFunction|"
    r"collectionView|tableView|numberOfSections|prepare|draw|layout\w*|"
    r"traitCollection\w*|preferredContentSize\w*|accessibility\w*|"
    r"observeValue|photoLibraryDidChange|audioPlayer\w*|locationManager\w*|"
    r"peripheral\w*|central\w*|session|urlSession|userNotificationCenter)"
)

# Written-and-never-read is the point; these are read by the framework itself.
IGNORED_PROPERTIES = {"body", "id"}


def swift_files(dirs):
    for d in dirs:
        base = ROOT / d
        if not base.is_dir():
            continue
        for path in base.rglob("*.swift"):
            yield path


def strip_comments(text):
    out = []
    for line in text.split("\n"):
        stripped = line.strip()
        if stripped.startswith("//"):
            out.append("")
        else:
            out.append(re.sub(r"//.*$", "", line))
    return "\n".join(out)


def load(dirs):
    return {p: strip_comments(p.read_text(encoding="utf-8", errors="replace"))
            for p in swift_files(dirs)}


PROPERTY = re.compile(
    r"@(?:Published|State|AppStorage\([^)]*\))\s+(?:private\s+|fileprivate\s+)?"
    r"(?:private\(set\)\s+)?var\s+([A-Za-z_]\w*)"
)
FUNC = re.compile(r"^\s*(?:@\w+\s+)*(?:public\s+|internal\s+)?(?:static\s+|class\s+)?func\s+([A-Za-z_]\w*)\s*\(")


IDENTIFIER = re.compile(r"(?<![\w.])(\$?)([A-Za-z_]\w*)")
# `x = 1` writes; `x == 1`, `x != 1`, `x >= 1` read.
WRITE_SUFFIX = re.compile(r"^\s*(?:=(?!=)|\+=|-=|\*=|/=)")


def index_reads(sources):
    """name -> {(file, line)} for every occurrence that consumes the value.

    One pass over the tree rather than one pass per property, which took half a
    minute and is no use in a build phase.

    Classified per occurrence, not per line: `withAnimation { flag = true }` is
    a write even though the line does not begin with the name, and judging the
    line as a whole counted it as a read — which let exactly the bug this check
    exists for slip past.
    """
    reads = {}
    for path, text in sources.items():
        for line_no, line in enumerate(text.split("\n"), 1):
            for m in IDENTIFIER.finditer(line):
                sigil, name = m.group(1), m.group(2)
                # A `$` prefix hands the binding to someone else, which is a
                # read however the value is used later.
                if sigil != "$" and WRITE_SUFFIX.match(line[m.end():]):
                    continue
                reads.setdefault(name, set()).add((path, line_no))
    return reads


def unread_properties(product):
    reads = index_reads(product)
    problems = []
    for path, text in product.items():
        for match in PROPERTY.finditer(text):
            name = match.group(1)
            if name in IGNORED_PROPERTIES:
                continue
            decl_line = text[: match.start()].count("\n") + 1
            # The declaration mentions the name and is not a read of it.
            if not (reads.get(name, set()) - {(path, decl_line)}):
                problems.append(
                    (path, decl_line, f"'{name}' is written but never read")
                )
    return problems


CALL = re.compile(r"(?<![\w])([A-Za-z_]\w*)\s*\(")


def called_names(sources, skip_declarations=True):
    """Every identifier that appears as a call, gathered in one pass."""
    names = {}
    for path, text in sources.items():
        for i, line in enumerate(text.split("\n"), 1):
            declares = FUNC.match(line)
            for m in CALL.finditer(line):
                name = m.group(1)
                # A declaration is not a call of itself.
                if skip_declarations and declares and declares.group(1) == name:
                    continue
                names.setdefault(name, set()).add((path, i))
    return names


PROTOCOL = re.compile(r"^\s*(?:public |internal |private |fileprivate )?protocol \s*\w+")


def protocol_requirements(sources):
    """Names declared inside a `protocol` body.

    A protocol requirement is called through the protocol, so its
    implementations have no direct caller and look exactly like dead code from
    here. That was 49 of the 58 findings the first audit produced — enough
    noise to bury the one real bug in it, which was that call duration padding
    is built, tested and never invoked.
    """
    names = set()
    for _, text in sources.items():
        depth = None
        for line in text.split("\n"):
            if PROTOCOL.match(line):
                depth = 0
                continue
            if depth is None:
                continue
            depth += line.count("{") - line.count("}")
            m = re.match(r"\s*(?:static\s+)?func (\w+)\s*\(", line)
            if m:
                names.add(m.group(1))
            if depth <= 0 and "}" in line:
                depth = None
    return names


def test_only_functions(product, tests):
    in_product = called_names(product)
    in_tests = called_names(tests, skip_declarations=False)
    conformances = protocol_requirements(product)

    problems = []
    for path, text in product.items():
        for i, line in enumerate(text.split("\n"), 1):
            m = FUNC.match(line)
            if not m:
                continue
            name = m.group(1)
            if CALLED_BY_FRAMEWORK.match(name):
                continue
            if "private" in line or "override" in line:
                continue
            if in_product.get(name):
                continue
            if name in conformances:
                continue
            if name in in_tests:
                problems.append(
                    (path, i, f"'{name}' is called only from tests")
                )
    return problems


BASELINE = ROOT / "Scripts" / "unread-state-baseline.txt"


def load_baseline():
    if not BASELINE.exists():
        return set()
    entries = set()
    for line in BASELINE.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            entries.add(line)
    return entries


def main():
    product = load(PRODUCT_DIRS)
    tests = load(TEST_DIRS)

    # The property check is precise and quick, so it gates the build.
    #
    # The function check is neither. It is genuinely useful — it is what would
    # have caught `applyLockedStop` and `didConfirmRecentSelection`, each of
    # which had a passing test and no caller — but a protocol requirement whose
    # only direct call is through the protocol looks identical to dead code
    # from here, and it reports around seventy candidates that each need a
    # judgement. It runs under --audit instead, where a person is reading.
    problems = unread_properties(product)
    if "--audit" in sys.argv:
        problems += test_only_functions(product, tests)
    problems.sort(key=lambda p: (str(p[0]), p[1]))

    if "--write-baseline" in sys.argv:
        header = BASELINE.read_text().split("\n\n", 1)[0] if BASELINE.exists() else ""
        lines = [f"{p[0].relative_to(ROOT)}: {p[2]}" for p in problems]
        BASELINE.write_text(header + "\n\n" + "\n".join(lines) + "\n")
        print(f"Wrote {len(lines)} entries to {BASELINE.relative_to(ROOT)}")
        return 0

    baseline = load_baseline()
    # Keyed by file and message, not line number, so the entry survives edits
    # above it. A file that legitimately changes will re-report, which is the
    # moment to fix it rather than move the line.
    def key(path, message):
        return f"{path.relative_to(ROOT)}: {message}"

    fresh = [p for p in problems if key(p[0], p[2]) not in baseline]

    for path, line, message in fresh:
        print(f"{ROOT}/{path.relative_to(ROOT)}:{line}: error: {message}")

    if fresh:
        print(f"\n{len(fresh)} new unread-state problem(s). Each of these reads "
              "as working code and does nothing at runtime.")
        print("If one is a false positive, add its line to "
              "Scripts/unread-state-baseline.txt with a reason.")
        return 1

    stale = baseline - {key(p[0], p[2]) for p in problems}
    if stale:
        print("Scripts/unread-state-baseline.txt: warning: "
              f"{len(stale)} baselined entr(y/ies) no longer occur — delete them:")
        for entry in sorted(stale):
            print(f"  {entry}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
