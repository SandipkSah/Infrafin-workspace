#!/usr/bin/env python3
"""
For a service directory (e.g. /srv/docker/<service>/), produce git-trackable,
secret-redacted copies of every top-level file (NOT recursing into
subdirectories like certs/, data/, pki/ -- only files that sit directly
alongside docker-compose.yaml).

The compose file gets two things layered together:
  1. Structural extraction: hardcoded `environment:` values get moved out to
     .env, replaced in the compose file with ${VAR} references (same logic as
     the old extract_compose_env.py, now folded in here).
  2. The same generic scan-and-redact pass every other file gets, run over the
     result of step 1 -- this catches secrets OUTSIDE `environment:` blocks
     (e.g. a token sitting in `command:` args or `labels:`), which step 1
     alone would silently miss since it only ever looks inside `environment:`.

Every other file just gets step 2: a generic, format-agnostic redaction pass.
Rather than parsing each format (XML, .conf, TOML, JSON, YAML, shell, ...), it
runs the same value-based scanners (gitleaks + trufflehog) directly against
each file's raw text, plus a key-name regex fallback for low-entropy secrets
those scanners miss, then blanks out just the matched secret substrings.

Safety model:
  - READ-ONLY against the service directory. Never writes, moves, or modifies
    any file there.
  - All output goes under --out-dir (default: ~/srv_version_control/env-variables),
    in a subfolder named after the service directory. Nothing is ever written
    back into the source tree.
  - Only ever prints file/variable NAMES and redaction COUNTS to stdout --
    never the redacted values themselves, so this script's output is safe to
    paste into chat/logs/tickets.
  - If .env/.env.example exist but aren't readable (e.g. a tightly-locked-down
    production .env), the compose-file's structural extraction step (1) is
    skipped for that service -- proceeding as if it were empty could produce
    a .env.additions that duplicates or conflicts with real, unreadable
    secrets. This does NOT block sanitizing the rest of the service's files
    (step 2 needs no access to .env at all), so e.g. redis.conf still gets
    sanitized even when .env is root-only.
  - Certs/keys/binaries/archives/logs/already-handled files (.env*, this
    script's own .sanitized/.additions outputs) are skipped, not processed --
    see SKIP_EXTENSIONS / SKIP_NAMES / is_env_like below.

Usage:
  python3 sanitize_service_files.py <service_dir> [--compose-file NAME] [--out-dir DIR] [--write]

  (no flags)   report only: lists candidate files, redaction counts, and (for
               the compose file) which vars would move to .env -- names only.
  --write      also write, under <out-dir>/<service-name>/:
                 docker-compose.yaml.sanitized  - compose file: ${VAR}-substituted
                                                   AND generically redacted -- only
                                                   written if there was actually
                                                   something to extract/redact
                 <filename>.sanitized            - every other candidate file that
                                                   actually had something redacted
                                                   (a clean file gets NO .sanitized
                                                   copy at all -- the real file is
                                                   already safe to track as itself)
                 .env.additions                  - KEY=value lines (real values,
                                                   stays local, never printed)
                 .env.example.additions          - KEY= lines (secrets blanked,
                                                   config vars kept as real values)
                 .gitignore                      - a per-directory .gitignore (bare
                                                   filenames) listing every real file
                                                   that DID get a .sanitized twin --
                                                   review and copy to
                                                   /srv/docker/<service>/.gitignore so
                                                   only the real, secret-bearing files
                                                   stay untracked there; everything
                                                   else in the service is trackable
                                                   as-is by default. Host-specific by
                                                   construction: never merge this
                                                   across hosts, even for a
                                                   same-named service directory -- its
                                                   content can legitimately differ.

Everything written stays under --out-dir. Applying it to the real service
directory (as root, once you've reviewed it) is a separate manual step, e.g.:
  diff /srv/docker/<svc>/docker-compose.yaml ~/srv_version_control/env-variables/<svc>/docker-compose.yaml.sanitized
  cat ~/srv_version_control/env-variables/<svc>/.env.additions            # review, then append to /srv/docker/<svc>/.env
  cat ~/srv_version_control/env-variables/<svc>/.env.example.additions     # review, then append to /srv/docker/<svc>/.env.example
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------------------
# Generic per-file scanning (used for every candidate file, compose included)
# ---------------------------------------------------------------------------

# Cert/key/binary/archive/log material: either public-and-harmless (no need to
# sanitize) or private-and-total (no partial "sanitized" version makes sense).
# Running entropy-based scanners on base64 cert/key bodies would also produce
# garbage false-positive redactions.
SKIP_EXTENSIONS = {
    '.crt', '.csr', '.ext', '.srl', '.key', '.pem', '.pfx', '.p12', '.der',
    '.log', '.rdb', '.tar', '.gz', '.tgz', '.zip', '.bz2', '.7z',
    '.png', '.jpg', '.jpeg', '.gif', '.ico', '.svg',
    '.db', '.sqlite', '.sqlite3',
}
SKIP_NAMES = {'htpasswd', 'users.acl', '.gitignore', '.gitattributes'}
SKIP_SUFFIXES = ('.sanitized', '.additions', '.orig', '.bak')


def is_env_like(filename):
    """.env, .env.example, .env_chproxy, .env.save, etc -- handled by the
    dedicated .env/.env.example flow already, not by generic sanitization."""
    return filename == '.env' or filename.startswith('.env.') or filename.startswith('.env_')


def should_skip(filename):
    if filename in SKIP_NAMES:
        return True
    if filename.endswith(SKIP_SUFFIXES):
        return True
    if is_env_like(filename):
        return True
    _, ext = os.path.splitext(filename)
    if ext.lower() in SKIP_EXTENSIONS:
        return True
    return False


def list_candidate_files(service_dir):
    candidates = []
    for entry in sorted(os.scandir(service_dir), key=lambda e: e.name):
        if not entry.is_file(follow_symlinks=False):
            continue
        if should_skip(entry.name):
            continue
        candidates.append(entry.name)
    return candidates


def read_text_or_none(path):
    """Returns the file's lines if it decodes as UTF-8 text, else None (binary)."""
    try:
        with open(path, encoding='utf-8') as f:
            return f.readlines()
    except (UnicodeDecodeError, ValueError):
        return None


