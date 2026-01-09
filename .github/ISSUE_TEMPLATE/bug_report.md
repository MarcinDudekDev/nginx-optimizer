---
name: Bug Report
about: Report a bug or unexpected behavior
title: '[BUG] '
labels: bug
assignees: ''
---

## Describe the bug
A clear and concise description of what the bug is.

## To Reproduce
Steps to reproduce the behavior:
1. Run command '...'
2. With options '...'
3. See error

## Expected behavior
A clear and concise description of what you expected to happen.

## Screenshots/Logs
If applicable, add screenshots or log output to help explain your problem.

Relevant log files:
```bash
# View latest optimization log
ls -lt ~/.nginx-optimizer/logs/ | head -1
cat ~/.nginx-optimizer/logs/optimization-*.log
```

## Environment
- **OS**: [e.g., macOS 14.2, Ubuntu 22.04, Debian 11]
- **Bash version**: [output of `bash --version`]
- **nginx-optimizer version**: [output of `nginx-optimizer --version`]
- **nginx version**: [output of `nginx -v`]
- **Installation method**: [git clone, direct download, Docker]
- **nginx installation type**: [system package, compiled, Docker, wp-test]

## Additional context
Add any other context about the problem here:
- Was this working in a previous version?
- Did you use `--dry-run` before applying?
- Any custom configurations or modifications?
- Output of `nginx-optimizer analyze`
