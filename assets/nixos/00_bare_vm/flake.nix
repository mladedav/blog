{
  description = "A simple NixOS flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }@inputs:
  {
    nixosConfigurations.obsidian = nixpkgs.lib.nixosSystem {
      modules = [
        {
          nix.settings.experimental-features = [ "nix-command" "flakes" ];
          nixpkgs.hostPlatform.system = "x86_64-linux";
          system.stateVersion = "25.11";
        }
        {
          virtualisation.vmVariant = {
            virtualisation = {
              memorySize = 2048;
              cores = 2;
              diskSize = 8192;
              graphics = false;
            };
          };
        }
      ];
    };
  };
}
