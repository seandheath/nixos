{ config, pkgs, ... }:

let
  # Helper to build lua config inline
  lua = code: ''
    lua << EOF
    ${code}
    EOF
  '';
in
{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    withPython3 = true;
    viAlias = true;
    vimAlias = true;

    extraConfig = ''
      " ── General Settings ──────────────────────────────────────────────
      syntax on
      filetype plugin indent on
      set background=dark
      set number
      set relativenumber
      set wildmenu
      set showcmd
      set hlsearch
      set incsearch
      set smartcase
      set ignorecase
      set backspace=indent,eol,start
      set confirm
      set foldlevel=99
      set foldmethod=expr
      set foldexpr=v:lua.vim.treesitter.foldexpr()
      set shiftwidth=2
      set softtabstop=2
      set tabstop=2
      set expandtab
      set scrolloff=8
      set sidescrolloff=8
      set signcolumn=yes
      set termguicolors
      set cursorline
      set splitbelow
      set splitright
      set updatetime=250
      set timeoutlen=400
      set undofile
      set mouse=a
      set clipboard=unnamedplus
      set colorcolumn=80
      set wrap
      set linebreak

      " Leader keys
      let mapleader=" "
      let maplocalleader=","

      " Sudo write
      cmap w!! w !sudo tee > /dev/null %

      " ── Window Navigation ─────────────────────────────────────────────
      nnoremap <C-h> <C-w>h
      nnoremap <C-j> <C-w>j
      nnoremap <C-k> <C-w>k
      nnoremap <C-l> <C-w>l

      " Resize splits
      nnoremap <C-Up> :resize +2<CR>
      nnoremap <C-Down> :resize -2<CR>
      nnoremap <C-Left> :vertical resize -2<CR>
      nnoremap <C-Right> :vertical resize +2<CR>

      " ── Buffer Navigation (Tab-like) ──────────────────────────────────
      nnoremap <S-l> :bnext<CR>
      nnoremap <S-h> :bprevious<CR>
      nnoremap <leader>bd :bdelete<CR>

      " Clear search highlight
      nnoremap <Esc> :nohlsearch<CR>

      " Better indenting (stay in visual mode)
      vnoremap < <gv
      vnoremap > >gv

      " Move lines up/down in visual mode
      vnoremap J :m '>+1<CR>gv=gv
      vnoremap K :m '<-2<CR>gv=gv
    '';

    extraLuaConfig = ''
      -- ── Colorscheme ────────────────────────────────────────────────────
      require("catppuccin").setup({
        flavour = "mocha",
        integrations = {
          cmp = true,
          gitsigns = true,
          neo_tree = true,
          treesitter = true,
          telescope = { enabled = true },
          which_key = true,
          indent_blankline = { enabled = true },
          native_lsp = {
            enabled = true,
            underlines = {
              errors = { "undercurl" },
              hints = { "undercurl" },
              warnings = { "undercurl" },
              information = { "undercurl" },
            },
          },
        },
      })
      vim.cmd.colorscheme("catppuccin")

      -- ── Neo-tree (File Sidebar) ────────────────────────────────────────
      require("neo-tree").setup({
        close_if_last_window = true,
        popup_border_style = "rounded",
        filesystem = {
          follow_current_file = { enabled = true },
          use_libuv_file_watcher = true,
          filtered_items = {
            hide_dotfiles = false,
            hide_gitignored = false,
            hide_by_name = { ".git", "node_modules", "__pycache__", ".venv" },
          },
        },
        window = {
          width = 35,
          mappings = {
            ["<space>"] = "none",
          },
        },
        default_component_configs = {
          git_status = {
            symbols = {
              added     = "✚",
              modified  = "",
              deleted   = "✖",
              renamed   = "󰁕",
              untracked = "",
              ignored   = "",
              unstaged  = "󰄱",
              staged    = "",
              conflict  = "",
            },
          },
        },
      })
      vim.keymap.set("n", "<leader>e", ":Neotree toggle<CR>", { desc = "Toggle file explorer", silent = true })
      vim.keymap.set("n", "<leader>o", ":Neotree focus<CR>", { desc = "Focus file explorer", silent = true })

      -- ── Bufferline (Tabs) ──────────────────────────────────────────────
      require("bufferline").setup({
        options = {
          mode = "buffers",
          diagnostics = "nvim_lsp",
          separator_style = "slant",
          show_buffer_close_icons = true,
          show_close_icon = false,
          always_show_bufferline = true,
          offsets = {
            {
              filetype = "neo-tree",
              text = "File Explorer",
              highlight = "Directory",
              separator = true,
            },
          },
        },
      })

      -- ── Lualine (Statusbar) ────────────────────────────────────────────
      require("lualine").setup({
        options = {
          theme = "catppuccin",
          component_separators = { left = "", right = "" },
          section_separators = { left = "", right = "" },
          globalstatus = true,
        },
        sections = {
          lualine_a = { "mode" },
          lualine_b = { "branch", "diff", "diagnostics" },
          lualine_c = { { "filename", path = 1 } },
          lualine_x = { "encoding", "fileformat", "filetype" },
          lualine_y = { "progress" },
          lualine_z = { "location" },
        },
      })

      -- ── Telescope (Fuzzy Finder) ───────────────────────────────────────
      local telescope = require("telescope")
      local actions = require("telescope.actions")
      telescope.setup({
        defaults = {
          prompt_prefix = "   ",
          selection_caret = " ",
          path_display = { "truncate" },
          mappings = {
            i = {
              ["<C-j>"] = actions.move_selection_next,
              ["<C-k>"] = actions.move_selection_previous,
              ["<Esc>"] = actions.close,
            },
          },
        },
        pickers = {
          find_files = { hidden = true },
          live_grep = { additional_args = function() return { "--hidden" } end },
        },
      })
      telescope.load_extension("fzf")

      -- Telescope keymaps (VSCode-like)
      local builtin = require("telescope.builtin")
      vim.keymap.set("n", "<leader>ff", builtin.find_files, { desc = "Find files" })
      vim.keymap.set("n", "<leader>fg", builtin.live_grep, { desc = "Live grep" })
      vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Find buffers" })
      vim.keymap.set("n", "<leader>fh", builtin.help_tags, { desc = "Help tags" })
      vim.keymap.set("n", "<leader>fr", builtin.oldfiles, { desc = "Recent files" })
      vim.keymap.set("n", "<leader>fs", builtin.lsp_document_symbols, { desc = "Document symbols" })
      vim.keymap.set("n", "<leader>fw", builtin.lsp_workspace_symbols, { desc = "Workspace symbols" })
      vim.keymap.set("n", "<leader>fd", builtin.diagnostics, { desc = "Diagnostics" })
      -- Ctrl+P like VSCode
      vim.keymap.set("n", "<C-p>", builtin.find_files, { desc = "Find files" })

      -- ── Treesitter ─────────────────────────────────────────────────────
      -- Grammars are pre-compiled by Nix via withAllGrammars.
      -- Just enable the built-in Neovim treesitter features directly.
      vim.api.nvim_create_autocmd("FileType", {
        callback = function(args)
          pcall(vim.treesitter.start, args.buf)
        end,
      })

      -- ── LSP Configuration (Neovim 0.11+ native API) ────────────────────
      local capabilities = require("cmp_nvim_lsp").default_capabilities()

      -- Keymaps applied when any LSP attaches to a buffer
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(ev)
          local bufnr = ev.buf
          local map = function(keys, func, desc)
            vim.keymap.set("n", keys, func, { buffer = bufnr, desc = "LSP: " .. desc })
          end

          map("gd", builtin.lsp_definitions, "Go to definition")
          map("gr", builtin.lsp_references, "Go to references")
          map("gi", builtin.lsp_implementations, "Go to implementation")
          map("gy", builtin.lsp_type_definitions, "Go to type definition")
          map("K", vim.lsp.buf.hover, "Hover documentation")
          map("<leader>ca", vim.lsp.buf.code_action, "Code action")
          map("<leader>rn", vim.lsp.buf.rename, "Rename symbol")
          map("<leader>ds", builtin.lsp_document_symbols, "Document symbols")
          map("<leader>ws", builtin.lsp_dynamic_workspace_symbols, "Workspace symbols")
          map("[d", vim.diagnostic.goto_prev, "Previous diagnostic")
          map("]d", vim.diagnostic.goto_next, "Next diagnostic")
          map("<leader>D", vim.diagnostic.open_float, "Show diagnostic")
          map("<leader>f", function() vim.lsp.buf.format({ async = true }) end, "Format buffer")
        end,
      })

      -- Diagnostic display config
      vim.diagnostic.config({
        virtual_text = { prefix = "●", spacing = 4 },
        signs = true,
        underline = true,
        update_in_insert = false,
        float = { border = "rounded", source = "always" },
      })

      -- Language servers — add/remove as needed
      vim.lsp.config("rust_analyzer", {
        capabilities = capabilities,
        settings = {
          ["rust-analyzer"] = {
            checkOnSave = { command = "clippy" },
            cargo = { allFeatures = true },
          },
        },
      })

      vim.lsp.config("pyright", {
        capabilities = capabilities,
      })

      vim.lsp.config("nil_ls", {
        capabilities = capabilities,
        settings = {
          ["nil"] = {
            formatting = { command = { "nixfmt" } },
          },
        },
      })

      vim.lsp.config("lua_ls", {
        capabilities = capabilities,
        settings = {
          Lua = {
            runtime = { version = "LuaJIT" },
            diagnostics = { globals = { "vim" } },
            workspace = { checkThirdParty = false },
            telemetry = { enable = false },
          },
        },
      })

      vim.lsp.config("clangd", {
        capabilities = capabilities,
      })

      vim.lsp.config("bashls", {
        capabilities = capabilities,
      })

      -- Enable all configured servers
      vim.lsp.enable({ "rust_analyzer", "pyright", "nil_ls", "lua_ls", "clangd", "bashls" })

      -- ── nvim-cmp (Autocompletion) ──────────────────────────────────────
      local cmp = require("cmp")
      local luasnip = require("luasnip")
      require("luasnip.loaders.from_vscode").lazy_load()

      cmp.setup({
        snippet = {
          expand = function(args) luasnip.lsp_expand(args.body) end,
        },
        window = {
          completion = cmp.config.window.bordered(),
          documentation = cmp.config.window.bordered(),
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-b>"] = cmp.mapping.scroll_docs(-4),
          ["<C-f>"] = cmp.mapping.scroll_docs(4),
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<C-e>"] = cmp.mapping.abort(),
          ["<CR>"] = cmp.mapping.confirm({ select = true }),
          ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_next_item()
            elseif luasnip.expand_or_jumpable() then
              luasnip.expand_or_jump()
            else
              fallback()
            end
          end, { "i", "s" }),
          ["<S-Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_prev_item()
            elseif luasnip.jumpable(-1) then
              luasnip.jump(-1)
            else
              fallback()
            end
          end, { "i", "s" }),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },
          { name = "luasnip" },
          { name = "path" },
        }, {
          { name = "buffer" },
        }),
      })

      -- ── Gitsigns ───────────────────────────────────────────────────────
      require("gitsigns").setup({
        signs = {
          add          = { text = "│" },
          change       = { text = "│" },
          delete       = { text = "󰍵" },
          topdelete    = { text = "‾" },
          changedelete = { text = "~" },
          untracked    = { text = "┆" },
        },
        on_attach = function(bufnr)
          local gs = package.loaded.gitsigns
          local map = function(mode, l, r, desc)
            vim.keymap.set(mode, l, r, { buffer = bufnr, desc = desc })
          end
          map("n", "]h", gs.next_hunk, "Next git hunk")
          map("n", "[h", gs.prev_hunk, "Previous git hunk")
          map("n", "<leader>gp", gs.preview_hunk, "Preview hunk")
          map("n", "<leader>gb", function() gs.blame_line({ full = true }) end, "Git blame line")
          map("n", "<leader>gB", gs.toggle_current_line_blame, "Toggle line blame")
          map("n", "<leader>gd", gs.diffthis, "Diff this")
          map("n", "<leader>gr", gs.reset_hunk, "Reset hunk")
          map("n", "<leader>gs", gs.stage_hunk, "Stage hunk")
        end,
      })

      -- ── Which-Key ──────────────────────────────────────────────────────
      local wk = require("which-key")
      wk.setup({
        plugins = { spelling = { enabled = true } },
        win = { border = "rounded" },
      })
      wk.add({
        { "<leader>f", group = "Find" },
        { "<leader>g", group = "Git" },
        { "<leader>b", group = "Buffer" },
        { "<leader>c", group = "Code" },
        { "<leader>r", group = "Rename" },
        { "<leader>d", group = "Diagnostics" },
        { "<leader>w", group = "Workspace" },
      })

      -- ── Autopairs ──────────────────────────────────────────────────────
      require("nvim-autopairs").setup({})
      local cmp_autopairs = require("nvim-autopairs.completion.cmp")
      cmp.event:on("confirm_done", cmp_autopairs.on_confirm_done())

      -- ── Comment.nvim ───────────────────────────────────────────────────
      require("Comment").setup()

      -- ── Indent Blankline ───────────────────────────────────────────────
      require("ibl").setup({
        indent = { char = "│" },
        scope = { enabled = true },
      })

      -- ── Surround ──────────────────────────────────────────────────────
      require("nvim-surround").setup({})

      -- ── Todo Comments ──────────────────────────────────────────────────
      require("todo-comments").setup({})
      vim.keymap.set("n", "<leader>ft", ":TodoTelescope<CR>", { desc = "Find TODOs" })

      -- ── Illuminate (highlight word under cursor) ───────────────────────
      require("illuminate").configure({
        delay = 200,
        under_cursor = true,
      })
    '';

    plugins = with pkgs.vimPlugins; [
      # ── Colorscheme ──
      catppuccin-nvim

      # ── File Explorer ──
      neo-tree-nvim
      nvim-web-devicons        # icons for neo-tree, bufferline, lualine, etc.
      nui-nvim                 # UI library (neo-tree dependency)
      plenary-nvim             # Lua utilities (dependency for telescope, neo-tree, gitsigns)

      # ── Tabs & Statusline ──
      bufferline-nvim
      lualine-nvim

      # ── Fuzzy Finder ──
      telescope-nvim
      telescope-fzf-native-nvim

      # ── Treesitter ──
      nvim-treesitter.withAllGrammars

      # ── LSP ──
      nvim-lspconfig

      # ── Autocompletion ──
      nvim-cmp
      cmp-nvim-lsp
      cmp-buffer
      cmp-path
      luasnip
      cmp_luasnip
      friendly-snippets        # VSCode-like snippet collection

      # ── Git ──
      gitsigns-nvim

      # ── Editor Enhancements ──
      which-key-nvim           # keybinding popup
      nvim-autopairs           # auto-close brackets
      comment-nvim             # gcc to toggle comments
      indent-blankline-nvim    # indent guides
      nvim-surround            # surround text objects (replaces surround-nvim)
      todo-comments-nvim       # highlight TODO/FIXME/HACK
      vim-illuminate           # highlight word under cursor

      # ── Language Specific ──
      vim-nix
    ];

    # LSP servers and tools available on PATH
    extraPackages = with pkgs; [
      # LSP servers
      rust-analyzer
      pyright
      nil                      # Nix LSP
      lua-language-server
      clang-tools              # clangd for C/C++
      nodePackages.bash-language-server

      # Formatters
      nixfmt-rfc-style
      stylua
      black
      rustfmt

      # Tools
      ripgrep                  # for telescope live_grep
      fd                       # for telescope find_files
    ];
  };
}
