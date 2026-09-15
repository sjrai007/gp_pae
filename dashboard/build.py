#!/usr/bin/env python3
"""Splice the exported trace data into the dashboard page.

Idempotent: replaces whatever currently sits inside the traces-data script
tag, so it can be re-run after every `dune exec bin/export_traces.exe`.
"""
import re, pathlib
here = pathlib.Path(__file__).parent
html = (here / 'index.html').read_text()
traces = (here / 'traces.json').read_text().strip()
assert '</script>' not in traces, "trace data must not contain a script close tag"
new, n = re.subn(
    r'(<script id="traces-data" type="application/json">).*?(</script>)',
    lambda m: m.group(1) + traces + m.group(2),
    html, count=1, flags=re.S)
assert n == 1, "traces-data script tag not found"
(here / 'index.html').write_text(new)
print(f"spliced {len(traces)} bytes of trace data into index.html")
