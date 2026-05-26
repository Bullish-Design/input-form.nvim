# devenv.nix
#
# Development shell for the tasknotes.nvim fork.
#
# Usage:
#   devenv shell
#   tn-bootstrap      # fetch runtime plugin deps and generate local init.lua
#   tn-open           # open Neovim with this plugin and dev deps loaded
#   tn-smoke          # headless require/setup smoke test
#   tn-test           # run Plenary tests if ./tests exists
#   tn-check          # stylua --check + luacheck
#   tn-format         # stylua formatting
#
# Optional:
#   export TASKNOTES_INPUT_FORM_REPO="owner/input-form.nvim"
#   export TASKNOTES_INPUT_FORM_PATH="../input-form.nvim"
#
# The input-form.nvim source is intentionally configurable because this fork
# may use a private/local input-form.nvim plugin while the TaskNotes refactor is
# still in progress.

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
      unzip
      jq
      ripgrep
      fd
      tree
      just
      shellcheck

      # Neovim runtime
      neovim

      # Lua / Neovim plugin development
      luajit
      luarocks
      lua-language-server
      stylua

      # Useful for plugin docs and generated files
      gnused
      gawk
    ]
    ++ lib.optionals (luaPkgs ? luacheck) [
      luaPkgs.luacheck
    ]
    ++ lib.optionals (luaPkgs ? busted) [
      luaPkgs.busted
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
    NVIM_APPNAME = "tasknotes-dev";
  };

  enterShell = ''
    export TASKNOTES_ROOT="''${TASKNOTES_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    export TASKNOTES_DEV_DIR="$TASKNOTES_ROOT/.devenv/nvim"
    export TASKNOTES_RUNTIME="$TASKNOTES_DEV_DIR/site"
    export TASKNOTES_VAULT="$TASKNOTES_ROOT/.devenv/vault"

    export XDG_CONFIG_HOME="$TASKNOTES_ROOT/.devenv/xdg/config"
    export XDG_DATA_HOME="$TASKNOTES_ROOT/.devenv/xdg/data"
    export XDG_STATE_HOME="$TASKNOTES_ROOT/.devenv/xdg/state"
    export XDG_CACHE_HOME="$TASKNOTES_ROOT/.devenv/xdg/cache"

    mkdir -p "$TASKNOTES_DEV_DIR" "$TASKNOTES_RUNTIME" "$TASKNOTES_VAULT"
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

    echo "tasknotes.nvim dev shell"
    echo "  root:    $TASKNOTES_ROOT"
    echo "  runtime: $TASKNOTES_RUNTIME"
    echo "  vault:   $TASKNOTES_VAULT"
    echo ""
    echo "Commands: tn-bootstrap, tn-open, tn-smoke, tn-test, tn-check, tn-format, tn-clean"
  '';

  scripts."tn-bootstrap".exec = ''
    set -euo pipefail

    tn-deps
    tn-init

    root="''${TASKNOTES_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

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

  scripts."tn-deps".exec = ''
    set -euo pipefail

    root="''${TASKNOTES_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    site="''${TASKNOTES_RUNTIME:-$root/.devenv/nvim/site}"
    pack="$site/pack/tasknotes/start"
    data_root="''${XDG_DATA_HOME:-$root/.devenv/xdg/data}/''${NVIM_APPNAME:-tasknotes-dev}"
    deps_pack="$data_root/site/pack/deps/start"
    lazy_root="$data_root/lazy"

    mkdir -p "$pack"
    mkdir -p "$deps_pack" "$lazy_root"

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

    link_local_plugin() {
      src="$1"
      name="$2"
      dest="$pack/$name"

      if [ ! -d "$src" ]; then
        return 1
      fi

      if [ -e "$dest" ] && [ ! -L "$dest" ]; then
        echo "Warning: $dest already exists and is not a symlink; not replacing it" >&2
        return 0
      fi

      ln -sfn "$(cd "$src" && pwd)" "$dest"
      echo "Linked $name -> $(readlink "$dest")"
    }

    # Required / expected runtime dependencies for tasknotes.nvim.
    clone_or_update "edmundmiller/bases.nvim" "bases.nvim"
    clone_or_update "echasnovski/mini.nvim" "mini.nvim"
    clone_or_update "MunifTanjim/nui.nvim" "nui.nvim"
    clone_or_update "folke/snacks.nvim" "snacks.nvim"

    # Test/dev dependencies.
    clone_or_update "nvim-lua/plenary.nvim" "plenary.nvim"
    clone_or_update "nvim-telescope/telescope.nvim" "telescope.nvim"

    # Optional date-picker backend from DATEPICKER_ADDITION.md.
    clone_or_update "Dzejkop/datepicker.nvim" "datepicker.nvim"

    # Optional input-form dependency.
    #
    # Use one of:
    #   TASKNOTES_INPUT_FORM_PATH=/path/to/input-form.nvim
    #   TASKNOTES_INPUT_FORM_REPO=owner/input-form.nvim
    #
    # If neither is provided, try a sibling checkout first.
    if [ -n "''${TASKNOTES_INPUT_FORM_PATH:-}" ]; then
      link_local_plugin "$TASKNOTES_INPUT_FORM_PATH" "input-form.nvim" || true
    elif [ -d "$root/../input-form.nvim" ]; then
      link_local_plugin "$root/../input-form.nvim" "input-form.nvim" || true
    elif [ -n "''${TASKNOTES_INPUT_FORM_REPO:-}" ]; then
      clone_or_update "$TASKNOTES_INPUT_FORM_REPO" "input-form.nvim"
    else
      echo "Warning: input-form.nvim was not installed." >&2
      echo "Set TASKNOTES_INPUT_FORM_PATH or TASKNOTES_INPUT_FORM_REPO if this fork requires it." >&2
    fi

    # Test harness compatibility:
    # scripts/minimal_init.lua resolves these two paths from stdpath("data").
    ln -sfn "$pack/mini.nvim" "$deps_pack/mini.nvim"
    ln -sfn "$pack/bases.nvim" "$deps_pack/bases.nvim"
    ln -sfn "$pack/mini.nvim" "$lazy_root/mini.nvim"
    ln -sfn "$pack/bases.nvim" "$lazy_root/bases.nvim"

    echo "Dependencies are in: $pack"
  '';

  scripts."tn-init".exec = ''
    set -euo pipefail

    root="''${TASKNOTES_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    dev_dir="''${TASKNOTES_DEV_DIR:-$root/.devenv/nvim}"
    site="''${TASKNOTES_RUNTIME:-$dev_dir/site}"
    vault="''${TASKNOTES_VAULT:-$root/.devenv/vault}"

    mkdir -p "$dev_dir" "$site" "$vault"

    cat > "$dev_dir/init.lua" <<'LUA'
