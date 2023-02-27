{ config, pkgs, ... }: {
  programs.neovim = {
    enable = true;
    coc.enable = true;
    defaultEditor = true;
    withPython3 = true;
    extraConfig = ''
			syntax on
			filetype plugin on
			filetype indent on
			set background=dark
			set number
			set wildmenu
			set showcmd
			set hlsearch
			set smartcase
			set backspace=indent,eol,start
			set confirm
			set foldlevel=99
			set shiftwidth=2
			set softtabstop=2
			set expandtab
			let mapleader=","
			let maplocalleader="\\"
			set colorcolumn=80
			cmap w!! w !sudo tee > /dev/null %
			colors slate
		'';
    plugins = with pkgs.vimPlugins; [
      statix
      rust-vim
      vim-go
      vim-nix
      nerdtree
      tagbar
      vim-airline
      ctrlp
      easymotion
      rainbow_parentheses
      surround-nvim
    ];
  };
}
