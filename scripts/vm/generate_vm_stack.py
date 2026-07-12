#!/usr/bin/env python3
"""Regenerate the managed PROJECT-DBS block in virtualbox-stack/docker-compose.yml.

Reads project metadata as JSON from stdin:
  [
    {
      "project":  "eventstracker",
      "service":  "postgres",
      "image":    "postgres:17.5",
      "port":     "6433",
      "db_name":  "event-service",
      "name_key": "EVENTS_TRACKER_DB_NAME",
      "user_key": "EVENTS_TRACKER_DB_USER",
      "pass_key": "EVENTS_TRACKER_DB_PASSWORD",
      "volume":   "pg_data_eventstracker",
      "mount":    "/var/lib/postgresql/data"
    }, ...
  ]

Replaces the text between the marker pairs:
  # >>> PROJECT-DBS:START ... # >>> PROJECT-DBS:END
  # >>> PROJECT-DB-VOLUMES:START ... # >>> PROJECT-DB-VOLUMES:END

Usage: generate_vm_stack.py --compose <path> [--check]
  --check   exit 1 if the file would change (no write)
"""

import argparse
import json
import re
import sys

SVC_START = "# >>> PROJECT-DBS:START"
SVC_END = "# >>> PROJECT-DBS:END"
VOL_START = "# >>> PROJECT-DB-VOLUMES:START"
VOL_END = "# >>> PROJECT-DB-VOLUMES:END"

SERVICE_TEMPLATE = """\
  {service}:
    image: {image}
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${{{name_key}:-{db_name}}}
      POSTGRES_USER: ${{{user_key}:?set in Portainer stack env}}
      POSTGRES_PASSWORD: ${{{pass_key}:?set in Portainer stack env}}
    ports:
      - "{port}:5432"
    volumes:
      - {volume}:{mount}
    networks:
      - sathish-net
    healthcheck:
      test: [ "CMD-SHELL", "pg_isready -U ${{{user_key}}} -d ${{{name_key}:-{db_name}}}" ]
      interval: 10s
      timeout: 5s
      retries: 5
"""

REQUIRED_KEYS = (
    "project", "service", "image", "port", "db_name",
    "name_key", "user_key", "pass_key", "volume", "mount",
)


def replace_block(text: str, start: str, end: str, body: str, path: str) -> str:
    pattern = re.compile(
        r"^([ \t]*)" + re.escape(start) + r".*?\n(.*?)^[ \t]*" + re.escape(end) + r".*?$",
        re.DOTALL | re.MULTILINE,
    )
    match = pattern.search(text)
    if not match:
        sys.exit(f"ERROR: markers '{start}' / '{end}' not found in {path}")
    indent = match.group(1)
    replacement = (
        f"{indent}{start} — generated, do not edit by hand\n"
        f"{body}"
        f"{indent}{end}"
    )
    return text[: match.start()] + replacement + text[match.end():]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compose", required=True, help="path to virtualbox-stack docker-compose.yml")
    parser.add_argument("--check", action="store_true", help="exit 1 if file would change; do not write")
    args = parser.parse_args()

    try:
        projects = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        sys.exit(f"ERROR: invalid JSON on stdin: {exc}")

    if not isinstance(projects, list) or not projects:
        sys.exit("ERROR: expected a non-empty JSON array of project metadata on stdin")

    for meta in projects:
        missing = [k for k in REQUIRED_KEYS if not meta.get(k)]
        if missing:
            sys.exit(f"ERROR: project entry {meta.get('project', '?')} missing keys: {', '.join(missing)}")

    seen_ports, seen_services = set(), set()
    for meta in projects:
        if meta["port"] in seen_ports:
            sys.exit(f"ERROR: duplicate host port {meta['port']}")
        if meta["service"] in seen_services:
            sys.exit(f"ERROR: duplicate service name {meta['service']}")
        seen_ports.add(meta["port"])
        seen_services.add(meta["service"])

    services_body = "".join(SERVICE_TEMPLATE.format(**meta) for meta in projects)
    volumes_body = "".join(f"  {meta['volume']}:\n" for meta in projects)

    with open(args.compose, encoding="utf-8") as fh:
        original = fh.read()

    updated = replace_block(original, SVC_START, SVC_END, services_body, args.compose)
    updated = replace_block(updated, VOL_START, VOL_END, volumes_body, args.compose)

    if updated == original:
        print(f"No changes: {args.compose}")
        return

    if args.check:
        print(f"Would update: {args.compose}")
        sys.exit(1)

    with open(args.compose, "w", encoding="utf-8") as fh:
        fh.write(updated)
    print(f"Updated: {args.compose} ({len(projects)} project DB(s): "
          + ", ".join(m["project"] for m in projects) + ")")


if __name__ == "__main__":
    main()