local root = vim.env.TASKNOTES_ROOT or vim.fn.getcwd()
local site = vim.env.TASKNOTES_RUNTIME or (root .. "/.devenv/nvim/site")
local vault = vim.env.TASKNOTES_VAULT or (root .. "/.devenv/vault")

vim.opt.runtimepath:prepend(root)
vim.opt.packpath:prepend(site)

vim.g.mapleader = " "
vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = false
vim.o.hidden = true

-- Keep the development environment isolated from the user's real Neovim state.
vim.env.XDG_CONFIG_HOME = vim.env.XDG_CONFIG_HOME or (root .. "/.devenv/xdg/config")
vim.env.XDG_DATA_HOME = vim.env.XDG_DATA_HOME or (root .. "/.devenv/xdg/data")
vim.env.XDG_STATE_HOME = vim.env.XDG_STATE_HOME or (root .. "/.devenv/xdg/state")
vim.env.XDG_CACHE_HOME = vim.env.XDG_CACHE_HOME or (root .. "/.devenv/xdg/cache")

-- Optional local overrides. Create this file when testing custom settings.
local local_config = root .. "/.devenv/local.lua"
if vim.fn.filereadable(local_config) == 1 then
  dofile(local_config)
end

local ok, tasknotes = pcall(require, "tasknotes")
if ok then
  tasknotes.setup({
    vault_path = vault,

    cache = {
      enabled = true,
      cache_dir = vim.env.XDG_STATE_HOME .. "/tasknotes",
      filename = "cache.json",
      validate_on_startup = true,
      background_validation_delay = 100,
      validation_interval = 30,
    },

    picker = {
      enabled = true,
      backend = "snacks",
      dim_completed = true,
      hide_completed = false,
    },

    ui = {
      border_style = "rounded",
      task_form_width = 80,
      task_form_height = 24,

      -- The fork should prefer input-form when available, but this keeps
      -- the dev shell usable while the input-form migration is incomplete.
      form_backend = "input-form",
      fallback_to_nui = true,

      date_picker = {
        enabled = true,
        backend = "datepicker.nvim",
        fallback_backend = "text",
        format = "%Y-%m-%d",
        week_start = "monday",
        keymaps = {
          open = "<C-d>",
          clear = "<C-x>",
          today = "<C-t>",
        },
      },
    },

    keymaps = {
      browse = "<leader>tb",
      new_task = "<leader>tn",
      edit_task = "<leader>te",
      toggle_timer = "<leader>tt",
      view_selector = "<leader>tv",
    },
  })