# Generic key-name-based fallback, broadened to match value-assignment shapes
# across formats: "KEY=value", "KEY: value", "KEY = \"value\"", the XML-tag
# shape "<key>value</key>", and whitespace-separated directive syntax used by
# .conf files with no operator at all (e.g. redis.conf's "requirepass
# hunter2"). Catches low-entropy secrets (a weak/dictionary password) that
# gitleaks/trufflehog's entropy-based rules can miss.
#
# NOTE: this alternation MUST stay a non-capturing group (?:...) -- as a plain
# capturing group it silently shifts every later group index in the regexes
# below, which previously caused the XML pattern to redact the tag NAME
# ("password") instead of its VALUE ("changeit"), leaving the actual secret
# exposed in plaintext. Also note the closing-quote check below is `\1`
# (backreference to the quote group) -- using `\2` there (an earlier bug)
# backreferences the VALUE group instead, which can never match again right
# after itself, silently breaking every quoted match. Both caught by testing
# against synthetic files before this tool was ever pointed at real ones.
#
# Deliberately NOT included: a bare "PASS" or "AUTH" substring. Those seem
# tempting (they'd catch redis's "requirepass") but collide with ordinary,
# unrelated names -- e.g. a test-counter variable "PASS=0; FAIL=0" got
# falsely redacted into "PASS=REDACTED" during testing. REQUIREPASS/MASTERAUTH
# are specific enough to catch the real directives without that collision.
_SECRET_KEYWORD = r'(?:PASSWORD|PASSWD|PWD|REQUIREPASS|MASTERAUTH|SECRET|TOKEN|API[_-]?KEY|PRIVATE[_-]?KEY|CREDENTIAL|ACCESS[_-]?KEY|CLIENT[_-]?SECRET|PASSPHRASE|SIGNING)'
_ASSIGNMENT_RE = re.compile(
    rf'(?i){_SECRET_KEYWORD}\w*\s*[:=]\s*(["\']?)([^"\'<>\s]+)\1'
)
_SPACE_ASSIGNMENT_RE = re.compile(
    rf'(?i)^\s*\S*{_SECRET_KEYWORD}\S*\s+(["\']?)([^"\'<>\s]+)\1\s*$'
)
_XML_TAG_RE = re.compile(
    rf'(?i)<({_SECRET_KEYWORD}\w*)>([^<]+)</\1>'
)
# Quoted bare key, e.g. Ruby hash-rocket `'password' => 'value'` or
# `'password' = 'value'`, and JSON-style `"secret_key": "value"`. Distinct
# from _ASSIGNMENT_RE: the closing quote right after the keyword (before any
# operator) breaks that pattern's `{keyword}\w*\s*[:=]` requirement --
# `\w*` can't cross the quote character, so `\s*[:=]` never gets a chance to
# match. This was relied on detect-secrets alone to catch (its KeywordDetector
# isn't anchored to "operator immediately after key"), but detect-secrets
# caught this shape inside one service's isolated block-scalar content and
# silently missed the identical shape in another's -- found by testing
# against gitlab-registry-2's docker-compose.new.yaml, where a
# `registry['database']` block's `'password' => 'value'` line survived
# regeneration untouched after `gitlab_rails['secret_key_base']`-style values
# elsewhere in the same file class had already been fixed. A deterministic
# regex for this exact shape doesn't depend on an external tool's per-run
# heuristics.
_QUOTED_KEY_ASSIGNMENT_RE = re.compile(
    rf'(?i)[\'"]{_SECRET_KEYWORD}\w*[\'"]\s*(?:=>|[:=])\s*(["\'])([^"\'<>\s]+)\1'
)

# Bash/ERB-style variable expansion, e.g. ${SMTP_PASSWORD:-}, ${VAR:-default},
# $SOME_VAR. The ":" in "${NAME:-default}" syntax is structurally identical
# to a "key: value" separator, and the NAME portion can legitimately contain
# any of our tracked keywords (a var called SMTP_PASSWORD is completely
# normal) -- so "${SMTP_PASSWORD:-}" was matching as if "PASSWORD" were a key
# and "-}" its value, corrupting an already-safe parameterized value into
# "${SMTP_PASSWORD:REDACTED". Masked out (replaced with equal-length spaces)
# before any keyword regex runs, so nothing inside a variable reference can
# ever be mistaken for an assignment -- found by testing against a real
# GitLab omnibus config value, not guessed.
_DOLLAR_EXPR_RE = re.compile(r'\$\{[^}]*\}|\$\w+')


def _mask_dollar_expressions(line):
    return _DOLLAR_EXPR_RE.sub(lambda m: ' ' * len(m.group(0)), line)


def _is_placeholder(val):
    """
    True for a value that's already safe and should never be (re-)flagged:
    an externalized ${VAR}/$VAR reference, or our own REDACTED placeholder.
    Without the REDACTED check, a line already sanitized into
    `token = "REDACTED"` still structurally looks like `keyword = value` to
    these same patterns -- every .sanitized file would re-trigger itself
    forever, both here and in the pre-commit hook that shares this logic.
    """
    return val.startswith('$') or val == 'REDACTED'


