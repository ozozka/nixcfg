return {
  cmd = {
    "sh",
    "-c",
    [[
      if [ -f uv.lock ] && grep -q 'name = "ty"' uv.lock; then
        exec uv run ty server
      else
        exec ty server
      fi
    ]],
  },
  filetypes = { "python" },
  root_markers = {
    "ty.toml",
    "pyproject.toml",
    "setup.py",
    "setup.cfg",
    "requirements.txt",
    ".git",
  },
}
