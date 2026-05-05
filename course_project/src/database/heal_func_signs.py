import re
import sys
from pathlib import Path
from collections import defaultdict

CREATE_FUNC_RE = re.compile(
    r"""
    create\s+or\s+replace\s+function\s+
    (?P<full_name>[a-zA-Z_][\w$]*\.[a-zA-Z_][\w$]*)
    \s*\(
        (?P<args>.*?)
    \)
    \s*returns\b
    """,
    re.IGNORECASE | re.DOTALL | re.VERBOSE,
)

GRANT_FUNC_RE = re.compile(
    r"""
    grant\s+execute\s+on\s+function\s+
    (?P<full_name>[a-zA-Z_][\w$]*\.[a-zA-Z_][\w$]*)
    \s*\(
        (?P<args>.*?)
    \)
    \s*to\b
    """,
    re.IGNORECASE | re.DOTALL | re.VERBOSE,
)

ARG_SPLIT_RE = re.compile(r",(?![^(]*\))")


def split_args(arg_string: str) -> list[str]:
    arg_string = arg_string.strip()
    if not arg_string:
        return []
    return [a.strip() for a in ARG_SPLIT_RE.split(arg_string) if a.strip()]


def normalize_whitespace(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip())


def normalize_type(type_str: str) -> str:
    s = normalize_whitespace(type_str.lower())

    s = re.sub(r"\bcharacter varying\s*\(\s*\d+\s*\)", "varchar", s)
    s = re.sub(r"\bvarchar\s*\(\s*\d+\s*\)", "varchar", s)
    s = re.sub(r"\bcharacter varying\b", "varchar", s)
    s = re.sub(r"\bcharacter\s*\(\s*\d+\s*\)", "char", s)

    s = re.sub(r"\bnational character varying\b", "varchar", s)
    s = re.sub(r"\bnational char(?:acter)? varying\b", "varchar", s)

    s = re.sub(r"\btimestamp without time zone\b", "timestamp", s)
    s = re.sub(r"\btimestamp with time zone\b", "timestamptz", s)
    s = re.sub(r"\btime without time zone\b", "time", s)
    s = re.sub(r"\btime with time zone\b", "timetz", s)

    s = re.sub(r"\bdouble precision\b", "float8", s)
    s = re.sub(r"\breal\b", "float4", s)
    s = re.sub(r"\binteger\b", "int4", s)
    s = re.sub(r"\bint\b", "int4", s)
    s = re.sub(r"\bsmallint\b", "int2", s)
    s = re.sub(r"\bbigint\b", "int8", s)
    s = re.sub(r"\bboolean\b", "bool", s)
    s = re.sub(r"\bdecimal\b", "numeric", s)

    s = re.sub(r"\s+", " ", s).strip()
    return s


def extract_type_from_param(param: str) -> str:
    param = normalize_whitespace(param)
    if not param:
        return ""

    tokens = param.split()
    direction_keywords = {"in", "out", "inout", "variadic"}

    if tokens and tokens[0].lower() in direction_keywords:
        tokens = tokens[1:]

    if not tokens:
        return ""

    if len(tokens) == 1:
        return normalize_type(tokens[0])

    candidate_with_name_removed = " ".join(tokens[1:])
    return normalize_type(candidate_with_name_removed)


def parse_create_functions(sql_text: str):
    result = {}
    raw_signatures = {}

    for m in CREATE_FUNC_RE.finditer(sql_text):
        full_name = m.group("full_name").lower()
        raw_args = m.group("args")
        params = split_args(raw_args)

        arg_types = tuple(extract_type_from_param(p) for p in params)
        result[full_name] = arg_types
        raw_signatures[full_name] = f"{full_name}({', '.join(arg_types)})"

    return result, raw_signatures


def parse_grants(sql_text: str):
    grants = defaultdict(set)
    raw_grants = []

    for m in GRANT_FUNC_RE.finditer(sql_text):
        full_name = m.group("full_name").lower()
        raw_args = m.group("args")
        arg_types = tuple(normalize_type(x) for x in split_args(raw_args))

        grants[full_name].add(arg_types)
        raw_grants.append(
            (full_name, arg_types, f"{full_name}({', '.join(arg_types)})")
        )

    return grants, raw_grants


def main(file_path: str):
    text = Path(file_path).read_text(encoding="utf-8")

    functions, function_signatures = parse_create_functions(text)
    grants_by_name, raw_grants = parse_grants(text)

    print("=== Проверка grant execute по сигнатурам ===\n")

    issues_found = False

    for func_name, grant_sigs in sorted(grants_by_name.items()):
        actual_sig = functions.get(func_name)

        if actual_sig is None:
            issues_found = True
            for _, grant_sig, grant_repr in raw_grants:
                pass
            for grant_sig in sorted(grant_sigs):
                print(f"[MISSING_FUNCTION] Функция не найдена в CREATE FUNCTION:")
                print(f"  grant:   {func_name}({', '.join(grant_sig)})")
                print()

            continue

        if actual_sig not in grant_sigs:
            issues_found = True
            print(f"[SIGNATURE_MISMATCH] {func_name}")
            current_variants = ", ".join(
                f"({', '.join(sig)})" for sig in sorted(grant_sigs)
            )
            print(f"  Сейчас в grant: {func_name}{current_variants}")
            print(f"  Должно быть:    {function_signatures[func_name]}")
            print()

    if not issues_found:
        print("Расхождений не найдено.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Использование:")
        print("  python check_pg_function_grants.py path/to/file.sql")
        sys.exit(1)

    main(sys.argv[1])