def keyword_matches_in_line(line):
    """Returns the set of secret-looking substrings found in one line via the
    generic keyword-assignment / space-directive / XML-tag patterns
    (value-only, never the key/tag name itself). Skips anything that's already
    a ${VAR} / $VAR reference -- that's an externalized variable, not a literal
    secret, and blindly redacting it would clobber the very substitution the
    compose extraction step just made (e.g. turning "${PGPASSWORD_SUPERUSER}"
    back into "REDACTED", destroying the reference) -- and skips our own
    REDACTED placeholder, see _is_placeholder. Matches against a
    dollar-expression-masked copy of the line (see _mask_dollar_expressions)
    so a keyword appearing inside a ${VAR:-default}-style reference can never
    be mistaken for a "key: value" assignment in the first place."""
    masked = _mask_dollar_expressions(line)
    found = set()
    for m in _ASSIGNMENT_RE.finditer(masked):
        val = m.group(2)
        if val and not _is_placeholder(val):
            found.add(val)
    for m in _SPACE_ASSIGNMENT_RE.finditer(masked):
        val = m.group(2)
        if val and not _is_placeholder(val):
            found.add(val)
    for m in _XML_TAG_RE.finditer(masked):
        val = m.group(2).strip()
        if val and not _is_placeholder(val):
            found.add(val)
    for m in _QUOTED_KEY_ASSIGNMENT_RE.finditer(masked):
        val = m.group(2)
        if val and not _is_placeholder(val):
            found.add(val)
    return found


def expand_to_full_token(line, secret):
    """
    A scanner (gitleaks/trufflehog) match can land on a truncated fragment of
    the real value (a detector's rule may assume a fixed token length/shape
    that doesn't exactly match what's actually in the file). Redacting only
    the exact reported span can leave the untouched remainder of the real
    secret sitting in plain text right next to the redaction. To guard against
    that, expand the match outward: if it sits inside a quoted string, take
    the whole quoted content; otherwise take the whole contiguous
    non-whitespace/non-quote run it's part of.
    """
    idx = line.find(secret)
    if idx == -1:
        return secret
    start, end = idx, idx + len(secret)

    if start > 0 and line[start - 1] in ('"', "'"):
        quote = line[start - 1]
        close = line.find(quote, end)
        if close != -1:
            return line[start:close]

    while start > 0 and not line[start - 1].isspace() and line[start - 1] not in '"\'<>':
        start -= 1
    while end < len(line) and not line[end].isspace() and line[end] not in '"\'<>':
        end += 1
    return line[start:end]


def gitleaks_matches_by_line(path):
    """
    Runs gitleaks against a single file, WITHOUT --redact (this tool needs the
    actual matched secret text to redact it -- --redact would hide it from us
    too). The report is written to a throwaway temp dir and deleted
    immediately after reading; nothing from it is ever printed.
    Returns {line_number: set(secret_substrings)}.
    """
    gitleaks_bin = shutil.which('gitleaks')
    if not gitleaks_bin:
        return None  # signals "scanner unavailable", distinct from "no findings"

    by_line = {}
    with tempfile.TemporaryDirectory() as tmpdir:
        report_path = os.path.join(tmpdir, 'report.json')
        result = subprocess.run(
            [gitleaks_bin, 'detect', '--no-git', '--source', path,
             '--report-format', 'json', '--report-path', report_path,
             '--exit-code', '0', '--no-banner'],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"  WARNING: gitleaks exited {result.returncode} unexpectedly on {path} "
                  f"-- skipping that signal for this file", file=sys.stderr)
            return {}
        if os.path.isfile(report_path) and os.path.getsize(report_path) > 0:
            with open(report_path) as f:
                findings = json.load(f)
            for finding in findings:
                line = finding.get('StartLine')
                secret = finding.get('Secret') or finding.get('Match')
                if line and secret:
                    by_line.setdefault(line, set()).add(secret)
    return by_line


def trufflehog_matches_by_line(path):
    """
    Runs trufflehog against a single file. --no-verification is mandatory (no
    live API calls, ever). No redact option exists for trufflehog, so the
    "Raw" field (plaintext secret) is read here and used only to build the
    redacted copy -- never printed. Returns {line_number: set(secret_substrings)}.
    """
    trufflehog_bin = shutil.which('trufflehog')
    if not trufflehog_bin:
        return None

    by_line = {}
    result = subprocess.run(
        [trufflehog_bin, 'filesystem', path, '--json', '--no-verification', '--no-update',
         '--results=verified,unverified,unknown,filtered_unverified'],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"  WARNING: trufflehog exited {result.returncode} unexpectedly on {path} "
              f"-- skipping that signal for this file", file=sys.stderr)
        return {}
    for line_text in result.stdout.splitlines():
        line_text = line_text.strip()
        if not line_text:
            continue
        try:
            finding = json.loads(line_text)
        except json.JSONDecodeError:
            continue
        line = finding.get('SourceMetadata', {}).get('Data', {}).get('Filesystem', {}).get('line')
        secret = finding.get('Raw')
        if line and secret:
            by_line.setdefault(line, set()).add(secret)
    return by_line