else
  vim.notify("Could not require tasknotes from " .. root, vim.log.levels.ERROR)
end
LUA

    echo "Wrote $dev_dir/init.lua"
  '';

  scripts."tn-open".exec = ''
    set -euo pipefail
    tn-init
    tn-deps

    root="''${TASKNOTES_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    dev_dir="''${TASKNOTES_DEV_DIR:-$root/.devenv/nvim}"

    nvim -u "$dev_dir/init.lua" "$@"
  '';

  scripts."tn-smoke".exec = ''
    set -euo pipefail
    tn-init
    tn-deps

    root="''${TASKNOTES_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    dev_dir="''${TASKNOTES_DEV_DIR:-$root/.devenv/nvim}"

    nvim -u "$dev_dir/init.lua" --headless \
      +'lua assert(require("tasknotes"), "tasknotes module did not load")' \
      +'lua print("tasknotes smoke test passed")' \
      +qa
  '';

  scripts."tn-test".exec = ''
    set -euo pipefail
    tn-deps

    root="''${TASKNOTES_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

    if [ -d "$root/tests" ]; then
      nvim --headless --noplugin -u "$root/scripts/minimal_init.lua" \
        -c "lua MiniTest.run()" 2>&1
    else
      echo "No ./tests directory found; running smoke test instead."
      tn-smoke
    fi
  '';

  scripts."tn-check".exec = ''
    set -euo pipefail

    root="''${TASKNOTES_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
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

  scripts."tn-format".exec = ''
    set -euo pipefail

    root="''${TASKNOTES_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
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

  scripts."tn-health".exec = ''
    set -euo pipefail
    tn-init
    tn-deps

    root="''${TASKNOTES_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    dev_dir="''${TASKNOTES_DEV_DIR:-$root/.devenv/nvim}"

    nvim -u "$dev_dir/init.lua" --headless \
      +"checkhealth tasknotes" \
      +"qa"
  '';

  scripts."tn-clean".exec = ''
    set -euo pipefail

    root="''${TASKNOTES_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

    echo "Removing generated Neovim dev runtime under $root/.devenv/nvim"
    rm -rf "$root/.devenv/nvim"

    echo "Keeping $root/.devenv/vault so test tasks are not deleted."
    echo "Remove it manually if you want a fully clean vault."
  '';
}
