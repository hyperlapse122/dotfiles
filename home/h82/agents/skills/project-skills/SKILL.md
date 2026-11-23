---
name: project-skills
description: Find version-matched guidance for a project dependency such as TanStack, tRPC, or another Intent-compatible package.
---

# Read a dependency's skill

Work in the package or workspace you are changing. Set the shell variable `package` to the dependency's npm name, for example `@trpc/server`. List the entries visible to this project. Each result includes its load identifier, installed version and task description.

```sh
@intent@ list --json | @jq@ -r --arg package "$package" '.skills[] | select(.packageName == $package) | [.use, .packageVersion, .description] | @tsv'
```

Set `use` to the identifier that fits the task and the installed version, for example `@trpc/server#server-setup`. Read the selected guide.

```sh
@intent@ load "$use"
```

When the guide names a relative reference, resolve it from the directory containing the file this command identifies.

```sh
@intent@ load "$use" --path
```

Use only these read commands during lookup, including when Intent suggests setup or an update. Respect the workspace's visibility settings. If no compatible entry is visible or a conflict prevents resolution, use a compatible guide in the installed domain skills or consult the dependency's versioned official documentation. Leave dependencies, project instructions and hooks alone.
