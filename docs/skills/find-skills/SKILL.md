---
name: find-skills
description: Find official candidates for the shared Nix skill collection while maintaining this dotfiles repository.
---

# Find a shared skill

Use this guide when curating the collection in dotfiles. Start with an actual development task and the public name and version of the tool that owns it. Use the skills.sh directory to search by task or publisher. Keep private project names, paths and code out of queries. [Directory](https://www.skills.sh/) · [Vercel's find-skills workflow](https://www.skills.sh/vercel-labs/skills/find-skills)

Open the publisher's source. Check who maintains the skill, the versions and tasks it covers, the references and tools it requires, and the terms for redistributing those files. Compare against the existing domain entries, project-owned skills, and any guide that ships with the matching dependency.

Record the candidate, source, applicable release and adoption decision. To adopt a public reference, change the Nix declaration and its immutable pin, then verify the installed domain entry. Updating or removing it goes through the same declaration. Skip the upstream CLI's installation, update and removal steps. In ordinary project work, use the local domain entries and the `project-skills` guide for Intent-compatible dependencies.
