# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## System deployment

### System tree
The body of root-owned configuration this repository ships to absolute system paths rather than into the user's home directory. It is deliberately excluded from the set of files the dotfiles manager links, because that manager has no root-aware mode; an Install-system script installs it instead.

### System manifest
The single declaration of how the System tree is installed: per-path file modes, Host gates, source checks, and Retired paths, organized by subsystem. A file in a non-gated path needs no manifest entry — it is discovered at install time and takes the default mode. A non-default mode, a Host gate, or a retirement is what requires an entry.

### Install-system script
An onchange script that installs one subsystem's slice of the System tree to its absolute paths and then reloads whatever consumes it. Each one declares the paths it owns, so a change to a given system file has exactly one script that deploys it.

Scripts in this family resolve repository-rooted trees using position-independent script rendering rather than baking absolute checkout paths into rendered bodies. This ensures that applying from different worktrees produces bit-identical rendered scripts, preventing false-positive re-runs across unrelated checkouts.

### Position-independent script rendering
The technique of decoupling an onchange script's rendered body from the invoking checkout's absolute path. Instead of interpolating the dotfiles source directory at render time, the script resolves its source root at runtime from the manager's exported environment variable with an active source-path fallback. When accessing repository-rooted trees, a shared shell partial resolves the repository root from the source directory, ascending to its parent if a source-root marker exists. This ensures the rendered script text is bit-identical across worktrees, preventing false-positive execution cascades when applying from feature branches.

### Dependency fingerprint
A comment block that lists each of a script's declared dependencies with a hash of its content, so that changing a dependency changes the script's rendered text and re-triggers it. It exists because the dotfiles manager re-runs an onchange script on rendered-content change alone and has no other notion of a dependency. Hashing covers file content and declared capability probe tokens; template dependencies are hashed as raw text, so no secret enters a fingerprint.

### Host gate
An expression over host facts that scopes a manifest entry to the machines it applies to. The same grammar, negation included, scopes an install override and a retirement — which is what keeps a path from being installed under one gate and deleted under its negation on the same run.

### Declared hardware fact
A host fact whose truth comes from a committed table of verified device identities rather than from probing what the hardware can do. It exists for hardware the system exposes no generic signal for, such as a fingerprint reader or an infrared camera, and it fails safe: a device nobody has listed enables nothing.

### Declared skip
The contract by which an onchange script leaves early: it names the site and the direction of the skip, so a machine that did not converge is never recorded as one that did. Directions distinguish a condition the host will never satisfy, a precondition a later run will supply, a precondition that only an operator can clear, and a step that is already done; a completed interactive step the script cannot perform, such as enrolling a face, is reported through the same surface. Each declaration reaches CI as a generated sentinel comment in the rendered script, which is what makes the surface decidable; a call form that declares nothing emits no sentinel and is therefore invisible to that check unless something else reconciles it.

### Install verdict
The answer to whether a package installer converged, taken by re-inspecting the set of packages it declared after its install attempt rather than by reading the package manager's exit status. A verdict that still finds something missing prints it with the command that installs it by hand and leaves through a declared skip, so the host is reported as unconverged while every later phase of the run still happens.

### Derived authselect profile
A Fedora authentication profile this repository builds from the stock one to carry a factor the stock profiles have no feature for. Every file tracks the base except the stack that gains the factor, and the profile is selected with the machine's existing features plus the new one, so the distribution's tool still writes every PAM file and no script writes one directly.

### Greeter guard
The predicate that keeps the login greeter password-only whenever a factor is added: it resolves the greeter's authentication stack against the profile as it would be rendered and withholds the factor when the module would reach it. It fails closed on an unrecognized display manager or an unresolvable stack. Factors are placed in the shared privilege stack, which the greeter and the desktop lock screen do not include, because a face factor in a stack the lock screen starts on lock would unlock the screen for whoever locked it.

### Retired path
An absolute system path declared for removal so that every machine deletes the orphan on its next run, including one that only pulls the commit that removed the source file. Retirement is declared in the same commit that deletes the file; a retirement may carry a Host gate or a distro scope so it never deletes a native or user-owned file elsewhere.

### Elevation ladder
The ordered resolution of how a privileged script obtains root: already root, a non-prompting sudo, a sudo that can prompt on a terminal, or a sudo that prompts through a desktop askpass helper. The ladder fails loudly when no rung succeeds, rather than handing a script a privilege it cannot honour. The askpass rung is distro-shaped and is inert where its helper is not installed.

## Key custody

