#!/usr/bin/env python3
"""Regenerate the auto-generated sections of README.md.

Reads projects.txt and the orchestration scripts that actually exist in the
repo, then rewrites the architecture diagram (docs/architecture.puml, embedded
in README.md as a rendered PlantUML image) and the repository status table
between AUTO-GENERATED markers in README.md.

Run manually:   python3 scripts/update_readme.py
Run via hook:   .githooks/pre-commit (installed by scripts/install-git-hooks.sh)
"""
import pathlib
import re
import subprocess
import zlib

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
README = REPO_ROOT / "README.md"
PUML = REPO_ROOT / "docs" / "architecture.puml"

PLANTUML_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"

# Known project metadata (kept in sync with scripts/lib/project-config.sh)
PROJECT_INFO = {
    "eventstracker": {"port": "6433", "db": "event-service"},
    "runs-app": {"port": "5443", "db": "runsapp_db"},
    "runs-ai-analyzer": {"port": "5444", "db": "runs_ai_analyzer_db"},
}

LOCAL_SCRIPTS = [
    "scripts/local/multi-dev-up.sh",
    "scripts/local/multi-dev-down.sh",
    "scripts/local/multi-dev-verify.sh",
    "scripts/local/start-all-services.sh",
    "scripts/local/stop-all-services.sh",
]

CLOUD_SCRIPTS = {
    "DigitalOcean": ["cloud-start.sh", "cloud-stop.sh"],
    "Azure ACG": ["acg-start.sh", "acg-stop.sh"],
    "AWS ACG": ["acg-aws-start.sh", "acg-aws-stop.sh"],
}

RABBITMQ_SCRIPTS = ["rabbitmq-manager.sh", "start-rabbitmq.sh", "stop-rabbitmq.sh"]


def alias(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9]", "_", name)


def read_projects() -> list[str]:
    projects = []
    for line in (REPO_ROOT / "projects.txt").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        projects.append(line)
    return projects


def existing(paths: list[str]) -> list[str]:
    return [p for p in paths if (REPO_ROOT / p).exists()]


def extract_description(path: pathlib.Path) -> str:
    """Best-effort one-line description from a script's leading comments."""
    stems = {path.name, path.stem}
    for line in path.read_text(errors="ignore").splitlines()[:15]:
        stripped = line.strip()
        if not stripped.startswith("#"):
            continue
        text = stripped.lstrip("#").strip()
        if not text or text.startswith("!/") or set(text) <= {"#", "="}:
            continue
        if text in stems:
            continue
        return text
    return ""


def encode_plantuml(text: str) -> str:
    """PlantUML's URL encoding: raw deflate + custom base64-like alphabet."""
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    data = compressor.compress(text.encode("utf-8")) + compressor.flush()
    out = []
    for i in range(0, len(data), 3):
        b1 = data[i]
        b2 = data[i + 1] if i + 1 < len(data) else 0
        b3 = data[i + 2] if i + 2 < len(data) else 0
        c1 = b1 >> 2
        c2 = ((b1 & 0x3) << 4) | (b2 >> 4)
        c3 = ((b2 & 0xF) << 2) | (b3 >> 6)
        c4 = b3 & 0x3F
        out.extend(PLANTUML_ALPHABET[c] for c in (c1, c2, c3, c4))
    return "".join(out)