def detect_secrets_flagged_lines(path):
    """
    Runs detect-secrets against a single file. Unlike gitleaks/trufflehog,
    detect-secrets deliberately never reveals the matched secret text -- only
    a one-way hash of it -- so this returns just the set of flagged line
    numbers, not substrings. That's still enough to redact from (see
    redact_unknown_span), and it's what makes detect-secrets worth having as
    a fourth signal: it independently catches things the other three miss
    (e.g. Ruby-hash-style `key['name'] = 'value'` assignments, which don't
    match our "operator immediately after the key" regex, and credentials
    embedded inside a URL via BasicAuthDetector).

    Quirk (undocumented, found by testing): an ABSOLUTE --source/scan path
    silently returns zero results even with --all-files. Only a path
    relative to the current directory works, so this cd's into the file's
    directory and scans by basename.
    """
    ds_bin = shutil.which('detect-secrets')
    if not ds_bin:
        return None

    directory, filename = os.path.split(path)
    result = subprocess.run(
        [ds_bin, 'scan', '--all-files', filename],
        capture_output=True, text=True, cwd=directory or '.',
    )
    if result.returncode != 0:
        print(f"  WARNING: detect-secrets exited {result.returncode} unexpectedly on {path} "
              f"-- skipping that signal for this file", file=sys.stderr)
        return set()

    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError:
        return set()

    flagged = set()
    for findings in report.get('results', {}).values():
        for finding in findings:
            line = finding.get('line_number')
            if line:
                flagged.add(line)
    return flagged


# A flagged line where no other signal identified a specific substring to
# redact (only possible for detect-secrets, since it never reveals the text)
# falls back to this: redact the LAST quoted string on the line. That
# correctly isolates the value even in `key['name'] = 'value'` shapes (the
# key name itself is quoted too, but the value's quotes come last), and for
# a bare "url = \"...\"" case it safely redacts the whole value -- losing the
# non-secret part of the URL is an acceptable cost for never leaking the
# credential in it. If there's no quoted string at all, the whole line is
# replaced with a placeholder comment rather than guessing further.
_ANY_QUOTED_RE = re.compile(r'(["\'])((?:(?!\1).)*)\1')


def redact_unknown_span(line):
    matches = list(_ANY_QUOTED_RE.finditer(line))
    if matches:
        start, end = matches[-1].span(2)
        return line[:start] + 'REDACTED' + line[end:]
    stripped = line.rstrip('\n')
    indent = stripped[:len(stripped) - len(stripped.lstrip())]
    return f'{indent}# REDACTED (flagged by detect-secrets, no clear value span found)\n'


def sanitize_lines(path_for_scanning, lines, exclude_line_ranges=()):
    """
    Returns (sanitized_lines, redaction_count). Merges gitleaks + trufflehog +
    keyword-regex + detect-secrets findings per line, then replaces each
    matched substring with REDACTED. gitleaks/trufflehog/detect-secrets scan
    the file ON DISK at path_for_scanning (not the in-memory `lines`, which
    may already differ from it -- e.g. the compose file after ${VAR}
    substitution); callers that need to scan modified content pass a
    temp-file path holding that content instead.

    exclude_line_ranges: an iterable of (start, end) 1-based, inclusive line
    number pairs (matching `lines`' own numbering) to leave completely
    untouched -- no scanning result is applied there, regardless of what any
    detector reports. This exists for YAML block scalars already flagged by
    the structural extractor as needing manual review (skipped_multiline): a
    scanner can misattribute a finding inside such a block to the block's KEY
    line instead of the actual line the secret is on (observed with both
    trufflehog and detect-secrets), and blindly redacting whatever text got
    reported there corrupts the key while the real secret, elsewhere in the
    block, stays untouched and looks safe when it isn't.
    """
    excluded = set()
    for start, end in exclude_line_ranges:
        excluded.update(range(start, end + 1))

    gl = gitleaks_matches_by_line(path_for_scanning) or {}
    th = trufflehog_matches_by_line(path_for_scanning) or {}
    ds = detect_secrets_flagged_lines(path_for_scanning) or set()

    sanitized = []
    total = 0
    known_secrets = set()  # every secret substring confirmed anywhere in this file
    for idx, line in enumerate(lines, start=1):
        if idx in excluded:
            sanitized.append(line)
            continue
        scanner_hits = set(gl.get(idx, ())) | set(th.get(idx, ()))
        # Expand each scanner hit to its full quoted-string/token boundary --
        # see expand_to_full_token's docstring.
        secrets_here = {expand_to_full_token(line, s) for s in scanner_hits}
        secrets_here |= keyword_matches_in_line(line)
        # Never redact an already-externalized ${VAR}/$VAR reference or our
        # own REDACTED placeholder, from any source -- see _is_placeholder.
        secrets_here = {s for s in secrets_here if s and not _is_placeholder(s)}
        known_secrets |= secrets_here

        new_line = line
        for secret in sorted(secrets_here, key=len, reverse=True):
            if secret and secret in new_line:
                new_line = new_line.replace(secret, 'REDACTED')
                total += 1

        # detect-secrets flagged this line but never reveals what it found --
        # if nothing above already redacted something here, fall back to the
        # best-effort quoted-value heuristic rather than leave it untouched.
        if idx in ds and new_line == line:
            new_line = redact_unknown_span(line)
            total += 1

        sanitized.append(new_line)

    # A scanner reports a secret once, not on every line it's duplicated onto
    # -- trufflehog in particular deduplicates identical values. A real config
    # (a GitLab Runner config.toml with the same DOCKER_AUTH_CONFIG credential
    # copy-pasted into several [[runners]] blocks) can have the exact same
    # secret sitting on multiple lines, only one of which any scanner actually
    # flagged -- leaving every other copy fully exposed even though the tool
    # "found" that secret elsewhere in the same file. Once a value is
    # confirmed a secret anywhere above, redact every other verbatim
    # occurrence of it too, excluded ranges included (a known-secret string
    # match doesn't have the block-scalar misattribution risk a scanner's
    # own line-number report does -- this isn't asking a scanner about
    # content inside the block, just checking known text against it).
    if known_secrets:
        for idx in range(len(sanitized)):
            line = sanitized[idx]
            for secret in sorted(known_secrets, key=len, reverse=True):
                if secret and secret in line:
                    line = line.replace(secret, 'REDACTED')
                    total += 1
            sanitized[idx] = line

    return sanitized, total