### Key presence check
The check that runs before chezmoi reads the source state, verifying that the host holds a usable GPG private key, either as a local secret key or on an inserted YubiKey that carries the configured fingerprint. When the check fails, the host is treated as if its user is absent, and the command stops before any file renders. Real containers and CI do not run it.

### Card PIN wrapper
The pinentry stand-in that answers only the OpenPGP User PIN prompt for a known card serial, using the PIN kept in the OS keyring, and hands every other prompt to the desktop pinentry. It exists because GnuPG's own password cache does not apply to card PINs. It never re-sends a stored PIN after the card has rejected one.

## Agent orchestration

### Session role
The classification a session resolves for itself at start — `lead`, `worker`, or `none` — which decides how much of the orchestration rule set it receives. It is read from the Orca terminal handle and the leader pane, and an unset value and an empty string mean the same thing at every step, because a bare equality test between two empty values would classify every teammate as the lead.

### Everyone payload
The orchestration rules that bind every agent whatever its role. Every Orca-managed session receives it. Claude Code and Codex receive it at session start. omp receives it through its native extension before each model call, using the current role.

### Coordinator payload
The additional rules only a session that can dispatch is able to act on. It is delivered on top of the Everyone payload, and only to a lead.

### Lead envelope
The single composed delivery a lead receives through its hook or native extension: the authority preamble, the orchestration skill text, the version-matched guide read from the installed CLI, the Everyone payload, and the Coordinator payload. Delivery is atomic — a lead envelope missing any half is not delivered at all, because a partial rule set is worse than none.

### Subagent guard
The mechanism that stops an injected session from bypassing Orca dispatch. In an Orca-managed session whose local payload files are staged, the guard intercepts calls to the harness's own subagent tool — `Agent` and `Task` in Claude Code, `collaborationspawn_agent` in Codex, and `task` in omp — and denies them with a message directing the agent to the `orchestration` skill. It permits all calls in an Orca agent-teams session and outside Orca. The guard fails open on any error, missing file, or unexpected format.

### Workspace trust seeding
The proactive assertion of directory trust into agent harness configurations, preventing interactive security prompts from stalling unattended execution in fresh checkouts or worktrees.

Trust is seeded at two points: during repository deployment across registered checkouts, and via runtime interception whenever a new development worktree is created. Trust is asserted additively across supported harness stores, preserving unrelated user configurations and existing trust grants.

### Brief file
The file a dispatch names by path to carry context the dispatch spec itself cannot hold. A spec travels as an argv string, so context large enough to exceed the kernel argument limit is written to a brief instead of inlined. It is also where a coordinator materializes content only it can reach, such as facts extracted from an MCP the recipient has no access to.

### Brief defect
A worker escalation or failure caused by context missing from its brief rather than by the difficulty of the work. It carries no information about the unit's blast radius or judgment depth, so it never raises the model rung; the coordinator repairs the brief and re-dispatches at the same rung.

### Model roster
The single declaration in the agent data file of two things: one lead pin per agent that can run as the orchestrator, and every worker entry a lead may dispatch to. A worker entry carries agent, model id, effort or thinking level, the work shapes it takes, brief guidance for that model, and a `rung` for an entry the coordinator selects by name rather than by shape alone — such as a named implementation entry or the judgment rungs described under Judgment work below; a lead pin carries only the model and, where the harness takes one, its effort. The two halves are independent — a model that a lead session opens on need not be a dispatch target, and removing it from the worker list does not change what a direct session runs. The rendered payloads, instruction files, prose, and tests derive their model ids from it, so no other file names a model by hand.

### Judgment work
Work whose deliverable is the judgment itself: a code review, a document review, a code simplification pass, or an architectural evaluation verdict. It is never performed by the lead in place; it is dispatched to a roster judgment rung matched to the workflow tier the persona under review declares. The cheapest and standard rungs route to the primary judgment worker, with a secondary worker replacing it on failure or unavailability; deep judgment dispatches a cross-vendor pair over the same brief; escalation rungs sit outside default routing and are reached only through an explicit user upgrade request or after three consecutive consultation failures.

### Authoring work
Plan authoring's model-elevation step and brainstorm approach generation, dispatched as one worker to the roster's `authoring` entry whose model matches the alias the workflow resolved. When no entry matches the alias, or that single dispatch fails, the lead runs the step inline on its own model and prints the transparency line. A Unit the sizing cannot split returns to this same entry as a recorded plan defect for a re-cut. A later revision of that plan, or of the workflow's requirements document, is lead work: the lead edits that one artifact in place.

