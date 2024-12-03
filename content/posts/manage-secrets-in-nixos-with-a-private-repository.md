---
title: 'Manage Secrets in NixOS with a Private Repository'
date: 2024-12-02
draft: false
summary: Hide encrypted secrets and other configuration in a private repository.
---

I have been using NixOS for about a year now and have a few notes and things I solved along the way. Sometimes it took a while to figure out how things work and I always wanted to start a blog, so here we are.

This post will not be an introduction to NixOS. There are already lots of online resources explaining this better than I ever could. For those unfamiliar, NixOS is a Linux distribution that allows you to declaratively define your whole system configuration. Think of it like Ansible or Puppet, but built into the system. This makes the entire system reproducible and allows managing it in Git. Since I am a big fan of open source, of course I also have [my whole system configuration on Github](https://github.com/LorenzBischof/dotfiles). A big part of NixOS is the ability to learn from other configurations and maybe even copy-paste some parts of it.

However having my whole system configuration on Github also has some issues. I would prefer some things to stay private. The script that encrypts and stores a backup of my data in the cloud requires access to a password. The automatic Letsencrypt renewal does DNS validation and is allowed to create DNS entries in my Cloudflare account. There are lots of secrets that I cannot publish publicly on Github.

Of course other smart people have thought about this and there are ways to encrypt these secrets. Tools like agenix or sops-nix exist and work well. However I am a bit paranoid and do not like the idea of sharing my ciphertext for the whole world to see (and crack).

My solution to this problem involves maintaining two repositories:

- A public repository with my main NixOS configuration
- A private repository containing encrypted secrets

Even though the repository is private, we still have to encrypt our secrets. There are two main reasons for this:
- The private repository could get compromised
- When NixOS activates the configuration, it is loaded into the Nix store and everything in the Nix store is readable by any user on the system. If we encrypt the secrets, only the ciphertext is in the Nix store and the secrets are then decrypted at runtime and only made available to specific users.

If you fully trust the encryption, you might ask why we need a private repository. The problem is that only certain attributes of the configuration can be encrypted. Because of the way the Nix store works, it is impossible to encrypt string values. The secret itself must be inside an encrypted file and the configuration attributes must support loading the value from a file.

Usually there is other sensitive configuration on a system that are not explicitly secrets. Maybe we have a private email address or an editor snippet that expands to our home address. I use Syncthing which assigns an identifier to every connected device. Even though this identifier could be public I do not feel comfortable sharing it. These are not secrets and cannot be encrypted

The following will describe how I use a private Git repository to store encrypted secrets and hide unencrypted sensitive configuration.

## Implementation

It all starts with a Flake input. It is important to note that Flakes are still an experimental feature. It would be entirely possible to solve this without using Flakes.

```nix
{
    inputs = {
        nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
        nix-secrets.url = "github:lorenzbischof/nix-secrets";
    };
}
```

Because the repository is private, we need to configure access. For this I use a Github personal access token. I found the relevant documentation on [Github](https://github.blog/changelog/2022-10-18-introducing-fine-grained-personal-access-tokens/) and in the [Nix manual](https://nix.dev/manual/nix/stable/command-ref/conf-file#conf-access-tokens).

The personal access token is manually configured in `~/.config/nix/nix.conf`:
```
access-tokens = github.com=github_pat_xxx
```

Of course you have to create the private Git repository and a new flake. If you decided to use Agenix, check the [documentation](https://github.com/ryantm/agenix#install-via-flakes). I will not go into any detail regarding Agenix here. You can use any secret management tool available.

```nix
{
    inputs = {
        nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
        agenix = {
            url = "github:ryantm/agenix";
            inputs.nixpkgs.follows = "nixpkgs";
            inputs.darwin.follows = "";
        };
    };

    outputs = { self, nixpkgs, agenix }:
    let
        system = "x86_64-linux";
        pkgs = import nixpkgs { inherit system; };
    in
    {
    nixosModules.nas = { config, pkgs, lib, ... }:
        {
            imports = [
                agenix.nixosModules.default
            ];
            environment.systemPackages = [ agenix.packages.x86_64-linux.default ];

            age.secrets.offline-backup-password.file = ./secrets/offline-backup-password.age;

            age.secrets.paperless-password = {
                file = ./secrets/paperless-password.age;
                owner = "paperless";
            };

            age.identityPaths = [
                "/etc/ssh/ssh_host_ed25519_key"
            ];
        };
    };
}

```

Then simply import the NixOS module in your public configuration:
```nix
nas = nixpkgs.lib.nixosSystem {
  inherit system pkgs;
  modules = [
    ./hosts/nas/configuration.nix
    inputs.nix-secrets.nixosModules.nas
  ];
};
```

The secrets are now accessible at specific paths on the filesystem. The paths can be referenced in the configuration:
```nix
config.age.secrets.offline-backup-password.path
```

You might have noticed that we have a NixOS module in our private configuration. You are free to put any combination of NixOS configuration either in your private or public repository and when deploying everything will be merged together.

For example lets say we are configuring SSH in our public repository:
```nix
programs.ssh = {
    enable = true;
    matchBlocks = {
        "*" = {
            identitiesOnly = true;
        };
        "scanner" = {
            hostname = "192.168.0.157";
            user = "pi";
            identityFile = "~/.ssh/id_ed25519_sk_rk_homelab";
        };
    };
};
```
Then you can add any sensitive configuration to the private repository:
```nix
programs.ssh.matchBlocks."secret-server" = {
    hostname = "long-super-secret-hostname";
    user = "ec2-user";
};
```

Even though this works and everything is merged together it can get quite confusing, if we only want to hide certain values. In the above example the public is completely oblivious of the additional `matchBlock` entry and everything makes sense. However in some cases we might have a configuration where we want to hide only a single attribute in our public configuration. Technically this is not an issue, but then it would look like we forgot to set it.

I propose a new file named `default.nix` in the root of your private repository.

```nix
{
    secret-server-hostname = "long-super-secret-hostname";
}
```

Did you notice above, how we `import nixpkgs`? The [Nix manual](https://nix.dev/manual/nix/2.18/command-ref/new-cli/nix3-flake.html#flake-format) explains why this works:

> In addition to the outputs of each input, each input in inputs also contains some metadata about the inputs. These are:
> - `outPath`: The path in the Nix store of the flake's source tree. This way, the attribute set can be passed to `import` as if it was a path, as in the example above (`import nixpkgs`).

That might be a bit confusing. To see this a bit more clearly, run `nix repl`, load the flake with `:lf .` and check `inputs.nix-secrets`.

We can use this feature to load our own variables from `default.nix` and use them in our configuration:
```nix
nas = nixpkgs.lib.nixosSystem {
  inherit system pkgs;
  modules = [
    ./hosts/nas/configuration.nix
    nix-secrets.nixosModules.nas
  ];
  specialArgs = {
    secrets = import nix-secrets;
  };
};

```
Now add `secrets` to the module arguments in the `configuration.nix` file and use the variables with `secrets.secret-server-hostname`.

## Updating

Every time you make a change in the private repository, you must commit and push it to Git and then run `nix flake update nix-secrets` to update the lock file in your public repository. This can get quite tedious, especially when developing and testing new features.

When testing locally it is possible to override the input and temporarily reference the local directory:
```bash
sudo nixos-rebuild switch --flake . --override-input nix-secrets ../nix-secrets
```

## Conclusion

This setup allows me to have all my secrets and sensitive configuration hidden in a private Git repository. Secrets are additionally encrypted so that they are not lying around on the internet (in case the repository is compromised) and also not copied into the Nix store.

It has worked well for me and I can recommend it to anyone that has their NixOS configuration on Github and is unsure about how to handle secrets.
