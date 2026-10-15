"""Total line coverage may not fall below the recorded baseline.

Usage: coverage-ratchet.py NAME REPORT
  NAME    the key in .github/coverage-baseline.json
  REPORT  an lcov file (LH and LF totals) or a Cobertura coverage.xml (line-rate)
"""
import json, os, re, sys

name, path = sys.argv[1], sys.argv[2]
report = open(path).read()
if path.endswith(".xml"):
    total = 100 * float(re.search(r'<coverage [^>]*line-rate="([\d.]+)"', report).group(1))
else:
    hit, found = (sum(map(int, re.findall(rf"^{k}:(\d+)$", report, re.M))) for k in ("LH", "LF"))
    total = 100 * hit / found
baseline_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "coverage-baseline.json")
base = json.load(open(baseline_file))[name]
print(f"{name}: total line coverage {total:.2f}%, baseline {base:.2f}%")
# A tenth of a point of slack keeps rounding from failing a change that touched nothing measured.
if total < base - 0.1:
    sys.exit(f"{name} total coverage fell below the baseline: test the code this change left untested")
if total > base + 0.1:
    print(f"It went up. Raise the baseline in this pull request: jq '.{name} = {total:.2f}' .github/coverage-baseline.json > b && mv b .github/coverage-baseline.json")
