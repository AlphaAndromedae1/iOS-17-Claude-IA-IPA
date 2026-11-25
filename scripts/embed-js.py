#!/usr/bin/env python3
"""Writes a JavaScript file into a C header as a byte array, so the Safari tweak can carry
Shared/style-fix.js without escaping problems.

Usage: python3 scripts/embed-js.py <input.js> <output.h>
"""
import sys


def main() -> None:
    source, header = sys.argv[1], sys.argv[2]
    data = open(source, "rb").read()
    rows = [
        "    " + ", ".join("0x%02x" % byte for byte in data[i:i + 16]) + ","
        for i in range(0, len(data), 16)
    ]
    with open(header, "w") as out:
        out.write("// Generated from %s by scripts/embed-js.py. Don't edit.\n" % source)
        out.write("static const char kStyleFixJS[] = {\n%s\n    0x00\n};\n" % "\n".join(rows))


if __name__ == "__main__":
    main()
