# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## System deployment

### System tree
The body of root-owned configuration this repository ships to absolute system paths rather than into the user's home directory. It is deliberately excluded from the set of files the dotfiles manager links, because that manager has no root-aware mode; an Install-system script installs it instead.

### System manifest
The single declaration of how the System tree is installed: per-path file modes, Host gates, source checks, and Retired paths, organized by subsystem. A file in a non-gated path needs no manifest entry — it is discovered at install time and takes the default mode. A non-default mode, a Host gate, or a retirement is what requires an entry.

### Install-system script
An onchange script that installs one subsystem's slice of the System tree to its absolute paths and then reloads whatever consumes it. Each one declares the paths it owns, so a change to a given system file has exactly one script that deploys it.

A script that reads the System tree carries the tree's location as a literal baked in at render time. Rendering that script against a different source location therefore changes its content, and content is what decides a re-run — so redirecting the whole apply at a different checkout re-runs every source-reading script, not only the one whose files changed. A script in this family that configures fixed state and reads nothing from the source tree is exempt: it renders identically from any checkout.

### Dependency fingerprint
A comment block that lists each of a script's declared dependencies with a hash of its content, so that changing a dependency changes the script's rendered text and re-triggers it. It exists because the dotfiles manager re-runs an onchange script on rendered-content change alone and has no other notion of a dependency. Hashing covers file content and declared capability probe tokens; template dependencies are hashed as raw text, so no secret enters a fingerprint.

### Host gate
An expression over host facts that scopes a manifest entry to the machines it applies to. The same grammar, negation included, scopes an install override and a retirement — which is what keeps a path from being installed under one gate and deleted under its negation on the same run.

### Retired path
An absolute system path declared for removal so that every machine deletes the orphan on its next run, including one that only pulls the commit that removed the source file. Retirement is declared in the same commit that deletes the file; a retirement may carry a Host gate or a distro scope so it never deletes a native or user-owned file elsewhere.

### Elevation ladder
The ordered resolution of how a privileged script obtains root: already root, a non-prompting sudo, a sudo that can prompt on a terminal, or a sudo that prompts through a desktop askpass helper. The ladder fails loudly when no rung succeeds, rather than handing a script a privilege it cannot honour. The askpass rung is distro-shaped and is inert where its helper is not installed.

## Repository layout

### Primary checkout
The plain checkout of a project on its default branch, used for default-branch inspection and base sessions. It is also what the dotfiles manager treats as its configured source, so a file that exists only in a Development worktree is invisible to an ordinary apply.

### Development worktree
A worktree holding one feature branch, created and destroyed through the session orchestrator and living in a central directory keyed by an orchestrator-managed name, never by project identity. Branch development happens here; the Primary checkout stays on the default branch.

## Keyboard lighting

### Direct mode
The state in which the keyboard's own effect engine yields a region's LEDs to a host-supplied buffer. It is entered and left per region, and leaving it restores whatever effect the user had saved — including "off". A host that stops proving it is alive is put back the same way, so a crash and a clean exit reach the same state.

### KEYS region
The 89 LEDs on the key matrix chain. Which firmware indicators reach it is a user setting rather than a fixed property: caps lock, Win-lock, and numlock each paint a key here under settings the user can change and the keyboard remembers, and the keyboard's own indicator pass runs after the host's pixels. A host holding this region cannot see it happen.

### SIDE region
The 12 LEDs on the logo and upper-strip chain. It is where the keyboard talks to the person: battery level, charging, and RF link render here and outrank host writes, applied after the host's pixels rather than suppressed by them. Caps lock is the exception — it is ceded to the host while the region is in Direct mode.

### Heartbeat deadline
The time a host declares, with each heartbeat, before which it will be heard from again. It is carried per heartbeat rather than fixed in firmware, so a status indicator that is silent for hours and an animation pushing frames choose different values without either one reflashing the keyboard.
