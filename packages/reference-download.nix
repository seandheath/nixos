{ pkgs }:

pkgs.writeShellApplication {
  name = "reference-download";
  runtimeInputs = with pkgs; [
    coreutils
    curl
    file
    gawk
    poppler-utils
  ];
  text = builtins.readFile ../skills/datasheet-reference/scripts/reference-download;
}
