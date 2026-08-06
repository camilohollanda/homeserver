# Conventions

## Language

**Everything committed to this repository is written in English.** That covers:

- Code comments (`#`, `--`, `//`) in shell, Terraform, YAML, SQL
- Commit messages
- Documentation: `README.md`, `AGENTS.md`, and anything else tracked in git

Conversation with the maintainer happens in Portuguese; the repository does
not. Do not mirror the language of the request into the artifact.

`docs/superpowers/` is gitignored — specs and plans that live there are working
notes, not repository content, and may be written in Portuguese.

## Repo orientation

See `AGENTS.md` for the VM inventory, the bootstrap script convention, the
domain/TLS layout, and the rules for adding services to the shared VMs.
