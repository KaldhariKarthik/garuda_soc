"""Python 3.12 removed the `imp` module; riscv-dv pygen (pinned) still does
`from imp import reload`. This shim keeps the pinned checkout unmodified."""
from importlib import reload  # noqa: F401
