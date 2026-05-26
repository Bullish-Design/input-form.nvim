# devenv.nix
#
# Development shell for input-form.nvim.
#
# Usage:
#   devenv shell
#   if-bootstrap      # fetch deps (mini.nvim) and generate local init.lua
#   if-open           # open Neovim with the plugin loaded
#   if-smoke          # headless require/setup smoke test
#   if-test           # run mini.test test suite
#   if-check          # stylua --check + optional luacheck
#   if-format         # stylua formatting
#   if-docs           # regenerate documentation with mini.doc
#   if-clean          # remove generated dev runtime

{ pkgs, lib, ... }:

let
  luaPkgs = pkgs.luajitPackages;
in
{
  packages =
    with pkgs;
    [
      # Core
      git
      curl
      gnumake
      ripgrep
      fd
      tree

      # Neovim runtime
      neovim

      # Lua / Neovim plugin development
      luajit
      luarocks
      lua-language-server
      stylua

      # Useful for docs and generated files
      gnused
      gawk
    ]
    ++ lib.optionals (luaPkgs ? luacheck) [
      luaPkgs.luacheck
    ]
    ++ lib.optionals (pkgs ? selene) [
      pkgs.selene
    ]
    ++ lib.optionals (pkgs ? nil) [
      pkgs.nil
    ]
    ++ lib.optionals (pkgs ? nixfmt-rfc-style) [
      pkgs.nixfmt-rfc-style
    ];

  env = {
    NVIM_APPNAME = "input-form-dev";
  };

  enterShell = ''
    export IF_ROOT="''${IF_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    export IF_DEV_DIR="$IF_ROOT/.devenv/nvim"
    export IF_RUNTIME="$IF_DEV_DIR/site"

    export XDG_CONFIG_HOME="$IF_ROOT/.devenv/xdg/config"
    export XDG_DATA_HOME="$IF_ROOT/.devenv/xdg/data"
    export XDG_STATE_HOME="$IF_ROOT/.devenv/xdg/state"
    export XDG_CACHE_HOME="$IF_ROOT/.devenv/xdg/cache"

    mkdir -p "$IF_DEV_DIR" "$IF_RUNTIME"
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

    echo "input-form.nvim dev shell"
    echo "  root:    $IF_ROOT"
    echo "  runtime: $IF_RUNTIME"
    echo ""
    echo "Commands: if-bootstrap, if-open, if-smoke, if-test, if-check, if-format, if-docs, if-clean"
  '';

  scripts."if-bootstrap".exec = ''
    set -euo pipefail

    if-deps
    if-init

    root="''${IF_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

    if [ ! -f "$root/.luarc.json" ]; then
      cat > "$root/.luarc.json" <<'JSON'
{
  "runtime.version": "LuaJIT",
  "diagnostics.globals": ["vim"],
  "workspace.checkThirdParty": false,
  "telemetry.enable": false
}
JSON
      echo "Created .luarc.json"
    fi

    echo "Bootstrap complete."
  '';

  scripts."if-deps".exec = ''
    set -euo pipefail

    root="''${IF_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    site="''${IF_RUNTIME:-$root/.devenv/nvim/site}"
    pack="$site/pack/input-form/start"

    mkdir -p "$pack"

    clone_or_update() {
      repo="$1"
      name="$2"
      dest="$pack/$name"

      if [ -L "$dest" ]; then
        echo "Skipping symlinked dependency: $name -> $(readlink "$dest")"
        return
      fi

      if [ -d "$dest/.git" ]; then
        echo "Updating $repo"
        git -C "$dest" pull --ff-only || {
          echo "Warning: could not fast-forward $repo; leaving existing checkout in place" >&2
        }
      else
        echo "Cloning $repo"
        git clone --depth 1 "https://github.com/$repo.git" "$dest"
      fi
    }

    # mini.nvim — used for mini.test and mini.doc
    clone_or_update "echasnovski/mini.nvim" "mini.nvim"

    # Also place mini.nvim at deps/ so that the existing Makefile / minimal_init.lua
    # can find it without changes.
    deps_dir="$root/deps"
    if [ ! -d "$deps_dir/mini.nvim" ]; then
      mkdir -p "$deps_dir"
      ln -sfn "$pack/mini.nvim" "$deps_dir/mini.nvim"
      echo "Symlinked deps/mini.nvim -> $pack/mini.nvim"
    fi

    echo "Dependencies are in: $pack"
  '';

  scripts."if-init".exec = ''
    set -euo pipefail

    root="''${IF_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    dev_dir="''${IF_DEV_DIR:-$root/.devenv/nvim}"
    site="''${IF_RUNTIME:-$dev_dir/site}"

    mkdir -p "$dev_dir" "$site"

    cat > "$dev_dir/init.lua" <<'LUA'
local root = vim.env.IF_ROOT or vim.fn.getcwd()
local site = vim.env.IF_RUNTIME or (root .. "/.devenv/nvim/site")

vim.opt.runtimepath:prepend(root)
vim.opt.packpath:prepend(site)

vim.g.mapleader = " "
vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = false
vim.o.hidden = true

-- Keep the dev environment isolated from the user's real Neovim state.
vim.env.XDG_CONFIG_HOME = vim.env.XDG_CONFIG_HOME or (root .. "/.devenv/xdg/config")
vim.env.XDG_DATA_HOME   = vim.env.XDG_DATA_HOME   or (root .. "/.devenv/xdg/data")
vim.env.XDG_STATE_HOME  = vim.env.XDG_STATE_HOME  or (root .. "/.devenv/xdg/state")
vim.env.XDG_CACHE_HOME  = vim.env.XDG_CACHE_HOME  or (root .. "/.devenv/xdg/cache")

-- Optional local overrides. Create this file to test custom settings.
local local_config = root .. "/.devenv/local.lua"
if vim.fn.filereadable(local_config) == 1 then
  dofile(local_config)
end

local ok, input_form = pcall(require, "input-form")
if ok then
  input_form.setup({})
  vim.notify("input-form.nvim loaded from " .. root, vim.log.levels.INFO)
else
  vim.notify("Could not require input-form from " .. root, vim.log.levels.ERROR)
end
LUA

    echo "Wrote $dev_dir/init.lua"
  '';

  scripts."if-open".exec = ''
    set -euo pipefail
    if-init
    if-deps

    root="''${IF_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    dev_dir="''${IF_DEV_DIR:-$root/.devenv/nvim}"

    nvim -u "$dev_dir/init.lua" "$@"
  '';

  scripts."if-smoke".exec = ''
    set -euo pipefail
    if-init
    if-deps

    root="''${IF_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    dev_dir="''${IF_DEV_DIR:-$root/.devenv/nvim}"

    nvim -u "$dev_dir/init.lua" --headless \
      +'lua assert(require("input-form"), "input-form module did not load")' \
      +'lua print("input-form smoke test passed")' \
      +qa
  '';

  scripts."if-test".exec = ''
    set -euo pipefail
    if-deps

    root="''${IF_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

    if [ -d "$root/tests" ]; then
      nvim --headless --noplugin -u "$root/scripts/minimal_init.lua" \
        -c "lua require('mini.test').setup()" \
        -c "lua MiniTest.run({ execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 1 }) } })" 2>&1
    else
      echo "No ./tests directory found; running smoke test instead."
      if-smoke
    fi
  '';

  scripts."if-docs".exec = ''
    set -euo pipefail
    if-deps

    root="''${IF_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

    nvim --headless --noplugin -u "$root/scripts/minimal_init.lua" \
      -c "luafile $root/scripts/docgen.lua" \
      -c "qa!"
  '';

  scripts."if-check".exec = ''
    set -euo pipefail

    root="''${IF_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    cd "$root"

    paths=()
    for d in lua plugin tests; do
      if [ -d "$d" ]; then
        paths+=("$d")
      fi
    done

    if [ "''${#paths[@]}" -eq 0 ]; then
      echo "No lua/plugin/tests paths found."
      exit 0
    fi

    stylua --check "''${paths[@]}"

    if command -v luacheck >/dev/null 2>&1; then
      luacheck "''${paths[@]}" --globals vim
    else
      echo "luacheck not available in this nixpkgs; skipped."
    fi
  '';

  scripts."if-format".exec = ''
    set -euo pipefail

    root="''${IF_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    cd "$root"

    paths=()
    for d in lua plugin tests; do
      if [ -d "$d" ]; then
        paths+=("$d")
      fi
    done

    if [ "''${#paths[@]}" -eq 0 ]; then
      echo "No lua/plugin/tests paths found."
      exit 0
    fi

    stylua "''${paths[@]}"
  '';

  scripts."if-clean".exec = ''
    set -euo pipefail

    root="''${IF_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

    echo "Removing generated Neovim dev runtime under $root/.devenv/nvim"
    rm -rf "$root/.devenv/nvim"

    echo "Removing deps/ symlinks"
    rm -rf "$root/deps"

    echo "Clean complete."
  '';
}
