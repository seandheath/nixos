{ config, pkgs, ... }: {

  home.packages = with pkgs; [
    fzf
  ];

  # BASH
  programs.bash = {
    enable = true;
    initExtra = ''
      # PATH
      export PATH="$HOME/.local/bin:$PATH"

      # Environment Variables
      export GEMINI_API_KEY="$(cat ${config.sops.secrets.gemini-api-key.path})"
      export GITLAB_TOKEN="$(cat ${config.sops.secrets.gitlab-token.path})"
      export GITLAB_USERNAME="$(cat ${config.sops.secrets.gitlab-username.path})"
      
      # ALIASES
      alias ns="nix search nixpkgs"
      alias dmesg="dmesg --color=always"

      # FUNCTIONS
      new-project() {
        local name="''${1:?usage: new-project <project-name>}"
        mkdir -p "$name" && cd "$name" && nix flake init -t github:seandheath/llm-devcontainer --refresh
        sed -i "s/projectName = \"my-project\"/projectName = \"$name\"/" flake.nix
        nix run github:seandheath/llm-devcontainer#build --refresh
        nix build .#shell .#claude --no-link
      }

      srmd() {
          local dir="$1"
          
          if [[ -z "$dir" ]]; then
              echo "Usage: srm_dir <directory>"
              return 1
          fi
          
          if [[ ! -d "$dir" ]]; then
              echo "Error: $dir is not a directory"
              return 1
          fi
          
          # Confirmation prompt
          read -p "Recursively deleting all files in $dir - are you sure? [y/N]: " -n 1 -r
          echo
          if [[ ! $REPLY =~ ^[Yy]$ ]]; then
              echo "Aborted."
              return 0
          fi
          
          echo "Securely deleting all files in $dir..."
          
          # Securely delete all files in parallel (auto-detect cores)
          find "$dir" -type f -print0 | parallel -0 --bar srm {}
          
          # Remove empty directories bottom-up, then the parent
          echo "Removing directory structure..."
          srm -rf "$dir"
      }
      
      claude-container() {
        local image="claude-sandbox:latest"
        local project="$(basename "$(pwd)")"

        # Build image if missing
        if ! podman image inspect "$image" &>/dev/null; then
          claude-container-update
        fi

        podman run --rm -it \
          --userns=keep-id \
          -e HOME=/home/developer \
          -e TERM=xterm-256color \
          -e COLORTERM=truecolor \
          --network=host \
          --cap-drop=ALL \
          --security-opt=no-new-privileges \
          -w "/''${project}" \
          -v "$(pwd):/''${project}:rw" \
          -v "claude-nix-''${project}:/nix:rw" \
          -v "claude-home-''${project}:/home/developer:rw" \
          --tmpfs=/tmp:rw,exec,size=2g \
          "$image" \
          bash -c '. /home/developer/.nix-profile/etc/profile.d/nix.sh && nix develop -L --command claude --dangerously-skip-permissions "$@"' _ "$@"
      }

      claude-container-update() {
        local image="claude-sandbox:latest"
        podman rmi -f "$image" 2>/dev/null
        podman build --no-cache -t "$image" -f - . <<'CONTAINERFILE'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates git xz-utils ncurses-term && \
    rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash -u 1000 developer
RUN mkdir -m 0755 /nix && chown developer /nix
USER developer
RUN curl -L https://nixos.org/nix/install | sh -s -- --no-daemon
RUN mkdir -p ~/.config/nix && printf 'sandbox = false\nexperimental-features = nix-command flakes\n' > ~/.config/nix/nix.conf
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/developer/.local/bin:/home/developer/.nix-profile/bin:$PATH"
CONTAINERFILE
      }

      nr() {
        local target_host
        if [[ "$HOSTNAME" == "nixos" ]]; then
          target_host=$(ls -1 /home/sheath/nixos/hosts | sed 's/\.nix$//' | fzf)
        else
          target_host=$HOSTNAME
        fi
        if [[ -n "$target_host" ]]; then
          nix flake update --flake /home/sheath/nixos && \
          sudo nixos-rebuild switch --no-write-lock-file --flake /home/sheath/nixos#"$target_host"
        fi
      }
      
      nb() {
        local target_host
        if [[ "$HOSTNAME" == "nixos" ]]; then
          target_host=$(ls -1 /home/sheath/nixos/hosts | sed 's/\.nix$//' | fzf)
        else
          target_host=$HOSTNAME
        fi
        if [[ -n "$target_host" ]]; then
          nix flake update --flake /home/sheath/nixos && \
          sudo nixos-rebuild boot --no-write-lock-file --flake /home/sheath/nixos#"$target_host"
        fi
      }
      
      bind 'set show-all-if-ambiguous on'
      bind 'TAB:menu-complete'
      bind 'set menu-complete-display-prefix on'

      export XZ_DEFAULTS='-T0 -9'
      export EDITOR=nvim

      # FZF
      if command -v fzf-share >/dev/null; then
        source "$(fzf-share)/key-bindings.bash"
        source "$(fzf-share)/completion.bash"
      fi
      export FZF_DEFAULT_OPTS='--border --info=default'
      _fzf_comprun() {
        local command=$1
        shift

        case "$command" in
          cd) fzf "$@" --preview 'tree -C {} | head -200' ;;
          cat) fzf "$@" --preview 'bat --style=numbers --color=always --line-range :500 {}' ;; 
          nvim) fzf "$@" --preview 'bat --style=numbers --color=always --line-range :500 {}' ;; 
          *) fzf "$@" ;;
        esac
      }

      # Prompt
      BLACK='\e[0;30m'        # Black
      RED='\e[0;31m'          # Red
      GREEN='\e[0;32m'        # Green
      YELLOW='\e[0;33m'       # Yellow
      BLUE='\e[0;34m'         # Blue
      PURPLE='\e[0;35m'       # Purple
      CYAN='\e[0;36m'         # Cyan
      WHITE='\e[0;37m'        # White

      # Free games claimer
      alias checkgames="podman run --rm -it -p 6080:6080 -v fgc:/fgc/data --pull=always ghcr.io/vogler/free-games-claimer bash -c 'node prime-gaming; node gog'"

      # get current status of git repo
      function nonzero_return() {
        RETVAL=$?
        [ $RETVAL -ne 0 ] && echo " $RED[$RETVAL] "
      }

      # get current branch in git repo
      function parse_git_branch() {
        BRANCH=`git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/\1/'`
        if [ ! "$BRANCH" == "" ]
        then
          STAT=`parse_git_dirty`
          echo -e " [$BRANCH$STAT]"
        else
          echo ""
        fi
      }

      # get current status of git repo
      function parse_git_dirty {
        status=`git status 2>&1 | tee`
        dirty=`echo -n "$status" 2> /dev/null | grep "modified:" &> /dev/null; echo "$?"`
        untracked=`echo -n "$status" 2> /dev/null | grep "Untracked files" &> /dev/null; echo "$?"`
        ahead=`echo -n "$status" 2> /dev/null | grep "Your branch is ahead of" &> /dev/null; echo "$?"`
        newfile=`echo -n "$status" 2> /dev/null | grep "new file:" &> /dev/null; echo "$?"`
        renamed=`echo -n "$status" 2> /dev/null | grep "renamed:" &> /dev/null; echo "$?"`
        deleted=`echo -n "$status" 2> /dev/null | grep "deleted:" &> /dev/null; echo "$?"`
        bits=""
        if [ "$renamed" == "0" ]; then
          bits=">$bits"
        fi
        if [ "$ahead" == "0" ]; then
          bits="*$bits"
        fi
        if [ "$newfile" == "0" ]; then
          bits="+$bits"
        fi
        if [ "$untracked" == "0" ]; then
          bits="?$bits"
        fi
        if [ "$deleted" == "0" ]; then
          bits="x$bits"
        fi
        if [ "$dirty" == "0" ]; then
          bits="!$bits"
        fi
        if [ ! "$bits" == "" ]; then
          echo -e " \001$RED\002$bits\001$PURPLE\002"
        else
          echo ""
        fi
      }

      export PS1="\n\[$GREEN\]\u\[$RED\]|\[$WHITE\]\h\[$RED\]|\[$GREEN\]\w\[$PURPLE\]\$(parse_git_branch)\[$RED\]\$(nonzero_return)\[$WHITE\]> "

      # Direnv
      #eval "$(direnv hook bash)"
    '';
  };
}
