# Security policy

## Supported versions

Security fixes go into the latest release and `main`. Older versions don't receive patches.

## Reporting a vulnerability

**Don't open a public issue.** Report privately through GitHub's **[Report a vulnerability](https://github.com/Eplisium/orb/security/advisories/new)** form (Security → Advisories).

Please include:

- The ORB version (About ORB, or `VERSION` and the commit hash) and your macOS version.
- What an attacker could do, and what they need first (for example a malicious model response, a malicious MCP server, or local access).
- Steps to reproduce or a proof of concept. **Remove any API keys** from logs and screenshots.

Expect an acknowledgement within a week. Please give us a reasonable amount of time to release a fix before you disclose publicly.

## Scope

ORB is a local desktop app that holds OpenRouter credentials and can run tools with the user's permissions. These are especially in scope:

- Credential exposure: keys leaking into logs, preferences, errors, or requests to non-OpenRouter origins, or one key role being used for the other.
- Tool policy bypass: a model getting a tool to run when the session doesn't grant it, or when the call wasn't approved; escapes from the workspace for ORB's own file tools.
- MCP: launching unapproved servers or tools, or unresolved secret references being passed to a subprocess.
- Credential-bearing requests sent to URLs that aren't `https://openrouter.ai/api/…`.
- PKCE sign-in flaws (state/origin/replay validation).

These are **by design** and not vulnerabilities by themselves:

- With Computer Access enabled, the Agent can do anything your macOS user can. Shell commands aren't confined to the workspace folder.
- When the user enables **OP Mode**, risky tool calls run without a prompt.
- MCP servers you add run as local processes with your permissions.
- Ad-hoc signed builds aren't notarized.

See the *Security model* section of the [README](README.md#security-model) for details.
