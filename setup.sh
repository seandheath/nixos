sudo mv /etc/nixos/configuration.nix /etc/nixos/$(date -Iseconds)-configuration.nix
sudo ln -s $(pwd)/hosts/$HOSTNAME.nix /etc/nixos/configuration.nix

