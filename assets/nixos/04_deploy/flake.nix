{
  description = "A simple NixOS flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    deploy-rs.url = "github:serokell/deploy-rs";
  };

  outputs = { self, nixpkgs, deploy-rs, ... }@inputs:
  {
    nixosConfigurations.obsidian = nixpkgs.lib.nixosSystem {
      modules = [
        {
          nix.settings.experimental-features = [ "nix-command" "flakes" ];
          nixpkgs.hostPlatform.system = "x86_64-linux";
          system.stateVersion = "25.11";

          users.users.alice = {
            isNormalUser = true;
            initialPassword = "bob";
            openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII7L/RkBxZ06hBAhcOEPAr76P00sEDVhh0bWcvwnkCak mladedav@silver" ];
          };
          nix.settings.trusted-users = [ "root" "@wheel" "alice" ];

          services.getty.autologinUser = "alice";

          security.sudo.extraRules = [
            {
              users = [ "alice" ];
              commands = [
                {
                  command = "ALL";
                  options = [ "NOPASSWD" ];
                }
              ];
            }
          ];

          services.openssh = {
            enable = true;
            ports = [ 22 ];
            settings = {
              AllowUsers = [ "alice" ];
              UseDns = false;
              X11Forwarding = false;
              PermitRootLogin = "no";
            };
          };

          networking.firewall.allowedTCPPorts = [ 22 ];
        }
        {
          virtualisation.vmVariant = {
            virtualisation = {
              memorySize = 2048;
              cores = 2;
              diskSize = 8192;
              graphics = false;
              forwardPorts = [
                {
                  from = "host";
                  host.port = 2222;
                  guest.port = 22;
                }
              ];
            };
          };
        }
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "/dev/disk/by-uuid/00952320-b7db-4025-867a-12a635dbde63";
            fsType = "ext4";
          };
        }
      ];
    };

    deploy = {
      nodes = {
        obsidian-vm = {
          hostname = "127.0.0.1";
          sshOpts = [ "-p" "2222" "-o" "UserKnownHostsFile=/dev/null" "-o" "StrictHostKeyChecking=no" ];
          profiles = {
            system = {
              sshUser = "alice";
              user = "root";
              path =
                deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.obsidian;
            };
          };
        };
      };
    };

    apps.x86_64-linux = rec {
      default = obsidian;
      obsidian = {
        type = "app";
        program = "${self.nixosConfigurations.obsidian.config.system.build.vm}/bin/run-nixos-vm";
      };
    };
  };
}
