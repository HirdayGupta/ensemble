# Workflows

The three GitHub workflows and what each one guards. Back to the [contributing guide](../.github/CONTRIBUTING.md).

| Workflow | Runs on | What it does |
|---|---|---|
| ci | Every pull request and push to main | Builds in release mode, runs the unit tests, then the network check and the size check. Keeps the logs as an artifact. |
| hygiene | Every pull request and push to main | Audits workflows with zizmor, verifies every action is pinned to the commit its version comment names with pinact, and scans the whole history for secrets with gitleaks. |
| Release | A pushed tag named v followed by a version | Builds, tests, signs, notarizes, publishes the disk image and updates the update feed. Stays disabled on the repository until Developer ID signing exists. The steps are in [RELEASING.md](RELEASING.md). |

## Rules every workflow follows

- Every action is a full commit SHA with the version in a trailing comment. Dependabot proposes bumps weekly.
- Workflows start from empty permissions and each job declares its own.
- Every checkout turns off stored credentials.
- No expression syntax inside a run step: pass values through the environment instead.
- A run step that pipes into tee needs the bash shell so the pipe fails the step.

## The two checks CI runs

| Script | Fails when |
|---|---|
| `scripts/check-network.sh` | A network call or web address appears outside a short allowlist of source, web files and the built app. |
| `scripts/check-size.sh` | The built app passes 7,400,000 bytes. |
