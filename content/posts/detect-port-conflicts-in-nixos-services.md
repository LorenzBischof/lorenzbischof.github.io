---
title: 'Detect Port Conflicts in NixOS Services'
date: 2025-03-12
draft: false
summary: 'Some NixOS services have conflicting default ports. With a little Nix code, we can detect these conflicts in the evaluation phase.'
---

NixOS is great for experimenting. The entire system can be declaratively defined and it is very easy to activate and try out new services. The following snippet is enough to activate Open-Webui and expose it via reverse proxy:

```nix
services.open-webui.enable = true;

services.nginx.virtualHosts."chat.${domain}" = {
  forceSSL = true;
  useACMEHost = domain;
  locations."/" = {
    proxyPass = "http://127.0.0.1:${toString config.services.open-webui.port}";
    proxyWebsockets = true;
  };
};
```

However, if the requested port happens to already be listening, the Systemd service will silently fail. For some reason the `nixos-rebuild switch` command also does not report the failure:
```
starting the following units: open-webui.service
```
This results in Nginx silently routing traffic to the wrong service.

As you might have noticed above, the port can be set with `services.open-webui.port`. Of course it is possible to manually change the port while ensuring that it is unique, but then I would have nothing to write about. 

## Exploring Solutions

The first idea I had was to add monitoring and check for failing Systemd services. It would also be possible to write a NixOS integration test, which starts a virtual machine and checks the Systemd service status. However this seems to be the wrong approach for something that is already known at evaluation time. It would also take quite a while until the error is shown.

The second approach I thought about was to add a function `services.open-webui.port = randomNonconflictingPort`. However I am still new to Nix and could not figure out how to keep a running tally of all the generated ports to check for conflicts.

The next approach I took is to implement an attribute set with the port as a key. Since the key must be unique, we correctly receive an error if two services are using the same port. The implementation is as follows:

```nix
options = {
  homelab.ports = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "Map of allocated port numbers to service names";
  };
};
```

Now create a new file (e.g. `open-webui.nix`), configure the service and add the following:
```nix
homelab.ports.${toString config.services.open-webui.port} = "open-webui";
```

Repeat for every additional service:
```nix
homelab.ports."8080" = "another-service";
```

Now open the Nix repl and check the value:
```nix
nix-repl> outputs.nixosConfigurations.nas.config.homelab.ports

error: The option `homelab.ports."8080"' has conflicting definition values:
- In `/nix/store/8whnbhx7cvad1xh8gdjlcgzk98al9npl-source/hosts/nas/open-webui.nix': "open-webui"
- In `/nix/store/8whnbhx7cvad1xh8gdjlcgzk98al9npl-source/hosts/nas/another-service.nix': "another-service"
```

We get an error since Open-WebUI listens on port 8080 by default and we cannot assign two different strings to `homelab.ports."8080"`. This is exactly the behavior we want.

However I quickly realized that the error only appears in the Nix repl and not when deploying. The reason for this is that Nix is lazy and only evaluates configuration that is referenced somewhere. Since none of our code uses `homelab.ports` the evaluation is skipped.

To workaround this problem, we could write the content to a file:
```nix
environment.etc."workaround".text = builtins.toJSON config.homelab.ports;
```

However, this feels hacky and I do not like having to explicitly specify the service name.

After looking around in the Nix repl a bit more, I found this:
```nix
nix-repl> :p outputs.nixosConfigurations.nas.options.homelab.ports.definitionsWithLocations
[
  {
    file = "/nix/store/bvx2naraks5nfd7mml3rxf7197d49ss9-source/hosts/nas/open-webui.nix";
    value = { "8080" = "open-webui"; };
  }
  {
    file = "/nix/store/bvx2naraks5nfd7mml3rxf7197d49ss9-source/hosts/nas/another-service.nix";
    value = { "8080" = "another-service"; };
  }
  {
    file = "/nix/store/bvx2naraks5nfd7mml3rxf7197d49ss9-source/hosts/nas/vaultwarden.nix";
    value = { "8222" = "vaultwarden"; };
  }
]
```

Since we now have the filename where a value was defined we can simplify the option and use a list:
```nix
homelab.ports = lib.mkOption {
  type = lib.types.listOf lib.types.int;
  default = [ ];
  description = "List of allocated port numbers";
};
```
Now we can use `homelab.ports = [ config.services.open-webui.port ]`, which results in the following data structure:
```nix
nix-repl> :p outputs.nixosConfigurations.nas.options.homelab.ports.definitionsWithLocations  
[
  {
    file = "/nix/store/bvx2naraks5nfd7mml3rxf7197d49ss9-source/hosts/nas/open-webui.nix";
    value = [ 8080 ];
  }
  {
    file = "/nix/store/bvx2naraks5nfd7mml3rxf7197d49ss9-source/hosts/nas/another-service.nix";
    value = [ 8080 ];
  }
  {
    file = "/nix/store/bvx2naraks5nfd7mml3rxf7197d49ss9-source/hosts/nas/vaultwarden.nix";
    value = [ 8222 ];
  }
]
```

To get duplicate ports we first group by the port number and then filter by groups with more than one entries:
```nix
# Group entries by port
groupedByPort = lib.groupBy (entry: toString entry.value) options.homelab.ports.definitionsWithLocations;

