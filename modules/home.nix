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
    in
    {
      inherit
        account
        enabledProfiles
        files
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

  makeEtcEntries =
    _: resolved:
    mapAttrs' (
      target: source:
      nameValuePair "home-files/${resolved.account.name}/${target}" { inherit source; }
    ) resolved.files;

  etcEntries = foldl' (entries: userEntries: entries // userEntries) { } (
    mapAttrsToList makeEtcEntries resolvedUsers
  );

  makeTmpfilesSettings =
    _: resolved:
    let
      inherit (resolved) account files;
      home = toString account.home;
      owner = account.name;
      parents = unique (concatMap parentTargets (attrNames files));

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

    # tmpfiles only creates links, so links that left the config are removed here: the rules of
    # the previous generation (still `/run/current-system` during activation) are compared with
    # the new ones by path. A link goes only while it still points to its old target, a parent
    # only when empty, both as the user. At boot there is no previous generation to compare.
    system.activationScripts.homeFilesCleanup = {
      deps = [ "users" ];
      text = ''
        homeFilesRules() {
          # Prints `<type> <path>\t<target>` of the `L` and `d` rules; paths contain no quotes or tabs.
          local line rest
          [ -f "$1" ] || return 0
          while IFS= read -r line; do
            case $line in
              "'L' '"* | "'d' '"*) ;;
              *) continue ;;
            esac
            rest=''${line:5}
            printf '%s %s\t%s\n' "''${line:1:1}" "''${rest%%\'*}" "''${line##*\'-\' }"
          done <"$1"
        }

        homeFilesCleanup() {
          local oldRules=$1 user=$2 newEntries type path target
          newEntries=$(homeFilesRules "$systemConfig/etc/tmpfiles.d/''${oldRules##*/}" | cut -f1)
          # Links first, then parents from the deepest.
          homeFilesRules "$oldRules" | LC_ALL=C sort -k1,1 -k2r | while IFS=$'\t' read -r type target; do
            path=''${type#? }
            type=''${type%% *}
            grep -qxF -- "$type $path" <<<"$newEntries" && continue
            if [ "$type" = L ]; then
              [ "$(readlink -- "$path")" = "$target" ] && runuser -u "$user" -- rm -f -- "$path"
            else
              runuser -u "$user" -- rmdir --ignore-fail-on-non-empty -- "$path" 2>/dev/null
            fi
          done
        }

        for oldRules in /run/current-system/etc/tmpfiles.d/10-home-files-*.conf; do
          [ -f "$oldRules" ] || continue
          user=''${oldRules##*/10-home-files-}
          user=''${user%.conf}
          id -- "$user" >/dev/null 2>&1 && homeFilesCleanup "$oldRules" "$user" || true
        done
      '';
    };
  };
}
