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

### Position-independent script rendering
The technique of decoupling an onchange script's rendered body from the invoking checkout's absolute path. Instead of interpolating the dotfiles source directory at render time, the script resolves its source root at runtime from the manager's exported environment variable with an active source-path fallback. This ensures the rendered script text is bit-identical across worktrees, preventing false-positive execution cascades when applying from feature branches.

### Dependency fingerprint
A comment block that lists each of a script's declared dependencies with a hash of its content, so that changing a dependency changes the script's rendered text and re-triggers it. It exists because the dotfiles manager re-runs an onchange script on rendered-content change alone and has no other notion of a dependency. Hashing covers file content and declared capability probe tokens; template dependencies are hashed as raw text, so no secret enters a fingerprint.

### Host gate
An expression over host facts that scopes a manifest entry to the machines it applies to. The same grammar, negation included, scopes an install override and a retirement — which is what keeps a path from being installed under one gate and deleted under its negation on the same run.

### Declared hardware fact
A host fact whose truth comes from a committed table of verified device identities rather than from probing what the hardware can do. It exists for hardware the system exposes no generic signal for, such as a fingerprint reader or an infrared camera, and it fails safe: a device nobody has listed enables nothing.

### Declared skip
The contract by which an onchange script leaves early: it names the site and the direction of the skip, so a machine that did not converge is never recorded as one that did. Directions distinguish a condition the host will never satisfy, a precondition a later run will supply, a precondition that only an operator can clear, and a step that is already done; a completed interactive step the script cannot perform, such as enrolling a face, is reported through the same surface.

### Derived authselect profile
A Fedora authentication profile this repository builds from the stock one to carry a factor the stock profiles have no feature for. Every file tracks the base except the stack that gains the factor, and the profile is selected with the machine's existing features plus the new one, so the distribution's tool still writes every PAM file and no script writes one directly.

### Greeter guard
The predicate that keeps the login greeter password-only whenever a factor is added: it resolves the greeter's authentication stack against the profile as it would be rendered and withholds the factor when the module would reach it. It fails closed on an unrecognized display manager or an unresolvable stack. Factors are placed in the shared privilege stack, which the greeter and the desktop lock screen do not include, because a face factor in a stack the lock screen starts on lock would unlock the screen for whoever locked it.

### Retired path
An absolute system path declared for removal so that every machine deletes the orphan on its next run, including one that only pulls the commit that removed the source file. Retirement is declared in the same commit that deletes the file; a retirement may carry a Host gate or a distro scope so it never deletes a native or user-owned file elsewhere.

### Elevation ladder
The ordered resolution of how a privileged script obtains root: already root, a non-prompting sudo, a sudo that can prompt on a terminal, or a sudo that prompts through a desktop askpass helper. The ladder fails loudly when no rung succeeds, rather than handing a script a privilege it cannot honour. The askpass rung is distro-shaped and is inert where its helper is not installed.

## Agent orchestration

### Session role
The classification a session resolves for itself at start — `lead`, `worker`, or `none` — which decides how much of the orchestration rule set it receives. It is read from the Orca terminal handle and the leader pane, and an unset value and an empty string mean the same thing at every step, because a bare equality test between two empty values would classify every teammate as the lead.

### Everyone payload
The orchestration rules that bind every agent whatever its role. Every Orca-managed session receives it. Claude Code and Codex receive it at session start. omp receives it through its native extension before each model call, using the current role.

### Coordinator payload
The additional rules only a session that can dispatch is able to act on. It is delivered on top of the Everyone payload, and only to a lead.

### Lead envelope
The single composed delivery a lead receives through its hook or native extension: the authority preamble, the orchestration skill text, the version-matched guide read from the installed CLI, the Everyone payload, and the Coordinator payload. Delivery is atomic — a lead envelope missing any half is not delivered at all, because a partial rule set is worse than none.

### Brief file
The file a dispatch names by path to carry context the dispatch spec itself cannot hold. A spec travels as an argv string, so context large enough to exceed the kernel argument limit is written to a brief instead of inlined. It is also where a coordinator materializes content only it can reach, such as facts extracted from an MCP the recipient has no access to.

### Brief defect
A worker escalation or failure caused by context missing from its brief rather than by the difficulty of the work. It carries no information about the unit's blast radius or judgment depth, so it never raises the model rung; the coordinator repairs the brief and re-dispatches at the same rung.

### Model roster
The single declaration in `.chezmoidata/agents.yaml` of two things: one lead pin per agent that can run as the orchestrator, and every worker entry a lead may dispatch to. A worker entry carries agent, model id, effort or thinking level, the work shapes it takes, brief guidance for that model, and a `rung` (`sonnet` or `opus`) for the two Claude implementation entries; a lead pin carries only the model and, where the harness takes one, its effort. The two halves are independent — a model that a lead session opens on need not be a dispatch target, and removing it from the worker list does not change what a direct session runs. The rendered payloads, instruction files, prose, and tests derive their model ids from it, so no other file names a model by hand.

### Judgment work
Work whose deliverable is the judgment itself: a code review, a document review, a `ce-pov` verdict, brainstorm approach generation, or the model-elevation step of plan authoring. It is dispatched to the roster's frontier judgment entries and never performed by the lead in place; the elevation step goes to the single judgment entry whose model matches the resolved elevation alias; when no entry matches the alias or that single dispatch fails, the lead runs the step inline on its own model and prints the transparency line.

### Mechanical work
A short, bounded, low-context unit: a scout read, a symbol or file lookup, or a worker step whose approach is fixed and whose acceptance a command settles. It goes to the roster's cheapest entry.

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
The 12 LEDs on the logo and upper-strip chain — five on the strip, then seven on the logo, each driven by its own effect loop. It is where the keyboard talks to the person: battery level and charging render here and outrank host writes, applied after the host's pixels rather than suppressed by them. Caps lock is the exception — it is ceded to the host while the region is in Direct mode. The RF-link indicator also lives on this chain but reaches it by a different path, so its ordering against host pixels is not settled.

### Layer
One client's contribution to the lighting, held for as long as that client's connection is. Layers are stacked by a declared order and the client above wins a shared LED; a layer names only the LEDs it cares about, so a three-key indicator stays three pixels. Losing the connection removes the layer, which is what keeps a dead client from holding the keyboard.

### Base layer
The bottom Layer, rendered from configuration rather than by any client. It exists because Direct mode is all-or-nothing per region: the moment a host takes a region to paint a few LEDs, the keyboard's own effect stops covering the rest, and the base layer is what stands in for it.

### Heartbeat deadline
The time a host declares, with each heartbeat, before which it will be heard from again. It is carried per heartbeat rather than fixed in firmware, so a status indicator that is silent for hours and an animation pushing frames choose different values without either one reflashing the keyboard.