# ---------------------------------------------------------------------------
# Compose-specific structural extraction: environment: -> ${VAR} + .env
# ---------------------------------------------------------------------------

ENV_BLOCK_RE = re.compile(r'^(\s*)environment:\s*$')
LIST_ITEM_RE = re.compile(r'^(\s*)-\s*(.+)$')
MAP_ITEM_RE = re.compile(r'^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$')
# YAML block scalar indicator, e.g. "KEY: |" or "KEY: >-" -- introduces a multi-line
# string value on the following more-indented lines (e.g. SPILO_CONFIGURATION in
# Spilo/Patroni compose files). Never auto-extracted: those indented lines look like
# ordinary "key: value" pairs and would otherwise be misparsed as separate env vars,
# corrupting the block. Left inline and flagged for manual review instead.
BLOCK_SCALAR_RE = re.compile(r'^[|>][+-]?\d*\s*(#.*)?$')


class EnvUnreadable(Exception):
    """Raised when an existing .env/.env.example can't be read (permission
    denied). Compose extraction refuses to guess in that case -- see
    load_env_keys."""


def strip_quotes(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
        return v[1:-1]
    return v


def split_value_and_comment(raw):
    """
    Split the text after "key:" (or after "key=" in a list item) into
    (value_text, comment_text). comment_text includes the leading '#' and is
    '' if there's none. Quote-aware: a '#' inside a quoted value is just part
    of the value, not a comment -- only an unquoted trailing '#' (preceded by
    whitespace, or at the very start) starts a comment, matching YAML.
    """
    s = raw.rstrip('\n')
    stripped = s.strip()
    if stripped and stripped[0] in ('"', "'"):
        quote = stripped[0]
        j = 1
        while j < len(stripped):
            if stripped[j] == quote:
                return stripped[:j + 1], stripped[j + 1:].strip()
            j += 1
        return stripped, ''  # unterminated quote; treat whole thing as value

    idx = s.find('#')
    while idx != -1:
        if idx == 0 or s[idx - 1] in (' ', '\t'):
            return s[:idx].rstrip(), s[idx:].rstrip()
        idx = s.find('#', idx + 1)
    return s.rstrip(), ''


def find_compose_file(service_dir, explicit):
    """Returns the compose file path, or None if this service dir doesn't
    have one (not every service directory does, e.g. a certs-only dir)."""
    if explicit:
        p = os.path.join(service_dir, explicit)
        return p if os.path.isfile(p) else None
    for name in ("docker-compose.yaml", "docker-compose.yml", "compose.yaml", "compose.yml"):
        p = os.path.join(service_dir, name)
        if os.path.isfile(p):
            return p
    return None


def load_env_keys(path):
    """
    Reads just the KEY names already present in an existing .env/.env.example
    (used to detect conflicts / avoid re-extracting). If the file exists but
    isn't readable (e.g. a tightly-locked-down production .env), raises
    EnvUnreadable rather than guessing -- proceeding as if it were empty could
    produce a .env.additions that duplicates or conflicts with real,
    unreadable secrets.
    """
    keys = set()
    if os.path.isfile(path):
        try:
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#') or '=' not in line:
                        continue
                    keys.add(line.split('=', 1)[0].strip())
        except PermissionError:
            raise EnvUnreadable(path)
    return keys


def extract_compose_environment(lines, existing_env_keys, existing_example_keys):
    """
    Walks a compose file's lines, moving hardcoded `environment:` values out
    to ${VAR} references. Returns (new_lines, env_appends, example_appends,
    conflicts, skipped_multiline, skipped_line_ranges).

    skipped_line_ranges is a list of (start, end) 1-based, inclusive line
    numbers *within new_lines* spanned by each skipped block scalar (key line
    through its last content line). Callers use this to keep the generic
    scan-and-redact pass away from that content entirely -- see
    process_compose_file for why: a scanner can misattribute a finding
    inside a multi-line block to the block's KEY line instead of the actual
    line the secret is on (observed with both trufflehog and detect-secrets
    against a GITLAB_OMNIBUS_CONFIG-style block), and blindly redacting
    whatever text got reported there corrupts the key instead of hiding the
    real secret, which stays fully exposed on the lines nobody touched.
    """
    new_lines = []
    env_appends = []      # (key, value) -> .env.additions
    example_appends = []  # key -> .env.example.additions
    conflicts = []        # key already present in .env with a hardcoded value still in compose
    skipped_multiline = []  # keys left inline because their value is a YAML block scalar
    skipped_line_ranges = []  # (start, end) 1-based lines in new_lines, per skipped block

    in_env_block = False
    env_block_indent = None
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        rstripped = line.rstrip('\n')

        if not in_env_block:
            m = ENV_BLOCK_RE.match(rstripped)
            if m:
                in_env_block = True
                env_block_indent = len(m.group(1))
            new_lines.append(line)
            i += 1
            continue

        stripped = rstripped.strip()
        if stripped == '':
            new_lines.append(line)
            i += 1
            continue

        cur_indent = len(rstripped) - len(rstripped.lstrip(' '))
        if cur_indent <= env_block_indent:
            in_env_block = False
            continue  # reprocess this line as normal (outside the block)

        lm = LIST_ITEM_RE.match(rstripped)
        mm = MAP_ITEM_RE.match(rstripped)
        handled = False

        if lm and '=' in lm.group(2):
            indent, item = lm.groups()
            key, raw_val = item.split('=', 1)
            key = key.strip()
            val_text, comment = split_value_and_comment(raw_val)
            val_stripped = strip_quotes(val_text)
            comment_suffix = f'  {comment}' if comment else ''
            if val_stripped.startswith('${'):
                new_lines.append(line)
            elif key in existing_env_keys:
                conflicts.append((key, i + 1))
                new_lines.append(line)
            else:
                new_lines.append(f'{indent}- {key}=${{{key}}}{comment_suffix}\n')
                env_appends.append((key, val_stripped))
                if key not in existing_example_keys:
                    example_appends.append(key)
            handled = True

        elif mm:
            indent, key, val = mm.groups()
            if BLOCK_SCALAR_RE.match(val.strip()):
                # Multi-line value: emit this line unchanged, then consume every
                # following line that's indented deeper than this key (the block's
                # content) unchanged too, so it's never misread as separate vars.
                range_start = len(new_lines) + 1  # 1-based index of the key line itself
                new_lines.append(line)
                skipped_multiline.append(key)
                key_indent = len(indent)
                i += 1
                while i < n:
                    nxt = lines[i]
                    nxt_r = nxt.rstrip('\n')
                    if nxt_r.strip() == '':
                        new_lines.append(nxt)
                        i += 1
                        continue
                    nxt_indent = len(nxt_r) - len(nxt_r.lstrip(' '))
                    if nxt_indent <= key_indent:
                        break
                    new_lines.append(nxt)
                    i += 1
                skipped_line_ranges.append((range_start, len(new_lines)))
                continue  # already advanced i; skip the trailing i += 1 below

            val_text, comment = split_value_and_comment(val)
            val_stripped = strip_quotes(val_text)
            comment_suffix = f'  {comment}' if comment else ''
            if val_stripped == '' or val_stripped.startswith('${'):
                new_lines.append(line)
            elif key in existing_env_keys:
                conflicts.append((key, i + 1))
                new_lines.append(line)
            else:
                new_lines.append(f'{indent}{key}: "${{{key}}}"{comment_suffix}\n')
                env_appends.append((key, val_stripped))
                if key not in existing_example_keys:
                    example_appends.append(key)
            handled = True

        if not handled:
            new_lines.append(line)
        i += 1

    return new_lines, env_appends, example_appends, conflicts, skipped_multiline, skipped_line_ranges


# Last-resort classifier for .env.additions values, only used if neither
# scanner is on PATH. Real classification is value-based (see
# classify_env_values below), same union approach as the per-file scanning.
_FALLBACK_SECRET_KEY_RE = re.compile(
    r'(PASSWORD|PASSWD|PWD|SECRET|TOKEN|API[_-]?KEY|PRIVATE[_-]?KEY|'
    r'CREDENTIAL|ACCESS[_-]?KEY|CLIENT[_-]?SECRET|PASSPHRASE|CERT|SIGNING)',
    re.IGNORECASE,
)


def is_secret_key_fallback(key):
    return bool(_FALLBACK_SECRET_KEY_RE.search(key))


def classify_env_values(env_appends):
    """
    Returns the set of keys (from env_appends) treated as secret: the UNION of
    (a) gitleaks (value-based: entropy + rules), (b) trufflehog (value-based:
    per-credential-type detectors, --no-verification so it never makes live
    API calls), and (c) the key-name heuristic (PASSWORD/SECRET/TOKEN/... in
    the name). Same reasoning as sanitize_lines' union: each signal catches
    things the others miss (e.g. a low-entropy dictionary-word password like
    "postgres" won't trip either scanner, but the key name gives it away).

    Scans a throwaway temp file (KEY=value per line, same order as
    env_appends) so report line numbers map straight back to keys; deleted
    immediately after.
    """
    if not env_appends:
        return set()

    name_flagged = {k for k, _ in env_appends if is_secret_key_fallback(k)}

    with tempfile.TemporaryDirectory() as tmpdir:
        scan_path = os.path.join(tmpdir, 'scan.env')
        with open(scan_path, 'w') as f:
            for k, v in env_appends:
                f.write(f"{k}={v}\n")

        gl_by_line = gitleaks_matches_by_line(scan_path) or {}
        th_by_line = trufflehog_matches_by_line(scan_path) or {}

    scanner_flagged = set()
    for line_no in set(gl_by_line) | set(th_by_line):
        if 1 <= line_no <= len(env_appends):
            scanner_flagged.add(env_appends[line_no - 1][0])

    return name_flagged | scanner_flagged


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def process_compose_file(compose_path, out_subdir, do_write):
    """
    Handles the compose file: structural ${VAR} extraction, then a generic
    scan-and-redact pass over the RESULT (catches secrets outside
    `environment:`, e.g. in `command:`/`labels:`). Prints its own report
    section. Returns True if a .sanitized file was written (or would be) --
    i.e. this file actually contained something worth redacting, so the REAL
    file needs a .gitignore entry and the .sanitized copy is what should be
    tracked instead. Returns False if the file is already clean (nothing to
    extract AND nothing to redact) -- no .sanitized is written in that case,
    and the real file can just be tracked as itself.
    """
    service_dir = os.path.dirname(compose_path)
    env_path = os.path.join(service_dir, '.env')
    example_path = os.path.join(service_dir, '.env.example')

    try:
        with open(compose_path) as f:
            lines = f.readlines()
    except PermissionError:
        # Same reasoning as process_generic_file's PermissionError handling:
        # a root-locked compose file can't be verified as safe without read
        # access, so flag it for its own .gitignore entry rather than crash
        # the whole service's report or silently skip it.
        print(f"  compose file: {compose_path}")
        print(f"  SKIPPED -- permission denied reading this file. Cannot verify it's safe without "
              f"read access, so it needs its own .gitignore entry -- review by hand, as root, "
              f"when you can actually read it.")
        return True

    print(f"  compose file: {compose_path}")

    try:
        existing_env_keys = load_env_keys(env_path)
        existing_example_keys = load_env_keys(example_path)
    except EnvUnreadable as e:
        print(f"  structural extraction SKIPPED -- permission denied reading {e}: cannot safely "
              f"tell which vars are already externalized without read access to it.")
        print("  (the compose file will still get the generic redaction pass below, and every "
              "other file in this service is unaffected by this.)")
        result_lines = lines
        env_appends, example_appends, conflicts, skipped_multiline, skipped_line_ranges = [], [], [], [], []
    else:
        result_lines, env_appends, example_appends, conflicts, skipped_multiline, skipped_line_ranges = \
            extract_compose_environment(lines, existing_env_keys, existing_example_keys)

        secret_keys = classify_env_values(env_appends)
        print(f"  vars that would move to .env: {len(env_appends)}")
        for k, _ in env_appends:
            tag = "secret -> blanked in .env.example" if k in secret_keys else "config -> real value kept in .env.example"
            print(f"    - {k}  ({tag})")
        if conflicts:
            print("  CONFLICTS -- key already exists in .env, compose value left untouched, review by hand:")
            for k, ln in conflicts:
                print(f"    - {k}  (compose line {ln})")
        if skipped_multiline:
            print("  SKIPPED -- multi-line YAML block scalar, left inline, review/extract by hand if wanted:")
            for k in skipped_multiline:
                print(f"    - {k}")

        if do_write and env_appends:
            additions_path = os.path.join(out_subdir, '.env.additions')
            with open(additions_path, 'w') as f:
                for k, v in env_appends:
                    f.write(f"{k}={v}\n")
            print(f"  wrote: {additions_path}  ({len(env_appends)} lines, real values -- do not paste this file anywhere)")

            env_appends_by_key = dict(env_appends)
            example_additions_path = os.path.join(out_subdir, '.env.example.additions')
            with open(example_additions_path, 'w') as f:
                for k in example_appends:
                    if k in secret_keys:
                        f.write(f"{k}=\n")
                    else:
                        f.write(f"{k}={env_appends_by_key[k]}\n")
            print(f"  wrote: {example_additions_path}  ({len(example_appends)} lines, "
                  f"flagged secrets blanked / config vars kept as real values)")

    # Generic pass over the (possibly ${VAR}-substituted) result, to catch
    # anything outside `environment:` (command:, labels:, ...). Scan a temp
    # copy holding result_lines, since that may now differ from the file on disk.
    with tempfile.TemporaryDirectory() as tmpdir:
        scan_copy = os.path.join(tmpdir, os.path.basename(compose_path))
        with open(scan_copy, 'w') as f:
            f.writelines(result_lines)
        final_lines, redaction_count = sanitize_lines(scan_copy, result_lines, skipped_line_ranges)

        # Each skipped block scalar was excluded above wholesale (key line +
        # content) because scanning it TOGETHER WITH the surrounding YAML let
        # a scanner misattribute a finding inside it to the block's KEY line
        # instead of the real line -- redacting whatever text got reported
        # there corrupted the key while the actual secret, elsewhere in the
        # block, stayed untouched. Fix: scan the block's CONTENT alone, in
        # isolation, as its own standalone text with its own line numbering --
        # with no enclosing "KEY: |" line for anything to misattribute to,
        # findings land on the right line and can be redacted safely. The key
        # line itself is never touched either way.
        unresolved_blocks = []
        for key, (start, end) in zip(skipped_multiline, skipped_line_ranges):
            content_start = start + 1  # 1-based; skip the "KEY: |" line itself
            if content_start > end:
                continue  # empty block, nothing to isolate
            block_lines = result_lines[content_start - 1:end]
            block_copy = os.path.join(tmpdir, f'block_{start}_{end}.txt')
            with open(block_copy, 'w') as f:
                f.writelines(block_lines)
            redacted_block, block_count = sanitize_lines(block_copy, block_lines)
            final_lines[content_start - 1:end] = redacted_block
            redaction_count += block_count
            if block_count == 0:
                unresolved_blocks.append(key)

    filename = os.path.basename(compose_path)
    needs_sanitized = bool(env_appends) or redaction_count > 0

    if unresolved_blocks:
        # Found nothing to redact inside this block, but "nothing found" is
        # not the same guarantee as "confirmed clean" -- never silently claim
        # it's safe; require a human decision, same as the pg-cluster-instance-2
        # precedent (its SPILO_CONFIGURATION was read and confirmed clean by
        # hand, not just waved through because nothing matched automatically).
        print(f"  NOTE: {', '.join(unresolved_blocks)} (block scalar) had nothing automatically "
              f"redacted in it -- that's not the same as confirmed clean. Review it by hand "
              f"before trusting {'the .sanitized copy' if needs_sanitized else 'this file'}.")
        needs_sanitized = True

    if not needs_sanitized:
        print(f"  generic redaction pass: 0 additional redaction(s) outside environment: -- "
              f"nothing extracted either, this file is already clean. No .sanitized needed; "
              f"the real {filename} can be tracked as-is.")
        return False

    if do_write:
        out_path = os.path.join(out_subdir, filename + '.sanitized')
        with open(out_path, 'w', encoding='utf-8') as f:
            f.writelines(final_lines)
        print(f"  generic redaction pass: {redaction_count} additional redaction(s) outside "
              f"environment: -> wrote {out_path}")
        print(f"  next steps (manual, your call, e.g. as root once reviewed):")
        print(f"    diff {compose_path} {out_path}")
        if env_appends:
            print(f"    cat {os.path.join(out_subdir, '.env.additions')} >> {env_path}")
            print(f"    cat {os.path.join(out_subdir, '.env.example.additions')} >> {example_path}")
    else:
        print(f"  generic redaction pass: {redaction_count} additional redaction(s) outside "
              f"environment: -> would write {filename}.sanitized")
    return True


def process_generic_file(service_dir, filename, out_subdir, do_write):
    """
    Returns True if a .sanitized file was written (or would be) -- i.e. this
    file contained something worth redacting, so the REAL file needs a
    .gitignore entry. Returns False if it's already clean: no .sanitized is
    written (nothing would differ from the real file anyway), and the real
    file can just be tracked as itself.
    """
    path = os.path.join(service_dir, filename)
    try:
        lines = read_text_or_none(path)
    except PermissionError:
        # A root-only file (a keyfile, a locked-down sentinel.conf/.key) used
        # to crash the whole service's report here -- read_text_or_none only
        # ever caught UnicodeDecodeError/ValueError (binary detection), not
        # this. That meant one unreadable file silently prevented every OTHER
        # file in the same service directory from being checked at all (found
        # via mongo/mongo-production/proxy/redis*'s reports erroring out
        # entirely on db1). Since this file can't be verified as safe without
        # read access, the conservative default is the same one used for an
        # unresolved block scalar: never silently assume it's fine -- flag it
        # for its own .gitignore entry and hand review, but let every other
        # file in the directory still get processed normally.
        service_name = os.path.basename(service_dir.rstrip('/'))
        print(f"  {filename}: SKIPPED -- permission denied reading this file (likely root-only "
              f"by design, e.g. a keyfile/credential). Cannot verify it's safe without read access, "
              f"so it needs its own /srv/docker/{service_name}/.gitignore entry excluding it -- "
              f"review by hand, as root, when you can actually read it.")
        return True
    if lines is None:
        print(f"  {filename}: skipped (not valid UTF-8 text, likely binary)")
        return False

    sanitized_lines, count = sanitize_lines(path, lines)

    if count == 0:
        print(f"  {filename}: 0 redaction(s) -- already clean, no .sanitized needed, "
              f"track the real file as-is")
        return False

    if not do_write:
        print(f"  {filename}: {count} redaction(s) -> would write {filename}.sanitized")
        return True

    out_path = os.path.join(out_subdir, filename + '.sanitized')
    with open(out_path, 'w', encoding='utf-8') as f:
        f.writelines(sanitized_lines)
    print(f"  {filename}: {count} redaction(s) -> wrote {out_path}")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('service_dir')
    ap.add_argument('--compose-file', default=None)
    ap.add_argument('--out-dir', default=os.path.expanduser('~/srv_version_control/env-variables'),
                     help='where .sanitized/.additions files are written '
                          '(default: ~/srv_version_control/env-variables)')
    ap.add_argument('--write', action='store_true', help='write .sanitized/.additions files under --out-dir')
    args = ap.parse_args()

    service_dir = os.path.abspath(args.service_dir)
    service_name = os.path.basename(service_dir.rstrip('/'))

    if not shutil.which('gitleaks') and not shutil.which('trufflehog'):
        print("  WARNING: neither gitleaks nor trufflehog is on PATH -- sanitization will rely "
              "solely on the keyword-regex fallback, which is much less thorough.", file=sys.stderr)

    out_subdir = os.path.join(args.out_dir, service_name)
    if args.write:
        os.makedirs(out_subdir, exist_ok=True)

    print(f"[{service_dir}]  (source files untouched)")

    needs_gitignore = []  # real filenames that contained secrets -- .sanitized is their tracked twin

    compose_path = find_compose_file(service_dir, args.compose_file)
    if compose_path:
        if process_compose_file(compose_path, out_subdir, args.write):
            needs_gitignore.append(os.path.basename(compose_path))
    else:
        print("  no compose file found in this directory (not every service dir has one).")

    compose_name = os.path.basename(compose_path) if compose_path else None
    candidates = [f for f in list_candidate_files(service_dir) if f != compose_name]

    if not candidates and not compose_path:
        print("  no candidate files found (top-level only; certs/keys/binaries/.env* skipped).")
        return

    for filename in candidates:
        if process_generic_file(service_dir, filename, out_subdir, args.write):
            needs_gitignore.append(filename)

    if needs_gitignore:
        print(f"\n  files that contained secrets -- the REAL file should stay out of git, its "
              f".sanitized twin is what gets tracked instead. This service needs its own "
              f"/srv/docker/{service_name}/.gitignore excluding:")
        for filename in needs_gitignore:
            print(f"    {filename}")
        if args.write:
            # A per-directory .gitignore (a normal git feature) -- bare filenames,
            # relative to the service directory itself. This is self-contained and
            # host-specific by construction: db1 and db2 can have same-named service
            # directories with different content (a file secret-bearing on one host,
            # already clean on the other), so this must never be merged into one
            # shared/global .gitignore across hosts -- each host's copy of this file,
            # for the same service name, can legitimately differ.
            gitignore_path = os.path.join(out_subdir, '.gitignore')
            with open(gitignore_path, 'w') as f:
                for filename in needs_gitignore:
                    f.write(f"{filename}\n")
            print(f"  wrote: {gitignore_path}  (review, then copy to /srv/docker/{service_name}/.gitignore)")
    else:
        print("\n  nothing in this service contained a detected secret -- every file here can be "
              "tracked as its real self, no .sanitized copies or .gitignore needed.")

    if not args.write:
        print(f"\n  report only. re-run with --write to generate files under --out-dir.")
        print(f"  (would write under: {out_subdir})")


if __name__ == '__main__':
    main()
