# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| latest  | :1.0: |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do not** open a public GitHub issue for security vulnerabilities
2. Email security concerns to the maintainers (see repository contacts)
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact assessment

## Security Practices

### Secrets Management

- **Never commit secrets** to the repository
- Use `.env` file for sensitive configuration (gitignored)
- Copy `.env.example` to `.env` and set permissions:
  ```bash
  cp .env.example .env
  chmod 600 .env
  ```
- The script warns if `.env` has overly permissive permissions

### Environment Variables

All sensitive values should be set via environment variables or `.env`:

| Variable | Purpose |
|----------|---------|
| `LITELLM_API_KEY` | LiteLLM proxy authentication |
| `OMNIROUTE_API_KEY` | Omniroute authentication |
| `TELEGRAM_BOT_TOKEN` | Telegram API authentication |

### Input Validation

- YouTube URLs are validated before processing
- Environment variable keys are validated (alphanumeric + underscore only)
- No `eval` or command substitution in configuration parsing

### File Security

- Temporary files are created with restricted permissions
- Cache files use timestamp-based naming to avoid collisions
- Output files respect configured permissions

### Network Security

- HTTPS is used for all external API calls
- Certificate validation is enabled by default
- API keys are transmitted via secure headers, not URLs

### Error Handling

- Errors are logged to stderr (not stdout)
- Sensitive information is not exposed in error messages
- Failed operations clean up temporary resources

### Bash Security

- Scripts use `set -euo pipefail` for strict error handling
- All variables are properly quoted to prevent injection
- No use of `eval` for untrusted input

## Configuration Security

### Recommended Practices

1. **Restrict `.env` permissions**:
   ```bash
   chmod 600 .env
   ```

2. **Use dedicated API keys** with minimal required permissions

3. **Rotate keys periodically** and after any suspected compromise

4. **Monitor logs** for unexpected API usage patterns

### What NOT to Do

- Do not hardcode API keys in scripts or configuration files
- Do not commit `.env` files or any files containing secrets
- Do not share API keys via insecure channels
- Do not use production keys in development environments

## Dependencies

All dependencies are pinned in lockfiles where applicable. Regular updates are recommended to patch known vulnerabilities:

```bash
# Check for outdated dependencies (if using package managers)
# Update yt-dlp regularly
yt-dlp -U
```

## Audit Checklist

- [ ] `.env` file has `chmod 600` permissions
- [ ] No secrets in git history
- [ ] API keys have minimal required scope
- [ ] Regular dependency updates
- [ ] Logs do not contain sensitive information