# Find ports that appear more than once
duplicateEntries = lib.filterAttrs (port: entries: builtins.length entries > 1) groupedByPort;
```

This gives us a list of conflicting ports and their respective files:
```nix
nix-repl> :p duplicateEntries
{
  "8080" = [
    {
      file = "/nix/store/bh57lav832l2a3j98c8qwhpmx3k2gziq-source/hosts/nas/open-webui.nix";
      value = [ 8080 ];
    }
    {
      file = "/nix/store/bh57lav832l2a3j98c8qwhpmx3k2gziq-source/hosts/nas/another-service.nix";
      value = [ 8080 ];
    }
  ];
}
```

The following code does the error formatting:
```nix
formatDuplicateError =
  port: entries:
  "Duplicate port ${port} found in:\n" + lib.concatMapStrings (entry: "  - ${entry.file}\n") entries;

duplicateErrors = lib.mapAttrsToList formatDuplicateError duplicateEntries;

errorMsg = lib.concatStrings duplicateErrors;
```

We can use these values for an assertion:
```nix
assertions = [
  {
    assertion = duplicateErrors == [ ];
    message = errorMsg;
  }
];
```

Now an error is thrown when switching our configuration:
```nix
error:
Failed assertions:
- Duplicate port 8080 found in:
  - /nix/store/bh57lav832l2a3j98c8qwhpmx3k2gziq-source/hosts/nas/open-webui.nix
  - /nix/store/bh57lav832l2a3j98c8qwhpmx3k2gziq-source/hosts/nas/another-service.nix
```

Sometimes multiple services are defined in the same file. Currently a list of multiple ports is treated as an unique value. To fix this we have to expand entries with multiple ports into individual port entries:
```nix
expanded = lib.flatten (
  map (
    entry:
    map (port: {
      file = entry.file;
      port = port;
    }) entry.value
  ) options.homelab.ports.definitionsWithLocations
);
```
Assuming we have the following data structure:
```nix
[
  {
    file = "/nix/store/bh57lav832l2a3j98c8qwhpmx3k2gziq-source/hosts/nas/monitoring.nix";
    value = [
      9090
      9100
    ];
  }
]
```
It would result in:
```nix
[
  {
    file = "/nix/store/bh57lav832l2a3j98c8qwhpmx3k2gziq-source/hosts/nas/monitoring.nix";
    port = 9090;
  }
  {
    file = "/nix/store/bh57lav832l2a3j98c8qwhpmx3k2gziq-source/hosts/nas/monitoring.nix";
    port = 9100;
  }
]
```
In the final solution below I used `lib.concatMap`, which removes the need to flatten the result.


## Solution

The solution below uses `lib.pipe` which expects the input variable and a list of functions. The result of one function is passed to the next function. It basically does the exact same thing as above, but I find it cleaner.

Add the following to a file (e.g. `port-conflicts.nix`) and import it in your configuration:
```nix
{
  lib,
  options,
  ...
}:
let
  duplicatePorts = lib.pipe options.homelab.ports.definitionsWithLocations [
    # Expand entries with multiple ports into individual port entries
    (lib.concatMap (
      entry:
      map (port: {
        file = entry.file;
        port = port;
      }) entry.value
    ))
    (lib.groupBy (entry: toString entry.port))
    (lib.filterAttrs (port: entries: builtins.length entries > 1))
    (lib.mapAttrsToList (
      port: entries:
      "Duplicate port ${port} found in:\n" + lib.concatMapStrings (entry: "  - ${entry.file}\n") entries
    ))
    (lib.concatStrings)
  ];
in
{
  options = {
    homelab.ports = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [ ];
      description = "List of allocated port numbers";
    };
  };
  config = {
    assertions = [
      {
        assertion = duplicatePorts == "";
        message = duplicatePorts;
      }
    ];
  };
}
```

Now create another file for every service (e.g. `open-webui.nix`) and define the ports. You may have multiple ports in the same file, but the error message is only at the file granularity and does not include line numbers.
```nix
homelab.ports = [ config.services.open-webui.port ]
```

If you add another service that uses the same port, you should correctly receive an error while deploying:
```nix
error:
Failed assertions:
- Duplicate port 8080 found in:
  - /nix/store/bh57lav832l2a3j98c8qwhpmx3k2gziq-source/hosts/nas/open-webui.nix
  - /nix/store/bh57lav832l2a3j98c8qwhpmx3k2gziq-source/hosts/nas/another-service.nix
```

Update: I [posted a link to this post on Discourse](https://discourse.nixos.org/t/detect-port-conflicts-in-nixos-services/61589), which got some attention, with some people suggesting upstreaming to nixpkgs, while others mentioned previous work that was never finished.
