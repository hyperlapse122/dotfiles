# Files under /etc that a non-NixOS host's distribution owns and the system
# layer must never write, relative to /etc as environment.etc keys are.
[
  "passwd"
  "group"
  "shadow"
  "gshadow"
  "subuid"
  "subgid"
  "shells"
]
