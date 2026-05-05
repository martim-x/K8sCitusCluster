import re
import sys
from pathlib import Path
from collections import defaultdict
from tabulate import tabulate


FUNCTION_RE = re.compile(
    r"""
    create\s+or\s+replace\s+function\s+
    (?P<func_name>[a-zA-Z_][\w$]*\.[a-zA-Z_][\w$]*)
    \s*\(
        (?P<args>.*?)
    \)
    .*?
    as\s+\$\$
    (?P<body>.*?)
    \$\$
    \s*;
    """,
    re.IGNORECASE | re.DOTALL | re.VERBOSE,
)

INSERT_RE = re.compile(
    r"\binsert\s+into\s+([a-zA-Z_][\w$]*\.[a-zA-Z_][\w$]*)",
    re.IGNORECASE,
)

UPDATE_RE = re.compile(
    r"\bupdate\s+([a-zA-Z_][\w$]*\.[a-zA-Z_][\w$]*)",
    re.IGNORECASE,
)

DELETE_RE = re.compile(
    r"\bdelete\s+from\s+([a-zA-Z_][\w$]*\.[a-zA-Z_][\w$]*)",
    re.IGNORECASE,
)

SELECT_FROM_RE = re.compile(
    r"\bfrom\s+([a-zA-Z_][\w$]*\.[a-zA-Z_][\w$]*)",
    re.IGNORECASE,
)

JOIN_RE = re.compile(
    r"\bjoin\s+([a-zA-Z_][\w$]*\.[a-zA-Z_][\w$]*)",
    re.IGNORECASE,
)


def normalize_sql(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    text = re.sub(r"--.*?$", " ", text, flags=re.MULTILINE)
    return text


def parse_functions(sql_text: str):
    matches = []
    for m in FUNCTION_RE.finditer(sql_text):
        func_name = m.group("func_name").lower()
        args = re.sub(r"\s+", " ", m.group("args").strip())
        body = m.group("body")
        matches.append((func_name, args, body))
    return matches


def extract_operations(body: str):
    body_clean = normalize_sql(body)
    table_ops = defaultdict(set)

    for table in INSERT_RE.findall(body_clean):
        table_ops[table.lower()].add("INSERT")

    for table in UPDATE_RE.findall(body_clean):
        table_ops[table.lower()].add("UPDATE")

    for table in DELETE_RE.findall(body_clean):
        table_ops[table.lower()].add("DELETE")

    for table in SELECT_FROM_RE.findall(body_clean):
        table_ops[table.lower()].add("SELECT")

    for table in JOIN_RE.findall(body_clean):
        table_ops[table.lower()].add("SELECT")

    return table_ops


def format_required_privileges(ops: set[str]) -> str:
    order = ["SELECT", "INSERT", "UPDATE", "DELETE"]
    return ", ".join(op for op in order if op in ops)


def main(file_path: str):
    sql_text = Path(file_path).read_text(encoding="utf-8")
    functions = parse_functions(sql_text)

    if not functions:
        print("Функции CREATE OR REPLACE FUNCTION не найдены.")
        return

    rows = []

    for func_name, args, body in functions:
        signature = f"{func_name}({args})"
        table_ops = extract_operations(body)

        if not table_ops:
            rows.append([signature, "-", "-", "-"])
            continue

        for table_name in sorted(table_ops.keys()):
            ops = sorted(table_ops[table_name], key=lambda x: ["SELECT", "INSERT", "UPDATE", "DELETE"].index(x))
            rows.append([
                signature,
                table_name,
                ", ".join(ops),
                format_required_privileges(set(ops)),
            ])

    print(tabulate(
        rows,
        headers=["Function", "Table", "DML operations", "Required grants"],
        tablefmt="psql",
    ))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Использование:")
        print("  python scan_function_privileges.py path/to/functions.sql")
        sys.exit(1)

    main(sys.argv[1])