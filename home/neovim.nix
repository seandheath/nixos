{ config, pkgs, ... }: {
	programs.neovim = {
		enable = true;
		coc.enable = true;
		defaultEditor = true;
		withPython3 = true;
		plugins = with pkgs.vimPlugins; [
			statix
			rust-vim
			vim-go
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
