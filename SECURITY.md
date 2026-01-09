# Security Policy

## Supported Versions

We actively support and provide security updates for the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |
| 0.9.x   | :white_check_mark: |
| < 0.9   | :x:                |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

We take security seriously. If you discover a security vulnerability in nginx-optimizer, please report it privately to help protect users.

### How to Report

Send your report via email to: **security@example.com**

Please include the following information:

- **Description**: Clear explanation of the vulnerability
- **Steps to reproduce**: Detailed steps to trigger the issue
- **Potential impact**: What could an attacker achieve?
- **Affected versions**: Which versions are impacted
- **Suggested fix**: If you have ideas for remediation (optional)
- **Your contact info**: For follow-up questions

### What to Expect

We are committed to responding promptly to security reports:

1. **Acknowledgment**: Within 48 hours of your report
2. **Initial Assessment**: Within 7 days with severity classification
3. **Resolution Timeline**: Based on severity level
   - **Critical**: 24-72 hours (remote code execution, privilege escalation)
   - **High**: 7 days (authentication bypass, significant data exposure)
   - **Medium**: 30 days (limited information disclosure, DoS)
   - **Low**: Next scheduled release (minor issues)
4. **Disclosure**: Coordinated disclosure after fix is available

## Security Considerations

nginx-optimizer requires privileged access to modify system configurations. Users should understand the security boundaries and best practices.

### Privilege Requirements

- **Root/Sudo Access**: Required to modify nginx configurations, reload nginx, and modify PHP settings
- **File System Access**: Writes to `/etc/nginx/`, PHP configuration directories, and creates backups in `~/.nginx-optimizer/`
- **Command Execution**: Executes nginx, PHP, and system commands with elevated privileges

**Best Practice**: Always review changes with `--dry-run` before applying optimizations.

### Backup Recommendations

The tool automatically creates backups, but users should verify:

- **Automatic backups** are created before any changes to: `~/.nginx-optimizer/backups/`
- **Backup contents** include: nginx configs, PHP configs, and system state snapshots
- **Verify backups** are accessible before running optimization: `ls -lh ~/.nginx-optimizer/backups/`
- **Test rollback** capability in non-production environments first
- **External backups** recommended for production systems (independent of the tool)

### Input Validation & Security Boundaries

The tool implements several security controls:

- **Site name validation**: Prevents path traversal in site/domain inputs
- **Backup path sanitization**: Prevents directory traversal in backup operations
- **Lock file mechanism**: Prevents concurrent execution that could corrupt configs
- **Configuration testing**: Uses `nginx -t` before applying changes
- **Rollback capability**: Automatic recovery if nginx reload fails

### Known Security Boundaries

**What is protected:**
- Path traversal attacks in site names and backup paths
- Concurrent execution conflicts via lock files
- Invalid nginx configurations (tested before reload)
- Sensitive file protection (wp-config.php, .env blocked in nginx configs)

**What requires user attention:**
- Root/sudo password prompts (tool cannot protect against compromised sudo)
- Docker socket access (if optimizing Docker-based nginx)
- Custom backup directory paths (user-specified paths are trusted)
- Network-accessible monitoring endpoints (if enabled, secure separately)

### Secure Usage Guidelines

1. **Review before applying**: Use `--dry-run` to preview all changes
2. **Test in staging**: Validate on non-production environments first
3. **Monitor logs**: Check `~/.nginx-optimizer/logs/` for unexpected behavior
4. **Verify backups**: Ensure rollback works before production use
5. **Update regularly**: Keep nginx-optimizer updated for security fixes
6. **Audit permissions**: Review generated nginx configs for unintended exposure

### Template Security

All configuration templates follow security best practices:

- **Rate limiting**: Protects against brute force attacks
- **Security headers**: HSTS, CSP, X-Frame-Options, X-Content-Type-Options
- **WordPress hardening**: Blocks xmlrpc.php, protects sensitive files
- **Cache exclusions**: Prevents caching of authenticated content
- **Bot blocker**: Blocks known malicious user agents (with auto-update script)

## Recognition

We appreciate responsible disclosure and working with the security community.

With your permission, we will:

- **Credit you** in the security advisory and release notes
- **Add you to CONTRIBUTORS.md** as a security researcher
- **Provide attribution** in the GitHub Security Advisory (if applicable)

If you prefer to remain anonymous, we will respect your wishes.

## Contact

- **Security vulnerabilities**: security@example.com (private reports)
- **General bug reports**: [GitHub Issues](https://github.com/MarcinDudekDev/nginx-optimizer/issues)
- **Feature requests**: [GitHub Discussions](https://github.com/MarcinDudekDev/nginx-optimizer/discussions)
- **Project maintainer**: [GitHub Profile](https://github.com/MarcinDudekDev)

## Security Updates

Security fixes will be released as soon as possible and announced via:

- GitHub Security Advisories
- Release notes with `[SECURITY]` tag
- Git tags with version bumps

Subscribe to repository releases to stay informed about security updates.
