_:

{ lib, config, ... }:

let
  inherit (builtins) attrNames;
  inherit (lib)
    all
    any
    attrValues
    concatLists
    concatMap
    concatStringsSep
    filter
    filterAttrs
    foldl'
    hasAttr
    hasInfix
    hasPrefix
    head
    length
    listToAttrs
    mapAttrs
    mapAttrs'
    mapAttrsToList
    mkOption
    nameValuePair
    sort
    splitString
    tail
    types
    unique
    ;

  fileType = types.either types.path (types.attrsOf fileType);

  profileType = types.submodule {
    options.files = mkOption {
      type = types.attrsOf fileType;
      default = { };
      description = "Home-relative targets mapped to public, store-backed source files or directories. Nested attribute sets group targets under a shared prefix. Do not use for secrets.";
    };
  };

  cfg = config.ozozka.home;

  # Keep declarations as a list until collision checks have seen every target.
  # Check for paths first because derivations are also attribute sets.
  flattenFiles =
    prefix: files:
    concatLists (
      mapAttrsToList (
        name: value:
        let
          components = prefix ++ [ name ];
          target = concatStringsSep "/" components;
        in
        if types.path.check value then
          [
            {
              inherit target;
              source = value;
            }
          ]
        else
          flattenFiles components value
      ) files
    );

  isSafeTmpfilesValue =
    value:
    all (character: !hasInfix character (toString value)) [
      "'"
      "%"
      "\\"
      "\n"
      "\r"
      "\t"
    ];

  isValidTarget =
    target:
    let
      components = splitString "/" target;
    in
    target != ""
    && !hasPrefix "/" target
    && all (component: component != "" && component != "." && component != "..") components
    && isSafeTmpfilesValue target;

  duplicateValues =
    values:
    unique (filter (value: length (filter (candidate: candidate == value) values) > 1) values);

  ancestorConflicts =
    targets:
    unique (
      concatMap (
        ancestor:
        map (descendant: "${ancestor} -> ${descendant}") (
          filter (descendant: descendant != ancestor && hasPrefix "${ancestor}/" descendant) targets
        )
      ) targets
    );

  parentTargets =
    target:
    let
      go =
        prefix: components:
        if length components <= 1 then
          [ ]
        else
          let
            next = if prefix == "" then head components else "${prefix}/${head components}";
          in
          [ next ] ++ go next (tail components);
    in
    go "" (splitString "/" target);

  resolveProfile =
    profileName: profile:
    let
      declarations = flattenFiles [ ] profile.files;
      targets = map (file: file.target) declarations;
      validDeclarations = filter (file: isValidTarget file.target) declarations;
      duplicates = duplicateValues targets;
      fileAssertions = map (file: {
        assertion = isValidTarget file.target;
        message = "home profile '${profileName}' has invalid target '${file.target}'. Targets must be safe relative paths without empty, '.' or '..' components.";
      }) declarations;
      duplicateAssertion = {
        assertion = duplicates == [ ];
        message = "Home profile '${profileName}' contains duplicate targets after flattening: ${toString duplicates}.";
      };
    in
    {
      inherit
        declarations
        targets
        validDeclarations
        fileAssertions
        duplicateAssertion
        ;
    };

  resolvedProfiles = mapAttrs resolveProfile cfg.profiles;

  enabledProfileNames = activations: attrNames (filterAttrs (_: enabled: enabled) activations);

  configuredUsers = filterAttrs (
    userName: activations:
    hasAttr userName config.users.users && any (enabled: enabled) (attrValues activations)
  ) cfg.users;

  resolveUser =
    userName: activations:
    let
      account = config.users.users.${userName};
      enabledProfiles = enabledProfileNames activations;
      knownProfiles = filter (profileName: hasAttr profileName cfg.profiles) enabledProfiles;
      profiles = map (profileName: resolvedProfiles.${profileName}) knownProfiles;
      targets = concatMap (profile: profile.targets) profiles;
      files = listToAttrs (
        map (file: nameValuePair file.target file.source) (
          concatMap (profile: profile.validDeclarations) profiles
        )
      );
      parents = unique (concatMap parentTargets (attrNames files));
    in
    {
      inherit
        account
        enabledProfiles
        files
        parents
        targets
        ;
    };

  resolvedUsers = mapAttrs resolveUser configuredUsers;

  fileAssertions = concatMap (profile: profile.fileAssertions) (attrValues resolvedProfiles);

  profileAssertions = map (profile: profile.duplicateAssertion) (attrValues resolvedProfiles);

  userReferenceAssertions = mapAttrsToList (userName: _: {
    assertion = hasAttr userName config.users.users;
    message = "Home configuration references unknown NixOS user '${userName}'.";
  }) cfg.users;

  resolvedUserAssertions = concatLists (
    mapAttrsToList (
      userName: resolved:
      let
        inherit (resolved) account enabledProfiles targets;
        unknownProfiles = filter (profileName: !hasAttr profileName cfg.profiles) enabledProfiles;
        duplicates = duplicateValues targets;
        conflicts = ancestorConflicts targets;
      in
      [
        {
          assertion = account.enable;
          message = "Home configuration for '${userName}' requires the NixOS user to be enabled.";
        }
        {
          assertion = account.isNormalUser;
          message = "Home configuration for '${userName}' is only supported for normal NixOS users.";
        }
        {
          assertion = account.createHome;
          message = "Home configuration for '${userName}' requires users.users.${userName}.createHome to be enabled.";
        }
        {
          assertion = isSafeTmpfilesValue account.home;
          message = "Home directory '${toString account.home}' for '${userName}' contains characters unsupported by this home manager.";
        }
        {
          assertion = unknownProfiles == [ ];
          message = "Home configuration for '${userName}' enables unknown profiles: ${toString unknownProfiles}.";
        }
        {
          assertion = duplicates == [ ];
          message = "Home configuration for '${userName}' contains duplicate targets: ${toString duplicates}.";
        }
        {
          assertion = conflicts == [ ];
          message = "Home configuration for '${userName}' contains parent/child target conflicts: ${toString conflicts}.";
        }
      ]
    ) resolvedUsers
  );

  resolvedHomes = mapAttrsToList (_: resolved: toString resolved.account.home) resolvedUsers;
  resolvedOwners = mapAttrsToList (_: resolved: resolved.account.name) resolvedUsers;
  duplicateHomes = duplicateValues resolvedHomes;
  overlappingHomes = ancestorConflicts resolvedHomes;
  duplicateOwners = duplicateValues resolvedOwners;

  crossUserAssertions = [
    {
      assertion = duplicateHomes == [ ];
      message = "Home configuration contains users with duplicate home directories: ${toString duplicateHomes}.";
    }
    {
      assertion = overlappingHomes == [ ];
      message = "Home configuration contains overlapping home directories: ${toString overlappingHomes}.";
    }
    {
      assertion = duplicateOwners == [ ];
      message = "Home configuration contains duplicate effective user names: ${toString duplicateOwners}.";
    }
  ];

  # What home.nix manages for a user, read by the activation cleanup: tab-separated `L <path>
  # <link target>` lines, then `d <path>` lines from the deepest folder, the order of removal.
  makeManifest =
    resolved:
    let
      inherit (resolved) account files parents;
      home = toString account.home;
      links = map (target: "L\t${home}/${target}\t/etc/home-files/${account.name}/${target}") (
        attrNames files
      );
      folders = map (parent: "d\t${home}/${parent}") (sort (a: b: a > b) parents);
    in
    concatStringsSep "\n" (links ++ folders) + "\n";

  makeEtcEntries =
    _: resolved:
    mapAttrs' (
      target: source:
      nameValuePair "home-files/${resolved.account.name}/${target}" { inherit source; }
    ) resolved.files
    // {
      "home-files/.${resolved.account.name}.manifest".text = makeManifest resolved;
    };

  etcEntries = foldl' (entries: userEntries: entries // userEntries) { } (
    mapAttrsToList makeEtcEntries resolvedUsers
  );

  makeTmpfilesSettings =
    _: resolved:
    let
      inherit (resolved) account files parents;
      home = toString account.home;
      owner = account.name;

      parentRules = listToAttrs (
        map (
          parent:
          nameValuePair "${home}/${parent}" {
            d = {
              mode = ":0755";
              user = ":${owner}";
              group = ":${account.group}";
            };
          }
        ) parents
      );

      linkRules = mapAttrs' (
        target: _:
        nameValuePair "${home}/${target}" {
          L = {
            user = ":${owner}";
            group = ":${account.group}";
            argument = "/etc/home-files/${owner}/${target}";
          };
        }
      ) files;
    in
    nameValuePair "10-home-files-${owner}" (parentRules // linkRules);

  tmpfilesSettings = listToAttrs (mapAttrsToList makeTmpfilesSettings resolvedUsers);
in
{
  options.ozozka.home = {
    profiles = mkOption {
      type = types.attrsOf profileType;
      default = { };
      description = "Reusable home configuration profiles.";
    };

    users = mkOption {
      type = types.attrsOf (types.attrsOf types.bool);
      default = { };
      description = "Home profiles enabled for each NixOS user.";
    };
  };

  config = {
    assertions =
      fileAssertions
      ++ profileAssertions
      ++ userReferenceAssertions
      ++ resolvedUserAssertions
      ++ crossUserAssertions;
    environment.etc = etcEntries;
    systemd.tmpfiles.settings = tmpfilesSettings;

    # tmpfiles only creates links, so links that left the config are removed here: the previous
    # generation's manifest (still under `/run/current-system` during activation) is compared with
    # the new one. A link goes only while it still points to its old target, a folder only when
    # empty, both as the user. At boot there is no previous generation, so only warnings run.
    system.activationScripts.homeFiles = {
      deps = [ "users" ];
      text = ''
        homeFilesCleanup() {
          local user=$1 new=$2 type path target
          # Old entries missing from the new manifest, in its order: links before their folders.
          grep -vxFf "$new" "$3" | while IFS=$'\t' read -r type path target; do
            case $type in
              L) [ "$(readlink -- "$path")" = "$target" ] && runuser -u "$user" -- rm -f -- "$path" ;;
              d) [ -d "$path" ] && runuser -u "$user" -- rmdir -- "$path" 2>/dev/null ;;
            esac && echo "home-files: removed $path"
          done
        }

        for old in /run/current-system/etc/home-files/.*.manifest; do
          [ -f "$old" ] || continue
          new=$systemConfig/etc/home-files/''${old##*/}
          [ -f "$new" ] || new=/dev/null
          user=''${old##*/.}
          user=''${user%.manifest}
          id -- "$user" >/dev/null 2>&1 && homeFilesCleanup "$user" "$new" "$old" || true
        done

        # tmpfiles skips targets that already exist, so the config would silently not apply.
        for new in "$systemConfig"/etc/home-files/.*.manifest; do
          [ -f "$new" ] || continue
          while IFS=$'\t' read -r type path target; do
            [ "$type" = L ] || continue
            if [ -e "$path" ] || [ -L "$path" ]; then
              [ "$(readlink -- "$path")" = "$target" ] || echo "home-files: $path is occupied, not linked" >&2
            fi
          done <"$new"
        done
      '';
    };
  };
}
