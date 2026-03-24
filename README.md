# AWS Cross-Account S3 Skill

This repository contains a reusable AI skill for setting up and operating AWS cross-account S3 access using an intermediate account + customer account role assumption model.

- Skill file: `aws-cross-account-s3/SKILL.md`
- Supporting docs: `aws-cross-account-s3/references/`
- Automation scripts: `aws-cross-account-s3/scripts/`

## Install on Claude Code (native Skill support)

1. Copy the skill folder into your Claude skills directory:
   ```bash
   mkdir -p ~/.claude/skills
   cp -R "aws-cross-account-s3" ~/.claude/skills/
   ```
2. Restart Claude Code (or start a new session).
3. Use a prompt like:
   - "Help me set up cross-account S3 access with an intermediate account."
4. Claude should auto-trigger the skill when your request matches the skill description.

## Install on Cursor (native Agent Skill support)

1. Copy the folder into your Cursor skills directory:
   ```bash
   mkdir -p ~/.cursor/skills
   cp -R "aws-cross-account-s3" ~/.cursor/skills/
   ```
2. Restart Cursor or reload the window.
3. In an agent chat, ask for cross-account S3 setup help.
4. The agent can use `SKILL.md` instructions and referenced scripts/docs from this folder.

## Install on ChatGPT (manual adaptation)

ChatGPT does not currently use `SKILL.md` as a native skill format. Use one of these options:

1. Create a Custom GPT and paste the content of `SKILL.md` into the GPT's instructions.
2. Upload these files to the GPT knowledge base:
   - `aws-cross-account-s3/references/customer-guide.md`
   - `aws-cross-account-s3/references/email-templates.md`
   - `aws-cross-account-s3/references/policies.md`
3. In chats, ask the GPT to follow the same step-by-step workflow from the imported skill.

## Install on Gemini / NotebookLM / Other assistants (manual adaptation)

For assistants without native Claude/Cursor skill support:

1. Paste `SKILL.md` into the assistant's system instructions (or pinned instructions).
2. Upload the `references/` markdown files as grounding material.
3. Keep `scripts/` in your local repo and run commands manually when the assistant instructs you.

## Quick local setup

If you just cloned or copied this repo:

```bash
cd "Useful Automations"
ls
```

You should see:
- `aws-cross-account-s3/`

Then open `aws-cross-account-s3/SKILL.md` and start with the `SETUP WORKFLOW` section.

## Notes

- This skill is focused on secure AWS IAM practices (AssumeRole + ExternalId + short-lived credentials).
- Always verify AWS account identity before running any script.
- Use the sandbox and audit logging guidance in the skill for all IAM changes.