def build_puml(projects: list[str]) -> str:
    local_scripts = existing(LOCAL_SCRIPTS)
    cloud_groups = {label: existing(scripts) for label, scripts in CLOUD_SCRIPTS.items()}
    rabbitmq_scripts = existing(RABBITMQ_SCRIPTS)

    lines = [
        "@startuml",
        "title consolidated-postgres -- orchestration map (auto-generated)",
        "skinparam componentStyle rectangle",
        "left to right direction",
        "",
        'package "Local Orchestration" {',
    ]
    for s in local_scripts:
        name = pathlib.Path(s).name
        lines.append(f'  [{name}] as {alias(name)}')
    lines.append("}")
    lines.append("")

    lines.append('package "Cloud Orchestration" {')
    for label, scripts in cloud_groups.items():
        if not scripts:
            continue
        lines.append(f'  [{label} ({" / ".join(scripts)})] as {alias(label)}')
    lines.append("}")
    lines.append("")

    if rabbitmq_scripts:
        lines.append('package "RabbitMQ Management" {')
        for s in rabbitmq_scripts:
            name = pathlib.Path(s).name
            lines.append(f'  [{name}] as {alias(name)}')
        lines.append("}")
        lines.append("")

    lines.append('package "Managed Projects (projects.txt)" {')
    for p in projects:
        lines.append(f'  [{p}] as {alias(p)}')
    lines.append("}")
    lines.append("")

    lines.append('database "Per-project PostgreSQL" as PG')
    lines.append('queue "RabbitMQ" as MQ')
    lines.append("")

    for s in local_scripts:
        name = pathlib.Path(s).name
        if "multi-dev-up" in name or "start-all" in name:
            for p in projects:
                lines.append(f'{alias(name)} --> {alias(p)}')
            lines.append(f'{alias(name)} --> PG')
            lines.append(f'{alias(name)} --> MQ')

    for label, scripts in cloud_groups.items():
        if scripts:
            lines.append(f'{alias(label)} --> PG : provisions')

    for s in rabbitmq_scripts:
        name = pathlib.Path(s).name
        lines.append(f'{alias(name)} --> MQ')

    for p in projects:
        lines.append(f'{alias(p)} ..> PG : reads/writes')

    lines.append("@enduml")
    return "\n".join(lines) + "\n"


def build_architecture_block(puml_src: str) -> str:
    encoded = encode_plantuml(puml_src)
    image_url = f"https://www.plantuml.com/plantuml/svg/{encoded}"
    return (
        f"![Architecture diagram]({image_url})\n\n"
        "<details>\n"
        "<summary>PlantUML source (also at <code>docs/architecture.puml</code>)</summary>\n\n"
        "```plantuml\n"
        f"{puml_src}"
        "```\n"
        "</details>"
    )


def git_head_short() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], cwd=REPO_ROOT, text=True
        ).strip()
    except Exception:
        return "unknown"


def build_status_block(projects: list[str]) -> str:
    rows = ["| Script | Present | Description |", "|---|---|---|"]

    def script_row(path: str) -> str:
        full = REPO_ROOT / path
        present = "yes" if full.exists() else "no"
        desc = extract_description(full) if full.exists() else ""
        return f"| `{path}` | {present} | {desc} |"

    all_scripts = (
        LOCAL_SCRIPTS
        + [s for scripts in CLOUD_SCRIPTS.values() for s in scripts]
        + RABBITMQ_SCRIPTS
    )
    for s in all_scripts:
        rows.append(script_row(s))

    project_rows = ["", "| Managed project | DB port | DB name |", "|---|---|---|"]
    for p in projects:
        info = PROJECT_INFO.get(p, {"port": "?", "db": "?"})
        project_rows.append(f"| `{p}` | {info['port']} | `{info['db']}` |")

    head = git_head_short()
    return (
        f"_Generated from `projects.txt` and the scripts present in the repo as of `{head}`._\n\n"
        + "\n".join(rows)
        + "\n"
        + "\n".join(project_rows)
    )


def replace_block(content: str, start: str, end: str, body: str) -> str:
    pattern = re.compile(re.escape(start) + r".*?" + re.escape(end), re.DOTALL)
    if not pattern.search(content):
        raise ValueError(f"Markers {start} / {end} not found in README.md")
    return pattern.sub(f"{start}\n{body}\n{end}", content)


def main() -> None:
    projects = read_projects()
    puml_src = build_puml(projects)
    PUML.write_text(puml_src)

    readme = README.read_text()
    readme = replace_block(
        readme,
        "<!-- AUTO-GENERATED:ARCHITECTURE:START -->",
        "<!-- AUTO-GENERATED:ARCHITECTURE:END -->",
        build_architecture_block(puml_src),
    )
    readme = replace_block(
        readme,
        "<!-- AUTO-GENERATED:STATUS:START -->",
        "<!-- AUTO-GENERATED:STATUS:END -->",
        build_status_block(projects),
    )
    README.write_text(readme)


if __name__ == "__main__":
    main()