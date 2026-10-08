# Shared by developer containers; the CI runner has separate credentials and policy.
{ pkgs }:
let
  devices = import ../modules/family/devices.nix;
  sshConfig = pkgs.writeText "agent-gitea-ssh.conf" ''
    Host git.luckyobserver.com hydrogen-forge
      HostName git.luckyobserver.com
      User git
      Port 2222
      IdentityFile /run/gitea-identity.pub
      IdentitiesOnly yes
      UserKnownHostsFile ${./gitea-known-hosts}
      StrictHostKeyChecking yes
  '';
in
''
  sshagent_args=(--add-host=git.luckyobserver.com:${devices.hydrogen.tailAddress}
    -v /run/secrets/development-token:/run/secrets/development-token:ro)
  if [[ -S "''${SSH_AUTH_SOCK:-}" ]]; then
    sshagent_args+=(-v "$SSH_AUTH_SOCK:/run/ssh-agent.sock:ro" -e SSH_AUTH_SOCK=/run/ssh-agent.sock)
    # A public identity selects the right agent key even when many keys are loaded.
    if [[ -f "$HOME/.ssh/personal.pub" ]]; then
      sshagent_args+=(-v "$(readlink -f "$HOME/.ssh/personal.pub"):/run/gitea-identity.pub:ro"
        -e "GIT_SSH_COMMAND=ssh -F ${sshConfig}")
    fi
  fi
''
