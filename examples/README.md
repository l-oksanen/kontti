# Examples

Two projects that bootstrap themselves in the container from what they
declare, with the elan and uv of the image:

- `hello-lean`: `lean-toolchain` names the Lean version, which elan
  installs into `~/.elan` of the home at the first build.

  ```sh
  lake build && lake exe hello-lean
  ```

- `hello-python`: `requires-python` (and `.python-version`) names the
  Python, which uv installs into the home; `uv sync` makes the venv in
  the project.

  ```sh
  uv sync && uv run hello-python
  ```

Copy one into the home (e.g. `~/claude/work/`), and run the commands in
it with `kontti shell`, or ask Claude Code (`kontti claude`) to.