### Mechanical work
A short, bounded, low-context unit: a scout read, a symbol or file lookup, or a worker step whose approach is fixed and whose acceptance a command settles. It goes to the roster entry that takes the mechanical shape, serving as the default recipient for bounded, low-complexity tasks.

### Launch ceremony
The number of lead tool calls a dispatch costs before the recipient can be given work. It is uniform across the roster so that no recipient requires multi-step setup over another. Each worker terminal serves a single dispatch and is released in the turn its dispatch settles. Ceremony influences which worker a lead selects when multiple entries are eligible, so uneven ceremony distorts routing away from declared policies; maintaining uniform single-command dispatch and explicit routing defaults ensures dispatches follow intended model allocations rather than tooling friction.

### Unproven release
A terminal settlement record for a dispatched worker whose release was retained or unverified and could not be proven to have exited without residual resources.

A coordinator cannot treat an unproven retention as settled, even when the query reports the dispatch inactive, because actions such as typing into a terminal pane trigger retention without indicating a genuine user takeover. When an explicit stop and repeated release still fail to verify process exit, the coordinator records the dispatch as an unproven release and proceeds, leaving the resident terminal for the operator to inspect and close.

## Repository layout

### Source root
The directory the dotfiles manager reads its source state from, configured by a source-root marker at the repository root.

### Repository root
The git top level. Holds repository infrastructure, root markers, and bootstrapping prerequisites.

### Primary checkout
The plain checkout of a project on its default branch, used for default-branch inspection and base sessions. It is also what the dotfiles manager treats as its configured source, so a file that exists only in a Development worktree is invisible to an ordinary apply.

### Development worktree
A worktree holding one feature branch, created and destroyed through the session orchestrator and living in a central directory keyed by an orchestrator-managed name, never by project identity. Branch development happens here; the Primary checkout stays on the default branch.

### Top-level deployment boundary
The line separating repository-only entries at the source root from the ones that deploy into the home directory. A dot-prefixed name falls outside it by construction; every other name is inside it and must be classified, either as deployed or as denied in the source-state ignore file. The boundary is declared as data and checked against what the source state actually renders, so a new entry cannot cross it silently.

### Generated-in-source path
A path written into the source root by a tool rather than by a commit. It is hidden from version control yet still part of the source state, so the source-state ignore file must deny it even though version control already hides it.

## Keyboard lighting

### Direct mode
The state in which the keyboard's own effect engine yields a region's LEDs to a host-supplied buffer. It is entered and left per region, and leaving it restores whatever effect the user had saved — including "off". A host that stops proving it is alive is put back the same way, so a crash and a clean exit reach the same state.

### KEYS region
The 89 LEDs on the key matrix chain. Which firmware indicators reach it is a user setting rather than a fixed property: caps lock, Win-lock, and numlock each paint a key here under settings the user can change and the keyboard remembers, and the keyboard's own indicator pass runs after the host's pixels. A host holding this region cannot see it happen.

### SIDE region
The 12 LEDs on the logo and upper-strip chain — five on the strip, then seven on the logo, each driven by its own effect loop. It is where the keyboard talks to the person: battery level and charging render here and outrank host writes, applied after the host's pixels rather than suppressed by them. Caps lock is the exception — it is ceded to the host while the region is in Direct mode. The RF-link indicator also lives on this chain but reaches it by a different path, so its ordering against host pixels is not settled.

### Layer
One client's contribution to the lighting, held for as long as that client's connection is. Layers are stacked by a declared order and the client above wins a shared LED; a layer names only the LEDs it cares about, so a three-key indicator stays three pixels. Losing the connection removes the layer, which is what keeps a dead client from holding the keyboard.

### Base layer
The bottom Layer, rendered from configuration rather than by any client. It exists because Direct mode is all-or-nothing per region: the moment a host takes a region to paint a few LEDs, the keyboard's own effect stops covering the rest, and the base layer is what stands in for it.

### Heartbeat deadline
The time a host declares, with each heartbeat, before which it will be heard from again. It is carried per heartbeat rather than fixed in firmware, so a status indicator that is silent for hours and an animation pushing frames choose different values without either one reflashing the keyboard.

## External tool releases and overlays

### Held-back pin
The state where the lock job kept the committed compound-engineering entry because the overlay patches do not survive the newly resolved release. The candidate release stays held back until the patches are rebased. The rest of the release lock updates and commits normally.

### Pristine pre-image
The unmodified upstream file extracted by the include-only pristine external. It provides the reference base for verifying pre-images and calculating patch application without modifying tracked archive files.
